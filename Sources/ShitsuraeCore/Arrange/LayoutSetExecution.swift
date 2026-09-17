import Foundation

public extension VirtualSpaceEngine {
    package func arrangeSetDryRun(
        setName: String,
        requestID: String,
        config: LoadedConfig,
        token: ArrangeOperationToken
    ) throws -> LayoutSetDryRunJSON {
        try validateMutationAdmission(token: token)
        guard currentState.pendingLayoutTransition == nil else {
            throw ShitsuraeError(
                .operationBlocked,
                "window recovery is required before planning another operation",
                subcode: "recoveryRequired"
            )
        }
        let observation = control.focusedWindowObservation()
        let windows = observation.inventory.isAuthoritative
            ? WindowEligibility.geometryCandidates(in: observation)
            : nil
        let plan: LayoutSetPlan
        do {
            plan = try LayoutSetPlanner.build(
                setName: setName,
                config: config.config,
                state: currentState,
                displays: control.displays(),
                currentWindows: windows
            )
        } catch {
            throw Self.mapLayoutSetPlanError(error)
        }
        return LayoutSetDryRunJSON(requestID: requestID, plan: plan)
    }

    package func arrangeSet(
        setName: String,
        requestID: String,
        config: LoadedConfig,
        token: ArrangeOperationToken
    ) throws -> LayoutSetExecutionJSON {
        try validateMutationAdmission(token: token)
        let started = DispatchTime.now().uptimeNanoseconds
        func elapsedMS() -> Int {
            Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        func timedOut(
            phase: ArrangeOperationPhase,
            committed: Bool,
            members: [LayoutSetMemberResult],
            releasedCount: Int = 0,
            transferredCount: Int = 0
        ) -> LayoutSetExecutionJSON {
            let interruption = operationCoordinator.interruptionError(token: token)
            return LayoutSetExecutionJSON(
                requestID: requestID,
                setName: setName,
                result: "failed",
                phase: phase.rawValue,
                ownershipCommitted: committed,
                selectedSet: committed ? setName : currentState.selectedLayoutSet?.name,
                memberResults: members,
                releasedCount: releasedCount,
                transferredCount: transferredCount,
                unresolved: [PendingUnresolvedSlot(
                    slot: 0,
                    spaceID: 0,
                    reason: interruption?.subcode ?? "deadlineExceeded"
                )],
                warnings: interruption.map { [WarningItem(code: $0.subcode ?? "operationInterrupted", detail: $0.message)] } ?? [],
                focusOutcome: "notAttempted",
                recoveryRequired: currentState.pendingLayoutTransition != nil,
                elapsedMS: elapsedMS(),
                exitCode: interruption?.code.rawValue ?? ErrorCode.operationTimedOut.rawValue
            )
        }

        func closeSafePrecommitJournalAfterInvalidation() throws {
            // No AX mutation has started in launch/wait. Generation changes
            // can close this journal safely; a real expired deadline must not
            // start a finalize save.
            guard operationCoordinator.interruptionError(token: token)?.code == .operationBlocked else { return }
            var safe = currentState
            safe.pendingLayoutTransition = nil
            try replaceState(safe, allowsInvalidatedJournalCleanup: true)
        }

        operationCoordinator.update(token: token, phase: .preflight)
        guard currentState.pendingLayoutTransition == nil else {
            operationCoordinator.updateJournalMirror(state: currentState)
            throw ShitsuraeError(
                .operationBlocked,
                "window recovery is required before applying a layout set",
                subcode: "recoveryRequired"
            )
        }
        guard control.accessibilityGranted() else {
            throw ShitsuraeError(.missingPermission, "Accessibility permission is required")
        }

        let preflightObservation = control.focusedWindowObservation()
        guard preflightObservation.inventory.isAuthoritative else {
            throw ShitsuraeError(
                .backendUnavailable,
                "authoritative window inventory is unavailable",
                subcode: "windowInventoryUnavailable"
            )
        }
        let plan: LayoutSetPlan
        do {
            plan = try LayoutSetPlanner.build(
                setName: setName,
                config: config.config,
                state: currentState,
                displays: control.displays(),
                currentWindows: WindowEligibility.geometryCandidates(in: preflightObservation)
            )
        } catch {
            throw Self.mapLayoutSetPlanError(error)
        }
        let focusBeforeOperation = preflightObservation.focusedIdentity
        let sourceLayoutNames = Set(plan.sourceLayoutNames)
        let sourceBoundIdentities = Set(
            currentState.slots
                .filter { sourceLayoutNames.contains($0.layoutName) }
                .compactMap(\.boundIdentity)
        )
        let initialMemberResults = plan.members.map {
            LayoutSetMemberResult(
                layout: $0.layoutName,
                resolvedDisplayID: $0.resolvedDisplayID,
                targetSpace: $0.targetSpaceID,
                result: "pending"
            )
        }
        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(phase: .preflight, committed: false, members: initialMemberResults)
        }

        let targetSet = SelectedLayoutSet(
            name: setName,
            memberNames: plan.memberNames,
            definitionDigest: plan.definitionDigest
        )
        var journaled = currentState
        journaled.pendingLayoutTransition = PendingLayoutTransition(
            requestID: requestID,
            scopeKind: .layoutSet,
            phase: .precommit,
            sourceLayoutNames: plan.sourceLayoutNames,
            targetLayoutNames: plan.memberNames,
            sourceSelectedSet: currentState.selectedLayoutSet,
            targetSet: targetSet,
            definitionDigest: plan.definitionDigest,
            topologyDigest: plan.topologyDigest
        )
        try replaceState(journaled)
        try reachTransitionCheckpoint(.journalPersisted)
        operationCoordinator.update(token: token, phase: .journaled)

        let targetRecords = Self.makeTargetRecords(plan: plan, config: config, state: currentState)
        let launchRequests = Set(targetRecords.compactMap { record -> ApplicationLaunchRequest? in
            guard record.definition.launch ?? true else { return nil }
            return ApplicationLaunchRequest(
                bundleID: record.definition.match.bundleID,
                profileDirectory: record.definition.match.profile
            )
        })
        for request in launchRequests {
            guard operationCoordinator.permitsNewSideEffect(token: token) else {
                try closeSafePrecommitJournalAfterInvalidation()
                return timedOut(phase: .waitingForWindows, committed: false, members: initialMemberResults)
            }
            operationCoordinator.update(
                token: token,
                phase: .waitingForWindows,
                waitingReason: "launchingApplication",
                inFlight: true
            )
            _ = control.launchApplication(request: request)
            operationCoordinator.update(
                token: token,
                phase: .waitingForWindows,
                waitingReason: "waitingForWindows"
            )
        }

        operationCoordinator.update(
            token: token,
            phase: .waitingForWindows,
            waitingReason: "waitingForWindows"
        )
        let assignment = resolveSetTargets(
            records: targetRecords,
            config: config,
            token: token
        )
        let assignments = assignment.resolution.assignments

        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            try closeSafePrecommitJournalAfterInvalidation()
            return timedOut(phase: .waitingForWindows, committed: false, members: initialMemberResults)
        }
        try reachTransitionCheckpoint(.launchWaitFinished)
        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            try closeSafePrecommitJournalAfterInvalidation()
            return timedOut(phase: .waitingForWindows, committed: false, members: initialMemberResults)
        }

        let recordsByEntryID = Dictionary(uniqueKeysWithValues: targetRecords.map { ($0.entry.id, $0) })
        let candidateConflicts = assignment.resolution.unresolved.filter {
            assignment.resolution.unresolvedReasons[$0] == .candidateConflict
        }
        if !candidateConflicts.isEmpty {
            var safeToClose = currentState
            safeToClose.pendingLayoutTransition = nil
            try replaceState(safeToClose)
            let unresolved = candidateConflicts.compactMap { entryID -> PendingUnresolvedSlot? in
                guard let record = recordsByEntryID[entryID] else { return nil }
                return PendingUnresolvedSlot(
                    slot: record.definition.slot,
                    spaceID: record.spaceID,
                    reason: "candidateConflict"
                )
            }
            return LayoutSetExecutionJSON(
                requestID: requestID,
                setName: setName,
                result: "failed",
                phase: ArrangeOperationPhase.waitingForWindows.rawValue,
                ownershipCommitted: false,
                selectedSet: currentState.selectedLayoutSet?.name,
                memberResults: initialMemberResults,
                releasedCount: 0,
                transferredCount: 0,
                unresolved: unresolved,
                warnings: [],
                focusOutcome: "notAttempted",
                recoveryRequired: false,
                elapsedMS: elapsedMS(),
                exitCode: ErrorCode.validationError.rawValue
            )
        }

        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(phase: .waitingForWindows, committed: false, members: initialMemberResults)
        }

        operationCoordinator.update(token: token, phase: .releasing)
        let assignedIdentities = Set(assignments.values.map(\.identity))
        let releaseResult = try restoreAndReleaseSourceWindows(
            sourceLayoutNames: Set(plan.sourceLayoutNames),
            retiringLayoutNames: Set(plan.retiringLayoutNames),
            transferredIdentities: assignedIdentities,
            token: token
        )
        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(
                phase: .releasing,
                committed: false,
                members: initialMemberResults,
                releasedCount: releaseResult.releasedIdentities.count,
                transferredCount: assignedIdentities.count
            )
        }
        guard releaseResult.unresolvedEntryIDs.isEmpty else {
            return LayoutSetExecutionJSON(
                requestID: requestID,
                setName: setName,
                result: "failed",
                phase: ArrangeOperationPhase.releasing.rawValue,
                ownershipCommitted: false,
                selectedSet: currentState.selectedLayoutSet?.name,
                memberResults: initialMemberResults,
                releasedCount: releaseResult.releasedIdentities.count,
                transferredCount: assignedIdentities.count,
                unresolved: releaseResult.unresolvedEntryIDs.map {
                    PendingUnresolvedSlot(slot: 0, spaceID: 0, reason: "releaseIncomplete:\($0)")
                },
                warnings: [],
                focusOutcome: "notAttempted",
                recoveryRequired: true,
                elapsedMS: elapsedMS(),
                exitCode: ErrorCode.partialSuccess.rawValue
            )
        }
        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(
                phase: .releasing,
                committed: false,
                members: initialMemberResults,
                releasedCount: releaseResult.releasedIdentities.count,
                transferredCount: assignedIdentities.count
            )
        }

        var committed = currentState
        let sourceNames = Set(plan.sourceLayoutNames)
        let retainedAdopted = plan.members.map { member in
            RetainedAdoptedWindows.retain(committed.slots.filter { $0.layoutName == member.layoutName },
                layout: config.config.layouts[member.layoutName]!, targetSpaceID: member.targetSpaceID,
                claimed: assignedIdentities, observation: WindowObservation(inventory: assignment.inventory,
                    focusedIdentity: nil, mainIdentity: nil))
        }
        committed.slots.removeAll { sourceNames.contains($0.layoutName) }
        committed.activeWorkspaces.removeAll()
        committed.pendingVisibilityConvergences.removeAll { sourceNames.contains($0.layoutName) }
        committed.releasedWindowIdentities.formUnion(releaseResult.releasedIdentities)
        committed.releasedWindowIdentities.subtract(assignedIdentities)
        if assignment.inventory.isAuthoritative {
            committed.releasedWindowIdentities = Set(
                committed.releasedWindowIdentities.filter { assignment.inventory.mayContain($0) }
            )
        }

        let ignoredFingerprints = Set(plan.members.flatMap { $0.arrangePlan.ignoredDefinitionFingerprints })
        for record in targetRecords where !ignoredFingerprints.contains(record.fingerprint) {
            var entry = record.entry
            if let window = assignments[entry.id] {
                entry = entry.bound(to: window)
                entry.spaceID = record.spaceID
                entry.visibilityState = .visible
                entry.lastHiddenFrame = nil
                entry.lastVisibleFrame = record.frame ?? window.frame
            }
            committed.slots.append(entry)
        }
        committed.slots.append(contentsOf: retainedAdopted.flatMap(\.entries))
        for member in plan.members {
            committed.upsertActiveWorkspace(
                displayID: member.resolvedDisplayID,
                layoutName: member.layoutName,
                spaceID: member.targetSpaceID,
                appliedDefinitionDigest: ConfigDigest.workspace(layoutName: member.layoutName, config: config.config)
            )
        }
        committed.selectedLayoutSet = targetSet
        committed.configGeneration = config.configGeneration
        committed.pendingLayoutTransition?.phase = .postcommit
        committed.liveArrangeRecoveryRequired = false
        try replaceState(committed)
        try reachTransitionCheckpoint(.ownershipCommitted)
        operationCoordinator.update(token: token, phase: .ownershipCommitted)

        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(
                phase: .ownershipCommitted,
                committed: true,
                members: initialMemberResults,
                releasedCount: releaseResult.releasedIdentities.count,
                transferredCount: assignedIdentities.count
            )
        }

        operationCoordinator.update(token: token, phase: .placing)
        let unverifiedAdopted = retainedAdopted.flatMap(\.unverified)
        var unresolved = unverifiedAdopted.map {
            PendingUnresolvedSlot(slot: $0.entry.slot, spaceID: $0.entry.spaceID, reason: $0.reason)
        }
        var failedLayouts = Set(unverifiedAdopted.map { $0.entry.layoutName })
        var physicalStateUnverified = !unverifiedAdopted.isEmpty
        for record in targetRecords where !ignoredFingerprints.contains(record.fingerprint) {
            guard let window = assignments[record.entry.id] else {
                let reason = Self.unresolvedReasonString(
                    assignment.resolution.unresolvedReasons[record.entry.id]
                )
                unresolved.append(
                    PendingUnresolvedSlot(slot: record.definition.slot, spaceID: record.spaceID, reason: reason)
                )
                failedLayouts.insert(record.layoutName)
                continue
            }
            guard let frame = record.frame else { continue }
            guard operationCoordinator.permitsNewSideEffect(token: token) else {
                return timedOut(
                    phase: .placing,
                    committed: true,
                    members: initialMemberResults,
                    releasedCount: releaseResult.releasedIdentities.count,
                    transferredCount: assignedIdentities.count
                )
            }
            operationCoordinator.update(
                token: token,
                phase: .placing,
                layout: record.layoutName,
                space: record.spaceID,
                slot: record.definition.slot,
                inFlight: true
            )
            let frameOutcome = control.setWindowFrame(
                windowID: window.windowID,
                pid: window.pid,
                processStartTime: window.processStartTime,
                bundleID: window.bundleID,
                frame: frame
            )
            operationCoordinator.update(
                token: token,
                phase: .placing,
                layout: record.layoutName,
                space: record.spaceID,
                slot: record.definition.slot
            )
            if !frameOutcome.isApplied {
                physicalStateUnverified = true
                unresolved.append(
                    PendingUnresolvedSlot(
                        slot: record.definition.slot,
                        spaceID: record.spaceID,
                        reason: "frameDidNotConverge"
                    )
                )
                failedLayouts.insert(record.layoutName)
            }
        }

        operationCoordinator.update(token: token, phase: .visibility)
        let primaryDisplayID = DisplayResolver.primaryDisplay(control.displays())?.id
        let primaryMember = primaryDisplayID.flatMap { primaryID in
            plan.members.first(where: { $0.resolvedDisplayID == primaryID })
        }
        let operationControlledIdentities = sourceBoundIdentities.union(assignedIdentities)
        func userOverrodeFocus() -> Bool {
            guard let live = control.frontmostWindowIdentity(),
                  live != focusBeforeOperation
            else {
                return false
            }
            return !operationControlledIdentities.contains(live)
        }
        var primarySwitchOutcome: SpaceSwitchOutcome?
        let visibilityMembers = plan.members.filter { $0.layoutName != primaryMember?.layoutName }
            + plan.members.filter { $0.layoutName == primaryMember?.layoutName }
        for member in visibilityMembers {
            guard operationCoordinator.permitsNewSideEffect(token: token) else {
                return timedOut(
                    phase: .visibility,
                    committed: true,
                    members: initialMemberResults,
                    releasedCount: releaseResult.releasedIdentities.count,
                    transferredCount: assignedIdentities.count
                )
            }
            do {
                operationCoordinator.update(
                    token: token,
                    phase: .visibility,
                    layout: member.layoutName,
                    space: member.targetSpaceID,
                    inFlight: true
                )
                let isPrimaryMember = member.layoutName == primaryMember?.layoutName
                let primaryHasExplicitFocus = isPrimaryMember
                    && config.config.layouts[member.layoutName]?.initialFocus != nil
                let outcome = try switchSpace(
                    layoutName: member.layoutName,
                    to: member.targetSpaceID,
                    config: config,
                    reconcile: true,
                    adoptionIgnoreRules: config.config.ignore?.apply,
                    shouldFocusTarget: isPrimaryMember
                        && !primaryHasExplicitFocus
                        && !userOverrodeFocus(),
                    allowLayoutTransition: true,
                    token: token
                )
                if isPrimaryMember {
                    primarySwitchOutcome = outcome
                }
                operationCoordinator.update(
                    token: token,
                    phase: .visibility,
                    layout: member.layoutName,
                    space: member.targetSpaceID
                )
                unresolved.append(contentsOf: outcome.unresolvedSlots)
                physicalStateUnverified = physicalStateUnverified || outcome.physicalStateUnverified
                if !outcome.converged || !outcome.unresolvedSlots.isEmpty {
                    failedLayouts.insert(member.layoutName)
                }
            } catch let error as LayoutTransitionCheckpointFailure {
                throw error
            } catch let error as ShitsuraeError where error.code == .operationTimedOut || error.subcode == "operationInvalidated" {
                return timedOut(
                    phase: .visibility,
                    committed: true,
                    members: initialMemberResults,
                    releasedCount: releaseResult.releasedIdentities.count,
                    transferredCount: assignedIdentities.count
                )
            } catch let error as VirtualSpaceEngineError {
                if case .persistenceFailed = error {
                    throw error
                }
                failedLayouts.insert(member.layoutName)
                physicalStateUnverified = true
                unresolved.append(
                    PendingUnresolvedSlot(slot: 0, spaceID: member.targetSpaceID, reason: "visibilityFailed")
                )
            } catch {
                failedLayouts.insert(member.layoutName)
                physicalStateUnverified = true
                unresolved.append(
                    PendingUnresolvedSlot(slot: 0, spaceID: member.targetSpaceID, reason: "visibilityFailed")
                )
            }
        }

        operationCoordinator.update(token: token, phase: .focusing)
        var focusOutcome = primaryMember == nil ? "preserved" : "notRequested"
        var successfullyFocusedIdentity: WindowIdentity?
        if userOverrodeFocus() {
            focusOutcome = "userOverridden"
        } else if let primaryMember,
                  let layout = config.config.layouts[primaryMember.layoutName],
                  let focusSlot = layout.initialFocus?.slot
        {
            let focusDefinition = layout.spaces
                .first(where: { $0.spaceID == primaryMember.targetSpaceID })?
                .windows.first(where: { $0.slot == focusSlot })
            let focusFingerprint = focusDefinition.map {
                SlotEntry.fingerprint(
                    layoutName: primaryMember.layoutName,
                    spaceID: primaryMember.targetSpaceID,
                    definition: $0
                )
            }
            if let focusFingerprint, ignoredFingerprints.contains(focusFingerprint) {
                focusOutcome = "unavailable"
                failedLayouts.insert(primaryMember.layoutName)
                unresolved.append(
                    PendingUnresolvedSlot(
                        slot: focusSlot,
                        spaceID: primaryMember.targetSpaceID,
                        reason: "initialFocusIgnored"
                    )
                )
            } else if let entry = currentState.slots(layoutName: primaryMember.layoutName).first(where: {
                $0.spaceID == primaryMember.targetSpaceID && $0.slot == focusSlot
            }), let identity = entry.boundIdentity,
               let window = assignment.inventory.windows.first(where: { $0.identity == identity })
            {
                do {
                    operationCoordinator.update(
                        token: token,
                        phase: .focusing,
                        layout: primaryMember.layoutName,
                        space: primaryMember.targetSpaceID,
                        slot: focusSlot,
                        inFlight: true
                    )
                    try applyFocus(window: window, token: token)
                    operationCoordinator.update(
                        token: token,
                        phase: .focusing,
                        layout: primaryMember.layoutName,
                        space: primaryMember.targetSpaceID,
                        slot: focusSlot
                    )
                    focusOutcome = "focused"
                    successfullyFocusedIdentity = window.identity
                } catch let error as ShitsuraeError where error.code == .operationTimedOut || error.subcode == "operationInvalidated" {
                    return timedOut(
                        phase: .focusing,
                        committed: true,
                        members: initialMemberResults,
                        releasedCount: releaseResult.releasedIdentities.count,
                        transferredCount: assignedIdentities.count
                    )
                } catch {
                    focusOutcome = "failed"
                    failedLayouts.insert(primaryMember.layoutName)
                }
            } else {
                focusOutcome = "unavailable"
                failedLayouts.insert(primaryMember.layoutName)
            }
        } else if let primaryMember,
                  config.config.layouts[primaryMember.layoutName]?.initialFocus == nil
        {
            let hasFocusCandidate = currentState.slots(layoutName: primaryMember.layoutName).contains {
                $0.spaceID == primaryMember.targetSpaceID && $0.boundIdentity != nil
            }
            if primarySwitchOutcome?.focusedWindowID != nil {
                focusOutcome = "focused"
            } else if hasFocusCandidate {
                focusOutcome = "failed"
                failedLayouts.insert(primaryMember.layoutName)
            } else {
                focusOutcome = "notRequested"
            }
        }

        let isPartial = !unresolved.isEmpty || !failedLayouts.isEmpty || physicalStateUnverified
        let memberResults = plan.members.map { member in
            LayoutSetMemberResult(
                layout: member.layoutName,
                resolvedDisplayID: member.resolvedDisplayID,
                targetSpace: member.targetSpaceID,
                result: failedLayouts.contains(member.layoutName) ? "partial" : "success",
                reason: unverifiedAdopted.first { $0.entry.layoutName == member.layoutName }?.reason
                    ?? (failedLayouts.contains(member.layoutName) ? "unresolved" : nil)
            )
        }

        guard operationCoordinator.permitsNewSideEffect(token: token) else {
            return timedOut(
                phase: .finalizing,
                committed: true,
                members: memberResults,
                releasedCount: releaseResult.releasedIdentities.count,
                transferredCount: assignedIdentities.count
            )
        }
        operationCoordinator.update(token: token, phase: .finalizing)
        var finalized = currentState
        if !physicalStateUnverified {
            finalized.pendingLayoutTransition = nil
        }
        if let successfullyFocusedIdentity {
            finalized.slots = finalized.slots.map { entry in
                guard entry.boundIdentity == successfullyFocusedIdentity else { return entry }
                var activated = entry
                activated.lastActivatedAt = Date.rfc3339UTC()
                return activated
            }
        }
        try reachTransitionCheckpoint(.finalSave)
        try replaceState(finalized)

        return LayoutSetExecutionJSON(
            requestID: requestID,
            setName: setName,
            result: isPartial ? "partial" : "success",
            phase: ArrangeOperationPhase.finalizing.rawValue,
            ownershipCommitted: true,
            selectedSet: setName,
            memberResults: memberResults,
            releasedCount: releaseResult.releasedIdentities.count,
            transferredCount: assignedIdentities.count,
            unresolved: unresolved,
            warnings: plan.warnings,
            focusOutcome: focusOutcome,
            recoveryRequired: physicalStateUnverified,
            elapsedMS: elapsedMS(),
            exitCode: isPartial ? ErrorCode.partialSuccess.rawValue : ErrorCode.success.rawValue
        )
    }

    private struct SetTargetRecord {
        let layoutName: String
        let spaceID: Int
        let definition: WindowDefinition
        let fingerprint: String
        let frame: ResolvedFrame?
        let entry: SlotEntry
    }

    private struct SetAssignment {
        let inventory: WindowInventory
        let resolution: WindowRegistry.Resolution
    }

    private struct SetReleaseResult {
        let releasedIdentities: Set<WindowIdentity>
        let unresolvedEntryIDs: [String]
    }

    private static func makeTargetRecords(
        plan: LayoutSetPlan,
        config: LoadedConfig,
        state: RuntimeState
    ) -> [SetTargetRecord] {
        let previous = Dictionary(
            state.slots.filter { $0.origin == .layout }.map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return plan.members.flatMap { member in
            member.arrangePlan.steps.map { step in
                let fingerprint = SlotEntry.fingerprint(
                    layoutName: member.layoutName,
                    spaceID: step.spaceID,
                    definition: step.definition
                )
                var entry = SlotEntry.makeEntry(
                    layoutName: member.layoutName,
                    spaceID: step.spaceID,
                    definition: step.definition
                )
                if let old = previous[fingerprint] {
                    entry.id = old.id
                    entry.pid = old.pid
                    entry.processStartTime = old.processStartTime
                    entry.windowID = old.windowID
                    entry.lastKnownTitle = old.lastKnownTitle
                    entry.displayID = old.displayID
                    entry.lastVisibleFrame = old.lastVisibleFrame
                    entry.lastHiddenFrame = old.lastHiddenFrame
                    entry.visibilityState = old.visibilityState
                    entry.lastActivatedAt = old.lastActivatedAt
                }
                return SetTargetRecord(
                    layoutName: member.layoutName,
                    spaceID: step.spaceID,
                    definition: step.definition,
                    fingerprint: fingerprint,
                    frame: step.resolvedFrame,
                    entry: entry
                )
            }
        }.sorted {
            if $0.layoutName != $1.layoutName { return $0.layoutName < $1.layoutName }
            if $0.spaceID != $1.spaceID { return $0.spaceID < $1.spaceID }
            if $0.definition.slot != $1.definition.slot { return $0.definition.slot < $1.definition.slot }
            return $0.fingerprint < $1.fingerprint
        }
    }

    private func resolveSetTargets(
        records: [SetTargetRecord],
        config: LoadedConfig,
        token: ArrangeOperationToken
    ) -> SetAssignment {
        let localDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(arrangeWaitTimeoutMS) * 1_000_000
        var lastInventory = control.windowInventory()
        var lastResolution = WindowRegistry.resolve(
            entries: records.map(\.entry.registryEntry),
            manageableWindows: [],
            fullInventory: lastInventory
        )
        while operationCoordinator.permitsNewSideEffect(token: token) {
            let inventory = control.windowInventory()
            if inventory.isAuthoritative {
                let manageable = inventory.windows.filter {
                    WindowEligibility.isManageableForVirtualWorkspace($0)
                        && !PolicyEngine.matchesIgnoreRule(window: $0, rules: config.config.ignore?.apply)
                }
                let resolution = WindowRegistry.resolve(
                    entries: records.map(\.entry.registryEntry),
                    manageableWindows: manageable,
                    fullInventory: inventory
                )
                lastInventory = inventory
                lastResolution = resolution
                if resolution.unresolved.isEmpty { break }
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < localDeadline else { break }
            let remainingLocalMS = Int((localDeadline - now) / 1_000_000)
            let remainingMS = min(remainingLocalMS, operationCoordinator.remainingBudgetMS(token: token))
            guard remainingMS > 0 else { break }
            control.sleep(milliseconds: min(100, remainingMS))
        }
        return SetAssignment(inventory: lastInventory, resolution: lastResolution)
    }

    private func restoreAndReleaseSourceWindows(
        sourceLayoutNames: Set<String>,
        retiringLayoutNames: Set<String>,
        transferredIdentities: Set<WindowIdentity>,
        token: ArrangeOperationToken
    ) throws -> SetReleaseResult {
        let entries = currentState.slots.filter { entry in
            guard sourceLayoutNames.contains(entry.layoutName) else { return false }
            return retiringLayoutNames.contains(entry.layoutName)
                || (entry.visibilityState.isManagedHidden
                    && entry.boundIdentity.map(transferredIdentities.contains) == true)
        }
        let retiringIdentities = Set(entries.filter {
            retiringLayoutNames.contains($0.layoutName)
        }.compactMap(\.boundIdentity))
        let restored = try restoreEntriesForTransition(entries, token: token)
        return SetReleaseResult(
            releasedIdentities: restored.live.intersection(retiringIdentities).subtracting(transferredIdentities),
            unresolvedEntryIDs: restored.unresolvedEntryIDs
        )
    }

    private static func unresolvedReasonString(_ reason: WindowRegistry.UnresolvedReason?) -> String {
        switch reason {
        case .reservedExactIdentity: "reservedExactIdentity"
        case .exactOnlyMissing: "exactOnlyMissing"
        case .indexOutOfBounds: "indexOutOfBounds"
        case .candidateConflict: "candidateConflict"
        case .noCandidate, nil: "windowNotFound"
        }
    }

    private static func mapLayoutSetPlanError(_ error: Error) -> ShitsuraeError {
        switch error {
        case let LayoutSetPlanError.setNotFound(name):
            ShitsuraeError(.validationError, "layout set not found: \(name)", subcode: "layoutSetNotFound")
        case let LayoutSetPlanError.memberLayoutNotFound(name):
            ShitsuraeError(.validationError, "layout not found: \(name)", subcode: "layoutNotFound")
        case let LayoutSetPlanError.hostDisplayUnavailable(layout):
            ShitsuraeError(
                .validationError,
                "host display is unavailable for layout \(layout)",
                subcode: "hostDisplayUnavailable"
            )
        case let LayoutSetPlanError.displayCollision(displayID, layouts):
            ShitsuraeError(
                .validationError,
                "layouts \(layouts.joined(separator: ", ")) resolve to the same display \(displayID)",
                subcode: "displayCollision"
            )
        case let LayoutSetPlanError.candidateConflict(layouts, _):
            ShitsuraeError(
                .validationError,
                "candidate conflict across layouts \(layouts.joined(separator: ", "))",
                subcode: "candidateConflict"
            )
        case let LayoutSetPlanError.initialFocusExcluded(layout, bundleID):
            ShitsuraeError(
                .validationError,
                "initial focus for layout \(layout) is excluded by ignore.apply.apps (\(bundleID))",
                subcode: "initialFocusExcluded"
            )
        default:
            ShitsuraeError(.validationError, String(describing: error))
        }
    }
}
