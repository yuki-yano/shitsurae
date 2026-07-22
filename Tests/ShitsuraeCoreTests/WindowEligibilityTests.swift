import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowEligibility")
struct WindowEligibilityTests {
    private func window(
        role: String? = "AXWindow",
        subrole: String? = "AXStandardWindow",
        modal: Bool? = false,
        isAXBacked: Bool,
        bundleID: String = "com.google.Chrome"
    ) -> WindowSnapshot {
        TestFixtures.window(
            id: 1,
            bundleID: bundleID,
            frame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
            role: role,
            subrole: subrole,
            modal: modal,
            isAXBacked: isAXBacked
        )
    }

    @Test func managesStandardWindows() {
        #expect(WindowEligibility.isManageableForVirtualWorkspace(
            window(isAXBacked: true)
        ))
        #expect(WindowEligibility.classification(of: window(isAXBacked: true)) == .manageable)
    }

    @Test func missingAXClassificationAttributesAreUnknown() {
        for candidate in [
            window(role: nil, isAXBacked: true),
            window(subrole: nil, isAXBacked: true),
            window(modal: nil, isAXBacked: true),
        ] {
            #expect(WindowEligibility.classification(of: candidate) == .unknown)
            #expect(!WindowEligibility.isManageableForVirtualWorkspace(candidate))
        }
    }

    @Test func excludesCGOnlySurface() {
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(isAXBacked: false)
        ))
        #expect(WindowEligibility.classification(of: window(isAXBacked: false)) == .unknown)
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

    @Test func excludesKnownModalWindowEvenWhenOtherAttributesAreMissing() {
        let candidate = window(role: nil, subrole: nil, modal: true, isAXBacked: true)
        #expect(WindowEligibility.classification(of: candidate) == .companion)
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(candidate))
    }

    @Test func companionProjectsOnlyToManageableWindowOfSameExactProcess() throws {
        let companion = TestFixtures.window(
            id: 1,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 1_000,
            subrole: "AXSheet",
            modal: true,
            isAXBacked: true,
            frontIndex: 0
        )
        let sameProcessMain = TestFixtures.window(
            id: 2,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 1_000,
            isAXBacked: true,
            frontIndex: 1
        )
        let siblingProcess = TestFixtures.window(
            id: 3,
            bundleID: "com.google.Chrome",
            pid: 101,
            processStartTime: 2_000,
            isAXBacked: true,
            frontIndex: 0
        )

        let projected = WindowEligibility.manageableMainWindow(
            for: companion,
            mainIdentity: sameProcessMain.identity,
            in: [siblingProcess, sameProcessMain, companion]
        )
        #expect(projected?.identity == sameProcessMain.identity)
        #expect(WindowEligibility.manageableMainWindow(
            for: window(modal: nil, isAXBacked: true),
            mainIdentity: sameProcessMain.identity,
            in: [sameProcessMain]
        ) == nil)

        #expect(WindowEligibility.manageableMainWindow(
            for: companion,
            mainIdentity: siblingProcess.identity,
            in: [siblingProcess, sameProcessMain, companion]
        ) == nil)
    }

    @Test func focusedIdentityMissingFromInventoryBlocksExactMain() {
        let main = TestFixtures.window(
            id: 2,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 1_000,
            isAXBacked: true
        )
        let missingFocusedIdentity = WindowIdentity(
            pid: 100,
            processStartTime: 1_000,
            windowID: 3,
            bundleID: "com.google.Chrome"
        )
        let observation = WindowObservation(
            inventory: .available([main]),
            focusedIdentity: missingFocusedIdentity,
            mainIdentity: main.identity
        )

        #expect(WindowEligibility.geometryBlockedIdentities(in: observation) == [main.identity])
        #expect(WindowEligibility.geometryCandidates(in: observation).isEmpty)
    }

    @Test func managesOwnStandardWindowForExplicitWorkspaceAssignmentButStillExcludesXPC() {
        let ownWindow = window(
            subrole: "AXStandardWindow",
            isAXBacked: true,
            bundleID: "com.yuki-yano.shitsurae"
        )
        #expect(WindowEligibility.isShitsuraeApplication(bundleID: ownWindow.bundleID))
        #expect(WindowEligibility.isManageableForVirtualWorkspace(ownWindow))
        #expect(!WindowEligibility.isManageableForVirtualWorkspace(
            window(
                subrole: "AXStandardWindow",
                isAXBacked: true,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService"
            )
        ))
    }
}
