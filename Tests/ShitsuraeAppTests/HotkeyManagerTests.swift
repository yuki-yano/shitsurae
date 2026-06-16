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
}
