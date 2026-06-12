import Foundation

/// Query and single-window command surface of the engine, used by the CLI
/// router and the GUI alike.
public extension VirtualSpaceEngine {
    // MARK: - Window resolution

    /// Resolves a CLI selector to a live window. Empty selector = focused.
    func resolveTargetWindow(selector: WindowTargetSelector) -> WindowSnapshot? {
        if selector.isEmpty {
            return control.focusedWindow()
        }

        let windows = control.listAllWindows()

        if let windowID = selector.windowID {
            return windows.first(where: { $0.windowID == windowID })
        }

        guard let bundleID = selector.bundleID else {
            return nil
        }

        let rule = WindowMatchRule(
            bundleID: bundleID,
            title: selector.title.map { TitleMatcher(contains: $0) }
        )
        return WindowRegistry.sortedCandidates(rule: rule, pool: windows).first
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
            title: window.title,
            profile: window.profileDirectory,
            spaceID: entry?.spaceID,
            activeSpaceID: currentState.primaryActiveSpaceID,
            displayID: window.displayID ?? "",
            role: window.role,
            subrole: window.subrole,
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

        let windows = control.listAllWindows()
        let resolution = WindowRegistry.resolve(
            entries: entries.map(\.registryEntry),
            windows: windows
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

    private func applyFocus(window: WindowSnapshot) throws {
        let result = control.focusWindow(windowID: window.windowID, bundleID: window.bundleID)
        if !result.isSuccess, !control.activateBundle(bundleID: window.bundleID) {
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

        let basis = VisibilityPlanner.coordinateRect(display.visibleFrame, displays: displays)
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

        guard control.setWindowFrame(windowID: window.windowID, bundleID: window.bundleID, frame: frame) else {
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

        let basis = VisibilityPlanner.coordinateRect(display.visibleFrame, displays: displays)
        let frame = SnapPresetResolver.frame(for: preset, basis: basis)

        guard control.setWindowFrame(windowID: window.windowID, bundleID: window.bundleID, frame: frame) else {
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

        var didCreateTrackingEntry = false
        if trackedEntry(for: window) == nil {
            try adoptWindow(window, config: config)
            didCreateTrackingEntry = true
        }

        let outcome = try moveWindowToWorkspace(window: window, toSpaceID: toSpaceID, config: config)
        let entry = trackedEntry(for: window)

        return WindowWorkspaceJSON(
            requestID: UUID().uuidString.lowercased(),
            windowID: window.windowID,
            bundleID: window.bundleID,
            slot: entry.map(\.slot) ?? 0,
            previousSpaceID: outcome.fromSpaceID,
            spaceID: outcome.toSpaceID,
            didChangeSpace: outcome.fromSpaceID != outcome.toSpaceID,
            didCreateTrackingEntry: didCreateTrackingEntry,
            visibilityAction: toSpaceID == currentState.primaryActiveSpaceID ? "shown" : "hiddenOffscreen"
        )
    }

    // MARK: - Adoption

    /// Pulls untracked on-screen windows of the host display into the active
    /// workspace so cycle/switcher can reach them.
    func adoptUntrackedWindows(config: LoadedConfig) throws -> Int {
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

        let layoutSlots = currentState.slots(layoutName: layoutName)
        let windows = control.listWindows().filter { window in
            window.displayID == hostDisplay.id
                && !window.minimized
                && !window.bundleID.hasPrefix("com.yuki-yano.shitsurae")
                && !PolicyEngine.matchesIgnoreRule(window: window, rules: config.config.ignore?.focus)
        }

        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            windows: windows
        )

        guard !resolution.unassignedWindows.isEmpty else {
            return 0
        }

        var newState = currentState
        var adoptedCount = 0
        for window in resolution.unassignedWindows {
            let entry = SlotEntry(
                layoutName: layoutName,
                spaceID: activeSpaceID,
                slot: 0,
                origin: .adopted,
                definitionFingerprint: "adopted\u{0}\(window.bundleID)\u{0}\(window.windowID)",
                bundleID: window.bundleID,
                profile: window.profileDirectory,
                pid: window.pid,
                windowID: window.windowID,
                lastKnownTitle: window.title,
                displayID: window.displayID,
                lastVisibleFrame: window.frame,
                visibilityState: .visible
            )
            newState.slots.append(entry)
            adoptedCount += 1
        }

        try replaceState(newState)
        return adoptedCount
    }

    private func adoptWindow(_ window: WindowSnapshot, config: LoadedConfig) throws {
        guard let layoutName = currentState.activeLayoutName,
              let activeSpaceID = currentState.primaryActiveSpaceID
        else {
            throw VirtualSpaceEngineError.noActiveLayout
        }

        var newState = currentState
        newState.slots.append(
            SlotEntry(
                layoutName: layoutName,
                spaceID: activeSpaceID,
                slot: 0,
                origin: .adopted,
                definitionFingerprint: "adopted\u{0}\(window.bundleID)\u{0}\(window.windowID)",
                bundleID: window.bundleID,
                profile: window.profileDirectory,
                pid: window.pid,
                windowID: window.windowID,
                lastKnownTitle: window.title,
                displayID: window.displayID,
                lastVisibleFrame: window.frame,
                visibilityState: .visible
            )
        )
        try replaceState(newState)
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

        let windows = control.listAllWindows()
        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            windows: windows
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

        let windows = control.listAllWindows()
        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            windows: windows
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
        let focusedWindowID = control.focusedWindow()?.windowID
        let layoutSlots = currentState.slots(layoutName: layoutName)
        let hostDisplayID = currentState.activeSpaces.first?.displayID

        let spaces = layout.spaces.map(\.spaceID).sorted().map { spaceID in
            let trackedWindowIDs = layoutSlots
                .filter { $0.spaceID == spaceID }
                .compactMap(\.windowID)
            return SpaceSummaryJSON(
                spaceID: spaceID,
                displayID: hostDisplayID,
                isActive: spaceID == activeSpaceID,
                hasFocus: focusedWindowID.map { trackedWindowIDs.contains($0) } ?? false,
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
        let onScreenIDs = control.onScreenWindowIDs()

        return entries.compactMap { entry -> BoundWindow? in
            guard let window = assignments[entry.id] else { return nil }
            guard !window.minimized, !window.hidden else { return nil }
            guard onScreenIDs.contains(window.windowID)
                || entry.visibilityState == .hiddenOffscreen
            else {
                return nil
            }
            return BoundWindow(entry: entry, window: window)
        }
    }

    private func trackedEntry(for window: WindowSnapshot) -> SlotEntry? {
        guard let layoutName = currentState.activeLayoutName else { return nil }
        let layoutSlots = currentState.slots(layoutName: layoutName)
        guard let matched = WindowRegistry.lookup(
            window: window,
            entries: layoutSlots.map(\.registryEntry)
        ) else {
            return nil
        }
        return layoutSlots.first(where: { $0.id == matched.id })
    }
}
