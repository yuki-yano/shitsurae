import XCTest
@testable import ShitsuraeCore

final class SwitcherPreviewCapturePlannerTests: XCTestCase {
    func testPlannedJobsRefreshesCachedWindowCandidatesWhenForced() {
        let candidates = [
            SwitcherCandidate(
                id: "window:101",
                source: .window,
                title: "Editor",
                bundleID: "com.example.editor",
                spaceID: 1,
                displayID: "display-a",
                slot: 1,
                quickKey: "a"
            ),
        ]

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: ["window:101"],
            pendingPreviewIDs: [],
            forceRefreshVisiblePreviews: true
        )

        XCTAssertEqual(jobs, ["window:101": 101])
    }

    func testPlannedJobsSkipsCachedWindowCandidatesWithoutForcedRefresh() {
        let candidates = [
            SwitcherCandidate(
                id: "window:101",
                source: .window,
                title: "Editor",
                bundleID: "com.example.editor",
                spaceID: 1,
                displayID: "display-a",
                slot: 1,
                quickKey: "a"
            ),
        ]

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: ["window:101"],
            pendingPreviewIDs: [],
            forceRefreshVisiblePreviews: false
        )

        XCTAssertTrue(jobs.isEmpty)
    }

    func testPlannedJobsSkipsPendingAndNonWindowCandidates() {
        let candidates = [
            SwitcherCandidate(
                id: "window:101",
                source: .window,
                title: "Editor",
                bundleID: "com.example.editor",
                spaceID: 1,
                displayID: "display-a",
                slot: 1,
                quickKey: "a"
            ),
            SwitcherCandidate(
                id: "window:bad",
                source: .window,
                title: "Bad",
                bundleID: "com.example.bad",
                spaceID: 1,
                displayID: "display-a",
                slot: 2,
                quickKey: "b"
            ),
            SwitcherCandidate(
                id: "window:dev",
                source: .window,
                title: "dev",
                bundleID: "com.apple.Terminal",
                spaceID: 1,
                displayID: "display-a",
                slot: 3,
                quickKey: "c"
            ),
        ]

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: [],
            pendingPreviewIDs: ["window:101"],
            forceRefreshVisiblePreviews: true
        )

        XCTAssertTrue(jobs.isEmpty)
    }

    func testPlannedJobsReturnsEmptyWhenThumbnailsDisabled() {
        let candidates = [
            SwitcherCandidate(
                id: "window:101",
                source: .window,
                title: "Editor",
                bundleID: "com.example.editor",
                spaceID: 1,
                displayID: "display-a",
                slot: 1,
                quickKey: "a"
            ),
        ]

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: [],
            pendingPreviewIDs: [],
            thumbnailsEnabled: false,
            forceRefreshVisiblePreviews: true
        )

        XCTAssertTrue(jobs.isEmpty)
    }
}
