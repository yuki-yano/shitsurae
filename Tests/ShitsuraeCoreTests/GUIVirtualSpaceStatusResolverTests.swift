import XCTest
@testable import ShitsuraeCore

final class GUIVirtualSpaceStatusResolverTests: XCTestCase {
    func testResolveReturnsNativeStatusWhenModeIsNative() {
        let status = GUIVirtualSpaceStatusResolver.resolve(
            config: ShitsuraeConfig(
                app: nil,
                ignore: nil,
                overlay: nil,
                executionPolicy: nil,
                monitors: nil,
                layouts: [:],
                shortcuts: nil,
                mode: ModeDefinition(space: .native)
            ),
            diagnostics: nil,
            spaceCurrentResult: CommandResult(exitCode: 0, stdout: "")
        )

        XCTAssertEqual(
            status,
            GUIVirtualSpaceStatus(
                mode: .native,
                activeLayoutName: nil,
                activeVirtualSpaceID: nil,
                activeLayoutSpaceIDs: [],
                blockReason: nil,
                preferredRecoverySpaceID: nil,
                canForceClearPendingState: false
            )
        )
        XCTAssertFalse(status.isVirtualMode)
    }

    func testResolveReturnsVirtualStatusUsingEffectiveDiagnosticsMode() {
        let config = ShitsuraeConfig(
            app: nil,
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: [
                "work": LayoutDefinition(
                    initialFocus: nil,
                    spaces: [
                        SpaceDefinition(spaceID: 1, display: nil, windows: []),
                        SpaceDefinition(spaceID: 2, display: nil, windows: []),
                    ]
                ),
            ],
            shortcuts: nil,
            mode: ModeDefinition(space: .native)
        )
        let diagnostics = DiagnosticsJSON(
            schemaVersion: 4,
            generatedAt: Date.rfc3339UTC(),
            configuredSpaceMode: .native,
            effectiveSpaceMode: .virtual,
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            permissions: PermissionsStatus(
                accessibility: PermissionItem(granted: true, required: true),
                automation: PermissionItem(granted: false, required: false),
                screenRecording: PermissionItem(granted: true, required: false)
            ),
            spacesMode: .perDisplay,
            spacesModeCompatibility: SpacesModeCompatibility(
                matches: true,
                expected: .perDisplay,
                actual: .perDisplay,
                reason: nil
            ),
            eventTap: EventTapStatus(enabled: true, reason: nil),
            backend: BackendStatus(initialized: true, name: "skyLight", reason: nil),
            configFiles: [],
            layouts: ["work"],
            spaces: [],
            lastConfigReload: ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: nil,
                message: nil
            ),
            diagnosticEventFields: [],
            diagnosticEvents: [],
            recentErrors: []
        )

        let status = GUIVirtualSpaceStatusResolver.resolve(
            config: config,
            diagnostics: diagnostics,
            spaceCurrentResult: CommandResult(exitCode: 0, stdout: "")
        )

        XCTAssertEqual(status.mode, .virtual)
        XCTAssertEqual(status.activeLayoutName, "work")
        XCTAssertEqual(status.activeVirtualSpaceID, 2)
        XCTAssertEqual(status.activeLayoutSpaceIDs, [1, 2])
        XCTAssertTrue(status.isVirtualMode)
    }
}
