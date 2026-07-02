import Carbon.HIToolbox
import Testing
@testable import Shitsurae
import ShitsuraeCore

@Suite("HotkeyManager")
struct HotkeyManagerTests {
    @Test func cycleOverlayRepeatUsesConfiguredNextAndPrevDirections() {
        let shortcuts = ResolvedShortcuts(from: nil)

        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_J), shortcuts: shortcuts) == true)
        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_K), shortcuts: shortcuts) == false)
        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_L), shortcuts: shortcuts) == nil)
    }

    @Test func interactiveEngineActionsUseLatencyCriticalHighPriorityScheduling() {
        #expect(EngineActionUrgency.interactive.taskPriority == .high)
        #expect(EngineActionUrgency.interactive.activityOptions == [.userInitiated, .latencyCritical])
    }

    @Test func normalEngineActionsDoNotRequestLatencyCriticalScheduling() {
        #expect(EngineActionUrgency.normal.taskPriority == nil)
        #expect(EngineActionUrgency.normal.activityOptions == nil)
    }

    @Test func fastPathRecognizesVirtualSpaceSwitchShortcut() {
        let shortcuts = ResolvedShortcuts(from: nil)

        #expect(
            HotkeyFastPathAction.match(
                eventKeyCode: Int(kVK_ANSI_2),
                modifiers: ["ctrl"],
                shortcuts: shortcuts,
                frontmostBundleID: "com.apple.Terminal",
                frontmostBelongsToActiveWorkspace: true
            ) == .switchSpace(2)
        )
    }

    @Test func fastPathRespectsDisabledShortcutPolicy() {
        let shortcuts = ResolvedShortcuts(
            from: ShortcutsDefinition(
                focusBySlot: nil,
                moveCurrentWindowToSpace: nil,
                switchVirtualSpace: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: nil,
                globalActions: nil,
                disabledInApps: ["com.apple.Terminal": ["switchVirtualSpace:2"]],
                focusBySlotEnabledInApps: nil
            )
        )

        #expect(
            HotkeyFastPathAction.match(
                eventKeyCode: Int(kVK_ANSI_2),
                modifiers: ["ctrl"],
                shortcuts: shortcuts,
                frontmostBundleID: "com.apple.Terminal",
                frontmostBelongsToActiveWorkspace: true
            ) == nil
        )
    }

    @Test func fastPathLeavesNonWorkspaceShortcutsOnMainPath() {
        let shortcuts = ResolvedShortcuts(from: nil)

        #expect(
            HotkeyFastPathAction.match(
                eventKeyCode: Int(kVK_ANSI_2),
                modifiers: ["cmd"],
                shortcuts: shortcuts,
                frontmostBundleID: "com.apple.Terminal",
                frontmostBelongsToActiveWorkspace: true
            ) == nil
        )
    }
}
