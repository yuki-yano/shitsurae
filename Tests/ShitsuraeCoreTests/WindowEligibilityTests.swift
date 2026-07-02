import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowEligibility")
struct WindowEligibilityTests {
    private func window(subrole: String?, bundleID: String = "com.google.Chrome") -> WindowSnapshot {
        TestFixtures.window(
            id: 1,
            bundleID: bundleID,
            frame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
            subrole: subrole
        )
    }

    @Test func managesStandardWindows() {
        #expect(WindowEligibility.isManageableForVirtualWorkspace(window(subrole: "AXStandardWindow")))
    }

    @Test func managesWindowsWithUnknownSubrole() {
        // A nil subrole means AX could not resolve it — keep managing rather
        // than regress on windows we handled before subrole was populated.
        #expect(WindowEligibility.isManageableForVirtualWorkspace(window(subrole: nil)))
    }

    @Test func excludesDialogAndPopupSubroles() {
        for subrole in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"] {
            #expect(
                !WindowEligibility.isManageableForVirtualWorkspace(window(subrole: subrole)),
                "\(subrole) should be excluded"
            )
        }
    }

    @Test func stillExcludesOwnAndXPCWindowsRegardlessOfSubrole() {
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(subrole: "AXStandardWindow", bundleID: "com.yuki-yano.shitsurae")
        ))
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(subrole: "AXStandardWindow", bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService")
        ))
    }
}
