import XCTest
@testable import ShitsuraeCore

final class SwitcherCandidateSelectionTests: XCTestCase {
    func testInitialIndexStartsFromNextSlotWhenFocusedWindowIsTracked() {
        let candidates = [
            candidate(windowID: 101, bundleID: "com.example.one", slot: 1),
            candidate(windowID: 102, bundleID: "com.example.two", slot: 2),
            candidate(windowID: 103, bundleID: "com.example.three", slot: 3),
            candidate(windowID: 104, bundleID: "com.example.extra", slot: nil),
        ]

        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 102,
                frontmostBundleID: "com.example.two",
                forward: true
            ),
            2
        )
        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 102,
                frontmostBundleID: "com.example.two",
                forward: false
            ),
            0
        )
    }

    func testInitialIndexWrapsAroundFromLastCandidate() {
        let candidates = [
            candidate(windowID: 101, bundleID: "com.example.one", slot: 1),
            candidate(windowID: 102, bundleID: "com.example.two", slot: 2),
            candidate(windowID: 103, bundleID: "com.example.extra", slot: nil),
        ]

        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 103,
                frontmostBundleID: "com.example.extra",
                forward: true
            ),
            0
        )
        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 103,
                frontmostBundleID: "com.example.extra",
                forward: false
            ),
            1
        )
    }

    func testInitialIndexFallsBackToFrontmostBundleWhenFocusedWindowIsUnavailable() {
        let candidates = [
            candidate(windowID: 201, bundleID: "com.example.one", slot: 1),
            candidate(windowID: 202, bundleID: "com.example.two", slot: 2),
            candidate(windowID: 203, bundleID: "com.example.extra", slot: nil),
        ]

        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: nil,
                frontmostBundleID: "com.example.two",
                forward: true
            ),
            2
        )
        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: nil,
                frontmostBundleID: "com.example.two",
                forward: false
            ),
            0
        )
    }

    func testInitialIndexFallsBackToListBoundariesWhenCurrentCandidateIsUnknown() {
        let candidates = [
            candidate(windowID: 301, bundleID: "com.example.one", slot: 1),
            candidate(windowID: 302, bundleID: "com.example.two", slot: 2),
        ]

        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 999,
                frontmostBundleID: "com.example.missing",
                forward: true
            ),
            0
        )
        XCTAssertEqual(
            SwitcherCandidateSelection.initialIndex(
                candidates: candidates,
                focusedWindowID: 999,
                frontmostBundleID: "com.example.missing",
                forward: false
            ),
            1
        )
    }

    private func candidate(windowID: UInt32, bundleID: String, slot: Int?) -> SwitcherCandidate {
        SwitcherCandidate(
            id: "window:\(windowID)",
            source: .window,
            title: "Window \(windowID)",
            bundleID: bundleID,
            spaceID: 1,
            displayID: "display-a",
            slot: slot,
            quickKey: nil
        )
    }
}
