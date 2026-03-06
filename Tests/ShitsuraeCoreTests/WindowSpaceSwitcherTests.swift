import XCTest
@testable import ShitsuraeCore

final class WindowSpaceSwitcherTests: XCTestCase {
    func testDragAttemptsWithoutTitleBarHandlesCoverMultipleTopBandRows() {
        let attempts = WindowSpaceDragPlanner.dragAttempts(
            fallbackFrame: ResolvedFrame(x: 0, y: 0, width: 1200, height: 800),
            titleBarHandleFrames: []
        )

        XCTAssertEqual(attempts.count, 15)
        XCTAssertGreaterThan(Set(attempts.map(\.startPoint.y)).count, 1)
        XCTAssertTrue(attempts.allSatisfy { $0.holdPoint.y > $0.startPoint.y })
    }

    func testDragAttemptsPreferHandleFramesBeforeFallbackPoints() throws {
        let attempts = WindowSpaceDragPlanner.dragAttempts(
            fallbackFrame: ResolvedFrame(x: 10, y: 20, width: 800, height: 600),
            titleBarHandleFrames: [CGRect(x: 24, y: 26, width: 12, height: 12)]
        )

        let first = try XCTUnwrap(attempts.first)
        XCTAssertEqual(first.startPoint.x, 30, accuracy: 0.01)
        XCTAssertEqual(first.holdPoint.x, 30, accuracy: 0.01)
        XCTAssertGreaterThan(first.holdPoint.y, first.startPoint.y)
    }

    func testDragAttemptsKeepHoldPointInsideWindowBounds() {
        let attempts = WindowSpaceDragPlanner.dragAttempts(
            fallbackFrame: ResolvedFrame(x: 100, y: 200, width: 300, height: 120),
            titleBarHandleFrames: []
        )

        XCTAssertTrue(attempts.allSatisfy { attempt in
            attempt.holdPoint.y < 310
        })
    }
}
