import XCTest
@testable import ShitsuraeCore

final class ShortcutCandidateFilterTests: XCTestCase {
    func testExcludingRemovesExcludedBundlesWithoutChangingOrder() {
        let candidates = [
            SwitcherCandidate(id: "window:1", source: .window, title: "A", bundleID: "com.example.a", spaceID: 1, displayID: "display-1", slot: nil, quickKey: nil),
            SwitcherCandidate(id: "window:2", source: .window, title: "B", bundleID: "com.example.b", spaceID: 1, displayID: "display-1", slot: nil, quickKey: nil),
            SwitcherCandidate(id: "window:3", source: .window, title: "C", bundleID: "com.example.c", spaceID: 1, displayID: "display-1", slot: nil, quickKey: nil),
        ]

        let filtered = ShortcutCandidateFilter.excluding(
            candidates: candidates,
            excludedBundleIDs: ["com.example.b"]
        )

        XCTAssertEqual(filtered.map(\.id), ["window:1", "window:3"])
        XCTAssertEqual(filtered.map(\.quickKey), [nil, nil])
    }

    func testAssignQuickKeysRewritesKeysForFinalCandidateOrder() {
        let candidates = [
            SwitcherCandidate(id: "window:1", source: .window, title: "A", bundleID: "com.example.a", spaceID: 1, displayID: "display-1", slot: nil, quickKey: "z"),
            SwitcherCandidate(id: "window:3", source: .window, title: "C", bundleID: "com.example.c", spaceID: 1, displayID: "display-1", slot: nil, quickKey: "y"),
        ]

        let keyed = ShortcutCandidateFilter.assignQuickKeys(
            candidates: candidates,
            quickKeys: "ab"
        )

        XCTAssertEqual(keyed.map(\.id), ["window:1", "window:3"])
        XCTAssertEqual(keyed.map(\.quickKey), ["a", "b"])
    }

    func testFilterRemovesExcludedBundlesAndReassignsQuickKeys() {
        let candidates = [
            SwitcherCandidate(id: "window:1", source: .window, title: "A", bundleID: "com.example.a", spaceID: 1, displayID: "display-1", slot: nil, quickKey: "1"),
            SwitcherCandidate(id: "window:2", source: .window, title: "B", bundleID: "com.example.b", spaceID: 1, displayID: "display-1", slot: nil, quickKey: "2"),
            SwitcherCandidate(id: "window:3", source: .window, title: "C", bundleID: "com.example.c", spaceID: 1, displayID: "display-1", slot: nil, quickKey: "3"),
        ]

        let filtered = ShortcutCandidateFilter.filter(
            candidates: candidates,
            excludedBundleIDs: ["com.example.b"],
            quickKeys: "abc"
        )

        XCTAssertEqual(filtered.map(\.id), ["window:1", "window:3"])
        XCTAssertEqual(filtered.map(\.quickKey), ["a", "b"])
    }

    func testFilterKeepsCandidatesWithoutBundleID() {
        let candidates = [
            SwitcherCandidate(id: "window:dev", source: .window, title: "dev", bundleID: nil, spaceID: 1, displayID: "display-1", slot: nil, quickKey: "1"),
        ]

        let filtered = ShortcutCandidateFilter.filter(
            candidates: candidates,
            excludedBundleIDs: ["com.example.a"],
            quickKeys: "a"
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.quickKey, "a")
    }
}
