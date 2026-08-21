import Foundation

public extension VirtualSpaceEngine {
    /// Applies layouts hosted by distinct displays as one logical request.
    /// Structural validation completes before the first window mutation.
    /// Layouts whose declared host display is unavailable are reported as
    /// skipped; available layouts continue in caller order. Physical mutations
    /// are serialized; only the primary-hosted layout may apply initial focus.
    func arrange(
        layoutNames: [String],
        config: LoadedConfig
    ) throws -> ArrangeBatchExecutionJSON {
        guard layoutNames.count >= 2 else {
            throw VirtualSpaceEngineError.invalidArrangeBatch(
                "multi-display arrange requires at least two layouts"
            )
        }
        guard Set(layoutNames).count == layoutNames.count else {
            throw VirtualSpaceEngineError.invalidArrangeBatch(
                "multi-display arrange contains duplicate layout names"
            )
        }

        let displays = control.displays()
        var hostDisplayIDByLayout: [String: String] = [:]
        var hostLayoutByDisplayID: [String: String] = [:]
        var unavailableLayouts: Set<String> = []
        for layoutName in layoutNames {
            guard let layout = config.config.layouts[layoutName] else {
                throw VirtualSpaceEngineError.layoutNotFound(layoutName)
            }
            guard let hostDisplay = DisplayResolver.hostDisplay(
                layout: layout,
                config: config.config,
                displays: displays
            ) else {
                unavailableLayouts.insert(layoutName)
                continue
            }
            if let existing = hostLayoutByDisplayID[hostDisplay.id] {
                throw VirtualSpaceEngineError.invalidArrangeBatch(
                    "layouts \(existing) and \(layoutName) resolve to the same display \(hostDisplay.id)"
                )
            }
            hostDisplayIDByLayout[layoutName] = hostDisplay.id
            hostLayoutByDisplayID[hostDisplay.id] = layoutName
        }

        let primaryDisplayID = DisplayResolver.primaryDisplay(displays)?.id
        let results = try layoutNames.map { layoutName in
            if unavailableLayouts.contains(layoutName) {
                return ArrangeExecutionJSON(
                    layout: layoutName,
                    result: "skipped",
                    subcode: "hostDisplayUnavailable",
                    unresolvedSlots: [],
                    hardErrors: [],
                    softErrors: [],
                    skipped: [
                        SkippedItem(
                            spaceID: nil,
                            slot: nil,
                            reason: "hostDisplayUnavailable",
                            detail: "host display is unavailable; layout was skipped"
                        ),
                    ],
                    warnings: [],
                    exitCode: ErrorCode.success.rawValue
                )
            }
            return try arrange(
                layoutName: layoutName,
                spaceID: nil,
                config: config,
                applyInitialFocus: hostDisplayIDByLayout[layoutName] == primaryDisplayID
            )
        }
        return ArrangeBatchExecutionJSON(layouts: results)
    }

    // MARK: - Dry run

    func arrangeDryRun(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> ArrangeDryRunJSON {
        let (layout, hostDisplay, displays) = try arrangeContext(
            layoutName: layoutName,
            spaceID: spaceID,
            config: config
        )

        let observation = control.focusedWindowObservation()
        let plan = ArrangePlanner.buildPlan(
            layoutName: layoutName,
            layout: layout,
            spaceID: spaceID,
            config: config.config,
            hostDisplay: hostDisplay,
            displays: displays,
            currentWindows: WindowEligibility.geometryCandidates(in: observation)
        )

        return ArrangeDryRunJSON(
            layout: layoutName,
            availableSpaceIDs: layout.spaces.map(\.spaceID).sorted(),
            plan: plan.planItems,
            skipped: plan.skipped,
            warnings: plan.warnings
        )
    }

    // MARK: - State only

    func arrangeStateOnly(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> ArrangeExecutionJSON {
        let (layout, hostDisplay, _) = try arrangeContext(layoutName: layoutName, spaceID: spaceID, config: config)
        let activeSpaceID = resolvedActiveSpaceID(
            requestedSpaceID: spaceID,
            layout: layout,
            layoutName: layoutName,
            hostDisplay: hostDisplay
        )

        try bootstrapState(layoutName: layoutName, activeSpaceID: activeSpaceID, config: config)

        return ArrangeExecutionJSON(
            layout: layoutName,
            result: "success",
            subcode: nil,
            unresolvedSlots: [],
            hardErrors: [],
            softErrors: [],
            skipped: [],
            warnings: [
                WarningItem(
                    code: "arrange.stateOnly",
                    detail: "updated runtime state without applying layout operations"
                ),
            ],
            exitCode: ErrorCode.success.rawValue
        )
    }

    // MARK: - Live arrange

    /// Full arrange: restore hidden windows → launch/wait/place every window
    /// of the selected scope → rebuild state → re-hide non-active workspaces.
    /// The pre/post processing v1 spread across CommandService lives here.
    func arrange(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig,
        applyInitialFocus: Bool = true
    ) throws -> ArrangeExecutionJSON {
        logger.log(event: "arrange.start", fields: ["layout": layoutName])

        guard control.accessibilityGranted() else {
            return ArrangeExecutionJSON(
                layout: layoutName,
                result: "failed",
                subcode: "missingPermission",
                unresolvedSlots: [],
                hardErrors: [
                    ErrorItem(
                        code: ErrorCode.missingPermission.rawValue,
                        message: "Accessibility permission is required",
                        spaceID: nil,
                        slot: nil
                    ),
                ],
                softErrors: [],
                skipped: [],
                warnings: [],
                exitCode: ErrorCode.missingPermission.rawValue
            )
        }

        let (layout, hostDisplay, displays) = try arrangeContext(
            layoutName: layoutName,
            spaceID: spaceID,
            config: config
        )
        let arrangeObservation = control.focusedWindowObservation()

        // Restore only the layout this arrange replaces on ITS display —
        // never another display's workspace (arrange calendar must not
        // restore the primary layout's hidden windows).
        if let replacedLayoutName = currentState.activeWorkspace(displayID: hostDisplay.id)?.layoutName,
           replacedLayoutName != layoutName
        {
            let previousEntries = currentState.slots(layoutName: replacedLayoutName)
            let previousHiddenEntries = previousEntries.filter(\.visibilityState.isManagedHidden)
            guard restoreHiddenEntriesBeforeArrange(
                previousHiddenEntries,
                registryEntries: previousEntries.map(\.registryEntry),
                recoveryLayout: layout,
                hostDisplay: hostDisplay,
                displays: displays,
                preferredVisibleFramesByFingerprint: [:]
            ) else {
                return restoreIncompleteResult(layoutName: layoutName)
            }
        }

        let plan = ArrangePlanner.buildPlan(
            layoutName: layoutName,
            layout: layout,
            spaceID: spaceID,
            config: config.config,
            hostDisplay: hostDisplay,
            displays: displays,
            currentWindows: arrangeObservation.inventory.isAuthoritative
                ? WindowEligibility.geometryCandidates(in: arrangeObservation)
                : []
        )
        let arrangedFingerprints = Set(plan.steps.map { step in
            SlotEntry.fingerprint(
                layoutName: layoutName,
                spaceID: step.spaceID,
                definition: step.definition
            )
        })
        let arrangedFramesByFingerprint: [String: ResolvedFrame] = Dictionary(
            uniqueKeysWithValues: plan.steps.compactMap { step in
                guard let frame = step.resolvedFrame else { return nil }
                return (
                    SlotEntry.fingerprint(
                        layoutName: layoutName,
                        spaceID: step.spaceID,
                        definition: step.definition
                    ),
                    frame
                )
            }
        )
        let configuredFingerprints: Set<String> = Set(layout.spaces.flatMap { space in
            space.windows.compactMap { definition in
                guard !PolicyEngine.matchesIgnoreAppRule(
                    windowDefinition: definition,
                    rules: config.config.ignore?.apply
                ) else {
                    return nil
                }
                return SlotEntry.fingerprint(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )
            }
        }).subtracting(plan.ignoredDefinitionFingerprints)
        let arrangeRegistryEntries = makeArrangeRegistryEntries(
            layoutName: layoutName,
            layout: layout,
            config: config,
            excluding: plan.ignoredDefinitionFingerprints
        )

        // Only windows that this invocation will place need to be visible.
        // Restoring hidden entries from another requested space (or adopted /
        // ignored entries) can both mutate out-of-scope windows and make an
        // otherwise independent arrange fail on an AX-invisible window.
        guard restoreHiddenWindowsBeforeArrange(
            layoutName: layoutName,
            layout: layout,
            arrangedFingerprints: arrangedFingerprints,
            arrangedFramesByFingerprint: arrangedFramesByFingerprint,
            configuredFingerprints: configuredFingerprints,
            config: config
        ) else {
            return restoreIncompleteResult(layoutName: layoutName)
        }

        // Arrange is the user-initiated takeover: display affinity does not
        // apply, but windows bound to a *different-display* workspace's
        // layout slots stay untouchable.
        let arrangeExcludedIdentities = crossLayoutExcludedIdentities(
            layoutName: layoutName,
            hostDisplayID: hostDisplay.id,
            windows: [],
            includeDisplayAffinity: false
        )

        var softErrors: [ErrorItem] = []
        var boundWindows: [String: WindowSnapshot] = [:] // fingerprint → window
        var provisionalBindings: [String: WindowSnapshot] = [:]
        var frames: [String: ResolvedFrame] = [:]

        for step in plan.steps {
            let definition = step.definition
            let launch = definition.launch ?? true
            let fingerprint = SlotEntry.fingerprint(
                layoutName: layoutName,
                spaceID: step.spaceID,
                definition: definition
            )

            let preLaunchInventory = launch && definition.match.profile != nil
                ? control.windowInventory()
                : nil
            let preLaunchWindowHandles = preLaunchInventory?.isAuthoritative == true
                ? preLaunchInventory?.liveWindowHandles
                : nil

            if launch,
               !control.launchApplication(
                   request: ApplicationLaunchRequest(
                       bundleID: definition.match.bundleID,
                       profileDirectory: definition.match.profile
                   )
               )
            {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.appLaunchFailed.rawValue,
                        message: "failed to launch app: \(definition.match.bundleID)",
                        spaceID: step.spaceID,
                        slot: definition.slot
                    )
                )
                continue
            }

            guard let window = waitForWindow(
                rule: definition.match,
                fingerprint: fingerprint,
                spaceID: step.spaceID,
                slot: definition.slot,
                preLaunchWindowHandles: preLaunchWindowHandles,
                alreadyBound: Set(boundWindows.values.map(\.identity)),
                registryEntries: arrangeRegistryEntries,
                ignoreRules: config.config.ignore?.apply,
                excludedIdentities: arrangeExcludedIdentities,
                provisionalBindings: &provisionalBindings
            ) else {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.targetWindowNotFound.rawValue,
                        message: "target window not found: \(definition.match.bundleID)",
                        spaceID: step.spaceID,
                        slot: definition.slot
                    )
                )
                continue
            }

            if let resolvedFrame = step.resolvedFrame {
                if !setFrame(window: window, frame: resolvedFrame) {
                    softErrors.append(
                        ErrorItem(
                            code: ErrorCode.operationTimedOut.rawValue,
                            message: "failed to apply frame",
                            spaceID: step.spaceID,
                            slot: definition.slot
                        )
                    )
                    // Still bind the window: placement failed but tracking works.
                }
            }

            boundWindows[fingerprint] = window
            frames[fingerprint] = step.resolvedFrame ?? window.frame
        }

        if applyInitialFocus,
           let initialFocusSlot = layout.initialFocus?.slot,
           let focusStep = plan.steps.first(where: { $0.definition.slot == initialFocusSlot })
        {
            let fingerprint = SlotEntry.fingerprint(
                layoutName: layoutName,
                spaceID: focusStep.spaceID,
                definition: focusStep.definition
            )
            if let window = boundWindows[fingerprint] {
                do {
                    try applyFocus(window: window)
                } catch {
                    softErrors.append(
                        ErrorItem(
                            code: ErrorCode.operationTimedOut.rawValue,
                            message: "failed to focus initial slot",
                            spaceID: focusStep.spaceID,
                            slot: focusStep.definition.slot
                        )
                    )
                }
            }
        }

        let postArrangeObservation = control.focusedWindowObservation()
        let postArrangeIgnoredFingerprints = postArrangeObservation.inventory.isAuthoritative
            ? ArrangePlanner.buildPlan(
                layoutName: layoutName,
                layout: layout,
                spaceID: spaceID,
                config: config.config,
                hostDisplay: hostDisplay,
                displays: displays,
                currentWindows: WindowEligibility.geometryCandidates(in: postArrangeObservation)
            ).ignoredDefinitionFingerprints
            : []
        let ignoredFingerprints = plan.ignoredDefinitionFingerprints
            .union(postArrangeIgnoredFingerprints)

        // Rebuild state for the arranged scope, binding resolved windows.
        try rebuildStateAfterArrange(
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: spaceID,
            boundWindows: boundWindows,
            frames: frames,
            ignoredFingerprints: ignoredFingerprints,
            config: config,
            hostDisplay: hostDisplay
        )

        // Adopt windows no layout slot claimed into the active workspace so
        // they are tracked (and hidden/shown) from the start.
        _ = try? adoptUntrackedWindows(
            config: config,
            additionalIgnoreRules: config.config.ignore?.apply
        )

        // Re-hide everything outside the active workspace of THIS layout.
        let activeSpaceID = resolvedActiveSpaceID(
            requestedSpaceID: spaceID,
            layout: layout,
            layoutName: layoutName,
            hostDisplay: hostDisplay
        )
        let switchOutcome = try switchSpace(
            layoutName: layoutName,
            to: activeSpaceID,
            config: config,
            reconcile: true,
            adoptionIgnoreRules: config.config.ignore?.apply,
            shouldFocusTarget: applyInitialFocus
        )

        let unresolvedSlots = switchOutcome.unresolvedSlots
        let completedWithoutGaps = softErrors.isEmpty && unresolvedSlots.isEmpty
        let result = completedWithoutGaps ? "success" : "partial"
        let exitCode = completedWithoutGaps
            ? ErrorCode.success.rawValue
            : ErrorCode.partialSuccess.rawValue

        logger.log(
            event: "arrange.finished",
            fields: [
                "layout": layoutName,
                "result": result,
                "exitCode": exitCode,
            ]
        )

        return ArrangeExecutionJSON(
            layout: layoutName,
            result: result,
            subcode: unresolvedSlots.isEmpty ? nil : "unresolvedSlots",
            unresolvedSlots: unresolvedSlots,
            hardErrors: [],
            softErrors: softErrors,
            skipped: plan.skipped,
            warnings: plan.warnings,
            exitCode: exitCode
        )
    }

    // MARK: - Helpers

    private func arrangeContext(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> (LayoutDefinition, DisplayInfo, [DisplayInfo]) {
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        if let spaceID, !layout.spaces.contains(where: { $0.spaceID == spaceID }) {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: spaceID)
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        return (layout, hostDisplay, displays)
    }

    private func resolvedActiveSpaceID(
        requestedSpaceID: Int?,
        layout: LayoutDefinition,
        layoutName: String,
        hostDisplay: DisplayInfo
    ) -> Int {
        let layoutSpaceIDs = Set(layout.spaces.map(\.spaceID))
        if let requestedSpaceID {
            return requestedSpaceID
        }
        // Re-arranging the layout that is already active on this display (or
        // dormant elsewhere after a declaration change) keeps its space.
        if let workspace = currentState.activeWorkspace(displayID: hostDisplay.id),
           workspace.layoutName == layoutName,
           layoutSpaceIDs.contains(workspace.spaceID)
        {
            return workspace.spaceID
        }
        if let workspace = currentState.activeWorkspace(layoutName: layoutName),
           layoutSpaceIDs.contains(workspace.spaceID)
        {
            return workspace.spaceID
        }
        return layout.spaces.map(\.spaceID).min() ?? 1
    }

    private func restoreHiddenWindowsBeforeArrange(
        layoutName: String,
        layout: LayoutDefinition,
        arrangedFingerprints: Set<String>,
        arrangedFramesByFingerprint: [String: ResolvedFrame],
        configuredFingerprints: Set<String>,
        config: LoadedConfig
    ) -> Bool {
        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            return false
        }

        let hiddenEntries = currentState.slots(layoutName: layoutName)
            .filter {
                $0.visibilityState.isManagedHidden
                    && $0.origin == .layout
                    && (arrangedFingerprints.contains($0.definitionFingerprint)
                        || !configuredFingerprints.contains($0.definitionFingerprint))
            }
        guard !hiddenEntries.isEmpty else {
            return true
        }

        // Restore participates in the same global ownership assignment as
        // wait/place. Resolving only the selected hidden entries lets a stale
        // binding borrow a live window that an out-of-scope layout entry owns
        // exactly, mutating it before the later global arrange pass can stop
        // the duplicate claim.
        let registryEntries = makeArrangeRegistryEntries(
            layoutName: layoutName,
            layout: layout,
            config: config,
            excluding: []
        )
        let registeredIDs = Set(registryEntries.map(\.entry.id))
        let discardedEntries = currentState.slots(layoutName: layoutName)
            .filter { !registeredIDs.contains($0.id) }
            .map(\.registryEntry)
        return restoreHiddenEntriesBeforeArrange(
            hiddenEntries,
            registryEntries: registryEntries.map(\.entry) + discardedEntries,
            recoveryLayout: layout,
            hostDisplay: hostDisplay,
            displays: displays,
            preferredVisibleFramesByFingerprint: arrangedFramesByFingerprint
        )
    }

    private func restoreHiddenEntriesBeforeArrange(
        _ hiddenEntries: [SlotEntry],
        registryEntries: [WindowRegistry.Entry],
        recoveryLayout: LayoutDefinition,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo],
        preferredVisibleFramesByFingerprint: [String: ResolvedFrame]
    ) -> Bool {
        guard !hiddenEntries.isEmpty else { return true }

        let observation = control.focusedWindowObservation()
        let inventory = observation.inventory
        guard inventory.isAuthoritative else { return false }
        let windows = WindowEligibility.geometryCandidates(in: observation)
        let resolution = WindowRegistry.resolve(
            entries: registryEntries,
            manageableWindows: windows,
            fullInventory: inventory
        )

        var plans: [VisibilityPlan] = []
        var authoritativelyGoneEntryIDs: Set<String> = []
        for entry in hiddenEntries {
            guard let window = resolution.assignments[entry.id] else {
                if resolution.unresolvedReasons[entry.id] == .reservedExactIdentity {
                    return false
                }
                // An authoritatively gone exact-only window needs no restore.
                if entry.boundIdentity.map({ !inventory.mayContain($0) }) ?? true {
                    authoritativelyGoneEntryIDs.insert(entry.id)
                }
                continue
            }
            guard let plan = VisibilityPlanner.plan(
                entry: entry,
                window: window,
                transition: .show,
                layout: recoveryLayout,
                hostDisplay: hostDisplay,
                displays: displays,
                preferredVisibleFrame: preferredVisibleFramesByFingerprint[entry.definitionFingerprint]
            ) else {
                return false
            }
            plans.append(plan)
        }

        let applied = VisibilityApplier.apply(plans: plans, control: control, logger: logger)
        let convergence = VisibilityApplier.converge(
            changes: applied,
            control: control,
            logger: logger,
            retryDelaysMS: retryDelaysMS
        )
        guard !convergence.hasPending,
              convergence.changes.allSatisfy({ $0.effectiveEntry == $0.desiredEntry })
        else {
            return false
        }

        var newState = currentState
        var restoredEntries = Dictionary(uniqueKeysWithValues: convergence.changes.map {
            ($0.effectiveEntry.id, $0.effectiveEntry)
        })
        for entry in hiddenEntries where authoritativelyGoneEntryIDs.contains(entry.id) {
            var restored = entry
            restored.visibilityState = .visible
            restored.lastHiddenFrame = nil
            restoredEntries[restored.id] = restored
        }
        newState.slots = newState.slots.map { restoredEntries[$0.id] ?? $0 }
        do {
            try replaceState(newState)
            return true
        } catch {
            logger.error(
                event: "arrange.restore.persistFailed",
                fields: ["error": String(describing: error)]
            )
            return false
        }
    }

    private func restoreIncompleteResult(layoutName: String) -> ArrangeExecutionJSON {
        let error = ErrorItem(
            code: ErrorCode.operationTimedOut.rawValue,
            message: "unable to restore hidden windows before arrange",
            spaceID: nil,
            slot: nil
        )
        return ArrangeExecutionJSON(
            layout: layoutName,
            result: "failed",
            subcode: "restoreIncomplete",
            unresolvedSlots: [],
            hardErrors: [error],
            softErrors: [],
            skipped: [],
            warnings: [],
            exitCode: ErrorCode.operationTimedOut.rawValue
        )
    }

    private func rebuildStateAfterArrange(
        layoutName: String,
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        boundWindows: [String: WindowSnapshot],
        frames: [String: ResolvedFrame],
        ignoredFingerprints: Set<String>,
        config: LoadedConfig,
        hostDisplay: DisplayInfo
    ) throws {
        let existing = currentState.slots(layoutName: layoutName)
        let existingByFingerprint = Dictionary(
            existing.map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [SlotEntry] = []
        for space in layout.spaces {
            for definition in space.windows {
                let fingerprint = SlotEntry.fingerprint(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )
                if ignoredFingerprints.contains(fingerprint) {
                    continue
                }
                if PolicyEngine.matchesIgnoreAppRule(
                    windowDefinition: definition,
                    rules: config.config.ignore?.apply
                ) {
                    continue
                }
                var entry = SlotEntry.makeEntry(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )

                if let previous = existingByFingerprint[entry.definitionFingerprint] {
                    entry.id = previous.id
                    entry.spaceID = previous.spaceID
                    entry.pid = previous.pid
                    entry.processStartTime = previous.processStartTime
                    entry.windowID = previous.windowID
                    entry.lastKnownTitle = previous.lastKnownTitle
                    entry.displayID = previous.displayID
                    entry.lastVisibleFrame = previous.lastVisibleFrame
                    entry.lastHiddenFrame = previous.lastHiddenFrame
                    entry.visibilityState = previous.visibilityState
                    entry.lastActivatedAt = previous.lastActivatedAt
                }

                if let window = boundWindows[entry.definitionFingerprint] {
                    entry = entry.bound(to: window)
                    // arrange moves the window back to its layout space.
                    entry.spaceID = space.spaceID
                    entry.visibilityState = .visible
                    entry.lastVisibleFrame = frames[entry.definitionFingerprint] ?? entry.lastVisibleFrame
                    entry.lastHiddenFrame = nil
                }

                entries.append(entry)
            }
        }

        let claimedIdentities = Set(boundWindows.values.map(\.identity))
        let adopted = existing.filter {
            $0.origin == .adopted
                && ($0.boundIdentity.map { !claimedIdentities.contains($0) } ?? true)
        }

        var newState = currentState
        newState.slots = newState.slots.filter { $0.layoutName != layoutName } + entries + adopted
        // Layout rules beat other workspaces' adopted bindings: a window this
        // arrange claimed leaves any adopted entry another workspace held for
        // it (the reclaim half of the cross-layout ownership rules).
        newState.slots.removeAll { entry in
            entry.layoutName != layoutName
                && entry.origin == .adopted
                && (entry.boundIdentity.map { claimedIdentities.contains($0) } ?? false)
        }
        newState.configGeneration = config.configGeneration
        let activeSpaceID = resolvedActiveSpaceID(
            requestedSpaceID: arrangedSpaceID,
            layout: layout,
            layoutName: layoutName,
            hostDisplay: hostDisplay
        )
        newState.upsertActiveWorkspace(
            displayID: hostDisplay.id,
            layoutName: layoutName,
            spaceID: activeSpaceID
        )
        newState.liveArrangeRecoveryRequired = false

        try replaceState(newState)
    }

    private func waitForWindow(
        rule: WindowMatchRule,
        fingerprint: String,
        spaceID: Int,
        slot: Int,
        preLaunchWindowHandles: Set<WindowHandle>?,
        alreadyBound: Set<WindowIdentity>,
        registryEntries: [(fingerprint: String, entry: WindowRegistry.Entry)],
        ignoreRules: IgnoreRuleSet?,
        excludedIdentities: Set<WindowIdentity>,
        provisionalBindings: inout [String: WindowSnapshot]
    ) -> WindowSnapshot? {
        let deadline = Date().addingTimeInterval(TimeInterval(arrangeWaitTimeoutMS) / 1000)
        var preferredFullscreenWindow: WindowSnapshot?

        while Date() <= deadline {
            // index rules must see the FULL pool: shrinking it per bound
            // window shifts the index positions and breaks index:2 after
            // index:1 has bound (same bug class as v1's switch path).
            // alreadyBound is enforced after selection instead.
            let observation = control.focusedWindowObservation()
            let inventory = observation.inventory
            guard inventory.isAuthoritative else {
                let remainingMS = Int(deadline.timeIntervalSinceNow * 1000)
                if remainingMS <= 0 { break }
                control.sleep(milliseconds: min(100, remainingMS))
                continue
            }
            let manageable = WindowEligibility.geometryCandidates(in: observation).filter {
                !excludedIdentities.contains($0.identity)
                    && !PolicyEngine.matchesIgnoreRule(window: $0, rules: ignoreRules)
            }
            let entries = registryEntries.map { item -> WindowRegistry.Entry in
                guard let bound = provisionalBindings[item.fingerprint] else {
                    return item.entry
                }
                return WindowRegistry.Entry(
                    id: item.entry.id,
                    rule: item.entry.rule,
                    pid: bound.pid,
                    processStartTime: bound.processStartTime,
                    windowID: bound.windowID,
                    bindingPolicy: item.entry.bindingPolicy
                )
            }
            guard let currentEntry = registryEntries.first(where: { $0.fingerprint == fingerprint })?.entry
            else { return nil }
            let resolution = WindowRegistry.resolve(
                entries: entries,
                manageableWindows: manageable,
                fullInventory: inventory
            )
            for item in registryEntries {
                if let assigned = resolution.assignments[item.entry.id] {
                    provisionalBindings[item.fingerprint] = assigned
                } else if resolution.unresolvedReasons[item.entry.id] != .reservedExactIdentity {
                    provisionalBindings.removeValue(forKey: item.fingerprint)
                }
            }

            if let assigned = resolution.assignments[currentEntry.id],
               !alreadyBound.contains(assigned.identity)
            {
                if !assigned.isFullscreen {
                    return assigned
                }
                // Refresh every authoritative pass. A window that disappears
                // before the deadline must never be returned from stale cache.
                preferredFullscreenWindow = assigned
            } else {
                preferredFullscreenWindow = nil
            }

            if resolution.unresolvedReasons[currentEntry.id] != .reservedExactIdentity {
                let identitiesOwnedByOtherEntries = Set(resolution.assignments.compactMap { entryID, window in
                    entryID == currentEntry.id ? nil : window.identity
                })
                let unownedNonFullscreen = manageable.filter {
                    !$0.isFullscreen && !identitiesOwnedByOtherEntries.contains($0.identity)
                }
                if let found = selectWindow(
                    rule: rule,
                    candidates: unownedNonFullscreen,
                    preLaunchWindowHandles: preLaunchWindowHandles,
                    alreadyBound: alreadyBound
                ) {
                    return found
                }
            }

            let remainingMS = Int(deadline.timeIntervalSinceNow * 1000)
            if remainingMS <= 0 {
                // Never steal a sibling while the exact binding is alive. If
                // the only reason the exact window was excluded is native
                // fullscreen, return that same identity at the deadline and
                // let setFrame report whether macOS accepts arrange.
                if let preferredFullscreenWindow {
                    return preferredFullscreenWindow
                }
                break
            }
            control.sleep(milliseconds: min(100, remainingMS))
        }

        logger.error(event: "arrange.waitWindow.timeout", fields: ["spaceID": spaceID, "slot": slot])
        return nil
    }

    private func makeArrangeRegistryEntries(
        layoutName: String,
        layout: LayoutDefinition,
        config: LoadedConfig,
        excluding excludedFingerprints: Set<String>
    ) -> [(fingerprint: String, entry: WindowRegistry.Entry)] {
        let existingByFingerprint = Dictionary(
            currentState.slots(layoutName: layoutName)
                .filter { $0.origin == .layout }
                .map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return layout.spaces.flatMap { space in
            space.windows.compactMap { definition -> (fingerprint: String, entry: WindowRegistry.Entry)? in
                guard !PolicyEngine.matchesIgnoreAppRule(
                    windowDefinition: definition,
                    rules: config.config.ignore?.apply
                ) else {
                    return nil
                }
                let fresh = SlotEntry.makeEntry(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )
                guard !excludedFingerprints.contains(fresh.definitionFingerprint) else {
                    return nil
                }
                return (
                    fingerprint: fresh.definitionFingerprint,
                    entry: existingByFingerprint[fresh.definitionFingerprint]?.registryEntry
                        ?? fresh.registryEntry
                )
            }
        }
    }

    private func selectWindow(
        rule: WindowMatchRule,
        candidates: [WindowSnapshot],
        preLaunchWindowHandles: Set<WindowHandle>?,
        alreadyBound: Set<WindowIdentity>
    ) -> WindowSnapshot? {
        if let found = pick(rule: rule, pool: candidates, alreadyBound: alreadyBound) {
            return found
        }

        // Profile launch fallback: lsof may lag right after a profile-window
        // launch; a window that appeared after the launch is the one we made.
        guard rule.profile != nil, let preLaunchWindowHandles else {
            return nil
        }

        let newWindows = candidates.filter { !preLaunchWindowHandles.contains($0.handle) }
        guard !newWindows.isEmpty else {
            return nil
        }

        let fallbackRule = WindowMatchRule(
            bundleID: rule.bundleID,
            title: rule.title,
            role: rule.role,
            subrole: rule.subrole,
            profile: nil,
            excludeTitleRegex: rule.excludeTitleRegex,
            index: rule.index
        )
        return pick(rule: fallbackRule, pool: newWindows, alreadyBound: alreadyBound)
    }

    /// index selection runs against the full sorted pool (stable positions);
    /// the chosen window is rejected only afterwards when another step
    /// already bound it. Non-index rules pick the best unbound candidate.
    private func pick(
        rule: WindowMatchRule,
        pool: [WindowSnapshot],
        alreadyBound: Set<WindowIdentity>
    ) -> WindowSnapshot? {
        let matched = WindowRegistry.sortedCandidates(rule: rule, pool: pool)
        if let index = rule.index {
            let zeroBased = index - 1
            guard zeroBased >= 0, zeroBased < matched.count else { return nil }
            let chosen = matched[zeroBased]
            return alreadyBound.contains(chosen.identity) ? nil : chosen
        }
        return matched.first(where: { !alreadyBound.contains($0.identity) })
    }

    private func setFrame(window: WindowSnapshot, frame: ResolvedFrame) -> Bool {
        control.setWindowFrame(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            frame: frame
        ).isApplied
    }
}
