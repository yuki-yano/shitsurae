import Foundation

public enum SwitcherPreviewCapturePlanner {
    public static func plannedJobs(
        candidates: [SwitcherCandidate],
        cachedPreviewIDs: Set<String>,
        pendingPreviewIDs: Set<String>,
        thumbnailsEnabled: Bool = true,
        forceRefreshVisiblePreviews: Bool
    ) -> [String: UInt32] {
        guard thumbnailsEnabled else {
            return [:]
        }

        var jobs: [String: UInt32] = [:]

        for candidate in candidates {
            guard candidate.source == .window,
                  !pendingPreviewIDs.contains(candidate.id),
                  (forceRefreshVisiblePreviews || !cachedPreviewIDs.contains(candidate.id)),
                  let windowID = parseWindowID(from: candidate.id)
            else {
                continue
            }

            jobs[candidate.id] = windowID
        }

        return jobs
    }

    public static func parseWindowID(from candidateID: String) -> UInt32? {
        let parts = candidateID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "window",
              let rawID = UInt32(parts[1])
        else {
            return nil
        }

        return rawID
    }
}
