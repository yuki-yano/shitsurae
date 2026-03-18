import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceSpaceQueryContractTests: CommandServiceContractTestCase {
    func testDisplayListRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.displayList(json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "display list supports --json only\n")
    }

    func testDisplayListReturnsDisplaysJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let displays = [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
            ),
            DisplayInfo(
                id: "display-b",
                width: 2560,
                height: 1440,
                scale: 2.0,
                isPrimary: false,
                frame: CGRect(x: 1600, y: 0, width: 1280, height: 720),
                visibleFrame: CGRect(x: 1600, y: 0, width: 1280, height: 680)
            ),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.displayList(json: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(DisplayListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.displays.map(\.id), ["display-a", "display-b"])
        XCTAssertEqual(payload.displays.map(\.pixelWidth), [3200, 2560])
        XCTAssertEqual(payload.displays.map(\.frame.width), [1600, 1280])
        XCTAssertEqual(payload.displays.map(\.visibleFrame.height), [977, 680])
    }

    func testDisplayCurrentRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.displayCurrent(json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "display current supports --json only\n")
    }

    func testDisplayCurrentReturnsTargetWindowDisplayJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let window = Self.window(windowID: 700, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 2, frontIndex: 0)
        let displays = [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
            ),
            DisplayInfo(
                id: "display-b",
                width: 2560,
                height: 1440,
                scale: 2.0,
                isPrimary: false,
                frame: CGRect(x: 1600, y: 0, width: 1280, height: 720),
                visibleFrame: CGRect(x: 1600, y: 0, width: 1280, height: 680)
            ),
        ]
        let windowOnDisplayB = WindowSnapshot(
            windowID: window.windowID,
            bundleID: window.bundleID,
            pid: window.pid,
            title: window.title,
            role: window.role,
            subrole: window.subrole,
            minimized: window.minimized,
            hidden: window.hidden,
            frame: window.frame,
            spaceID: window.spaceID,
            displayID: "display-b",
            isFullscreen: window.isFullscreen,
            frontIndex: window.frontIndex
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [windowOnDisplayB] },
            focusedWindow: { windowOnDisplayB },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.displayCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(DisplayCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.display.id, "display-b")
        XCTAssertFalse(payload.display.isPrimary)
        XCTAssertEqual(payload.display.visibleFrame.width, 1280)
    }

    func testDisplayCurrentMissingDisplayReturns40JSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let window = Self.window(windowID: 700, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 2, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.displayCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.targetWindowNotFound.rawValue)
    }

    func testSpaceListRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.spaceList(json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "space list supports --json only\n")
    }

    func testSpaceListReturnsRuntimeSpacesJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let focused = Self.window(windowID: 801, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 2, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.Notes", title: "Notes", spaceID: 1, frontIndex: 1),
                    focused,
                    Self.window(windowID: 900, bundleID: "com.apple.Terminal", title: "Shell", spaceID: 1, frontIndex: 2),
                ]
            },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 2, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.Notes", title: "Notes", spaceID: 1, frontIndex: 1),
                    focused,
                    Self.window(windowID: 900, bundleID: "com.apple.Terminal", title: "Shell", spaceID: 1, frontIndex: 2),
                ]
            }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.spaces.map(\.spaceID), [1, 2])
        XCTAssertEqual(payload.spaces.map(\.kind), [.native, .native])
        XCTAssertEqual(payload.spaces.map(\.displayID), ["display-a", "display-a"])
        XCTAssertEqual(payload.spaces.map(\.trackedWindowIDs), [[], []])
        XCTAssertEqual(payload.spaces.map(\.hasFocus), [false, true])
    }

    func testSpaceCurrentRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.spaceCurrent(json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "space current supports --json only\n")
    }

    func testSpaceCurrentReturnsFocusedWindowSpaceJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let focused = Self.window(windowID: 801, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 2, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 2, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [focused] }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertEqual(payload.space.kind, .native)
        XCTAssertEqual(payload.space.displayID, "display-a")
        XCTAssertTrue(payload.space.hasFocus)
        XCTAssertEqual(payload.space.trackedWindowIDs, [])
    }

    func testSpaceCurrentReturnsNativeSpaceWithoutPersistingVirtualStateWhenConfigModeChangesToNative() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-virtual",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )
        let focused = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { [focused] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.space.spaceID, 7)
        XCTAssertEqual(payload.space.kind, .native)
        XCTAssertEqual(payload.space.trackedWindowIDs, [])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.configGeneration, "generation-virtual")
    }

    func testSpaceListReturnsVirtualSpacesFromActiveLayout() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )

        let focused = Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    focused,
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.spaces.map(\.spaceID), [1, 2])
        XCTAssertEqual(payload.spaces.map(\.kind), [.virtual, .virtual])
        XCTAssertEqual(payload.spaces.map(\.trackedWindowIDs), [[800], [801]])
        XCTAssertEqual(payload.spaces.map(\.hasFocus), [false, true])
        XCTAssertEqual(payload.spaces.map(\.isVisible), [false, true])
    }

    func testSpaceListReturnsVirtualStateUnavailableWhenActiveStateMissing() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [], stateMode: .virtual, configGeneration: "generation-1")
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSpaceListReturnsVirtualStateUnavailableWhenStateGenerationIsStale() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSpaceListRecordsStaleGenerationDiagnosticEvent() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-space-list-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore
        )

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.staleGeneration")
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.subcode, "virtualStateUnavailable")
        XCTAssertEqual(event.rootCauseCategory, "staleStateRead")
        XCTAssertEqual(event.failedOperation, "space.list")
    }

    func testSpaceListIgnoresTrackedWindowIDsWhenNativeConfigOnlyHasStaleVirtualState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 1,
                    displayID: "display-a",
                    windowID: 800
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let window = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { [window] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.spaces.first?.trackedWindowIDs, [])
    }

    func testSpaceCurrentReturnsActiveVirtualSpaceJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertEqual(payload.space.kind, .virtual)
        XCTAssertTrue(payload.space.hasFocus)
        XCTAssertEqual(payload.space.trackedWindowIDs, [801])
    }

    func testSpaceCurrentReturnsVirtualStateUnavailableWhenActiveStateMissing() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [], stateMode: .virtual, configGeneration: "generation-1")
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSpaceCurrentReturnsVirtualStateUnavailableWhenStateGenerationIsStale() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSpaceCurrentRecordsStaleGenerationDiagnosticEvent() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-space-current-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore
        )

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.staleGeneration")
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.subcode, "virtualStateUnavailable")
        XCTAssertEqual(event.rootCauseCategory, "staleStateRead")
        XCTAssertEqual(event.failedOperation, "space.current")
    }

    func testSpaceCurrentMissingFocusedWindowReturns40JSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.targetWindowNotFound.rawValue)
    }

    func testSpaceListReturnsNativeSpacesWithoutPersistingVirtualStateWhenConfigModeChangesToNative() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-virtual",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                ]
            },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.spaces.first?.kind, .native)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.configGeneration, "generation-virtual")
    }

    func testSpaceCurrentDoesNotPersistClearingInvalidActiveVirtualState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801
                ),
            ],
            stateMode: .virtual,
            configGeneration: try workspace.currentConfigGeneration(),
            activeLayoutName: "work",
            activeVirtualSpaceID: 99,
            revision: 3
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 99)
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.stateMode, .virtual)
    }

    func testSpaceCurrentKeepsPendingRecoveryStateAcrossModeChange() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-virtual",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 9,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-recovery",
                startedAt: "2026-03-13T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-virtual",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let focused = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { [focused] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceCurrent(json: true)
        if result.exitCode == 0 {
            let payload = try decode(SpaceCurrentJSON.self, from: result.stdout)
            XCTAssertEqual(payload.space.kind, .native)
            XCTAssertEqual(payload.space.spaceID, 1)
        } else {
            XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        }

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertEqual(persisted.pendingSwitchTransaction?.status, .recoveryRequired)
    }

    func testSpaceListReturnsNativeSpacesAfterConfigReloadWithoutPersistingVirtualState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let initialConfigGeneration = try workspace.currentConfigGeneration()

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
            ],
            stateMode: .virtual,
            configGeneration: initialConfigGeneration,
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 5
        )
        try Self.validConfigYAML.write(
            to: workspace.configDirectory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                ]
            },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceList(json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.spaces.first?.kind, .native)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.configGeneration, initialConfigGeneration)
    }

    func testSpaceCurrentPromotesCrashLeftoverPendingStateToRecoveryRequired() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: try workspace.currentConfigGeneration(),
            activeLayoutName: "work",
            activeVirtualSpaceID: 99,
            revision: 5,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-inflight",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: try workspace.currentConfigGeneration(),
                status: .inFlight,
            )
        )
        let diagnosticEventStore = DiagnosticEventStore(fileURL: workspace.root.appendingPathComponent("diagnostic-events-crash-leftover.jsonl"))
        let service = workspace.makeService(stateStore: stateStore, diagnosticEventStore: diagnosticEventStore)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
        XCTAssertNil(payload.recoveryContext)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.revision, 5)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 99)
        XCTAssertEqual(persisted.pendingSwitchTransaction?.status, .inFlight)

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.crashLeftoverPromotionDeferred")
        XCTAssertEqual(event.subcode, "virtualStateRecoveryRequired")
        XCTAssertEqual(event.rootCauseCategory, "readNormalizationNotPersisted")
    }

    func testSpaceCurrentRecordsDeferredCrashLeftoverEventWhenPromotionSaveFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: try workspace.currentConfigGeneration(),
            activeLayoutName: "work",
            activeVirtualSpaceID: 99,
            revision: 5,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-inflight",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: try workspace.currentConfigGeneration(),
                status: .inFlight,
            )
        )
        let stateStore = RuntimeStateStore(
            fileManager: AlwaysFailingCreateDirectoryFileManager(),
            stateFileURL: workspace.stateFileURL
        )
        let diagnosticEventStore = DiagnosticEventStore(fileURL: workspace.root.appendingPathComponent("diagnostic-events-crash-leftover-save-fail.jsonl"))
        let service = workspace.makeService(stateStore: stateStore, diagnosticEventStore: diagnosticEventStore)

        let result = service.spaceCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
        XCTAssertNil(payload.recoveryContext)

        let persisted = RuntimeStateStore(stateFileURL: workspace.stateFileURL).load()
        XCTAssertEqual(persisted.revision, 5)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 99)
        XCTAssertEqual(persisted.pendingSwitchTransaction?.status, .inFlight)

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.crashLeftoverPromotionDeferred")
        XCTAssertEqual(event.subcode, "virtualStateRecoveryRequired")
        XCTAssertEqual(event.rootCauseCategory, "readNormalizationNotPersisted")
    }
}
