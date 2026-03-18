import XCTest
@testable import ShitsuraeCore

final class InteractiveShortcutContextResolverTests: XCTestCase {
    func testResolveReturnsNativeContextWithCurrentSpaceAndSlots() {
        let loadedConfig = makeLoadedConfig(mode: .native)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .native,
            configGeneration: "generation-1",
            activeLayoutName: nil,
            activeVirtualSpaceID: nil,
            pendingSwitchTransaction: nil,
            slots: [
                slotEntry(layoutName: "work", slot: 1, spaceID: 3, windowID: 101),
            ]
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 3
        )

        XCTAssertEqual(
            context,
            InteractiveShortcutContext(
                currentSpaceID: 3,
                scope: .native(spaceID: 3),
                slotEntries: state.slots
            )
        )
    }

    func testResolveReturnsVirtualContextForActiveSpace() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .virtual,
            configGeneration: Self.generatedConfigGeneration("a"),
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: nil,
            slots: [
                slotEntry(layoutName: "work", slot: 1, spaceID: 2, windowID: 201),
                slotEntry(layoutName: "work", slot: 2, spaceID: 1, windowID: 202),
            ]
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 9
        )

        XCTAssertEqual(
            context,
            InteractiveShortcutContext(
                currentSpaceID: 2,
                scope: .virtual(layoutName: "work", spaceID: 2),
                slotEntries: state.slots
            )
        )
    }

    func testResolveReturnsContextWhenVirtualPendingRecoveryExistsButActiveSpaceIsAvailable() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 2,
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
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertEqual(
            context,
            InteractiveShortcutContext(
                currentSpaceID: 1,
                scope: .virtual(layoutName: "work", spaceID: 1),
                slotEntries: []
            )
        )
    }

    func testResolveDetailedIgnoresInFlightPendingWhenActiveSpaceIsAvailable() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 2,
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-busy",
                startedAt: Date.rfc3339UTC(),
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .inFlight,
            ),
            slots: []
        )

        let resolution = RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertEqual(
            resolution,
            .resolved(
                InteractiveShortcutContext(
                    currentSpaceID: 1,
                    scope: .virtual(layoutName: "work", spaceID: 1),
                    slotEntries: []
                )
            )
        )
    }

    func testResolveDetailedIgnoresRecoveryPendingWhenActiveSpaceIsAvailable() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 2,
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
        )

        let resolution = RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertEqual(
            resolution,
            .resolved(
                InteractiveShortcutContext(
                    currentSpaceID: 1,
                    scope: .virtual(layoutName: "work", spaceID: 1),
                    slotEntries: []
                )
            )
        )
    }

    func testResolveReturnsNilWhenVirtualStateIsStaleGeneration() {
        let loadedConfig = makeLoadedConfig(mode: .virtual, configGeneration: Self.generatedConfigGeneration("b"))
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .virtual,
            configGeneration: Self.generatedConfigGeneration("a"),
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: nil,
            slots: []
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertNil(context)
    }

    func testResolveDetailedReturnsStaleGenerationWhenVirtualStateIsStaleGeneration() {
        let loadedConfig = makeLoadedConfig(mode: .virtual, configGeneration: Self.generatedConfigGeneration("b"))
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .virtual,
            configGeneration: Self.generatedConfigGeneration("a"),
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: nil,
            slots: []
        )

        let resolution = RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertEqual(resolution, .unavailable(reason: .staleGeneration))
    }

    func testResolveIgnoresStaleVirtualSlotsAfterModeChangesToNative() {
        let loadedConfig = makeLoadedConfig(mode: .native)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 3,
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: nil,
            slots: [
                slotEntry(layoutName: "work", slot: 1, spaceID: 2, windowID: 301),
            ]
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 4
        )

        XCTAssertEqual(
            context,
            InteractiveShortcutContext(
                currentSpaceID: 4,
                scope: .native(spaceID: 4),
                slotEntries: []
            )
        )
    }

    func testResolveReturnsNilWhenActiveVirtualSpaceIsNotInCurrentLayout() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .virtual,
            configGeneration: Self.generatedConfigGeneration("a"),
            activeLayoutName: "work",
            activeVirtualSpaceID: 99,
            pendingSwitchTransaction: nil,
            slots: []
        )

        let context = resolvedContext(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertNil(context)
    }

    func testResolveDetailedReturnsUninitializedWhenActiveVirtualSpaceIsNotInCurrentLayout() {
        let loadedConfig = makeLoadedConfig(mode: .virtual)
        let state = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 1,
            stateMode: .virtual,
            configGeneration: Self.generatedConfigGeneration("a"),
            activeLayoutName: "work",
            activeVirtualSpaceID: 99,
            pendingSwitchTransaction: nil,
            slots: []
        )

        let resolution = RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: 7
        )

        XCTAssertEqual(resolution, .unavailable(reason: .uninitialized))
    }

    private func makeLoadedConfig(
        mode: SpaceInterpretationMode,
        configGeneration: String = generatedConfigGeneration("a")
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

    private func slotEntry(layoutName: String, slot: Int, spaceID: Int, windowID: UInt32) -> SlotEntry {
        SlotEntry(
            layoutName: layoutName,
            slot: slot,
            source: .window,
            bundleID: "com.example.app",
            definitionFingerprint: "fp-\(slot)",
            lastKnownTitle: "Window \(windowID)",
            profile: nil,
            spaceID: spaceID,
            nativeSpaceID: 9,
            displayID: "display-a",
            windowID: windowID
        )
    }

    private static func generatedConfigGeneration(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func resolvedContext(
        loadedConfig: LoadedConfig?,
        state: RuntimeState,
        nativeCurrentSpaceID: Int?
    ) -> InteractiveShortcutContext? {
        let resolution = RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: loadedConfig,
            state: state,
            nativeCurrentSpaceID: nativeCurrentSpaceID
        )
        if case let .resolved(context) = resolution {
            return context
        }
        return nil
    }
}
