import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("FollowFocusPolicy")
struct FollowFocusPolicyTests {
    @Test func newlyCreatedFocusedWindowDoesNotSwitchWorkspace() {
        var policy = FollowFocusPolicy(newWindowGrace: 1.0)
        let now = Date(timeIntervalSince1970: 100)

        policy.recordWindowCreated(windowID: 42, now: now)

        let decision = policy.decisionForFocusedWindow(
            windowID: 42,
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: nil,
            lastActiveSpaceChangeAt: nil,
            now: now.addingTimeInterval(0.2)
        )

        #expect(decision == .adoptIntoActiveWorkspace)
    }

    @Test func existingFocusedWindowSwitchesToItsTrackedWorkspace() {
        var policy = FollowFocusPolicy(newWindowGrace: 1.0)
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
            windowID: 7,
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: nil,
            lastActiveSpaceChangeAt: nil,
            now: now
        )

        #expect(decision == .switchSpace(2))
    }

    @Test func untrackedFocusedWindowIsAdoptedIntoActiveWorkspace() {
        var policy = FollowFocusPolicy(newWindowGrace: 1.0)
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
            windowID: 99,
            targetSpaceID: nil,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: nil,
            lastActiveSpaceChangeAt: nil,
            now: now
        )

        #expect(decision == .adoptIntoActiveWorkspace)
    }

    @Test func followFocusDebounceSuppressesSwitch() {
        var policy = FollowFocusPolicy(newWindowGrace: 1.0)
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
            windowID: 7,
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: now.addingTimeInterval(-0.2),
            lastActiveSpaceChangeAt: nil,
            now: now
        )

        #expect(decision == .markActivated)
    }

    @Test func expiredCreatedWindowCanSwitchLater() {
        var policy = FollowFocusPolicy(newWindowGrace: 1.0)
        let now = Date(timeIntervalSince1970: 100)

        policy.recordWindowCreated(windowID: 42, now: now)

        let decision = policy.decisionForFocusedWindow(
            windowID: 42,
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: nil,
            lastActiveSpaceChangeAt: nil,
            now: now.addingTimeInterval(2.0)
        )

        #expect(decision == .switchSpace(2))
    }
}
