import Foundation
import XCTest
@testable import ShitsuraeCore

final class CycleFocusTimingTests: XCTestCase {
    func testShouldRefreshCandidatesWhenActiveSpaceChangedAfterLastCycle() {
        let now = Date(timeIntervalSinceReferenceDate: 200)
        let timing = CycleFocusTiming(
            hasCachedCandidates: true,
            lastCycleAt: Date(timeIntervalSinceReferenceDate: 100),
            lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 150)
        )

        XCTAssertTrue(timing.shouldRefreshCandidates(now: now, cycleSessionTimeout: 1.5))
    }

    func testShouldNotRefreshCandidatesWithinSessionWhenSpaceDidNotChange() {
        let now = Date(timeIntervalSinceReferenceDate: 101)
        let timing = CycleFocusTiming(
            hasCachedCandidates: true,
            lastCycleAt: Date(timeIntervalSinceReferenceDate: 100),
            lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 90)
        )

        XCTAssertFalse(timing.shouldRefreshCandidates(now: now, cycleSessionTimeout: 1.5))
    }

    func testDispatchDelayReturnsRemainingSettleTimeAfterRecentSpaceChange() {
        let now = Date(timeIntervalSinceReferenceDate: 100.05)
        let timing = CycleFocusTiming(
            hasCachedCandidates: false,
            lastCycleAt: nil,
            lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        XCTAssertEqual(
            timing.dispatchDelay(now: now, activeSpaceSettleDelay: 0.15),
            0.10,
            accuracy: 0.0001
        )
    }

    func testDispatchDelayIsZeroAfterSettleWindowElapsed() {
        let now = Date(timeIntervalSinceReferenceDate: 100.20)
        let timing = CycleFocusTiming(
            hasCachedCandidates: false,
            lastCycleAt: nil,
            lastActiveSpaceChangeAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        XCTAssertEqual(timing.dispatchDelay(now: now, activeSpaceSettleDelay: 0.15), 0)
    }
}
