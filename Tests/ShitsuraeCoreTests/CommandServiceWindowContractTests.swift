import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceWindowContractTests: CommandServiceContractTestCase {

    func testWindowCurrentRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.windowCurrent(json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "window current supports --json only\n")
    }

    func testWindowCurrentMissingFocusedWindowReturns40JSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.targetWindowNotFound.rawValue)
    }

    func testWindowCurrentReturnsSlotNullWhenUnassigned() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [])
        let window = Self.window(windowID: 700, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertNil(payload.slot)
        XCTAssertEqual(payload.windowID, 700)
        XCTAssertEqual(payload.spaceID, 1)
        XCTAssertEqual(payload.activeSpaceID, 1)
        XCTAssertEqual(payload.nativeSpaceID, 1)
    }

    func testWindowCurrentReturnsProfileWhenTrackedInRuntimeState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.google.Chrome",
                    title: "Editor",
                    profile: "Default",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 700
                ),
            ]
        )
        let window = Self.window(windowID: 700, bundleID: "com.google.Chrome", title: "Editor", spaceID: 1, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.profile, "Default")
        XCTAssertEqual(payload.windowID, 700)
        XCTAssertEqual(payload.spaceID, 1)
        XCTAssertEqual(payload.activeSpaceID, 1)
        XCTAssertEqual(payload.nativeSpaceID, 1)
    }

    func testWindowCurrentReturnsVirtualTrackedWindowAndActiveSpaceSeparately() throws {
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
            activeVirtualSpaceID: 1
        )
        let window = Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.windowID, 801)
        XCTAssertEqual(payload.slot, 2)
        XCTAssertEqual(payload.spaceID, 2)
        XCTAssertEqual(payload.activeSpaceID, 1)
        XCTAssertEqual(payload.nativeSpaceID, 7)
    }

    func testWindowCurrentReturnsNilVirtualSpaceForUntrackedWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        let window = Self.window(windowID: 802, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertNil(payload.spaceID)
        XCTAssertEqual(payload.activeSpaceID, 2)
        XCTAssertEqual(payload.nativeSpaceID, 7)
    }

    func testWindowCurrentReturnsNilActiveSpaceWhenVirtualStateIsUnavailable() throws {
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
            configGeneration: "generation-1"
        )
        let window = Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertNil(payload.spaceID)
        XCTAssertNil(payload.activeSpaceID)
        XCTAssertEqual(payload.nativeSpaceID, 7)
    }

    func testWindowCurrentOmitsVirtualSpaceFieldsWhenStateGenerationIsStale() throws {
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
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        let window = Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [window] },
            focusedWindow: { window },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.windowCurrent(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowCurrentJSON.self, from: result.stdout)
        XCTAssertNil(payload.spaceID)
        XCTAssertNil(payload.activeSpaceID)
        XCTAssertEqual(payload.nativeSpaceID, 7)
        XCTAssertNil(payload.slot)
    }

    func testWindowMoveResizeSetExitCodeContracts() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let focused = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)
        let displays = [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900)
            ),
        ]
        var setFrameCalls: [ResolvedFrame] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { frame in
                setFrameCalls.append(frame)
                return true
            },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        XCTAssertEqual(service.windowMove(x: .expression("10%"), y: .expression("20%")).exitCode, 0)
        XCTAssertEqual(service.windowResize(width: .expression("30%"), height: .expression("40%")).exitCode, 0)
        XCTAssertEqual(service.windowSet(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("60%")).exitCode, 0)
        XCTAssertEqual(setFrameCalls.count, 3)

        let invalid = service.windowResize(width: .expression("0pt"), height: .expression("10pt"))
        XCTAssertEqual(invalid.exitCode, Int32(ErrorCode.validationError.rawValue))

        let timeoutHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
            focusedWindow: { focused },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in false },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let timeoutService = workspace.makeService(runtimeHooks: timeoutHooks)
        XCTAssertEqual(
            timeoutService.windowMove(x: .expression("0%"), y: .expression("0%")).exitCode,
            Int32(ErrorCode.operationTimedOut.rawValue)
        )

        let noTargetHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let noTargetService = workspace.makeService(runtimeHooks: noTargetHooks)
        XCTAssertEqual(
            noTargetService.windowMove(x: .expression("0%"), y: .expression("0%")).exitCode,
            Int32(ErrorCode.targetWindowNotFound.rawValue)
        )

        let permissionHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { false },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { displays },
            runProcess: { _, _ in (0, "") }
        )
        let permissionService = workspace.makeService(runtimeHooks: permissionHooks)
        XCTAssertEqual(
            permissionService.windowMove(x: .expression("0%"), y: .expression("0%")).exitCode,
            Int32(ErrorCode.missingPermission.rawValue)
        )
    }

    func testWindowMoveResizeSetCanTargetExplicitWindowSelector() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.TextEdit", title: "Draft", spaceID: 1, frontIndex: 1),
        ]
        let displays = [
            DisplayInfo(
                id: "display-a",
                width: 3200,
                height: 2000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900)
            ),
        ]
        var focusedFrameCalls: [ResolvedFrame] = []
        var targetedFrameCalls: [(UInt32, String, ResolvedFrame)] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { frame in
                focusedFrameCalls.append(frame)
                return true
            },
            displays: { displays },
            runProcess: { _, _ in (0, "") },
            setWindowFrame: { windowID, bundleID, frame in
                targetedFrameCalls.append((windowID, bundleID, frame))
                return true
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let selector = WindowTargetSelector(windowID: nil, bundleID: "com.apple.TextEdit", title: "Draft")

        XCTAssertEqual(service.windowMove(target: selector, x: .expression("10%"), y: .expression("20%")).exitCode, 0)
        XCTAssertEqual(service.windowResize(target: selector, width: .expression("30%"), height: .expression("40%")).exitCode, 0)
        XCTAssertEqual(
            service.windowSet(target: selector, x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("60%")).exitCode,
            0
        )

        XCTAssertTrue(focusedFrameCalls.isEmpty)
        XCTAssertEqual(targetedFrameCalls.count, 3)
        XCTAssertEqual(targetedFrameCalls.map(\.0), [801, 801, 801])
        XCTAssertEqual(targetedFrameCalls.map(\.1), ["com.apple.TextEdit", "com.apple.TextEdit", "com.apple.TextEdit"])
    }

    func testWindowMoveRejectsInvalidExplicitSelector() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.windowMove(
            target: WindowTargetSelector(windowID: nil, bundleID: nil, title: "Draft"),
            x: .expression("0%"),
            y: .expression("0%")
        )
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
    }

    func testWindowWorkspaceRequiresVirtualModeAndJSONFlag() throws {
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

        let textResult = service.windowWorkspace(spaceID: 2, json: false)
        XCTAssertEqual(textResult.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(textResult.stderr, "window workspace supports --json only\n")

        let jsonResult = service.windowWorkspace(spaceID: 2, json: true)
        XCTAssertEqual(jsonResult.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: jsonResult.stdout)
        XCTAssertEqual(payload.subcode, "windowWorkspaceUnsupportedInNativeMode")
    }

    func testWindowWorkspaceMovesFocusedTrackedWindowToTargetVirtualSpace() throws {
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
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        let focused = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
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
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [focused] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.windowWorkspace(spaceID: 2, json: true)

        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowWorkspaceJSON.self, from: result.stdout)
        XCTAssertEqual(payload.windowID, 800)
        XCTAssertEqual(payload.previousSpaceID, 1)
        XCTAssertEqual(payload.spaceID, 2)
        XCTAssertTrue(payload.didChangeSpace)
        XCTAssertEqual(payload.visibilityAction, "hiddenOffscreen")

        let updated = try stateStore.loadStrict()
        XCTAssertEqual(updated.activeVirtualSpaceID, 1)
        XCTAssertEqual(updated.revision, 5)
        XCTAssertEqual(updated.slots.count, 1)
        XCTAssertEqual(updated.slots.first?.spaceID, 2)
        XCTAssertEqual(updated.slots.first?.windowID, 800)
        XCTAssertEqual(updated.slots.first?.visibilityState, .hiddenOffscreen)
        XCTAssertEqual(positionCalls.count, 1)
        XCTAssertEqual(positionCalls.first?.0, 800)
    }

    func testWindowWorkspaceCreatesRuntimeTrackedEntryForUntrackedFocusedWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 2
        )

        let focused = Self.window(windowID: 901, bundleID: "com.apple.Preview", title: "Spec", spaceID: 7, frontIndex: 0)
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focused] },
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
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [focused] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.windowWorkspace(spaceID: 2, json: true)

        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(WindowWorkspaceJSON.self, from: result.stdout)
        XCTAssertEqual(payload.windowID, 901)
        XCTAssertNil(payload.previousSpaceID)
        XCTAssertEqual(payload.spaceID, 2)
        XCTAssertTrue(payload.didCreateTrackingEntry)
        XCTAssertEqual(payload.visibilityAction, "hiddenOffscreen")

        let updated = try stateStore.loadStrict()
        XCTAssertEqual(updated.revision, 3)
        XCTAssertEqual(updated.slots.count, 1)
        XCTAssertEqual(updated.slots.first?.bundleID, "com.apple.Preview")
        XCTAssertEqual(updated.slots.first?.spaceID, 2)
        XCTAssertEqual(updated.slots.first?.windowID, 901)
        XCTAssertEqual(updated.slots.first?.titleMatchKind, .equals)
        XCTAssertEqual(updated.slots.first?.titleMatchValue, "Spec")
        XCTAssertEqual(updated.slots.first?.visibilityState, .hiddenOffscreen)
        XCTAssertEqual(positionCalls.count, 1)
        XCTAssertEqual(positionCalls.first?.0, 901)
    }

    func testMovedLayoutWindowCanSwitchToDestinationWorkspaceAndReturnToOriginSlotFrame() throws {
        let workspace = try TestConfigWorkspace(files: [
            "config.yaml": """
            mode:
              space: virtual
            layouts:
              work:
                spaces:
                  - spaceID: 1
                    display:
                      monitor: primary
                    windows:
                      - slot: 1
                        launch: false
                        match:
                          bundleID: com.apple.TextEdit
                        frame:
                          x: "0%"
                          y: "0%"
                          width: "50%"
                          height: "100%"
                  - spaceID: 2
                    display:
                      monitor: primary
                    windows:
                      - slot: 1
                        launch: false
                        match:
                          bundleID: com.apple.Notes
                        frame:
                          x: "50%"
                          y: "0%"
                          width: "50%"
                          height: "100%"
            """,
        ])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let customTextEditFrame = ResolvedFrame(x: 120, y: 100, width: 640, height: 420)
        let notesFrame = ResolvedFrame(x: 800, y: 0, width: 800, height: 977)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    layoutOriginSpaceID: 1,
                    layoutOriginSlot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1-textedit",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: customTextEditFrame,
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    layoutOriginSpaceID: 2,
                    layoutOriginSlot: 1,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-1-notes",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801,
                    lastVisibleFrame: notesFrame,
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 10
        )

        var liveWindows: [WindowSnapshot] = [
            WindowSnapshot(
                windowID: 800,
                bundleID: "com.apple.TextEdit",
                pid: 800,
                title: "Editor",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: customTextEditFrame,
                spaceID: 7,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 0
            ),
            WindowSnapshot(
                windowID: 801,
                bundleID: "com.apple.Notes",
                pid: 801,
                title: "Notes",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                spaceID: 7,
                displayID: "display-a",
                isFullscreen: false,
                frontIndex: 1
            ),
        ]
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []

        func updateLiveWindow(windowID: UInt32, frame: ResolvedFrame? = nil, minimized: Bool? = nil) {
            guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                return
            }
            let current = liveWindows[index]
            liveWindows[index] = WindowSnapshot(
                windowID: current.windowID,
                bundleID: current.bundleID,
                pid: current.pid,
                title: current.title,
                role: current.role,
                subrole: current.subrole,
                minimized: minimized ?? current.minimized,
                hidden: current.hidden,
                frame: frame ?? current.frame,
                spaceID: current.spaceID,
                displayID: current.displayID,
                profileDirectory: current.profileDirectory,
                isFullscreen: current.isFullscreen,
                frontIndex: current.frontIndex
            )
        }

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { liveWindows },
            focusedWindow: { liveWindows.first(where: { $0.windowID == 800 }) },
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
            focusWindow: { _, _ in .success },
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                updateLiveWindow(windowID: windowID, frame: frame, minimized: false)
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                let currentFrame = liveWindows.first(where: { $0.windowID == windowID })?.frame
                updateLiveWindow(
                    windowID: windowID,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: currentFrame?.width ?? 640,
                        height: currentFrame?.height ?? 480
                    )
                )
                return true
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let moveToWorkspace2 = service.windowWorkspace(spaceID: 2, json: true)
        XCTAssertEqual(moveToWorkspace2.exitCode, 0)
        XCTAssertEqual(try stateStore.loadStrict().slots.first(where: { $0.windowID == 800 })?.slot, 2)

        let switchToWorkspace2 = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(switchToWorkspace2.exitCode, 0)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 800 && $0.1 == customTextEditFrame }))
        XCTAssertEqual(try stateStore.loadStrict().activeVirtualSpaceID, 2)

        let moveBackToWorkspace1 = service.windowWorkspace(
            target: WindowTargetSelector(windowID: 800, bundleID: nil, title: nil),
            spaceID: 1,
            json: true
        )
        XCTAssertEqual(moveBackToWorkspace1.exitCode, 0)
        XCTAssertEqual(try stateStore.loadStrict().slots.first(where: { $0.windowID == 800 })?.slot, 1)

        let switchBackToWorkspace1 = service.spaceSwitch(spaceID: 1, json: true)
        XCTAssertEqual(switchBackToWorkspace1.exitCode, 0)

        let expectedOriginLayoutFrame = ResolvedFrame(x: 0, y: 0, width: 800, height: 977)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 800 && $0.1 == expectedOriginLayoutFrame }))

        let updated = try stateStore.loadStrict()
        let textEditEntry = updated.slots.first(where: { $0.windowID == 800 })
        XCTAssertEqual(updated.activeVirtualSpaceID, 1)
        XCTAssertEqual(textEditEntry?.spaceID, 1)
        XCTAssertEqual(textEditEntry?.slot, 1)
        XCTAssertEqual(textEditEntry?.visibilityState, .visible)
        XCTAssertFalse(positionCalls.isEmpty)
    }

    func testRestoreVirtualWorkspaceWindowsForShutdownRestoresHiddenWindowsAndClearsActiveState() throws {
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
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 23, width: 800, height: 977),
                    visibilityState: .visible
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
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 999, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 9
        )

        let editor = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        let notes = Self.window(windowID: 900, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1)
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [editor, notes] },
            focusedWindow: { editor },
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
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [editor, notes] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.restoreVirtualWorkspaceWindowsForShutdown()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(frameCalls.count, 2)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 800 && $0.1 == ResolvedFrame(x: 0, y: 0, width: 800, height: 977) }))
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 900 && $0.1 == ResolvedFrame(x: 800, y: 0, width: 800, height: 977) }))

        let updated = try stateStore.loadStrict()
        XCTAssertNil(updated.activeLayoutName)
        XCTAssertNil(updated.activeVirtualSpaceID)
        XCTAssertNil(updated.pendingSwitchTransaction)
        XCTAssertEqual(updated.revision, 10)
        XCTAssertEqual(updated.slots.first(where: { $0.slot == 2 })?.visibilityState, .visible)
        XCTAssertNil(updated.slots.first(where: { $0.slot == 2 })?.lastHiddenFrame)
    }

    func testRestoreVirtualWorkspaceWindowsForShutdownKeepsStateWhenFrameRestoreFails() throws {
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
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 999, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let notes = Self.window(windowID: 900, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [notes] },
            focusedWindow: { notes },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { _, _, _ in false },
            setWindowPosition: { _, _, _ in false },
            spaces: { [] },
            listWindowsOnAllSpaces: { [notes] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.restoreVirtualWorkspaceWindowsForShutdown()

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.virtualSpaceSwitchFailed.rawValue))

        let updated = try stateStore.loadStrict()
        XCTAssertEqual(updated.activeLayoutName, "work")
        XCTAssertEqual(updated.activeVirtualSpaceID, 1)
        XCTAssertEqual(updated.revision, 3)
        XCTAssertEqual(updated.slots.first?.visibilityState, .hiddenOffscreen)
    }

    func testRestoreVirtualWorkspaceWindowsForShutdownFallsBackToPositionWhenFrameRestoreFails() throws {
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
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 999, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let notes = Self.window(windowID: 900, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [notes] },
            focusedWindow: { notes },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { _, _, _ in false },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: { [] },
            listWindowsOnAllSpaces: { [notes] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.restoreVirtualWorkspaceWindowsForShutdown()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(positionCalls.count, 1)
        XCTAssertEqual(positionCalls.first?.0, 900)
        XCTAssertEqual(positionCalls.first?.1.x, 800)
        XCTAssertEqual(positionCalls.first?.1.y, 23)

        let updated = try stateStore.loadStrict()
        XCTAssertNil(updated.activeLayoutName)
        XCTAssertNil(updated.activeVirtualSpaceID)
        XCTAssertEqual(updated.slots.first?.visibilityState, .visible)
    }

    func testRestoreVirtualWorkspaceWindowsForShutdownPrefersLayoutFrameOverPersistedOffscreenFrame() throws {
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
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 5119, y: 25, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 5119, y: 25, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let notes = Self.window(windowID: 900, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [notes] },
            focusedWindow: { notes },
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
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { _, _, _ in true },
            spaces: { [] },
            listWindowsOnAllSpaces: { [notes] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.restoreVirtualWorkspaceWindowsForShutdown()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(frameCalls.count, 1)
        XCTAssertEqual(frameCalls.first?.0, 900)
        XCTAssertEqual(frameCalls.first?.1, ResolvedFrame(x: 800, y: 0, width: 800, height: 977))
    }

    func testRestoreVirtualWorkspaceWindowsForShutdownReloadsStateAfterCrossProcessStyleAtomicStateRewrite() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        try stateStore.saveStrict(
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
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 999, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "test",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        var minimizeCalls: [(UInt32, Bool)] = []
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let notes = Self.window(windowID: 900, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [notes] },
            focusedWindow: { notes },
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
            setWindowMinimized: { windowID, _, minimized in
                minimizeCalls.append((windowID, minimized))
                return .success
            },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: { [] },
            listWindowsOnAllSpaces: { [notes] }
        )

        let service = UnsafeSendableBox(value: workspace.makeService(
            stateStore: stateStore,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL),
            runtimeHooks: runtimeHooks
        ))
        let resultBox = LockedValueBox<CommandResult?>(nil)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            resultBox.set(service.value.restoreVirtualWorkspaceWindowsForShutdown())
            completion.leave()
        }

        usleep(200_000)
        XCTAssertNil(resultBox.get())

        try stateStore.saveStrict(
            state: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: 4,
                stateMode: .virtual,
                configGeneration: "test",
                activeLayoutName: nil,
                activeVirtualSpaceID: nil,
                pendingSwitchTransaction: nil,
                slots: []
            ),
            expecting: RuntimeStateWriteExpectation(
                revision: 3,
                configGeneration: "test"
            )
        )

        _ = flock(fd, LOCK_UN)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resultBox.get()?.exitCode, 0)
        XCTAssertTrue(minimizeCalls.isEmpty)
        XCTAssertTrue(frameCalls.isEmpty)
        XCTAssertTrue(positionCalls.isEmpty)

        let updated = try stateStore.loadStrict()
        XCTAssertEqual(updated.revision, 4)
        XCTAssertNil(updated.activeLayoutName)
        XCTAssertNil(updated.activeVirtualSpaceID)
        XCTAssertTrue(updated.slots.isEmpty)
    }

}
