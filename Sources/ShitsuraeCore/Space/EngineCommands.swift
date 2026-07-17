import Foundation

/// Result of processing one AX focus event. `spaceID` is the workspace the
/// window belongs to *after* processing (binding refresh or adoption already
/// applied); nil means the window stays unmanaged (focus-ignored).
public struct FocusEventOutcome: Equatable, Sendable {
    public let sequence: UInt64
    public let identity: WindowIdentity
    public let spaceID: Int?
    public let activeSpaceID: Int?
    public let didAdopt: Bool
}

/// Query and single-window command surface of the engine, used by the CLI
/// router and the GUI alike.
public extension VirtualSpaceEngine {
    // MARK: - Window resolution

    /// Resolves a CLI selector to a live window. Empty selector = focused.
    func resolveTargetWindow(selector: WindowTargetSelector) -> WindowSnapshot? {
        let observation = control.focusedWindowObservation()
        guard observation.inventory.isAuthoritative else { return nil }
        let geometryCandidates = WindowEligibility.geometryCandidates(in: observation)

        if selector.isEmpty {
            guard let focusedIdentity = observation.focusedIdentity else { return nil }
            return geometryCandidates.first { $0.identity == focusedIdentity }
        }

        let windows = geometryCandidates

        if let windowID = selector.windowID {
            guard let pid = selector.pid,
                  let processStartTime = selector.processStartTime,
                  let bundleID = selector.bundleID
            else {
                return nil
            }
            let identity = WindowIdentity(
                pid: pid,
                processStartTime: processStartTime,
                windowID: windowID,
                bundleID: bundleID
            )
            return windows.first(where: { $0.identity == identity })
        }

        guard let bundleID = selector.bundleID else {
            return nil
        }

        let rule = WindowMatchRule(
            bundleID: bundleID,
            title: selector.title.map { TitleMatcher(contains: $0) }
        )
        let processPool = selector.pid.map { pid in
            windows.filter {
                $0.pid == pid
                    && (selector.processStartTime == nil || $0.processStartTime == selector.processStartTime)
            }
        } ?? windows
        return WindowRegistry.sortedCandidates(rule: rule, pool: processPool).first
    }

    // MARK: - Focus event processing

    /// Handles one AX focus event on a single live snapshot: one enumeration
    /// feeds target resolution, the global assignment, the binding/MRU
    /// update, and — for unassigned windows — the adoption decision. Nothing
    /// is decided from an earlier snapshot, so an AX dropout or window close
    /// between enumerations can never leave a duplicate adopted entry.
    /// A definite companion surface projects state tracking to a manageable
    /// window of the same exact process. The returned identity nevertheless
    /// remains the real focused surface so follow-focus freshness checks can
    /// never accept a different focused window.
    func processFocusEvent(
        sequence: UInt64,
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        config: LoadedConfig
    ) -> FocusEventOutcome? {
        guard focusEventGate.accept(sequence) else { return nil }
        guard sequence > latestFocusEventSequence else { return nil }
        latestFocusEventSequence = sequence
        let identity = WindowIdentity(
            pid: pid,
            processStartTime: processStartTime,
            windowID: windowID,
            bundleID: bundleID
        )
        let observation = control.focusedWindowObservation()
        guard observation.focusedIdentity == identity else { return nil }
        guard let focusedWindow = observation.inventory.windows.first(where: {
            $0.identity == identity
        }) else {
            return nil
        }
        // A frontmost AX identity can transiently refer to a window that still
        // lives on another native macOS Space. Focus notifications must never
        // rebind or adopt such an off-screen window into the current virtual
        // workspace; wait for an on-screen event or the normal bulk-adoption
        // pass after it actually arrives.
        let onScreenIdentities = control.onScreenWindowIdentities()
        guard onScreenIdentities.contains(identity) else { return nil }

        guard let trackingWindow = WindowEligibility.manageableMainWindow(
            for: focusedWindow,
            mainIdentity: observation.mainIdentity,
            in: observation.inventory.windows
        ), onScreenIdentities.contains(trackingWindow.identity) else {
            return nil
        }

        let suspendedSpaceID = suspendedCompanionMainSpaces[trackingWindow.identity]
        guard let result = try? trackWindow(
            windowID: trackingWindow.windowID,
            pid: trackingWindow.pid,
            processStartTime: trackingWindow.processStartTime,
            expectedBundleID: trackingWindow.bundleID,
            config: config,
            respectFocusIgnoreRules: true,
            updateMRU: true,
            inventory: observation.inventory,
            allowBlockedBindingRefresh: trackingWindow.identity != focusedWindow.identity,
            adoptionSpaceID: suspendedSpaceID
        ), result.window != nil else {
            return nil
        }

        // Dismissing a companion normally focuses its main window. If an
        // explicit workspace switch happened while the companion was open,
        // reconcile the main to its original membership and consume this
        // focus event so follow-focus cannot immediately switch back.
        if suspendedSpaceID != nil,
           trackingWindow.identity == focusedWindow.identity
        {
            guard let activeSpaceID = currentState.primaryActiveSpaceID,
                  let entry = result.entry,
                  entry.spaceID != activeSpaceID
            else {
                suspendedCompanionMainSpaces.removeValue(forKey: trackingWindow.identity)
                return result.entry.map {
                    FocusEventOutcome(
                        sequence: sequence,
                        identity: identity,
                        spaceID: $0.spaceID,
                        activeSpaceID: currentState.primaryActiveSpaceID,
                        didAdopt: result.didAdopt
                    )
                }
            }

            do {
                _ = try switchSpace(to: activeSpaceID, config: config, reconcile: true)
                suspendedCompanionMainSpaces.removeValue(forKey: trackingWindow.identity)
            } catch {
                logger.log(
                    level: "warn",
                    event: "space.switch.companionReleaseReconcileFailed",
                    fields: [
                        "windowID": Int(trackingWindow.windowID),
                        "bundleID": trackingWindow.bundleID,
                        "originSpace": suspendedSpaceID ?? -1,
                        "activeSpace": activeSpaceID,
                        "error": String(describing: error),
                    ]
                )
            }
            return nil
        }
        return FocusEventOutcome(
            sequence: sequence,
            identity: identity,
            spaceID: result.entry?.spaceID,
            activeSpaceID: currentState.primaryActiveSpaceID,
            didAdopt: result.didAdopt
        )
    }

    /// Applies follow-focus only if this is still the latest event and the OS
    /// still reports the same exact frontmost focused window immediately
    /// before the switch. A stale continuation can never move workspaces.
    func switchSpaceForFocusEvent(
        sequence: UInt64,
        identity: WindowIdentity,
        to targetSpaceID: Int,
        config: LoadedConfig
    ) throws -> SpaceSwitchOutcome? {
        guard sequence == latestFocusEventSequence,
              focusEventGate.isCurrent(sequence)
        else {
            return nil
        }
        let observation = control.focusedWindowObservation()
        guard observation.focusedIdentity == identity else { return nil }
        return try switchSpace(to: targetSpaceID, config: config)
    }

    func invalidateFocusEvents(upTo sequence: UInt64) {
        focusEventGate.invalidate(with: sequence)
        latestFocusEventSequence = max(latestFocusEventSequence, sequence)
    }

    // MARK: - window current

    func windowCurrent() -> WindowCurrentJSON? {
        guard let window = control.focusedWindow() else {
            return nil
        }

        let entry = trackedEntry(for: window)

        return WindowCurrentJSON(
            windowID: window.windowID,
            bundleID: window.bundleID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            title: window.title,
            profile: window.profileDirectory,
            spaceID: entry?.spaceID,
            activeSpaceID: currentState.primaryActiveSpaceID,
            displayID: window.displayID ?? "",
            role: window.role,
            subrole: window.subrole,
            isModal: window.modal,
            isMinimized: window.minimized,
            frame: window.frame,
            slot: entry.flatMap { $0.slot > 0 ? $0.slot : nil }
        )
    }

    // MARK: - focus

    /// focus --slot N: targets the active workspace's tracked windows only.
    func focusSlot(_ slot: Int, config: LoadedConfig) throws -> FocusJSON {
        try ensureAccessibility()
        guard let layoutName = currentState.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        guard let activeSpaceID = currentState.primaryActiveSpaceID else {
            throw VirtualSpaceEngineError.noActiveLayout
        }

        let entries = currentState.slots(layoutName: layoutName)
            .filter { $0.spaceID == activeSpaceID && $0.slot == slot }
        guard !entries.isEmpty else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        let inventory = control.windowInventory()
        let windows = inventory.windows.filter(WindowEligibility.isManageableForVirtualWorkspace)
        let resolution = WindowRegistry.resolve(
            entries: entries.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )
        guard let (entryID, window) = resolution.assignments.first else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        try applyFocus(window: window)
        markActivated(window: window)

        return FocusJSON(
            windowID: window.windowID,
            bundleID: window.bundleID,
            slot: entry.slot > 0 ? entry.slot : nil,
            spaceID: entry.spaceID,
            didSwitchSpace: false
        )
    }

    /// focus by selector: when the target window belongs to another virtual
    /// workspace, switch there first (v1 skipped this and focused an
    /// offscreen window — bug 1-b).
    func focusWindow(selector: WindowTargetSelector, config: LoadedConfig) throws -> FocusJSON {
        try ensureAccessibility()
        guard let window = resolveTargetWindow(selector: selector) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        var didSwitchSpace = false
        let entry = trackedEntry(for: window)

        if let entry,
           let activeSpaceID = currentState.primaryActiveSpaceID,
           entry.spaceID != activeSpaceID
        {
            _ = try switchSpace(to: entry.spaceID, config: config)
            didSwitchSpace = true
        }

        try applyFocus(window: window)
        markActivated(window: window)

        return FocusJSON(
            windowID: window.windowID,
            bundleID: window.bundleID,
            slot: entry.flatMap { $0.slot > 0 ? $0.slot : nil },
            spaceID: entry?.spaceID,
            didSwitchSpace: didSwitchSpace
        )
    }

    /// Internal UI selection path. Unlike the CLI's windowID selector, an
    /// overlay candidate may outlive its original CGWindowID; accept it only
    /// while the complete identity is still live and manageable.
    func focusWindow(identity: WindowIdentity, config: LoadedConfig) throws -> FocusJSON {
        try ensureAccessibility()
        let inventory = control.windowInventory()
        guard let window = inventory.windows.first(where: {
            $0.identity == identity && WindowEligibility.isManageableForVirtualWorkspace($0)
        }) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        var didSwitchSpace = false
        let entry = assignedEntry(for: window)
        if let entry,
           let activeSpaceID = currentState.primaryActiveSpaceID,
           entry.spaceID != activeSpaceID
        {
            _ = try switchSpace(to: entry.spaceID, config: config)
            didSwitchSpace = true
        }

        try applyFocus(window: window)
        markActivated(window: window)
        return FocusJSON(
            windowID: window.windowID,
            bundleID: window.bundleID,
            slot: entry.flatMap { $0.slot > 0 ? $0.slot : nil },
            spaceID: entry?.spaceID,
            didSwitchSpace: didSwitchSpace
        )
    }

    /// Restores focus after the frontmost application terminates without
    /// changing the active virtual workspace. Candidates are limited to
    /// visible windows in the current workspace and tried in MRU order.
    ///
    /// The terminating process is excluded explicitly because AppKit can
    /// publish its termination before the last AX/CG window disappears.
    func focusPreferredWindowInActiveWorkspace(
        excludingPID: Int,
        bundleID excludedBundleID: String,
        config: LoadedConfig
    ) throws -> WindowIdentity? {
        try ensureAccessibility()
        guard let layoutName = currentState.activeLayoutName,
              let activeSpaceID = currentState.primaryActiveSpaceID
        else {
            throw VirtualSpaceEngineError.noActiveLayout
        }

        let inventory = control.windowInventory()
        guard inventory.isAuthoritative else {
            throw VirtualSpaceEngineError.stateError("window inventory unavailable")
        }

        let terminatingIdentities = Set(inventory.windows.compactMap { window in
            window.pid == excludingPID && window.bundleID == excludedBundleID
                ? window.identity
                : nil
        })
        _ = try? adoptUntrackedWindows(
            config: config,
            inventory: inventory,
            excludedWindowIdentities: terminatingIdentities
        )

        let entries = currentState.slots(layoutName: layoutName)
            .filter { $0.spaceID == activeSpaceID }
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let manageableWindows = inventory.windows.filter {
            WindowEligibility.isManageableForVirtualWorkspace($0)
        }
        let resolution = WindowRegistry.resolve(
            entries: entries.map(\.registryEntry),
            manageableWindows: manageableWindows,
            fullInventory: inventory
        )
        let onScreenIdentities = control.onScreenWindowIdentities()
        let candidates = resolution.assignments.compactMap { entryID, window -> BoundWindow? in
            guard let entry = entriesByID[entryID],
                  window.pid != excludingPID || window.bundleID != excludedBundleID,
                  !window.minimized,
                  !window.hidden,
                  onScreenIdentities.contains(window.identity)
            else {
                return nil
            }
            return BoundWindow(entry: entry, window: window)
        }
        let ordered = SpaceSwitchPlanner.preferredFocusCandidates(from: candidates)
        guard let focusedIdentity = focusTarget(from: ordered) else { return nil }

        if let focused = ordered.first(where: { $0.window.identity == focusedIdentity }) {
            var newState = currentState
            newState.slots = newState.slots.map { entry in
                guard entry.id == focused.entry.id else { return entry }
                var updated = entry.bound(to: focused.window)
                updated.lastActivatedAt = Date.rfc3339UTC()
                return updated
            }
            try replaceState(newState)
        }

        return focusedIdentity
    }

    private func applyFocus(window: WindowSnapshot) throws {
        let result = control.focusWindow(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID
        )
        if !result.isSuccess,
           !control.activateApplication(
               pid: window.pid,
               processStartTime: window.processStartTime,
               bundleID: window.bundleID
           )
        {
            throw VirtualSpaceEngineError.stateError("focus failed for window \(window.windowID)")
        }
    }

    // MARK: - window move/resize/set

    /// Unified frame mutation: nil components keep the current value.
    func setWindowFrame(
        selector: WindowTargetSelector,
        x: LengthValue?,
        y: LengthValue?,
        width: LengthValue?,
        height: LengthValue?,
        config: LoadedConfig
    ) throws -> WindowSetJSON {
        try ensureAccessibility()
        guard let window = resolveTargetWindow(selector: selector) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        let displays = control.displays()
        let display = displays.first(where: { $0.id == window.displayID })
            ?? DisplayResolver.primaryDisplay(displays)
        guard let display else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        let basis = display.visibleFrame
        func resolve(_ value: LengthValue?, dimension: Double, fallback: Double, origin: Double) throws -> Double {
            guard let value else { return fallback }
            return origin + (try LengthParser.parse(value).resolve(dimension: dimension, scale: display.scale))
        }

        let frame = ResolvedFrame(
            x: try resolve(x, dimension: basis.width, fallback: window.frame.x, origin: basis.origin.x),
            y: try resolve(y, dimension: basis.height, fallback: window.frame.y, origin: basis.origin.y),
            width: try {
                guard let width else { return window.frame.width }
                return try LengthParser.parse(width).resolve(dimension: basis.width, scale: display.scale)
            }(),
            height: try {
                guard let height else { return window.frame.height }
                return try LengthParser.parse(height).resolve(dimension: basis.height, scale: display.scale)
            }()
        )

        guard control.setWindowFrame(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            frame: frame
        ) else {
            throw VirtualSpaceEngineError.stateError("failed to set window frame")
        }

        // Keep tracking in sync when the window is managed.
        if let entry = trackedEntry(for: window) {
            var newState = currentState
            newState.slots = newState.slots.map { slot in
                guard slot.id == entry.id else { return slot }
                var updated = slot.bound(to: window)
                updated.lastVisibleFrame = frame
                return updated
            }
            try replaceState(newState)
        }

        return WindowSetJSON(windowID: window.windowID, bundleID: window.bundleID, frame: frame)
    }

    /// Snap the focused (or selected) window to a preset frame.
    func snapWindow(selector: WindowTargetSelector, preset: SnapPreset) throws -> WindowSetJSON {
        try ensureAccessibility()
        guard let window = resolveTargetWindow(selector: selector) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        let displays = control.displays()
        let display = displays.first(where: { $0.id == window.displayID })
            ?? DisplayResolver.primaryDisplay(displays)
        guard let display else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        let basis = display.visibleFrame
        let frame = SnapPresetResolver.frame(for: preset, basis: basis)

        guard control.setWindowFrame(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            frame: frame
        ) else {
            throw VirtualSpaceEngineError.stateError("failed to snap window")
        }

        if let entry = trackedEntry(for: window) {
            var newState = currentState
            newState.slots = newState.slots.map { slot in
                guard slot.id == entry.id else { return slot }
                var updated = slot.bound(to: window)
                updated.lastVisibleFrame = frame
                return updated
            }
            try replaceState(newState)
        }

        return WindowSetJSON(windowID: window.windowID, bundleID: window.bundleID, frame: frame)
    }

    // MARK: - window workspace

    /// Reassigns a window (selector or focused) to another workspace,
    /// adopting it into tracking first when it is unmanaged.
    func windowWorkspace(
        selector: WindowTargetSelector,
        toSpaceID: Int,
        config: LoadedConfig
    ) throws -> WindowWorkspaceJSON {
        try ensureAccessibility()
        guard let window = resolveTargetWindow(selector: selector) else {
            throw VirtualSpaceEngineError.windowNotTracked
        }

        // Re-validate on a fresh snapshot before creating any tracking
        // entry: binding refresh and adoption happen on the same enumeration
        // (explicit user command, so focus ignore rules do not apply here).
        let tracking = try trackWindow(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            expectedBundleID: window.bundleID,
            config: config,
            respectFocusIgnoreRules: false,
            updateMRU: false,
            persistChanges: false
        )
        guard let freshWindow = tracking.window, let trackedEntry = tracking.entry else {
            throw VirtualSpaceEngineError.windowNotTracked
        }
        let didCreateTrackingEntry = tracking.didAdopt

        let outcome = try moveResolvedWindowToWorkspace(
            window: freshWindow,
            trackedEntry: trackedEntry,
            toSpaceID: toSpaceID,
            config: config
        )
        let finalEntry = currentState.slots.first { $0.id == trackedEntry.id }

        return WindowWorkspaceJSON(
            requestID: UUID().uuidString.lowercased(),
            windowID: freshWindow.windowID,
            bundleID: freshWindow.bundleID,
            slot: finalEntry.map(\.slot) ?? 0,
            previousSpaceID: outcome.fromSpaceID,
            spaceID: outcome.toSpaceID,
            didChangeSpace: outcome.fromSpaceID != outcome.toSpaceID,
            didCreateTrackingEntry: didCreateTrackingEntry,
            visibilityAction: outcome.visibilityAction
        )
    }

    // MARK: - Adoption

    /// Pulls untracked on-screen windows of the host display into the active
    /// workspace so cycle/switcher can reach them.
    func adoptUntrackedWindows(
        config: LoadedConfig,
        persistChanges: Bool = true,
        inventory suppliedInventory: WindowInventory? = nil,
        excludedWindowIdentities: Set<WindowIdentity> = []
    ) throws -> Int {
        guard let layoutName = currentState.activeLayoutName,
              let activeSpaceID = currentState.primaryActiveSpaceID,
              let layout = config.config.layouts[layoutName]
        else {
            return 0
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            return 0
        }

        let inventory = suppliedInventory ?? control.windowInventory()
        guard inventory.isAuthoritative else { return 0 }
        let allWindows = inventory.windows
        let ineligibleAdoptedIDs = ineligibleAdoptedEntryIDs(layoutName: layoutName, windows: allWindows)
        let layoutSlots = currentState.slots(layoutName: layoutName)
        let onScreenIdentities = control.onScreenWindowIdentities()
        let windows = allWindows.filter { window in
            onScreenIdentities.contains(window.identity)
                && window.displayID == hostDisplay.id
                && !window.minimized
                && !excludedWindowIdentities.contains(window.identity)
                && WindowEligibility.isManageableForVirtualWorkspace(window)
                && !PolicyEngine.matchesIgnoreRule(window: window, rules: config.config.ignore?.focus)
        }

        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )

        guard !resolution.unassignedWindows.isEmpty || !ineligibleAdoptedIDs.isEmpty else {
            return 0
        }

        var newState = currentState
        newState.slots.removeAll { ineligibleAdoptedIDs.contains($0.id) }
        var adoptedCount = 0
        for window in resolution.unassignedWindows {
            newState.slots.append(Self.makeAdoptedEntry(
                window: window,
                layoutName: layoutName,
                spaceID: activeSpaceID
            ))
            adoptedCount += 1
        }

        if persistChanges {
            try replaceState(newState)
        } else {
            replaceStateInMemory(newState)
        }
        return adoptedCount
    }

    /// Adopts one exact focused window into the currently active workspace.
    /// The passed snapshot is only an identity hint: the decision runs on a
    /// fresh enumeration via `trackWindow`, so a window that dropped out of
    /// AX visibility or closed since the snapshot was taken is never adopted.
    func adoptWindowIntoActiveWorkspace(_ window: WindowSnapshot, config: LoadedConfig) throws -> Bool {
        let result = try trackWindow(
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            expectedBundleID: window.bundleID,
            config: config,
            respectFocusIgnoreRules: true,
            updateMRU: false
        )
        return result.didAdopt
    }

    struct WindowTrackingResult {
        /// Entry owning the window after processing (nil = unmanaged).
        let entry: SlotEntry?
        /// The window as seen by the fresh enumeration (nil = not present
        /// and manageable in the current snapshot; the caller must ignore
        /// the event instead of acting on stale data).
        let window: WindowSnapshot?
        let didAdopt: Bool
    }

    /// Single-snapshot tracking core: ONE `listAllWindows()` feeds the
    /// target lookup, the global assignment, the binding/MRU write, and the
    /// adoption decision. Adoption only ever uses the window snapshot from
    /// this same enumeration — a caller-supplied snapshot is never trusted —
    /// so "resolve succeeded, later enumeration failed, adopt from stale
    /// data" is impossible by construction.
    func trackWindow(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        expectedBundleID: String,
        config: LoadedConfig,
        respectFocusIgnoreRules: Bool,
        updateMRU: Bool,
        inventory suppliedInventory: WindowInventory? = nil,
        allowBlockedBindingRefresh: Bool = false,
        adoptionSpaceID: Int? = nil,
        persistChanges: Bool = true
    ) throws -> WindowTrackingResult {
        guard let layoutName = currentState.activeLayoutName,
              let activeSpaceID = currentState.primaryActiveSpaceID
        else {
            throw VirtualSpaceEngineError.noActiveLayout
        }

        let inventory = suppliedInventory ?? control.windowInventory()
        let targetIdentity = WindowIdentity(
            pid: pid,
            processStartTime: processStartTime,
            windowID: windowID,
            bundleID: expectedBundleID
        )
        // Focus projection may refresh the exact AX main's existing binding
        // and MRU while a sheet protects it from geometry. No other blocked
        // window enters the assignment pool, and a blocked target is never
        // newly adopted below.
        let manageable = inventory.windows.filter { candidate in
            WindowEligibility.isManageableForVirtualWorkspace(candidate)
                || (allowBlockedBindingRefresh
                    && candidate.identity == targetIdentity
                    && WindowEligibility.classification(of: candidate) == .manageable)
        }
        guard let window = manageable.first(where: {
            $0.windowID == windowID
                && $0.pid == pid
                && $0.processStartTime == processStartTime
                && $0.bundleID == expectedBundleID
        }) else {
            return WindowTrackingResult(entry: nil, window: nil, didAdopt: false)
        }

        let slots = currentState.slots(layoutName: layoutName)
        let resolution = WindowRegistry.resolve(
            entries: slots.map(\.registryEntry),
            manageableWindows: manageable,
            fullInventory: inventory
        )

        if let assignment = resolution.assignments.first(where: {
            $0.value.identity == window.identity
        }), let entry = slots.first(where: { $0.id == assignment.key }) {
            if allowBlockedBindingRefresh, entry.boundIdentity != window.identity {
                return WindowTrackingResult(entry: nil, window: window, didAdopt: false)
            }
            var updated = entry.bound(to: window)
            if updateMRU {
                updated.lastActivatedAt = Date.rfc3339UTC()
            }
            var newState = currentState
            newState.slots = newState.slots.map { $0.id == updated.id ? updated : $0 }
            if persistChanges {
                try replaceState(newState)
            }
            return WindowTrackingResult(entry: updated, window: window, didAdopt: false)
        }

        if resolution.deferredWindows.contains(where: { $0.identity == window.identity }) {
            return WindowTrackingResult(entry: nil, window: window, didAdopt: false)
        }

        if window.geometryBlocked || allowBlockedBindingRefresh {
            return WindowTrackingResult(entry: nil, window: window, didAdopt: false)
        }

        if respectFocusIgnoreRules,
           PolicyEngine.matchesIgnoreRule(window: window, rules: config.config.ignore?.focus)
        {
            return WindowTrackingResult(entry: nil, window: window, didAdopt: false)
        }

        var entry = Self.makeAdoptedEntry(
            window: window,
            layoutName: layoutName,
            spaceID: adoptionSpaceID ?? activeSpaceID
        )
        if updateMRU {
            entry.lastActivatedAt = Date.rfc3339UTC()
        }
        var newState = currentState
        newState.slots.append(entry)
        if persistChanges {
            try replaceState(newState)
        }
        return WindowTrackingResult(entry: entry, window: window, didAdopt: true)
    }

    internal static func makeAdoptedEntry(
        window: WindowSnapshot,
        layoutName: String,
        spaceID: Int
    ) -> SlotEntry {
        SlotEntry(
            layoutName: layoutName,
            spaceID: spaceID,
            slot: 0,
            origin: .adopted,
            definitionFingerprint: "adopted\u{0}\(window.bundleID)\u{0}\(window.windowID)",
            bundleID: window.bundleID,
            profile: window.profileDirectory,
            pid: window.pid,
            processStartTime: window.processStartTime,
            windowID: window.windowID,
            lastKnownTitle: window.title,
            displayID: window.displayID,
            // Native fullscreen reports the display rectangle, not the
            // windowed frame macOS should restore after leaving fullscreen.
            lastVisibleFrame: window.isFullscreen ? nil : window.frame,
            visibilityState: .visible
        )
    }

    // MARK: - Switcher / cycle candidates

    /// MRU-ordered candidates. Adopts untracked windows first so everything
    /// the user sees is reachable.
    func switcherCandidates(
        includeAllSpaces: Bool,
        config: LoadedConfig,
        excludedApps: Set<String> = []
    ) throws -> [SwitcherCandidate] {
        guard let layoutName = currentState.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        _ = try? adoptUntrackedWindows(config: config)

        let activeSpaceID = currentState.primaryActiveSpaceID
        let layoutSlots = currentState.slots(layoutName: layoutName)
            .filter { includeAllSpaces || $0.spaceID == activeSpaceID }
            .filter { !excludedApps.contains($0.bundleID) }

        let inventory = control.windowInventory()
        guard inventory.isAuthoritative else { return [] }
        let windows = inventory.windows.filter(WindowEligibility.isManageableForVirtualWorkspace)
        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )

        let bound = presentableBoundWindows(
            entries: layoutSlots,
            assignments: resolution.assignments
        )

        // MRU: most recently activated first; never-activated entries keep
        // slot order after them.
        let ordered = bound.sorted { lhs, rhs in
            switch SpaceSwitchPlanner.compareActivationRecency(
                lhs.entry.lastActivatedAt,
                rhs.entry.lastActivatedAt
            ) {
            case .orderedDescending:
                return true
            case .orderedAscending:
                return false
            case .orderedSame:
                return SpaceSwitchPlanner.switchOrdering(lhs: lhs, rhs: rhs)
            }
        }

        return ordered.map { item in
            SwitcherCandidate(
                id: item.entry.id,
                title: item.window.title.isEmpty ? item.entry.title : item.window.title,
                bundleID: item.window.bundleID,
                pid: item.window.pid,
                processStartTime: item.window.processStartTime,
                profile: item.window.profileDirectory,
                spaceID: item.entry.spaceID,
                displayID: item.window.displayID,
                slot: item.entry.slot > 0 ? item.entry.slot : nil,
                quickKey: nil,
                windowID: item.window.windowID
            )
        }
    }

    /// Cycle order: slotted windows first (slot ascending), then adopted
    /// windows in observed order. Used by nextWindow/prevWindow.
    func cycleCandidates(config: LoadedConfig, excludedApps: Set<String> = []) throws -> [SwitcherCandidate] {
        guard let layoutName = currentState.activeLayoutName else {
            throw VirtualSpaceEngineError.noActiveLayout
        }
        _ = try? adoptUntrackedWindows(config: config)

        let activeSpaceID = currentState.primaryActiveSpaceID
        let layoutSlots = currentState.slots(layoutName: layoutName)
            .filter { $0.spaceID == activeSpaceID }
            .filter { !excludedApps.contains($0.bundleID) }

        let inventory = control.windowInventory()
        guard inventory.isAuthoritative else { return [] }
        let windows = inventory.windows.filter(WindowEligibility.isManageableForVirtualWorkspace)
        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            manageableWindows: windows,
            fullInventory: inventory
        )

        let bound = presentableBoundWindows(
            entries: layoutSlots,
            assignments: resolution.assignments
        )

        let slotted = bound
            .filter { $0.entry.slot > 0 }
            .sorted { $0.entry.slot < $1.entry.slot }
        let unslotted = bound
            .filter { $0.entry.slot == 0 }
            .sorted { $0.window.frontIndex < $1.window.frontIndex }

        return (slotted + unslotted).map { item in
            SwitcherCandidate(
                id: item.entry.id,
                title: item.window.title.isEmpty ? item.entry.title : item.window.title,
                bundleID: item.window.bundleID,
                pid: item.window.pid,
                processStartTime: item.window.processStartTime,
                profile: item.window.profileDirectory,
                spaceID: item.entry.spaceID,
                displayID: item.window.displayID,
                slot: item.entry.slot > 0 ? item.entry.slot : nil,
                quickKey: nil,
                windowID: item.window.windowID
            )
        }
    }

    // MARK: - Space queries

    func spaceList(config: LoadedConfig) -> SpaceListJSON {
        guard let layoutName = currentState.activeLayoutName,
              let layout = config.config.layouts[layoutName]
        else {
            return SpaceListJSON(layoutName: nil, spaces: [])
        }

        let activeSpaceID = currentState.primaryActiveSpaceID
        let focusedIdentity = control.focusedWindow()?.identity
        let layoutSlots = currentState.slots(layoutName: layoutName)
        let hostDisplayID = currentState.activeSpaces.first?.displayID

        let spaces = layout.spaces.map(\.spaceID).sorted().map { spaceID in
            let trackedWindowIDs = layoutSlots
                .filter { $0.spaceID == spaceID }
                .compactMap(\.windowID)
            let trackedIdentities = Set(layoutSlots
                .filter { $0.spaceID == spaceID }
                .compactMap(\.boundIdentity))
            return SpaceSummaryJSON(
                spaceID: spaceID,
                displayID: hostDisplayID,
                isActive: spaceID == activeSpaceID,
                hasFocus: focusedIdentity.map { trackedIdentities.contains($0) } ?? false,
                trackedWindowIDs: trackedWindowIDs.sorted()
            )
        }

        return SpaceListJSON(layoutName: layoutName, spaces: spaces)
    }

    func spaceCurrent(config: LoadedConfig) -> SpaceCurrentJSON {
        let list = spaceList(config: config)
        return SpaceCurrentJSON(
            layoutName: list.layoutName,
            space: list.spaces.first(where: \.isActive),
            recoveryRequired: currentState.recoveryRequired
        )
    }

    // MARK: - Helpers

    /// Filters candidate bindings down to windows the user can actually
    /// reach: not minimized, not app-hidden, and either on screen right now
    /// or parked offscreen by us. This keeps phantom windows — minimized
    /// ones, windows on other *native* macOS Spaces, invisible helper
    /// windows — out of the switcher and cycle lists.
    private func presentableBoundWindows(
        entries: [SlotEntry],
        assignments: [String: WindowSnapshot]
    ) -> [BoundWindow] {
        let onScreenIdentities = control.onScreenWindowIdentities()

        return entries.compactMap { entry -> BoundWindow? in
            guard let window = assignments[entry.id] else { return nil }
            guard !window.minimized, !window.hidden else { return nil }
            guard onScreenIdentities.contains(window.identity)
                || entry.visibilityState == .hiddenOffscreen
            else {
                return nil
            }
            return BoundWindow(entry: entry, window: window)
        }
    }

    private func trackedEntry(for window: WindowSnapshot) -> SlotEntry? {
        assignedEntry(for: window)
    }
}
