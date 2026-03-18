import Foundation

public enum ShortcutCandidateFilter {
    public static func filter(
        candidates: [SwitcherCandidate],
        excludedBundleIDs: Set<String>,
        quickKeys: String
    ) -> [SwitcherCandidate] {
        assignQuickKeys(
            candidates: excluding(candidates: candidates, excludedBundleIDs: excludedBundleIDs),
            quickKeys: quickKeys
        )
    }

    public static func excluding(
        candidates: [SwitcherCandidate],
        excludedBundleIDs: Set<String>
    ) -> [SwitcherCandidate] {
        candidates.filter { candidate in
            guard let bundleID = candidate.bundleID else {
                return true
            }
            return !excludedBundleIDs.contains(bundleID)
        }
    }

    public static func assignQuickKeys(
        candidates: [SwitcherCandidate],
        quickKeys: String
    ) -> [SwitcherCandidate] {
        let quickKeyPool = Array(quickKeys)
        return candidates.enumerated().map { index, candidate in
            SwitcherCandidate(
                id: candidate.id,
                source: candidate.source,
                title: candidate.title,
                bundleID: candidate.bundleID,
                profile: candidate.profile,
                spaceID: candidate.spaceID,
                displayID: candidate.displayID,
                slot: candidate.slot,
                quickKey: index < quickKeyPool.count ? String(quickKeyPool[index]) : nil
            )
        }
    }
}
