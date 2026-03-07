import Foundation

package enum SwitcherCandidateSelection {
    package static func initialIndex(
        candidates: [SwitcherCandidate],
        focusedWindowID: UInt32?,
        frontmostBundleID: String?,
        forward: Bool
    ) -> Int {
        guard !candidates.isEmpty else {
            return 0
        }

        guard candidates.count > 1 else {
            return 0
        }

        if let currentIndex = currentCandidateIndex(
            candidates: candidates,
            focusedWindowID: focusedWindowID,
            frontmostBundleID: frontmostBundleID
        ) {
            return forward
                ? (currentIndex + 1) % candidates.count
                : (currentIndex - 1 + candidates.count) % candidates.count
        }

        return forward ? 0 : (candidates.count - 1)
    }

    package static func candidateWindowID(from candidateID: String) -> UInt32? {
        let parts = candidateID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "window",
              let rawID = UInt32(parts[1])
        else {
            return nil
        }

        return rawID
    }

    private static func currentCandidateIndex(
        candidates: [SwitcherCandidate],
        focusedWindowID: UInt32?,
        frontmostBundleID: String?
    ) -> Int? {
        if let focusedWindowID,
           let focusedIndex = candidates.firstIndex(where: { candidateWindowID(from: $0.id) == focusedWindowID })
        {
            return focusedIndex
        }

        if let frontmostBundleID,
           let bundleIndex = candidates.firstIndex(where: { $0.bundleID == frontmostBundleID })
        {
            return bundleIndex
        }

        return nil
    }
}
