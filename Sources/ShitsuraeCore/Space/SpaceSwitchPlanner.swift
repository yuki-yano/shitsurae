import Foundation

/// One entry bound to one live window for a switch operation.
public struct BoundWindow: Equatable, Sendable {
    public let entry: SlotEntry
    public let window: WindowSnapshot

    public init(entry: SlotEntry, window: WindowSnapshot) {
        self.entry = entry
        self.window = window
    }
}

public struct SpaceSwitchPlan: Equatable, Sendable {
    public let layoutName: String
    public let targetSpaceID: Int
    /// Show plans for windows of the target workspace, slot order.
    public let shows: [VisibilityPlan]
    /// Hide plans for windows of other workspaces on the host display.
    public let hides: [VisibilityPlan]
    /// Windows to try focusing after switching, in MRU fallback order.
    public let focusCandidates: [BoundWindow]
    /// The window to focus after switching (MRU within the target workspace).
    public let focusTarget: BoundWindow?
    /// Layout entries that could not be bound to any live window.
    public let unresolvedSlots: [PendingUnresolvedSlot]
    /// Adopted entries whose window no longer exists — prune them instead of
    /// reporting recovery (their fingerprint contains the dead windowID, so
    /// they can never resolve again).
    public let staleAdoptedEntryIDs: [String]
    /// Live windows no entry claimed (candidates for adoption).
    public let unassignedWindows: [WindowSnapshot]
}

/// Builds a complete switch plan from one bipartite resolution over the whole
/// layout. Pure — all side effects live in VisibilityApplier.
///
/// Single resolution pass = the structural fix for v1's multi-window bug:
/// target and "other" entries draw from one shared pool, so a window can never
/// be simultaneously "shown" by one entry and dedup-removed from the hide
/// list by another.
public enum SpaceSwitchPlanner {
    public static func plan(
        slots: [SlotEntry],
        layoutName: String,
        layout: LayoutDefinition,
        targetSpaceID: Int,
        windows: [WindowSnapshot],
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> SpaceSwitchPlan {
        let layoutSlots = slots.filter { $0.layoutName == layoutName }
        let entryByID = Dictionary(uniqueKeysWithValues: layoutSlots.map { ($0.id, $0) })

        let resolution = WindowRegistry.resolve(
            entries: layoutSlots.map(\.registryEntry),
            windows: windows
        )

        var targets: [BoundWindow] = []
        var others: [BoundWindow] = []
        for (entryID, window) in resolution.assignments {
            guard let entry = entryByID[entryID] else { continue }
            if entry.spaceID == targetSpaceID {
                targets.append(BoundWindow(entry: entry, window: window))
            } else {
                others.append(BoundWindow(entry: entry, window: window))
            }
        }

        // Hide only windows the host display manages; windows parked on other
        // displays are out of scope for this DisplayScope (multi-display
        // extension point).
        let managedOthers = others.filter { bound in
            (bound.window.displayID ?? bound.entry.displayID) == hostDisplay.id
        }

        let shows = targets
            .sorted(by: switchOrdering)
            .compactMap { bound in
                VisibilityPlanner.plan(
                    entry: bound.entry,
                    window: bound.window,
                    transition: .show,
                    layout: layout,
                    hostDisplay: hostDisplay,
                    displays: displays
                )
            }

        let hides = managedOthers
            .sorted(by: switchOrdering)
            .compactMap { bound in
                VisibilityPlanner.plan(
                    entry: bound.entry,
                    window: bound.window,
                    transition: .hide,
                    layout: layout,
                    hostDisplay: hostDisplay,
                    displays: displays
                )
            }

        let unresolvedEntries = resolution.unresolved.compactMap { entryByID[$0] }
        let unresolvedSlots = unresolvedEntries
            .filter { $0.origin == .layout }
            .map { entry in
                PendingUnresolvedSlot(
                    slot: entry.slot,
                    spaceID: entry.spaceID,
                    reason: "windowUnresolved"
                )
            }
            .sorted { lhs, rhs in
                if lhs.spaceID != rhs.spaceID { return lhs.spaceID < rhs.spaceID }
                return lhs.slot < rhs.slot
            }
        let staleAdoptedEntryIDs = unresolvedEntries
            .filter { $0.origin == .adopted }
            .map(\.id)

        let focusCandidates = preferredFocusCandidates(from: targets)

        return SpaceSwitchPlan(
            layoutName: layoutName,
            targetSpaceID: targetSpaceID,
            shows: shows,
            hides: hides,
            focusCandidates: focusCandidates,
            focusTarget: focusCandidates.first,
            unresolvedSlots: unresolvedSlots,
            staleAdoptedEntryIDs: staleAdoptedEntryIDs,
            unassignedWindows: resolution.unassignedWindows
        )
    }

    /// MRU focus selection: most recently activated entry wins; ties resolve
    /// to the lowest slot / frontmost window.
    public static func preferredFocusTarget(from targets: [BoundWindow]) -> BoundWindow? {
        preferredFocusCandidates(from: targets).first
    }

    /// MRU focus selection with deterministic fallback order.
    public static func preferredFocusCandidates(from targets: [BoundWindow]) -> [BoundWindow] {
        targets.sorted { lhs, rhs in
            switch compareActivationRecency(lhs.entry.lastActivatedAt, rhs.entry.lastActivatedAt) {
            case .orderedDescending:
                return true
            case .orderedAscending:
                return false
            case .orderedSame:
                return switchOrdering(lhs: lhs, rhs: rhs)
            }
        }
    }

    static func switchOrdering(lhs: BoundWindow, rhs: BoundWindow) -> Bool {
        if lhs.entry.slot != rhs.entry.slot {
            return lhs.entry.slot < rhs.entry.slot
        }
        if lhs.window.frontIndex != rhs.window.frontIndex {
            return lhs.window.frontIndex < rhs.window.frontIndex
        }
        return lhs.window.windowID < rhs.window.windowID
    }

    static func compareActivationRecency(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs == rhs {
                return .orderedSame
            }
            return lhs < rhs ? .orderedAscending : .orderedDescending
        case (.some, nil):
            return .orderedDescending
        case (nil, .some):
            return .orderedAscending
        case (nil, nil):
            return .orderedSame
        }
    }
}
