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
    private var state: RuntimeState

    public init(
        store: RuntimeStateStore,
        control: WindowControl,
        logger: ShitsuraeLogger,
        retryDelaysMS: [Int] = VisibilityApplier.defaultRetryDelaysMS,
        arrangeWaitTimeoutMS: Int = 5000
    ) {
        self.store = store
        self.control = control
        self.logger = logger
        self.retryDelaysMS = retryDelaysMS
        self.arrangeWaitTimeoutMS = arrangeWaitTimeoutMS
        self.state = store.load()
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

    /// The virtual workspace a tracked window belongs to, nil when untracked.
    public func spaceID(forWindowID windowID: UInt32) -> Int? {
        guard let layoutName = state.activeLayoutName else { return nil }
        return state.slots(layoutName: layoutName).first(where: { $0.windowID == windowID })?.spaceID
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

        // Untracked visible windows belong to the workspace the user sees
        // them on — adopt them into the *pre-switch* workspace so they hide
        // together with it instead of drifting to wherever the switcher is
        // first opened.
        _ = try? adoptUntrackedWindows(config: config, persistChanges: false)

        let windows = control.listAllWindows()
        let plan = SpaceSwitchPlanner.plan(
            slots: state.slots,
            layoutName: layoutName,
            layout: layout,
            targetSpaceID: targetSpaceID,
            windows: windows,
            hostDisplay: hostDisplay,
            displays: displays
        )

        let applied = VisibilityApplier.apply(
            plans: plan.shows + plan.hides,
            control: control,
            logger: logger
        )

        // Focus the MRU window of the target workspace right away — the
        // convergence retries below can take a few hundred ms and the user
        // must not wait for them to get keyboard focus.
        var focusedWindowID = focusTarget(plan.focusTarget)

        let convergence = VisibilityApplier.converge(
            changes: applied,
            control: control,
            logger: logger,
            retryDelaysMS: retryDelaysMS
        )

        // The early focus can fail while the window is still settling;
        // retry once after convergence.
        if focusedWindowID == nil, plan.focusTarget != nil {
            focusedWindowID = focusTarget(plan.focusTarget)
        }

        // Persist: merge effective entries back by id, update active space,
        // record pending convergence when not fully converged.
        var newState = state
        var slotsByID = Dictionary(uniqueKeysWithValues: newState.slots.map { ($0.id, $0) })
        for change in convergence.changes {
            slotsByID[change.effectiveEntry.id] = change.effectiveEntry
        }
        if let focusedWindowID,
           let focusEntry = plan.focusTarget?.entry,
           var entry = slotsByID[focusEntry.id],
           entry.windowID == focusedWindowID
        {
            entry.lastActivatedAt = Date.rfc3339UTC()
            slotsByID[entry.id] = entry
        }
        // Adopted entries whose window is gone can never resolve again
        // (their fingerprint embeds the dead windowID) — drop them so they
        // do not pollute recovery state forever.
        for staleID in plan.staleAdoptedEntryIDs {
            slotsByID.removeValue(forKey: staleID)
        }
        newState.slots = Array(slotsByID.values)
        newState.setActiveSpace(displayID: hostDisplay.id, spaceID: targetSpaceID)
        // ⑥ Drop active-space records of displays that are no longer
        // connected; a reconnect can change the display UUID and the stale
        // first entry would otherwise shadow the live one.
        newState.activeSpaces.removeAll { entry in
            !displays.contains(where: { $0.id == entry.displayID })
        }
        newState.activeLayoutName = layoutName
        newState.pendingVisibilityConvergence = convergence.hasPending || !plan.unresolvedSlots.isEmpty
            ? PendingVisibilityConvergence(
                requestID: UUID().uuidString.lowercased(),
                startedAt: Date.rfc3339UTC(),
                layoutName: layoutName,
                targetSpaceID: targetSpaceID,
                unresolvedSlots: plan.unresolvedSlots
            )
            : nil

        try persist(newState)

        logger.log(
            event: "space.switch",
            fields: [
                "layout": layoutName,
                "from": previousSpaceID ?? -1,
                "to": targetSpaceID,
                "shown": plan.shows.count,
                "hidden": plan.hides.count,
                "unresolved": plan.unresolvedSlots.count,
                "converged": !convergence.hasPending,
            ]
        )

        return SpaceSwitchOutcome(
            layoutName: layoutName,
            previousSpaceID: previousSpaceID,
            targetSpaceID: targetSpaceID,
            didChangeSpace: didChangeSpace,
            shownCount: plan.shows.count,
            hiddenCount: plan.hides.count,
            focusedWindowID: focusedWindowID,
            unresolvedSlots: plan.unresolvedSlots,
            converged: !convergence.hasPending
        )
    }

    /// Mutating commands need AX; failing early gives the CLI/GUI a clear
    /// missingPermission error instead of a silent visual no-op.
    func ensureAccessibility() throws {
        guard control.accessibilityGranted() else {
            throw ShitsuraeError(.missingPermission, "Accessibility permission is required")
        }
    }

    private func focusTarget(_ target: BoundWindow?) -> UInt32? {
        guard let target else { return nil }

        let result = control.focusWindow(
            windowID: target.window.windowID,
            bundleID: target.window.bundleID
        )
        if result.isSuccess || control.activateBundle(bundleID: target.window.bundleID) {
            return target.window.windowID
        }

        logger.log(
            level: "warn",
            event: "space.switch.focusFailed",
            fields: [
                "windowID": Int(target.window.windowID),
                "bundleID": target.window.bundleID,
            ]
        )
        return nil
    }

    // MARK: - Workspace move

    /// Reassigns one tracked window to another virtual workspace. The window
    /// is identified strictly (WindowRegistry.lookup) — ambiguity is an error,
    /// never a guess (v1 corrupted state here).
    @discardableResult
    public func moveWindowToWorkspace(
        window: WindowSnapshot,
        toSpaceID: Int,
        config: LoadedConfig
    ) throws -> WorkspaceMoveOutcome {
        try ensureAccessibility()
        guard let layoutName = state.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        guard layout.spaces.contains(where: { $0.spaceID == toSpaceID }) else {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: toSpaceID)
        }

        let layoutSlots = state.slots(layoutName: layoutName)
        guard let matched = WindowRegistry.lookup(
            window: window,
            entries: layoutSlots.map(\.registryEntry)
        ) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        guard var entry = layoutSlots.first(where: { $0.id == matched.id }) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        let fromSpaceID = entry.spaceID
        entry = entry.bound(to: window)
        entry.spaceID = toSpaceID

        let displays = control.displays()
        let hostDisplay = DisplayResolver.hostDisplay(layout: layout, config: config.config, displays: displays)
        let activeSpaceID = hostDisplay.flatMap { state.activeSpaceID(displayID: $0.id) } ?? state.primaryActiveSpaceID

        var newState = state
        // Moving off the active workspace parks the window offscreen
        // immediately; moving onto it shows the window.
        if let hostDisplay {
            if toSpaceID != activeSpaceID {
                if let plan = VisibilityPlanner.plan(
                    entry: entry,
                    window: window,
                    transition: .hide,
                    layout: layout,
                    hostDisplay: hostDisplay,
                    displays: displays
                ) {
                    let applied = VisibilityApplier.apply(plans: [plan], control: control, logger: logger)
                    let convergence = VisibilityApplier.converge(
                        changes: applied,
                        control: control,
                        logger: logger,
                        retryDelaysMS: retryDelaysMS
                    )
                    if let effective = convergence.changes.first?.effectiveEntry {
                        entry = effective
                        entry.spaceID = toSpaceID
                    }
                }
            } else {
                if let plan = VisibilityPlanner.plan(
                    entry: entry,
                    window: window,
                    transition: .show,
                    layout: layout,
                    hostDisplay: hostDisplay,
                    displays: displays
                ) {
                    let applied = VisibilityApplier.apply(plans: [plan], control: control, logger: logger)
                    let convergence = VisibilityApplier.converge(
                        changes: applied,
                        control: control,
                        logger: logger,
                        retryDelaysMS: retryDelaysMS
                    )
                    if let effective = convergence.changes.first?.effectiveEntry {
                        entry = effective
                        entry.spaceID = toSpaceID
                    }
                }
            }
        }

        newState.slots = newState.slots.map { $0.id == entry.id ? entry : $0 }
        try persist(newState)

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
            toSpaceID: toSpaceID
        )
    }

    // MARK: - Activation tracking (MRU)

    /// Records that a window was activated. Strict lookup only: when the
    /// window can't be unambiguously matched to an entry, nothing is written
    /// (v1's fuzzy fallback here polluted windowID + lastActivatedAt).
    public func markActivated(window: WindowSnapshot) {
        guard let layoutName = state.activeLayoutName else { return }
        let layoutSlots = state.slots(layoutName: layoutName)
        guard let matched = WindowRegistry.lookup(
            window: window,
            entries: layoutSlots.map(\.registryEntry)
        ) else {
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
            return true
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            return false
        }

        let windows = control.listAllWindows()
        let resolution = WindowRegistry.resolve(
            entries: hiddenEntries.map(\.registryEntry),
            windows: windows
        )

        var plans: [VisibilityPlan] = []
        var unresolvedCount = 0
        for entry in hiddenEntries {
            guard let window = resolution.assignments[entry.id] else {
                // The window is gone (app quit); nothing left to restore.
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
        for change in convergence.changes {
            slotsByID[change.effectiveEntry.id] = change.effectiveEntry
        }
        newState.slots = Array(slotsByID.values)
        try? persist(newState)

        return !convergence.hasPending && unresolvedCount == 0
    }

    // MARK: - Persistence

    func replaceState(_ newState: RuntimeState) throws {
        try persist(newState)
    }

    func replaceStateInMemory(_ newState: RuntimeState) {
        state = newState
    }

    private func persist(_ newState: RuntimeState) throws {
        var toSave = newState
        toSave.revision = state.revision + 1
        do {
            try store.saveStrict(state: toSave)
        } catch {
            throw VirtualSpaceEngineError.stateError(String(describing: error))
        }
        state = toSave
    }
}
