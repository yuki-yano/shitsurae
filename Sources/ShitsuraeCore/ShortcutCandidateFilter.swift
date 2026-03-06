import Foundation

public enum ShortcutCandidateFilter {
    public static func filter(
        candidates: [SwitcherCandidate],
        excludedBundleIDs: Set<String>,
        quickKeys: String
    ) -> [SwitcherCandidate] {
        let filtered = candidates.filter { candidate in
            guard let bundleID = candidate.bundleID else {
                return true
            }
            return !excludedBundleIDs.contains(bundleID)
        }

        let quickKeyPool = Array(quickKeys)
        return filtered.enumerated().map { index, candidate in
            SwitcherCandidate(
                id: candidate.id,
                source: candidate.source,
                title: candidate.title,
                bundleID: candidate.bundleID,
                spaceID: candidate.spaceID,
                displayID: candidate.displayID,
                slot: candidate.slot,
                quickKey: index < quickKeyPool.count ? String(quickKeyPool[index]) : nil
            )
        }
    }
}
