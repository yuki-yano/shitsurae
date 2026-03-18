import XCTest
@testable import ShitsuraeCore

final class CurrentSpaceResolverTests: XCTestCase {
    func testResolveReturnsNativeCurrentSpaceWhenConfigIsNativeEvenIfRuntimeStateContainsVirtualFields() {
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: makeLoadedConfig(mode: .native),
            runtimeState: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 2,
                stateMode: .virtual,
                configGeneration: "generation-1",
                activeLayoutName: "work",
                activeVirtualSpaceID: 2,
                pendingSwitchTransaction: nil,
                slots: []
            ),
            focusedWindow: window(spaceID: 7),
            spaces: [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
        )

        XCTAssertEqual(resolution, .resolved(spaceID: 7, kind: .native, layoutName: nil))
    }

    func testResolveReturnsUninitializedWhenNativeCurrentSpaceIsUnavailable() {
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: makeLoadedConfig(mode: .native),
            runtimeState: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 1,
                stateMode: .native,
                configGeneration: "generation-1",
                activeLayoutName: nil,
                activeVirtualSpaceID: nil,
                pendingSwitchTransaction: nil,
                slots: []
            ),
            focusedWindow: nil,
            spaces: []
        )

        XCTAssertEqual(resolution, .unavailable(reason: .uninitialized))
    }

    func testResolveReturnsVirtualActiveSpaceWhenConfigIsVirtual() {
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: makeLoadedConfig(mode: .virtual),
            runtimeState: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 3,
                stateMode: .virtual,
                configGeneration: "generation-1",
                activeLayoutName: "work",
                activeVirtualSpaceID: 2,
                pendingSwitchTransaction: nil,
                slots: []
            ),
            focusedWindow: window(spaceID: 7),
            spaces: [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
        )

        XCTAssertEqual(resolution, .resolved(spaceID: 2, kind: .virtual, layoutName: "work"))
    }

    func testResolveIgnoresPendingRecoveryWhenActiveVirtualSpaceIsAvailable() {
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: makeLoadedConfig(mode: .virtual),
            runtimeState: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 4,
                stateMode: .virtual,
                configGeneration: "generation-1",
                activeLayoutName: "work",
                activeVirtualSpaceID: 1,
                pendingSwitchTransaction: PendingSwitchTransaction(
                    requestID: "pending-recovery",
                    startedAt: Date.rfc3339UTC(),
                    activeLayoutName: "work",
                    attemptedTargetSpaceID: 2,
                    previousActiveSpaceID: 1,
                    configGeneration: "generation-1",
                    status: .recoveryRequired,
                ),
                slots: []
            ),
            focusedWindow: window(spaceID: 7),
            spaces: [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
        )

        XCTAssertEqual(resolution, .resolved(spaceID: 1, kind: .virtual, layoutName: "work"))
    }

    func testResolveReturnsStaleGenerationWhenVirtualStateGenerationDiffersFromConfig() {
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: makeLoadedConfig(mode: .virtual, configGeneration: String(repeating: "b", count: 64)),
            runtimeState: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 4,
                stateMode: .virtual,
                configGeneration: String(repeating: "a", count: 64),
                activeLayoutName: "work",
                activeVirtualSpaceID: 1,
                pendingSwitchTransaction: nil,
                slots: []
            ),
            focusedWindow: window(spaceID: 7),
            spaces: [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
        )

        XCTAssertEqual(resolution, .unavailable(reason: .staleGeneration))
    }

    private func makeLoadedConfig(
        mode: SpaceInterpretationMode,
        configGeneration: String = "generation-1"
    ) -> LoadedConfig {
        LoadedConfig(
            config: ShitsuraeConfig(
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
                mode: ModeDefinition(space: mode)
            ),
            configFiles: [],
            directoryURL: URL(fileURLWithPath: "/tmp"),
            configGeneration: configGeneration
        )
    }

    private func window(spaceID: Int) -> WindowSnapshot {
        WindowSnapshot(
            windowID: 101,
            bundleID: "com.example.app",
            pid: 101,
            title: "Main",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
            spaceID: spaceID,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: 0
        )
    }
}
