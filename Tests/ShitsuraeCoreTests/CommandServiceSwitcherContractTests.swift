import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceSwitcherContractTests: CommandServiceContractTestCase {
    func testSwitcherListJSONSchemaAndPriorityOrder() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 3,
                    source: .window,
                    bundleID: "com.example.mail",
                    title: "C",
                    spaceID: 2,
                    displayID: "display-a",
                    windowID: 103,
                ),
            ]
        )

        let windows = [
            Self.window(windowID: 101, bundleID: "com.example.notes", title: "A", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 102, bundleID: "com.example.chat", title: "B", spaceID: 2, frontIndex: 1),
            Self.window(windowID: 103, bundleID: "com.example.mail", title: "C", spaceID: 2, frontIndex: 2),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[1] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertTrue(Self.isRFC3339UTCWithFractionalSeconds(payload.generatedAt))
        XCTAssertTrue(payload.includeAllSpaces)
        XCTAssertEqual(payload.spacesMode, .perDisplay)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:103", "window:102", "window:101"])
        XCTAssertEqual(payload.candidates.map(\.quickKey), ["a", "b", "c"])
        XCTAssertEqual(payload.candidates.first(where: { $0.id == "window:103" })?.slot, 3)
    }

    func testSwitcherListOrdersFrontToBackWithinCurrentSpace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [])
        let windows = [
            Self.window(windowID: 101, bundleID: "com.example.notes", title: "A", spaceID: 2, frontIndex: 1),
            Self.window(windowID: 102, bundleID: "com.example.chat", title: "B", spaceID: 2, frontIndex: 0),
            Self.window(windowID: 103, bundleID: "com.example.mail", title: "C", spaceID: 1, frontIndex: 2),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[1] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:102", "window:101"])
    }

    func testSwitcherListFallsBackToVisibleCurrentSpaceWhenFocusedWindowIsUnavailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            Self.window(windowID: 101, bundleID: "com.example.notes", title: "A", spaceID: 1, frontIndex: 1),
            Self.window(windowID: 102, bundleID: "com.example.chat", title: "B", spaceID: 2, frontIndex: 0),
            Self.window(windowID: 103, bundleID: "com.example.mail", title: "C", spaceID: 2, frontIndex: 2),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: false, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 2, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:102", "window:103"])
    }

    func testSwitcherListAccessibilityMissingReturnsCode20JSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { false },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.missingPermission.rawValue))
        XCTAssertTrue(result.stderr.isEmpty)
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.missingPermission.rawValue)
    }

    func testSwitcherListExcludesHiddenWindowCandidates() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            WindowSnapshot(
                windowID: 701,
                bundleID: "com.example.visible",
                pid: 701,
                title: "Visible",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
                spaceID: 1,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 0
            ),
            WindowSnapshot(
                windowID: 702,
                bundleID: "com.example.hidden",
                pid: 702,
                title: "Hidden",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: true,
                frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
                spaceID: 1,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 1
            ),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[0] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:701"])
    }

    func testSwitcherListIgnoresStaleVirtualSlotAssignmentsAfterModeChangesToNative() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 3,
                    source: .window,
                    bundleID: "com.example.mail",
                    definitionFingerprint: "slot-3",
                    lastKnownTitle: "Mail",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 103
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        let windows = [
            Self.window(windowID: 103, bundleID: "com.example.mail", title: "Mail", spaceID: 2, frontIndex: 0),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[0] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.slot), [nil])
    }

    func testSwitcherListReturnsNativeCandidatesWithoutPersistingVirtualStateAfterModeChangesToNative() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 3,
                    source: .window,
                    bundleID: "com.example.mail",
                    definitionFingerprint: "slot-3",
                    lastKnownTitle: "Mail",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 103
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-virtual",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
        )
        let window = Self.window(windowID: 103, bundleID: "com.example.mail", title: "Mail", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:103"])
        XCTAssertEqual(payload.candidates.map(\.slot), [nil])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.configGeneration, "generation-virtual")
    }

    func testSwitcherListDefaultTargetsCurrentSpaceAndOverrideCanIncludeAllSpaces() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.switcherConfigYAML])
        defer { workspace.cleanup() }
        let windows = [
            Self.window(windowID: 1001, bundleID: "com.example.current", title: "Current", spaceID: 2, frontIndex: 0),
            Self.window(windowID: 1002, bundleID: "com.example.other", title: "Other", spaceID: 1, frontIndex: 1),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[0] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let byConfig = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(byConfig.exitCode, 0)
        let byConfigPayload = try decode(SwitcherListJSON.self, from: byConfig.stdout)
        XCTAssertFalse(byConfigPayload.includeAllSpaces)
        XCTAssertEqual(byConfigPayload.candidates.map(\.id), ["window:1001"])

        let byOverrideTrue = service.switcherList(json: true, includeAllSpacesOverride: true)
        XCTAssertEqual(byOverrideTrue.exitCode, 0)
        let byOverrideTruePayload = try decode(SwitcherListJSON.self, from: byOverrideTrue.stdout)
        XCTAssertTrue(byOverrideTruePayload.includeAllSpaces)
        XCTAssertEqual(byOverrideTruePayload.candidates.map(\.id), ["window:1001", "window:1002"])
    }

    func testSwitcherListWithoutConfigHonorsOverrideAndOrdersSlotFirst() throws {
        let workspace = try TestConfigWorkspace(files: [:])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 2,
                    source: .window,
                    bundleID: "com.example.b",
                    title: "B",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 1202,
                ),
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.example.c",
                    title: "C",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 1203,
                ),
            ]
        )

        let windows = [
            Self.window(windowID: 1201, bundleID: "com.example.a", title: "A", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 1202, bundleID: "com.example.b", title: "B", spaceID: 1, frontIndex: 1),
            Self.window(windowID: 1203, bundleID: "com.example.c", title: "C", spaceID: 1, frontIndex: 2),
            Self.window(windowID: 1204, bundleID: "com.example.d", title: "D", spaceID: 2, frontIndex: 3),
        ]

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { windows[0] },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.switcherList(json: true, includeAllSpacesOverride: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertTrue(payload.includeAllSpaces)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:1203", "window:1202", "window:1201", "window:1204"])
        XCTAssertEqual(payload.candidates.map(\.slot), [1, 2, nil, nil])
        XCTAssertEqual(payload.candidates.map(\.quickKey), ["1", "2", "3", "4"])
    }

    func testSwitcherListReturnsTrackedVisibleWindowsForActiveVirtualSpace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
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

        let currentSpaceWindows = [
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { currentSpaceWindows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertFalse(payload.includeAllSpaces)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:801"])
        XCTAssertEqual(payload.candidates.map(\.spaceID), [2])
        XCTAssertEqual(payload.candidates.map(\.slot), [2])
        XCTAssertEqual(payload.candidates.map(\.quickKey), ["a"])
    }

    func testSwitcherListVirtualCurrentSpaceIgnoresClosedWindowLeftInAllSpacesSnapshot() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
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
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.yuki-yano.shitsurae",
                    definitionFingerprint: "runtimeVirtualWorkspace\u{0}work\u{0}com.yuki-yano.shitsurae\u{0}Shitsurae\u{0}AXWindow\u{0}\u{0}",
                    lastKnownTitle: "Shitsurae",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 999
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )

        let currentSpaceWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { currentSpaceWindows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: {
                currentSpaceWindows + [
                    Self.window(
                        windowID: 999,
                        bundleID: "com.yuki-yano.shitsurae",
                        title: "Shitsurae",
                        spaceID: 7,
                        frontIndex: 1
                    ),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:800"])
        XCTAssertEqual(payload.candidates.map(\.bundleID), ["com.apple.TextEdit"])
    }

    func testSwitcherListIncludeAllSpacesReturnsTrackedWindowsAcrossActiveLayoutInVirtualMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 3,
                    source: .window,
                    bundleID: "com.apple.Calendar",
                    definitionFingerprint: "slot-3",
                    lastKnownTitle: "Calendar",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 802
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
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
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
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 2, minimized: true),
                    Self.window(windowID: 802, bundleID: "com.apple.Calendar", title: "Calendar", spaceID: 7, frontIndex: 3, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SwitcherListJSON.self, from: result.stdout)
        XCTAssertTrue(payload.includeAllSpaces)
        XCTAssertEqual(payload.candidates.map(\.id), ["window:800", "window:801", "window:802"])
        XCTAssertEqual(payload.candidates.map(\.spaceID), [2, 2, 1])
        XCTAssertEqual(payload.candidates.map(\.slot), [1, 2, 3])
        XCTAssertEqual(payload.candidates.map(\.quickKey), ["a", "b", "c"])
    }

    func testSwitcherListReturnsVirtualStateUnavailableWhenActiveStateMissing() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [], stateMode: .virtual, configGeneration: "generation-1")
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSwitcherListReturnsVirtualStateUnavailableWhenStateGenerationIsStale() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSwitcherListReturnsVirtualStateUnavailableWhilePendingRecoveryLeavesNoActiveState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-recovery",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSwitcherListReturnsVirtualStateUnavailableWhilePendingSwitchLeavesNoActiveState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-busy",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .inFlight,
            )
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSwitcherListRecordsStaleGenerationDiagnosticEvent() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSwitcherConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-switcher-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.switcherList(json: true, includeAllSpacesOverride: nil)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.staleGeneration")
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.subcode, "virtualStateUnavailable")
        XCTAssertEqual(event.rootCauseCategory, "staleStateRead")
        XCTAssertEqual(event.failedOperation, "switcher.list")
    }

    func testSwitcherRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let switcher = service.switcherList(json: false, includeAllSpacesOverride: nil)
        XCTAssertEqual(switcher.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(switcher.stderr, "switcher list supports --json only\n")
    }
}
