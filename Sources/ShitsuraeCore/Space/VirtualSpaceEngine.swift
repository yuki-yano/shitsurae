import Foundation

public struct SpaceSwitchOutcome: Equatable, Sendable {
    public let layoutName: String
    public let previousSpaceID: Int?
    public let targetSpaceID: Int
    public let didChangeSpace: Bool
    public let shownCount: Int
    public let hiddenCount: Int
    public let focusedWindowID: UInt32?
    public let unresolvedSlots: [PendingUnresolvedSlot]
    public let converged: Bool
}

public struct WorkspaceMoveOutcome: Equatable, Sendable {
    public let windowID: UInt32
    public let bundleID: String
    public let fromSpaceID: Int
    public let toSpaceID: Int
    public let visibilityAction: String
}

public enum VirtualSpaceEngineError: Error, Equatable, Sendable {
    case noActiveLayout
    case layoutNotFound(String)
    case spaceNotFound(layoutName: String, spaceID: Int)
    case hostDisplayUnavailable
    case windowNotTracked
    case ambiguousWindow
    case stateError(String)
}

/// The single owner of virtual workspace state. All mutations are serialized
/// by the actor; the state file is loaded once at init and kept as the
/// authoritative in-memory copy (the store's expectation check is only a
/// tripwire against external edits).
///
/// v1's flock-based VirtualSpaceStateMutationLock, the GUI/Agent split-brain,
/// and the lock-outside/lock-inside double validation all collapse into this
/// one actor.
public actor VirtualSpaceEngine {
    private let store: RuntimeStateStore
    let control: WindowControl
    let logger: ShitsuraeLogger
    let retryDelaysMS: [Int]
    let arrangeWaitTimeoutMS: Int
    nonisolated let focusEventGate: FocusEventGate
    private var state: RuntimeState
    var latestFocusEventSequence: UInt64 = 0
    private static let focusVerificationDelaysMS = [20, 40, 80]

    /// Windows an app refuses to move.
    /// Tracked in memory only — a per-window count of consecutive switches
    /// that left the window unconverged; once it reaches the threshold the
    /// window is quarantined so it stops pinning convergence and dragging
    /// every switch through the retry budget. A quarantined window is a hard
    /// no-op until an explicit user move clears it or the exact window closes.
    private var convergenceFailureCounts: [WindowIdentity: Int] = [:]
    private var quarantinedWindowIdentities: Set<WindowIdentity> = []
    private static let quarantineThreshold = 3

    /// Exact main windows temporarily kept on-screen because their focused
    /// companion surface must not be moved. The value is the workspace the
    /// main belonged to when protection started. Once the companion closes,
    /// the next main-window focus event reconciles that window back to this
    /// workspace without follow-focus undoing the user's explicit switch.
    var suspendedCompanionMainSpaces: [WindowIdentity: Int] = [:]

    public init(
        store: RuntimeStateStore,
        control: WindowControl,
        logger: ShitsuraeLogger,
        retryDelaysMS: [Int] = VisibilityApplier.defaultRetryDelaysMS,
        arrangeWaitTimeoutMS: Int = 5000,
        focusEventGate: FocusEventGate = FocusEventGate()
    ) throws {
        self.store = store
        self.control = control
        self.logger = logger
        self.retryDelaysMS = retryDelaysMS
        self.arrangeWaitTimeoutMS = arrangeWaitTimeoutMS
        self.focusEventGate = focusEventGate
        self.state = try store.loadStrict()
    }

    // MARK: - Queries

    public var currentState: RuntimeState {
        state
    }

    public func activeSpaceID() -> Int? {
        state.primaryActiveSpaceID
    }

    public func activeLayoutName() -> String? {
        state.activeLayoutName
    }

    /// Synchronous cross-actor invalidation for explicit commands entering
    /// outside AppModel (notably the CLI command server).
    public nonisolated func invalidatePendingFocusEvents() {
        focusEventGate.invalidateCurrent()
    }

    /// The virtual workspace of one exact live window identity.
    public func spaceID(for window: WindowSnapshot) -> Int? {
        assignedEntry(for: window)?.spaceID
    }

    /// Single source of truth for "which entry owns this live window":
    /// resolves every entry of the active layout against the manageable live
    /// windows — the same global assignment the next switchSpace computes.
    /// Per-window queries (focus follow, MRU marking, adoption checks,
    /// workspace moves) all share this result so they can never disagree with
    /// bulk resolution; in particular a relaunched app's new window
    /// re-associates with its layout entry here instead of spawning a
    /// duplicate adopted entry.
    func assignedEntry(for window: WindowSnapshot) -> SlotEntry? {
        guard let layoutName = state.activeLayoutName else { return nil }
        let slots = state.slots(layoutName: layoutName)
        guard !slots.isEmpty else { return nil }

        let inventory = control.windowInventory()
        let windows = inventory.windows.filter(WindowEligibility.isManageableForVirtualWorkspace)
        guard let matched = WindowRegistry.assignedEntry(
            for: window,
            entries: slots.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        ) else {
            return nil
        }
        return slots.first { $0.id == matched.id }
    }

    // MARK: - Space switch

    @discardableResult
    public func switchSpace(
        to targetSpaceID: Int,
        config: LoadedConfig,
        reconcile: Bool = false
    ) throws -> SpaceSwitchOutcome {
        try ensureAccessibility()
        guard let layoutName = state.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        guard layout.spaces.contains(where: { $0.spaceID == targetSpaceID }) else {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: targetSpaceID)
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        let previousSpaceID = state.activeSpaceID(displayID: hostDisplay.id) ?? state.primaryActiveSpaceID
        let didChangeSpace = previousSpaceID != targetSpaceID
        if !didChangeSpace, !reconcile, state.pendingVisibilityConvergence == nil {
            // Nothing to do; report idempotent success.
            return SpaceSwitchOutcome(
                layoutName: layoutName,
                previousSpaceID: previousSpaceID,
                targetSpaceID: targetSpaceID,
                didChangeSpace: false,
                shownCount: 0,
                hiddenCount: 0,
                focusedWindowID: nil,
                unresolvedSlots: [],
                converged: true
            )
        }

        let observation = control.focusedWindowObservation()
        let inventory = observation.inventory
        guard inventory.isAuthoritative else {
            throw VirtualSpaceEngineError.stateError("window inventory unavailable")
        }

        let allWindows = inventory.windows
        let windows = WindowEligibility.geometryCandidates(in: observation)
        let blockedIdentities = WindowEligibility.geometryBlockedIdentities(in: observation)
        let focusedMainIsBlocked = observation.mainIdentity.map(blockedIdentities.contains) == true

        // Resolve ownership with blocked-but-otherwise-manageable main
        // windows included. Their entries are then removed from the physical
        // switch plan altogether: no frame write can drag an attached sheet,
        // while every unrelated window can still switch normally.
        let layoutSlots = state.slots(layoutName: layoutName)
        let ownershipWindows = allWindows.filter {
            WindowEligibility.classification(of: $0) == .manageable
        }
        let ownershipResolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            manageableWindows: ownershipWindows,
            fullInventory: inventory
        )
        let protectedEntryIDs = Set(ownershipResolution.assignments.compactMap { entryID, window in
            blockedIdentities.contains(window.identity) ? entryID : nil
        })
        let entryByID = Dictionary(uniqueKeysWithValues: layoutSlots.map { ($0.id, $0) })
        for window in ownershipWindows where blockedIdentities.contains(window.identity) {
            guard suspendedCompanionMainSpaces[window.identity] == nil else { continue }
            let assignedSpaceID = ownershipResolution.assignments.first(where: {
                $0.value.identity == window.identity
            }).flatMap { entryByID[$0.key]?.spaceID }
            if let originSpaceID = assignedSpaceID ?? previousSpaceID {
                suspendedCompanionMainSpaces[window.identity] = originSpaceID
            }
        }

        // A CG inventory can be authoritative about liveness while the AX
        // view needed for safe mutations is temporarily incomplete. Resolve
        // before adoption or any other state change so an all-AX-dropout pass
        // cannot commit a logical space switch with zero physical work. Raw
        // CG identities are used only to reject the pass; they never become
        // mutation candidates.
        let preflightExcludedEntryIDs = Set(
            ineligibleAdoptedEntryIDs(layoutName: layoutName, windows: allWindows)
        )
        let preflightEntries = state.slots(layoutName: layoutName).filter {
            !preflightExcludedEntryIDs.contains($0.id)
                && !protectedEntryIDs.contains($0.id)
        }
        let preflightResolution = WindowRegistry.resolve(
            entries: preflightEntries.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )
        let reservedExactEntryIDs = Set(preflightResolution.unresolved.compactMap { entryID in
            preflightResolution.unresolvedReasons[entryID] == .reservedExactIdentity
                ? entryID
                : nil
        })
        let targetEntryIDs = Set(
            preflightEntries.filter { $0.spaceID == targetSpaceID }.map(\.id)
        )
        let previousEntryIDs = Set(
            preflightEntries.filter { $0.spaceID == previousSpaceID }.map(\.id)
        )
        let targetReservedCount = reservedExactEntryIDs.intersection(targetEntryIDs).count
        let previousReservedCount = reservedExactEntryIDs.intersection(previousEntryIDs).count
        let targetAssignmentCount = preflightResolution.assignments.keys.reduce(into: 0) { count, entryID in
            if targetEntryIDs.contains(entryID) {
                count += 1
            }
        }
        let previousAssignmentCount = preflightResolution.assignments.keys.reduce(into: 0) { count, entryID in
            if previousEntryIDs.contains(entryID) {
                count += 1
            }
        }
        let rejectedPrevious = previousReservedCount > 0 && previousAssignmentCount == 0
        let rejectedTarget = targetReservedCount > 0 && targetAssignmentCount == 0
        if rejectedPrevious || rejectedTarget {
            logger.log(
                level: "warn",
                event: "space.switch.preflightRejected",
                fields: [
                    "from": previousSpaceID ?? -1,
                    "to": targetSpaceID,
                    "manageable": windows.count,
                    "assignments": preflightResolution.assignments.count,
                    "reservedExact": reservedExactEntryIDs.count,
                    "previousReserved": previousReservedCount,
                    "previousAssignments": previousAssignmentCount,
                    "targetReserved": targetReservedCount,
                    "targetAssignments": targetAssignmentCount,
                ]
            )
            throw VirtualSpaceEngineError.stateError(
                "window inventory temporarily lacks manageable bindings"
            )
        }

        // Untracked visible windows belong to the workspace the user sees
        // them on — adopt them into the *pre-switch* workspace so they hide
        // together with it instead of drifting to wherever the switcher is
        // first opened.
        _ = try? adoptUntrackedWindows(
            config: config,
            persistChanges: false,
            inventory: inventory,
            excludedWindowIdentities: blockedIdentities
        )

        pruneIneligibleAdoptedEntriesInMemory(layoutName: layoutName, windows: allWindows)
        // Drop quarantine bookkeeping for windows that no longer exist so a
        // freshly opened window (new windowID) always gets a clean slate.
        convergenceFailureCounts = convergenceFailureCounts.filter { inventory.mayContain($0.key) }
        quarantinedWindowIdentities = Set(quarantinedWindowIdentities.filter { inventory.mayContain($0) })
        let plan = SpaceSwitchPlanner.plan(
            slots: state.slots.filter { !protectedEntryIDs.contains($0.id) },
            layoutName: layoutName,
            layout: layout,
            targetSpaceID: targetSpaceID,
            manageableWindows: windows,
            fullInventory: inventory,
            hostDisplay: hostDisplay,
            displays: displays,
            quarantinedWindowIdentities: quarantinedWindowIdentities
        )

        let allVisibilityPlans = plan.shows + plan.hides
        let hasPhysicalMutation = allVisibilityPlans.contains { $0.mutation != .none }
        if hasPhysicalMutation {
            // Persist the desired visibility and exact bindings before the
            // first AX mutation. If the process exits or the final save fails,
            // shutdown/startup recovery can still find every parked window.
            var intentState = state
            var entriesByID = Dictionary(uniqueKeysWithValues: intentState.slots.map { ($0.id, $0) })
            // A mutation-free plan (currently a manually minimized window)
            // has no physical crash window. Leaving its entry untouched is
            // essential: marking it hidden here would make shutdown recovery
            // unminimize a window the user chose to keep minimized.
            for visibilityPlan in allVisibilityPlans where visibilityPlan.mutation != .none {
                entriesByID[visibilityPlan.entryID] = Self.writeAheadEntry(for: visibilityPlan)
            }
            for staleID in plan.staleAdoptedEntryIDs {
                if let identity = entriesByID[staleID]?.boundIdentity,
                   inventory.mayContain(identity)
                {
                    continue
                }
                entriesByID.removeValue(forKey: staleID)
            }
            intentState.slots = intentState.slots.compactMap { entriesByID[$0.id] }
            intentState.setActiveSpace(displayID: hostDisplay.id, spaceID: targetSpaceID)
            intentState.activeSpaces.removeAll { active in
                !displays.contains(where: { $0.id == active.displayID })
            }
            intentState.activeLayoutName = layoutName
            // This snapshot describes the new physical transaction. The
            // complete plan above already re-evaluated every tracked entry,
            // so retaining an older targetSpaceID would make the WAL metadata
            // contradict the active space and visibility intent on disk.
            intentState.pendingVisibilityConvergence = PendingVisibilityConvergence(
                requestID: UUID().uuidString.lowercased(),
                startedAt: Date.rfc3339UTC(),
                layoutName: layoutName,
                targetSpaceID: targetSpaceID,
                unresolvedSlots: plan.unresolvedSlots + [PendingUnresolvedSlot(
                    slot: 0,
                    spaceID: targetSpaceID,
                    reason: "spaceSwitchInProgress"
                )]
            )
            try persist(intentState)
        }

        let mutationFreePlans = allVisibilityPlans.filter { $0.mutation == .none }
        let applied = VisibilityApplier.apply(
            plans: allVisibilityPlans.filter { $0.mutation != .none },
            control: control,
            logger: logger
        )

        // Focus the MRU window of the target workspace right away — the
        // convergence retries below can take a few hundred ms and the user
        // must not wait for them to get keyboard focus.
        var focusedIdentity = focusedMainIsBlocked
            ? nil
            : focusTarget(from: plan.focusCandidates)

        let convergence = VisibilityApplier.converge(
            changes: applied,
            control: control,
            logger: logger,
            retryDelaysMS: retryDelaysMS
        )
        updateQuarantine(plannedChanges: applied, convergence: convergence)

        // The early focus can fail while the window is still settling, or it
        // can succeed and then be clobbered: convergence (and the OS settling
        // the shown/hidden windows) can steal key focus to a *sibling* window
        // of the target workspace *after* we focused the intended one. Re-assert
        // focus once the layout has settled — but only for that case (a steal
        // within the workspace, or focus vanishing entirely), never when the
        // user deliberately moved focus outside the workspace mid-switch. This
        // folds the user's manual "press the shortcut again" into a single
        // switch.
        if !focusedMainIsBlocked, !plan.focusCandidates.isEmpty {
            let intendedTopIdentity = plan.focusCandidates[0].window.identity
            let liveFocus = control.focusedWindowObservation().focusedIdentity
            let driftedWithinWorkspace = liveFocus
                .map { identity in plan.focusCandidates.contains { $0.window.identity == identity } }
                ?? true
            let shouldReFocus = (liveFocus.map { $0 != intendedTopIdentity } ?? true)
                && driftedWithinWorkspace
            if shouldReFocus {
                focusedIdentity = focusTarget(from: plan.focusCandidates)
            }
        }

        // Persist: merge effective entries back by id, update active space,
        // and record pending convergence when not fully converged.
        var newState = state
        var slotsByID = Dictionary(uniqueKeysWithValues: newState.slots.map { ($0.id, $0) })
        // `.none` is an intentional no-op (currently a manually minimized
        // window). It has no physical state to converge or quarantine; merge
        // only its exact binding while preserving truthful visibility state.
        for visibilityPlan in mutationFreePlans {
            slotsByID[visibilityPlan.entryID] = visibilityPlan.desiredEntry
        }
        let unsafeToMerge = Set(
            convergence.unverifiedWindowIdentities + convergence.unconvergedWindowIdentities
        )
        for change in convergence.changes where !unsafeToMerge.contains(change.window.identity) {
            slotsByID[change.effectiveEntry.id] = change.effectiveEntry
        }
        if let focusedIdentity,
           let focusEntry = plan.focusTarget?.entry,
           var entry = slotsByID[focusEntry.id],
           entry.boundIdentity == focusedIdentity
        {
            entry.lastActivatedAt = Date.rfc3339UTC()
            slotsByID[entry.id] = entry
        }
        // Adopted entries are exact-only bindings. If their concrete window
        // identity is gone, drop them instead of rebinding to another window
        // from the same application or polluting recovery state forever.
        // A CG-alive window that is merely not AX-visible this pass is
        // unknown, not gone — keep its entry and retry next cycle. The
        // accepted trade-off: an entry whose window never becomes AX-visible
        // again stays in state (unmanaged, never operated on) until its CG
        // window disappears.
        if inventory.isAuthoritative {
            for staleID in plan.staleAdoptedEntryIDs {
                if let identity = slotsByID[staleID]?.boundIdentity,
                   inventory.mayContain(identity)
                {
                    continue
                }
                slotsByID.removeValue(forKey: staleID)
            }
        }
        // Rebuild in the original slot order — dictionary value order is
        // unspecified and would make clone-rule assignment flap between
        // persists.
        newState.slots = newState.slots.compactMap { slotsByID[$0.id] }
        newState.setActiveSpace(displayID: hostDisplay.id, spaceID: targetSpaceID)
        // ⑥ Drop active-space records of displays that are no longer
        // connected; a reconnect can change the display UUID and the stale
        // first entry would otherwise shadow the live one.
        newState.activeSpaces.removeAll { entry in
            !displays.contains(where: { $0.id == entry.displayID })
        }
        newState.activeLayoutName = layoutName
        // Quarantined windows are an accepted degraded mode: their verified
        // result is merged, while unknown/unsettled results keep the
        // conservative WAL entry above. They must not pin global recovery;
        // shutdown can still restore every WAL-hidden entry.
        let requiresRecovery = convergence.hasPending || !plan.unresolvedEntryIDs.isEmpty
        newState.pendingVisibilityConvergence = requiresRecovery
            ? PendingVisibilityConvergence(
                requestID: UUID().uuidString.lowercased(),
                startedAt: Date.rfc3339UTC(),
                layoutName: layoutName,
                targetSpaceID: targetSpaceID,
                unresolvedSlots: plan.unresolvedSlots
            )
            : nil

        try persist(newState)

        // A previously suspended main that is manageable again participated
        // in this successful switch, so no later focus event should suppress
        // an intentional follow-focus action for it.
        let reconciledSuspensions = Set(suspendedCompanionMainSpaces.keys).intersection(
            Set(windows.map(\.identity))
        )
        for identity in reconciledSuspensions {
            suspendedCompanionMainSpaces.removeValue(forKey: identity)
        }

        // Record intended, reported, and actual focus together with the same
        // convergence value returned to callers. This distinguishes a focus
        // steal from a partial visibility plan without misleading the GUI.
        let diagnosticActualFocused = control.focusedWindow()
        let converged = !requiresRecovery
        logger.log(
            event: "space.switch",
            fields: [
                "layout": layoutName,
                "from": previousSpaceID ?? -1,
                "to": targetSpaceID,
                "shown": plan.shows.count,
                "hidden": plan.hides.count,
                "unresolved": plan.unresolvedEntryIDs.count,
                "unresolvedSlots": plan.unresolvedSlots.count,
                "converged": converged,
                "intendedTop": plan.focusCandidates.first.map { Int($0.window.windowID) } ?? -1,
                "intendedTopBundle": plan.focusCandidates.first?.window.bundleID ?? "",
                "focused": focusedIdentity.map { Int($0.windowID) } ?? -1,
                "actualFocused": diagnosticActualFocused.map { Int($0.windowID) } ?? -1,
                "actualFocusedBundle": diagnosticActualFocused?.bundleID ?? "",
            ]
        )

        return SpaceSwitchOutcome(
            layoutName: layoutName,
            previousSpaceID: previousSpaceID,
            targetSpaceID: targetSpaceID,
            didChangeSpace: didChangeSpace,
            shownCount: plan.shows.count,
            hiddenCount: plan.hides.count,
            focusedWindowID: focusedIdentity?.windowID,
            unresolvedSlots: plan.unresolvedSlots,
            converged: converged
        )
    }

    /// Mutating commands need AX; failing early gives the CLI/GUI a clear
    /// missingPermission error instead of a silent visual no-op.
    func ensureAccessibility() throws {
        guard control.accessibilityGranted() else {
            throw ShitsuraeError(.missingPermission, "Accessibility permission is required")
        }
    }

    func focusTarget(from candidates: [BoundWindow]) -> WindowIdentity? {
        for target in candidates {
            if focusOneTarget(target) {
                return target.window.identity
            }
        }
        return nil
    }

    private func focusOneTarget(_ target: BoundWindow) -> Bool {
        let firstResult = control.focusWindow(
            windowID: target.window.windowID,
            pid: target.window.pid,
            processStartTime: target.window.processStartTime,
            bundleID: target.window.bundleID
        )
        if firstResult.isSuccess, waitForFocusedWindow(identity: target.window.identity) {
            return true
        }

        let activated = control.activateApplication(
            pid: target.window.pid,
            processStartTime: target.window.processStartTime,
            bundleID: target.window.bundleID
        )
        if activated {
            let retryResult = control.focusWindow(
                windowID: target.window.windowID,
                pid: target.window.pid,
                processStartTime: target.window.processStartTime,
                bundleID: target.window.bundleID
            )
            if retryResult.isSuccess, waitForFocusedWindow(identity: target.window.identity) {
                return true
            }
        }

        let actual = control.focusedWindow()

        logger.log(
            level: "warn",
            event: "space.switch.focusFailed",
            fields: [
                "windowID": Int(target.window.windowID),
                "bundleID": target.window.bundleID,
                "result": String(describing: firstResult),
                "activated": activated,
                "actualWindowID": actual.map { Int($0.windowID) } ?? -1,
                "actualBundleID": actual?.bundleID ?? "",
            ]
        )
        return false
    }

    private func waitForFocusedWindow(identity: WindowIdentity) -> Bool {
        if control.focusedWindowObservation().focusedIdentity == identity {
            return true
        }

        for delayMS in Self.focusVerificationDelaysMS {
            control.sleep(milliseconds: delayMS)
            if control.focusedWindowObservation().focusedIdentity == identity {
                return true
            }
        }

        return false
    }

    // MARK: - Workspace move

    /// Reassigns one tracked window to another virtual workspace. The window
    /// is identified through the shared global assignment — the entry moved
    /// is exactly the one the next switch would bind, never a guess
    /// (v1 corrupted state here by falling back to the first entry).
    @discardableResult
    public func moveWindowToWorkspace(
        window: WindowSnapshot,
        toSpaceID: Int,
        config: LoadedConfig
    ) throws -> WorkspaceMoveOutcome {
        guard let layoutName = state.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        let observation = control.focusedWindowObservation()
        let inventory = observation.inventory
        guard inventory.isAuthoritative else {
            throw VirtualSpaceEngineError.stateError("window inventory unavailable")
        }
        let manageable = WindowEligibility.geometryCandidates(in: observation)
        guard let freshWindow = manageable.first(where: { $0.identity == window.identity }) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        let entries = state.slots(layoutName: layoutName)
        let resolution = WindowRegistry.resolve(
            entries: entries.map(\.registryEntry),
            manageableWindows: manageable,
            fullInventory: inventory
        )
        guard let assignment = resolution.assignments.first(where: {
            $0.value.identity == freshWindow.identity
        }), let entry = entries.first(where: { $0.id == assignment.key }) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        return try moveResolvedWindowToWorkspace(
            window: freshWindow,
            trackedEntry: entry,
            toSpaceID: toSpaceID,
            config: config
        )
    }

    /// Transactional move primitive. `trackedEntry` and `window` must come
    /// from the same inventory resolution. It performs one final companion-
    /// safety observation before the write-ahead persist and physical move.
    func moveResolvedWindowToWorkspace(
        window: WindowSnapshot,
        trackedEntry: SlotEntry,
        toSpaceID: Int,
        config: LoadedConfig
    ) throws -> WorkspaceMoveOutcome {
        try ensureAccessibility()
        let observation = control.focusedWindowObservation()
        guard observation.inventory.isAuthoritative,
              WindowEligibility.geometryCandidates(in: observation).contains(where: {
                  $0.identity == window.identity
              })
        else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        guard let layoutName = state.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        guard layout.spaces.contains(where: { $0.spaceID == toSpaceID }) else {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: toSpaceID)
        }
        // A visibility convergence marker can remain while an unrelated
        // layout slot is temporarily unresolved (for example, Zoom replaces
        // one of its meeting windows). This move has its own write-ahead
        // transaction and restores the previous marker after a verified
        // success, so that marker must not disable explicit window moves.
        // A live-arrange recovery is different: its multi-window transaction
        // is still incomplete and must be reconciled before another mutation.
        guard !state.liveArrangeRecoveryRequired else {
            throw VirtualSpaceEngineError.stateError(
                "live arrange recovery is pending; reconcile before moving a window"
            )
        }

        var entry = trackedEntry
        let fromSpaceID = entry.spaceID
        entry = entry.bound(to: window)
        entry.spaceID = toSpaceID

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }
        let activeSpaceID = state.activeSpaceID(displayID: hostDisplay.id) ?? state.primaryActiveSpaceID
        let transition: VisibilityTransition = toSpaceID == activeSpaceID ? .show : .hide
        guard let plan = VisibilityPlanner.plan(
            entry: entry,
            window: window,
            transition: transition,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.stateError("unable to plan workspace move")
        }

        let previousPending = state.pendingVisibilityConvergence
        let requestID = UUID().uuidString.lowercased()

        func replacingEntry(in source: RuntimeState, with replacement: SlotEntry) -> RuntimeState {
            var result = source
            if result.slots.contains(where: { $0.id == replacement.id }) {
                result.slots = result.slots.map { $0.id == replacement.id ? replacement : $0 }
            } else {
                result.slots.append(replacement)
            }
            return result
        }

        // A mutation-free plan has no crash window: persist the logical move
        // directly. Every real geometry mutation uses write-ahead state below.
        if plan.mutation == .none {
            var finalState = replacingEntry(in: state, with: plan.desiredEntry)
            finalState.pendingVisibilityConvergence = previousPending
            try persist(finalState)
            return WorkspaceMoveOutcome(
                windowID: window.windowID,
                bundleID: window.bundleID,
                fromSpaceID: fromSpaceID,
                toSpaceID: toSpaceID,
                visibilityAction: plan.action
            )
        }

        // Write-ahead safety: persist the exact tracking identity, destination
        // membership and desired visibility before moving the real window.
        // A crash or later write failure therefore leaves enough state for
        // startup/shutdown recovery instead of an untracked offscreen window.
        let writeAheadEntry = Self.writeAheadEntry(for: plan)
        var intentState = replacingEntry(in: state, with: writeAheadEntry)
        intentState.pendingVisibilityConvergence = PendingVisibilityConvergence(
            requestID: requestID,
            startedAt: Date.rfc3339UTC(),
            layoutName: layoutName,
            targetSpaceID: toSpaceID,
            unresolvedSlots: [PendingUnresolvedSlot(
                slot: entry.slot,
                spaceID: toSpaceID,
                reason: "window workspace move in progress"
            )]
        )
        try persist(intentState)

        // An explicit user move is a fresh chance: drop quarantine bookkeeping
        // after the write-ahead record is durable.
        quarantinedWindowIdentities.remove(window.identity)
        convergenceFailureCounts[window.identity] = 0

        let applied = VisibilityApplier.apply(plans: [plan], control: control, logger: logger)
        let convergence = VisibilityApplier.converge(
            changes: applied,
            control: control,
            logger: logger,
            retryDelaysMS: retryDelaysMS
        )
        guard let change = convergence.changes.first else {
            throw VirtualSpaceEngineError.stateError("workspace move produced no visibility result")
        }

        let verificationUncertain = convergence.unverifiedWindowIdentities.contains(window.identity)
            || convergence.unconvergedWindowIdentities.contains(window.identity)
        if verificationUncertain {
            // Neither the desired nor the original frame is authoritative.
            // Keep the durable intent and recovery marker, then report failure.
            var pendingState = replacingEntry(in: state, with: writeAheadEntry)
            pendingState.pendingVisibilityConvergence = intentState.pendingVisibilityConvergence
            try persist(pendingState)
            throw VirtualSpaceEngineError.stateError("workspace move did not converge")
        } else if change.effectiveEntry == change.desiredEntry {
            var finalState = replacingEntry(in: state, with: change.desiredEntry)
            finalState.pendingVisibilityConvergence = previousPending
            try persist(finalState)
        } else {
            // The write was refused and the original physical state is still
            // authoritative. Roll logical membership back, but keep a newly
            // adopted tracking entry so the window can never become orphaned.
            var rollbackEntry = trackedEntry.bound(to: window)
            rollbackEntry.spaceID = fromSpaceID
            var rollbackState = replacingEntry(in: state, with: rollbackEntry)
            rollbackState.pendingVisibilityConvergence = previousPending
            try persist(rollbackState)
            throw VirtualSpaceEngineError.stateError("workspace move was refused")
        }

        logger.log(
            event: "window.workspace",
            fields: [
                "windowID": Int(window.windowID),
                "bundleID": window.bundleID,
                "from": fromSpaceID,
                "to": toSpaceID,
            ]
        )

        return WorkspaceMoveOutcome(
            windowID: window.windowID,
            bundleID: window.bundleID,
            fromSpaceID: fromSpaceID,
            toSpaceID: toSpaceID,
            visibilityAction: plan.action
        )
    }

    // MARK: - Activation tracking (MRU)

    /// Records that a window was activated. Writes only to the entry the
    /// global assignment gives this exact window — never a guessed one
    /// (v1's fuzzy first-entry fallback here polluted windowID +
    /// lastActivatedAt).
    public func markActivated(window: WindowSnapshot) {
        guard let matched = assignedEntry(for: window) else {
            return
        }

        var newState = state
        newState.slots = newState.slots.map { entry in
            guard entry.id == matched.id else { return entry }
            var updated = entry.bound(to: window)
            updated.lastActivatedAt = Date.rfc3339UTC()
            return updated
        }

        try? persist(newState)
    }

    // MARK: - State bootstrap / management

    /// arrange --state-only: rebuild slot entries for a layout from its
    /// definitions, preserving runtime bindings of unchanged definitions.
    public func bootstrapState(
        layoutName: String,
        activeSpaceID: Int,
        config: LoadedConfig
    ) throws {
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        guard layout.spaces.contains(where: { $0.spaceID == activeSpaceID }) else {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: activeSpaceID)
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        let incomingFingerprints: Set<String> = Set(layout.spaces.flatMap { space in
            space.windows.compactMap { definition in
                guard !PolicyEngine.matchesIgnoreRule(
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
        })
        let hiddenEntriesThatWouldLoseRecovery = state.slots.filter { entry in
            guard entry.visibilityState == .hiddenOffscreen else { return false }
            if let activeLayoutName = state.activeLayoutName,
               activeLayoutName != layoutName,
               entry.layoutName == activeLayoutName
            {
                return true
            }
            return entry.layoutName == layoutName
                && entry.origin == .layout
                && !incomingFingerprints.contains(entry.definitionFingerprint)
        }
        guard hiddenEntriesThatWouldLoseRecovery.isEmpty else {
            throw VirtualSpaceEngineError.stateError(
                "state-only arrange would discard recovery metadata for hidden windows; run live arrange first"
            )
        }

        let existingByFingerprint = Dictionary(
            state.slots(layoutName: layoutName).map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [SlotEntry] = []
        for space in layout.spaces {
            for definition in space.windows {
                if PolicyEngine.matchesIgnoreRule(windowDefinition: definition, rules: config.config.ignore?.apply) {
                    continue
                }
                var entry = SlotEntry.makeEntry(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )
                if let existing = existingByFingerprint[entry.definitionFingerprint] {
                    // Same definition: keep runtime binding and placement.
                    entry.id = existing.id
                    entry.spaceID = existing.spaceID
                    entry.pid = existing.pid
                    entry.processStartTime = existing.processStartTime
                    entry.windowID = existing.windowID
                    entry.lastKnownTitle = existing.lastKnownTitle
                    entry.displayID = existing.displayID
                    entry.lastVisibleFrame = existing.lastVisibleFrame
                    entry.lastHiddenFrame = existing.lastHiddenFrame
                    entry.visibilityState = existing.visibilityState
                    entry.lastActivatedAt = existing.lastActivatedAt
                }
                entries.append(entry)
            }
        }

        var newState = state
        // Replace this layout's entries; keep adopted entries of the layout.
        let adopted = state.slots(layoutName: layoutName).filter { $0.origin == .adopted }
        newState.slots = newState.slots.filter { $0.layoutName != layoutName } + entries + adopted
        newState.activeLayoutName = layoutName
        newState.configGeneration = config.configGeneration
        newState.setActiveSpace(displayID: hostDisplay.id, spaceID: activeSpaceID)
        newState.pendingVisibilityConvergence = nil

        try persist(newState)

        logger.log(
            event: "state.bootstrap",
            fields: [
                "layout": layoutName,
                "activeSpaceID": activeSpaceID,
                "entries": entries.count,
            ]
        )
    }

    /// space recover --force-clear-pending
    public func clearPending() throws {
        var newState = state
        newState.pendingVisibilityConvergence = nil
        newState.liveArrangeRecoveryRequired = false
        try persist(newState)
    }

    public func clearRuntimeState() {
        store.clear()
        state = RuntimeState()
    }

    /// Shutdown path: restore every offscreen-hidden window of the active
    /// layout so nothing stays stranded while Shitsurae is not running.
    /// Returns true when every hidden window was restored (and converged) —
    /// only then is it safe to discard the runtime state.
    @discardableResult
    public func restoreAllForShutdown(config: LoadedConfig) -> Bool {
        guard let layoutName = state.activeLayoutName else {
            return true // nothing tracked, nothing to restore
        }
        guard let layout = config.config.layouts[layoutName] else {
            return state.slots(layoutName: layoutName)
                .allSatisfy { $0.visibilityState != .hiddenOffscreen }
        }

        let hiddenEntries = state.slots(layoutName: layoutName)
            .filter { $0.visibilityState == .hiddenOffscreen }
        guard !hiddenEntries.isEmpty else {
            return !state.recoveryRequired
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            return false
        }

        let inventory = control.windowInventory()
        guard inventory.isAuthoritative else {
            return false
        }
        let allWindows = inventory.windows
        let windows = allWindows.filter(WindowEligibility.isManageableForVirtualWorkspace)
        let resolution = WindowRegistry.resolve(
            entries: hiddenEntries.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )

        var plans: [VisibilityPlan] = []
        var unresolvedCount = 0
        for entry in hiddenEntries {
            guard let window = resolution.assignments[entry.id] else {
                // Unresolved against the manageable pool. When the exact
                // window is still alive in CG (merely not AX-visible this
                // pass), restoring is incomplete: discarding the runtime
                // state now would strand the window offscreen forever.
                if let identity = entry.boundIdentity,
                   inventory.mayContain(identity)
                {
                    unresolvedCount += 1
                }
                // Otherwise the window is gone (app quit); nothing to restore.
                continue
            }
            guard let plan = VisibilityPlanner.plan(
                entry: entry,
                window: window,
                transition: .show,
                layout: layout,
                hostDisplay: hostDisplay,
                displays: displays
            ) else {
                unresolvedCount += 1
                continue
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

        var newState = state
        var slotsByID = Dictionary(uniqueKeysWithValues: newState.slots.map { ($0.id, $0) })
        let unsafeToMerge = Set(
            convergence.unverifiedWindowIdentities + convergence.unconvergedWindowIdentities
        )
        for change in convergence.changes where !unsafeToMerge.contains(change.window.identity) {
            slotsByID[change.effectiveEntry.id] = change.effectiveEntry
        }
        // Keep the original slot order (dictionary value order is unspecified).
        newState.slots = newState.slots.compactMap { slotsByID[$0.id] }
        try? persist(newState)

        return !convergence.hasPending && unresolvedCount == 0
    }

    // MARK: - Persistence

    func replaceState(_ newState: RuntimeState) throws {
        try persist(newState)
    }

    func replaceStateInMemory(_ newState: RuntimeState) {
        state = newState.canonicalized()
    }

    func ineligibleAdoptedEntryIDs(layoutName: String, windows: [WindowSnapshot]) -> Set<String> {
        let adoptedEntries = state.slots(layoutName: layoutName).filter { $0.origin == .adopted }
        guard !adoptedEntries.isEmpty else {
            return []
        }

        return Set(adoptedEntries.compactMap { entry in
            guard let identity = entry.boundIdentity,
                  let window = windows.first(where: { $0.identity == identity })
            else {
                return nil
            }
            // Only a definite companion can invalidate an adopted entry.
            // Missing AX backing or any missing classification attribute is
            // unknown and must preserve existing workspace membership.
            return WindowEligibility.classification(of: window) == .companion
                ? entry.id
                : nil
        })
    }

    func pruneIneligibleAdoptedEntriesInMemory(layoutName: String, windows: [WindowSnapshot]) {
        let ineligibleIDs = ineligibleAdoptedEntryIDs(layoutName: layoutName, windows: windows)
        guard !ineligibleIDs.isEmpty else {
            return
        }

        var newState = state
        newState.slots.removeAll { ineligibleIDs.contains($0.id) }
        replaceStateInMemory(newState)
    }

    /// Counts consecutive unconverged switches per window and quarantines a
    /// window once it crosses the threshold. A window that converges resets its
    /// count; quarantined windows leave geometry planning until an explicit
    /// workspace move clears them or they close.
    private func updateQuarantine(
        plannedChanges: [AppliedVisibilityChange],
        convergence: ConvergenceOutcome
    ) {
        let desiredUnresolved = Set(convergence.desiredUnresolvedWindowIdentities)
        let unverified = Set(convergence.unverifiedWindowIdentities)
        for change in plannedChanges {
            let identity = change.window.identity
            // Unknown inventory state is not an application refusing geometry;
            // preserve the existing count and wait for an authoritative pass.
            guard !unverified.contains(identity) else { continue }
            guard desiredUnresolved.contains(identity) else {
                convergenceFailureCounts[identity] = 0
                continue
            }
            let count = (convergenceFailureCounts[identity] ?? 0) + 1
            convergenceFailureCounts[identity] = count
            if count >= Self.quarantineThreshold, quarantinedWindowIdentities.insert(identity).inserted {
                logger.log(
                    level: "warn",
                    event: "visibility.quarantine",
                    fields: [
                        "windowID": Int(identity.windowID),
                        "bundleID": change.window.bundleID,
                        "failures": count,
                    ]
                )
            }
        }
    }

    /// A write-ahead entry must be safe on both sides of the physical AX
    /// mutation. Preserve `hiddenOffscreen` when either side is hidden: this
    /// makes a hidden→visible crash recoverable and records visible→hidden
    /// before parking. When both sides are visible, keep it visible so a
    /// pre-mutation crash cannot make shutdown unminimize a manually minimized
    /// window that Shitsurae never hid. The final persist records the exact
    /// converged state.
    private static func writeAheadEntry(for plan: VisibilityPlan) -> SlotEntry {
        var entry = plan.desiredEntry
        entry.visibilityState = plan.originalEntry.visibilityState == .hiddenOffscreen
            || plan.desiredEntry.visibilityState == .hiddenOffscreen
            ? .hiddenOffscreen
            : .visible
        if entry.lastVisibleFrame == nil {
            entry.lastVisibleFrame = plan.originalEntry.lastVisibleFrame ?? plan.window.frame
        }
        return entry
    }

    private func persist(_ newState: RuntimeState) throws {
        var toSave = newState
        toSave.revision = state.revision + 1
        do {
            toSave = try store.saveStrict(state: toSave)
        } catch {
            throw VirtualSpaceEngineError.stateError(String(describing: error))
        }
        state = toSave
    }
}
