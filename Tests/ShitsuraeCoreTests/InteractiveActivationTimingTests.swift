import Foundation
import XCTest
@testable import ShitsuraeCore

final class InteractiveActivationTimingTests: XCTestCase {
    func testHandlingDelayReturnsRemainingGraceInterval() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let timing = InteractiveActivationTiming(
            deferredUntil: Date(timeIntervalSinceReferenceDate: 100.18)
        )

        XCTAssertEqual(timing.handlingDelay(now: now), 0.18, accuracy: 0.0001)
    }

    func testHandlingDelayReturnsZeroAfterGraceIntervalExpires() {
        let now = Date(timeIntervalSinceReferenceDate: 100.25)
        let timing = InteractiveActivationTiming(
            deferredUntil: Date(timeIntervalSinceReferenceDate: 100.18)
        )

        XCTAssertEqual(timing.handlingDelay(now: now), 0)
    }

    func testHandlingDelayReturnsZeroWithoutDeferredDeadline() {
        let timing = InteractiveActivationTiming(deferredUntil: nil)

        XCTAssertEqual(timing.handlingDelay(now: Date(timeIntervalSinceReferenceDate: 100)), 0)
    }
}
