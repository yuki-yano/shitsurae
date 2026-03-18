import Foundation
import XCTest
@testable import ShitsuraeCore

final class WindowStatusTests: XCTestCase {
    // MARK: - slotsBySpace grouping

    func testSlotsBySpaceGroupsAndSortsBySpaceID() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(slot: 1, spaceID: 2, bundleID: "com.example.b"),
                makeSlot(slot: 2, spaceID: 1, bundleID: "com.example.a"),
                makeSlot(slot: 3, spaceID: 2, bundleID: "com.example.c"),
            ]
        )

        let groups = state.slotsBySpace()

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].spaceID, 1)
        XCTAssertEqual(groups[1].spaceID, 2)
    }

    func testSlotsBySpaceSortsSlotsWithinGroup() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(slot: 3, spaceID: 1, bundleID: "com.example.c"),
                makeSlot(slot: 1, spaceID: 1, bundleID: "com.example.a"),
                makeSlot(slot: 2, spaceID: 1, bundleID: "com.example.b"),
            ]
        )

        let groups = state.slotsBySpace()

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].slots.map(\.slot), [1, 2, 3])
    }

    func testSlotsBySpaceNilSpaceIDMapsToZero() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(slot: 1, spaceID: nil, bundleID: "com.example.unassigned"),
                makeSlot(slot: 2, spaceID: 1, bundleID: "com.example.assigned"),
            ]
        )

        let groups = state.slotsBySpace()

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].spaceID, 0)
        XCTAssertEqual(groups[0].slots.count, 1)
        XCTAssertEqual(groups[0].slots[0].bundleID, "com.example.unassigned")
        XCTAssertEqual(groups[1].spaceID, 1)
    }

    func testSlotsBySpaceEmptySlotsReturnsEmpty() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: []
        )

        let groups = state.slotsBySpace()

        XCTAssertTrue(groups.isEmpty)
    }

    func testSlotsBySpacePreservesSlotEntryDetails() {
        let frame = ResolvedFrame(x: 100, y: 200, width: 800, height: 600)
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.example.app",
                    lastKnownTitle: "My Window",
                    spaceID: 3,
                    displayID: "display-1",
                    windowID: 42,
                    lastVisibleFrame: frame,
                    visibilityState: .visible
                ),
            ]
        )

        let groups = state.slotsBySpace()

        XCTAssertEqual(groups.count, 1)
        let entry = groups[0].slots[0]
        XCTAssertEqual(entry.bundleID, "com.example.app")
        XCTAssertEqual(entry.lastKnownTitle, "My Window")
        XCTAssertEqual(entry.windowID, 42)
        XCTAssertEqual(entry.lastVisibleFrame, frame)
        XCTAssertEqual(entry.visibilityState, .visible)
    }

    func testSlotsBySpaceMultipleSpacesCorrectDistribution() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(slot: 1, spaceID: 1, bundleID: "com.a"),
                makeSlot(slot: 2, spaceID: 2, bundleID: "com.b"),
                makeSlot(slot: 3, spaceID: 3, bundleID: "com.c"),
                makeSlot(slot: 4, spaceID: 1, bundleID: "com.d"),
                makeSlot(slot: 5, spaceID: 3, bundleID: "com.e"),
            ]
        )

        let groups = state.slotsBySpace()

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].spaceID, 1)
        XCTAssertEqual(groups[0].slots.count, 2)
        XCTAssertEqual(groups[1].spaceID, 2)
        XCTAssertEqual(groups[1].slots.count, 1)
        XCTAssertEqual(groups[2].spaceID, 3)
        XCTAssertEqual(groups[2].slots.count, 2)
    }

    // MARK: - SlotSpaceGroup equality

    func testSlotSpaceGroupEquality() {
        let a = SlotSpaceGroup(
            spaceID: 1,
            slots: [makeSlot(slot: 1, spaceID: 1, bundleID: "com.a")]
        )
        let b = SlotSpaceGroup(
            spaceID: 1,
            slots: [makeSlot(slot: 1, spaceID: 1, bundleID: "com.a")]
        )
        let c = SlotSpaceGroup(
            spaceID: 2,
            slots: [makeSlot(slot: 1, spaceID: 2, bundleID: "com.a")]
        )

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Helpers

    private func makeSlot(slot: Int, spaceID: Int?, bundleID: String) -> SlotEntry {
        SlotEntry(
            slot: slot,
            source: .window,
            bundleID: bundleID,
            spaceID: spaceID,
            displayID: "display-1",
            windowID: UInt32(slot + 100)
        )
    }
}
