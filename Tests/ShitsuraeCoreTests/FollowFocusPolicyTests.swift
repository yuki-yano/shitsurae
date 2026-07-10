import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("FollowFocusPolicy")
struct FollowFocusPolicyTests {
    @Test func sequenceLessInvalidationDoesNotConsumeOSSequenceNumbers() {
        let gate = FocusEventGate()
        #expect(gate.accept(10))

        gate.invalidateCurrent()
        gate.invalidateCurrent()
        #expect(!gate.isCurrent(10))
        #expect(!gate.accept(10))

        // The very next source sequence is accepted even after multiple IPC
        // invalidations; the gate never invents values ahead of the source.
        #expect(gate.accept(11))
        #expect(gate.isCurrent(11))
    }

    @Test func trackedFocusedWindowKeepsItsWorkspace() {
        let policy = FollowFocusPolicy()
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: nil,
            lastActiveSpaceChangeAt: nil,
            now: now.addingTimeInterval(0.2)
        )

        #expect(decision == .switchSpace(2))
    }

    @Test func existingFocusedWindowSwitchesToItsTrackedWorkspace() {
        let policy = FollowFocusPolicy()
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
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
        let policy = FollowFocusPolicy()
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
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
        let policy = FollowFocusPolicy()
        let now = Date(timeIntervalSince1970: 100)

        let decision = policy.decisionForFocusedWindow(
            targetSpaceID: 2,
            activeSpaceID: 1,
            followFocusEnabled: true,
            lastFollowFocusSwitchAt: now.addingTimeInterval(-0.2),
            lastActiveSpaceChangeAt: nil,
            now: now
        )

        #expect(decision == .markActivated)
    }

    @Test func shortcutPolicyIgnoresFrontmostWindowFromInactiveWorkspace() {
        let disabled = PolicyEngine.isShortcutDisabled(
            frontmostBundleID: "org.alacritty",
            shortcutID: "focusBySlot:1",
            disabledInApps: [:],
            focusBySlotEnabledInApps: ["org.alacritty": false],
            frontmostBelongsToActiveWorkspace: false
        )

        #expect(disabled == false)
    }

    @Test func shortcutWorkspaceMembershipOnlyRejectsTrackedInactiveWindow() {
        #expect(FollowFocusPolicy.frontmostBelongsToActiveWorkspace(
            targetSpaceID: nil,
            activeSpaceID: 1
        ))
        #expect(FollowFocusPolicy.frontmostBelongsToActiveWorkspace(
            targetSpaceID: 1,
            activeSpaceID: 1
        ))
        #expect(!FollowFocusPolicy.frontmostBelongsToActiveWorkspace(
            targetSpaceID: 2,
            activeSpaceID: 1
        ))
    }
}
