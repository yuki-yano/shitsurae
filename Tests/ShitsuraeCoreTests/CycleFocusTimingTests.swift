import Foundation
import XCTest
@testable import ShitsuraeCore

final class CycleFocusTimingTests: XCTestCase {
    func testDispatchDelayReturnsRemainingSettleTimeAfterRecentSpaceChange() {
        let now = Date(timeIntervalSinceReferenceDate: 100.05)
        let timing = CycleFocusTiming(lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 100))

        XCTAssertEqual(
            timing.dispatchDelay(now: now, activeSpaceSettleDelay: 0.15),
            0.10,
            accuracy: 0.0001
        )
    }

    func testDispatchDelayIsZeroAfterSettleWindowElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 100.20)
        let timing = CycleFocusTiming(lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 100))

        XCTAssertEqual(timing.dispatchDelay(now: now, activeSpaceSettleDelay: 0.15), 0)
    }

    func testDispatchDelayIsZeroWithoutRecentSpaceChange() {
        let timing = CycleFocusTiming(lastActiveSpaceChangeAt: nil)

        XCTAssertEqual(
            timing.dispatchDelay(now: Date(timeIntervalSinceReferenceDate: 100), activeSpaceSettleDelay: 0.15),
            0
        )
    }
}
