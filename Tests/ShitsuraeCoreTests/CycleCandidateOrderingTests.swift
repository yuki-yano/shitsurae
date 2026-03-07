import XCTest
@testable import ShitsuraeCore

final class CycleCandidateOrderingTests: XCTestCase {
    func testCycleCandidatesPlaceSlottedWindowsFirstAndAppendTrailingInObservedOrder() {
        let windows = [
            window(windowID: 11, bundleID: "com.example.trailing-a", title: "A", spaceID: 1, frontIndex: 0),
            window(windowID: 12, bundleID: "com.example.trailing-b", title: "B", spaceID: 1, frontIndex: 1),
            window(windowID: 13, bundleID: "com.example.slot-three", title: "C", spaceID: 1, frontIndex: 2),
            window(windowID: 14, bundleID: "com.example.slot-one", title: "D", spaceID: 1, frontIndex: 3),
            window(windowID: 15, bundleID: "com.example.other-space", title: "E", spaceID: 2, frontIndex: 4),
        ]

        let slotEntries = [
            slotEntry(slot: 3, windowID: 13, bundleID: "com.example.slot-three"),
            slotEntry(slot: 1, windowID: 14, bundleID: "com.example.slot-one"),
        ]

        let result = ShortcutCandidateOrdering.cycleCandidates(
            windows: windows,
            currentSpaceID: 1,
            slotEntries: slotEntries,
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "1234",
            state: nil
        )

        XCTAssertEqual(result.candidates.map(\.id), ["window:14", "window:13", "window:11", "window:12"])
        XCTAssertEqual(result.candidates.map(\.quickKey), ["1", "2", "3", "4"])
        XCTAssertEqual(result.state, SpaceCycleState(spaceID: 1, trailingWindowIDs: [11, 12]))
    }

    func testCycleCandidatesKeepTrailingOrderAfterFrontIndexChanges() {
        let first = ShortcutCandidateOrdering.cycleCandidates(
            windows: [
                window(windowID: 21, bundleID: "com.example.trailing-a", title: "A", spaceID: 1, frontIndex: 0),
                window(windowID: 22, bundleID: "com.example.trailing-b", title: "B", spaceID: 1, frontIndex: 1),
            ],
            currentSpaceID: 1,
            slotEntries: [],
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "12",
            state: nil
        )

        let second = ShortcutCandidateOrdering.cycleCandidates(
            windows: [
                window(windowID: 22, bundleID: "com.example.trailing-b", title: "B", spaceID: 1, frontIndex: 0),
                window(windowID: 21, bundleID: "com.example.trailing-a", title: "A", spaceID: 1, frontIndex: 1),
            ],
            currentSpaceID: 1,
            slotEntries: [],
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "12",
            state: first.state
        )

        XCTAssertEqual(second.candidates.map(\.id), ["window:21", "window:22"])
        XCTAssertEqual(second.state, SpaceCycleState(spaceID: 1, trailingWindowIDs: [21, 22]))
    }

    func testCycleCandidatesRemoveMissingTrailingWindowAndMoveSlottedWindowOutOfTrailingState() {
        let state = SpaceCycleState(spaceID: 1, trailingWindowIDs: [31, 32, 33])
        let windows = [
            window(windowID: 32, bundleID: "com.example.trailing", title: "B", spaceID: 1, frontIndex: 1),
            window(windowID: 33, bundleID: "com.example.now-slotted", title: "C", spaceID: 1, frontIndex: 0),
        ]
        let slotEntries = [
            slotEntry(slot: 2, windowID: 33, bundleID: "com.example.now-slotted"),
        ]

        let result = ShortcutCandidateOrdering.cycleCandidates(
            windows: windows,
            currentSpaceID: 1,
            slotEntries: slotEntries,
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "12",
            state: state
        )

        XCTAssertEqual(result.candidates.map(\.id), ["window:33", "window:32"])
        XCTAssertEqual(result.state, SpaceCycleState(spaceID: 1, trailingWindowIDs: [32]))
    }

    func testSwitcherCandidatesIgnoreSlotsAndUseCurrentSpaceFrontIndexOrder() {
        let windows = [
            window(windowID: 41, bundleID: "com.example.slot", title: "Slot", spaceID: 1, frontIndex: 1),
            window(windowID: 42, bundleID: "com.example.front", title: "Front", spaceID: 1, frontIndex: 0),
            window(windowID: 43, bundleID: "com.example.other", title: "Other", spaceID: 2, frontIndex: 2),
        ]
        let slotEntries = [
            slotEntry(slot: 1, windowID: 41, bundleID: "com.example.slot"),
        ]

        let candidates = ShortcutCandidateOrdering.switcherCandidates(
            windows: windows,
            currentSpaceID: 1,
            slotEntries: slotEntries,
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "12"
        )

        XCTAssertEqual(candidates.map(\.id), ["window:42", "window:41"])
        XCTAssertEqual(candidates.map(\.slot), [nil, 1])
        XCTAssertEqual(candidates.map(\.quickKey), ["1", "2"])
    }

    func testCurrentSpaceUnresolvedReturnsEmptyCandidates() {
        let windows = [
            window(windowID: 51, bundleID: "com.example.one", title: "One", spaceID: 1, frontIndex: 0),
        ]

        let cycle = ShortcutCandidateOrdering.cycleCandidates(
            windows: windows,
            currentSpaceID: nil,
            slotEntries: [],
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "1",
            state: nil
        )
        let switcher = ShortcutCandidateOrdering.switcherCandidates(
            windows: windows,
            currentSpaceID: nil,
            slotEntries: [],
            ignoreFocusRules: nil,
            excludedBundleIDs: [],
            quickKeys: "1"
        )

        XCTAssertTrue(cycle.candidates.isEmpty)
        XCTAssertNil(cycle.state)
        XCTAssertTrue(switcher.isEmpty)
    }

    private func window(
        windowID: UInt32,
        bundleID: String,
        title: String,
        spaceID: Int?,
        frontIndex: Int
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: Int(windowID),
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
            spaceID: spaceID,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }

    private func slotEntry(slot: Int, windowID: UInt32, bundleID: String) -> SlotEntry {
        SlotEntry(
            slot: slot,
            source: .window,
            bundleID: bundleID,
            title: "Window \(windowID)",
            spaceID: 1,
            displayID: "display-a",
            windowID: windowID
        )
    }
}
