import Foundation

package struct SpaceCycleState: Equatable {
    package let spaceID: Int
    package var trailingWindowIDs: [UInt32]

    package init(spaceID: Int, trailingWindowIDs: [UInt32] = []) {
        self.spaceID = spaceID
        self.trailingWindowIDs = trailingWindowIDs
    }
}

package enum ShortcutCandidateOrdering {
    package static func switcherCandidates(
        windows: [WindowSnapshot],
        currentSpaceID: Int?,
        slotEntries: [SlotEntry],
        ignoreFocusRules: IgnoreRuleSet?,
        excludedBundleIDs: Set<String>,
        quickKeys: String
    ) -> [SwitcherCandidate] {
        guard currentSpaceID != nil else {
            return []
        }

        let ordered = liveCandidates(
            windows: windows,
            currentSpaceID: currentSpaceID,
            slotEntries: slotEntries,
            ignoreFocusRules: ignoreFocusRules,
            excludedBundleIDs: excludedBundleIDs
        )
        .sorted(by: compareLiveCandidates)
        .map(\.candidate)

        return ShortcutCandidateFilter.filter(
            candidates: ordered,
            excludedBundleIDs: excludedBundleIDs,
            quickKeys: quickKeys
        )
    }

    package static func cycleCandidates(
        windows: [WindowSnapshot],
        currentSpaceID: Int?,
        slotEntries: [SlotEntry],
        ignoreFocusRules: IgnoreRuleSet?,
        excludedBundleIDs: Set<String>,
        quickKeys: String,
        state: SpaceCycleState?
    ) -> (candidates: [SwitcherCandidate], state: SpaceCycleState?) {
        guard let currentSpaceID else {
            return ([], nil)
        }

        let live = liveCandidates(
            windows: windows,
            currentSpaceID: currentSpaceID,
            slotEntries: slotEntries,
            ignoreFocusRules: ignoreFocusRules,
            excludedBundleIDs: excludedBundleIDs
        )

        let fixed = live
            .filter { $0.candidate.slot != nil }
            .sorted(by: compareCycleFixedCandidates)
            .map(\.candidate)

        let trailingLive = live
            .filter { $0.candidate.slot == nil }
            .sorted(by: compareLiveCandidates)

        let liveTrailingIDs = trailingLive.map(\.window.windowID)
        let liveTrailingSet = Set(liveTrailingIDs)

        var nextState = state?.spaceID == currentSpaceID
            ? state!
            : SpaceCycleState(spaceID: currentSpaceID)

        nextState.trailingWindowIDs.removeAll { !liveTrailingSet.contains($0) }

        let existingIDs = Set(nextState.trailingWindowIDs)
        for windowID in liveTrailingIDs where !existingIDs.contains(windowID) {
            nextState.trailingWindowIDs.append(windowID)
        }

        let trailingByID = Dictionary(uniqueKeysWithValues: trailingLive.map { ($0.window.windowID, $0.candidate) })
        let orderedTrailing = nextState.trailingWindowIDs.compactMap { trailingByID[$0] }
        let ordered = fixed + orderedTrailing

        return (
            ShortcutCandidateFilter.filter(
                candidates: ordered,
                excludedBundleIDs: excludedBundleIDs,
                quickKeys: quickKeys
            ),
            nextState
        )
    }

    private struct LiveCandidate {
        let window: WindowSnapshot
        let candidate: SwitcherCandidate
    }

    private static func liveCandidates(
        windows: [WindowSnapshot],
        currentSpaceID: Int?,
        slotEntries: [SlotEntry],
        ignoreFocusRules: IgnoreRuleSet?,
        excludedBundleIDs: Set<String>
    ) -> [LiveCandidate] {
        guard let currentSpaceID else {
            return []
        }

        return windows.compactMap { window in
            guard window.spaceID == currentSpaceID,
                  !window.isFullscreen,
                  !window.hidden,
                  !window.minimized,
                  !excludedBundleIDs.contains(window.bundleID),
                  !PolicyEngine.matchesIgnoreRule(window: window, rules: ignoreFocusRules)
            else {
                return nil
            }

            let slot = slotEntries.first(where: { entry in
                if let windowID = entry.windowID {
                    return windowID == window.windowID
                }
                return entry.bundleID == window.bundleID
            })?.slot

            return LiveCandidate(
                window: window,
                candidate: SwitcherCandidate(
                    id: "window:\(window.windowID)",
                    source: .window,
                    title: window.title.isEmpty ? window.bundleID : window.title,
                    bundleID: window.bundleID,
                    profile: window.profileDirectory,
                    spaceID: window.spaceID,
                    displayID: window.displayID,
                    slot: slot,
                    quickKey: nil
                )
            )
        }
    }

    private static func compareLiveCandidates(_ lhs: LiveCandidate, _ rhs: LiveCandidate) -> Bool {
        if lhs.window.frontIndex != rhs.window.frontIndex {
            return lhs.window.frontIndex < rhs.window.frontIndex
        }

        if lhs.window.windowID != rhs.window.windowID {
            return lhs.window.windowID < rhs.window.windowID
        }

        return lhs.candidate.id < rhs.candidate.id
    }

    private static func compareCycleFixedCandidates(_ lhs: LiveCandidate, _ rhs: LiveCandidate) -> Bool {
        let leftSlot = lhs.candidate.slot ?? Int.max
        let rightSlot = rhs.candidate.slot ?? Int.max
        if leftSlot != rightSlot {
            return leftSlot < rightSlot
        }

        return compareLiveCandidates(lhs, rhs)
    }
}
