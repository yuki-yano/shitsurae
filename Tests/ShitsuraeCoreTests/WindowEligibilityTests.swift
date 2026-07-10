import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowEligibility")
struct WindowEligibilityTests {
    private func window(
        subrole: String?,
        isAXBacked: Bool,
        bundleID: String = "com.google.Chrome"
    ) -> WindowSnapshot {
        TestFixtures.window(
            id: 1,
            bundleID: bundleID,
            frame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
            subrole: subrole,
            isAXBacked: isAXBacked
        )
    }

    @Test func managesStandardWindows() {
        #expect(WindowEligibility.isManageableForVirtualWorkspace(
            window(subrole: "AXStandardWindow", isAXBacked: true)
        ))
    }

    @Test func managesWindowsWithUnknownSubrole() {
        // A nil subrole means AX could not resolve it — keep managing rather
        // than regress on windows we handled before subrole was populated.
        #expect(WindowEligibility.isManageableForVirtualWorkspace(
            window(subrole: nil, isAXBacked: true)
        ))
    }

    @Test func excludesCGOnlySurface() {
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(subrole: nil, isAXBacked: false)
        ))
    }

    @Test func excludesDialogAndPopupSubroles() {
        for subrole in ["AXDialog", "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow", "AXUnknown"] {
            #expect(
                !WindowEligibility.isManageableForVirtualWorkspace(
                    window(subrole: subrole, isAXBacked: true)
                ),
                "\(subrole) should be excluded"
            )
        }
    }

    @Test func stillExcludesOwnAndXPCWindowsRegardlessOfSubrole() {
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(
                subrole: "AXStandardWindow",
                isAXBacked: true,
                bundleID: "com.yuki-yano.shitsurae"
            )
        ))
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(
                subrole: "AXStandardWindow",
                isAXBacked: true,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService"
            )
        ))
    }
}
