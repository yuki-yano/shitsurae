import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceSpaceSwitchContractTests: CommandServiceContractTestCase {
    func testSpaceSwitchReturnsVirtualSpaceNotFound() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceSwitch(spaceID: 9, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceNotFound")
    }

    func testSpaceSwitchUpdatesActiveVirtualSpaceAndReturnsJSON() throws {
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
            activeVirtualSpaceID: 1,
            revision: 3
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

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.layoutName, "work")
        XCTAssertEqual(payload.previousSpaceID, 1)
        XCTAssertTrue(payload.didChangeSpace)
        XCTAssertEqual(payload.action, "switch")
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertEqual(payload.space.kind, .virtual)
        XCTAssertEqual(payload.space.trackedWindowIDs, [801])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertEqual(persisted.revision, 4)
    }

    func testSpaceSwitchNonJSONSuccessLineMatchesJSONActionAndDidChangeSpace() throws {
        let jsonWorkspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { jsonWorkspace.cleanup() }
        let textWorkspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { textWorkspace.cleanup() }

        for workspace in [jsonWorkspace, textWorkspace] {
            try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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
                activeVirtualSpaceID: 1,
                revision: 3
            )
        }

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
        let jsonService = jsonWorkspace.makeService(
            stateStore: RuntimeStateStore(stateFileURL: jsonWorkspace.stateFileURL),
            runtimeHooks: runtimeHooks
        )
        let textService = textWorkspace.makeService(
            stateStore: RuntimeStateStore(stateFileURL: textWorkspace.stateFileURL),
            runtimeHooks: runtimeHooks
        )

        let jsonResult = jsonService.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(jsonResult.exitCode, 0)
        let jsonPayload = try decode(SpaceSwitchJSON.self, from: jsonResult.stdout)
        XCTAssertEqual(jsonPayload.action, "switch")
        XCTAssertTrue(jsonPayload.didChangeSpace)

        let textResult = textService.spaceSwitch(spaceID: 2, json: false, reconcile: false)
        XCTAssertEqual(textResult.exitCode, 0)
        XCTAssertEqual(textResult.stderr, "")
        let line = textResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = Dictionary(
            uniqueKeysWithValues: line.split(separator: " ").compactMap { part -> (String, String)? in
                let components = part.split(separator: "=", maxSplits: 1)
                guard components.count == 2 else {
                    return nil
                }
                return (String(components[0]), String(components[1]))
            }
        )
        XCTAssertFalse(fields["requestID"]?.isEmpty ?? true)
        XCTAssertEqual(fields["action"], jsonPayload.action)
        XCTAssertEqual(fields["layout"], jsonPayload.layoutName)
        XCTAssertEqual(fields["space"], String(jsonPayload.space.spaceID))
        XCTAssertEqual(fields["didChangeSpace"], jsonPayload.didChangeSpace ? "true" : "false")
    }

    func testSpaceSwitchReturnsNoopForCurrentSpace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertFalse(payload.didChangeSpace)
        XCTAssertEqual(payload.action, "noop")
        XCTAssertEqual(stateStore.load().revision, 5)
    }

    func testSpaceSwitchReusesPrepareExecutionContextSnapshots() throws {
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var allWindowSnapshotCount = 0
        var onScreenWindowSnapshotCount = 0
        var focusedWindowCount = 0
        var displaysCount = 0
        var spacesCount = 0
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                onScreenWindowSnapshotCount += 1
                return []
            },
            focusedWindow: {
                focusedWindowCount += 1
                return Self.window(
                    windowID: 800,
                    bundleID: "com.apple.TextEdit",
                    title: "Editor",
                    spaceID: 7,
                    frontIndex: 0
                )
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                displaysCount += 1
                return [
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
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                spacesCount += 1
                return [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                allWindowSnapshotCount += 1
                return [
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(allWindowSnapshotCount, 2)
        XCTAssertEqual(onScreenWindowSnapshotCount, 1)
        XCTAssertEqual(focusedWindowCount, 1)
        XCTAssertEqual(displaysCount, 2)
        XCTAssertEqual(spacesCount, 1)
    }

    func testSpaceSwitchRestoresTargetWindowsMinimizesOtherWindowsAndFocusesTarget() throws {
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var minimizedCalls: [(UInt32, String, Bool)] = []
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        var focusedCalls: [(UInt32, String)] = []
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
            focusWindow: { windowID, bundleID in
                focusedCalls.append((windowID, bundleID))
                return .success
            },
            setWindowMinimized: { windowID, bundleID, minimized in
                minimizedCalls.append((windowID, bundleID, minimized))
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.action, "switch")
        XCTAssertTrue(payload.didChangeSpace)
        XCTAssertEqual(payload.previousSpaceID, 1)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertEqual(payload.space.trackedWindowIDs, [801])

        XCTAssertTrue(minimizedCalls.isEmpty)
        XCTAssertEqual(frameCalls.map(\.0), [801])
        XCTAssertEqual(positionCalls.map(\.0), [800])
        XCTAssertEqual(focusedCalls.map(\.0), [801])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertNil(persisted.pendingSwitchTransaction)
        XCTAssertEqual(persisted.revision, 4)
    }

    func testSpaceSwitchReconcileConvergesVisibilityWithoutChangingActiveSpace() throws {
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
            activeVirtualSpaceID: 2,
            revision: 5
        )

        var minimizedCalls: [(UInt32, String, Bool)] = []
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
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
            focusWindow: { _, _ in .success },
            setWindowMinimized: { windowID, bundleID, minimized in
                minimizedCalls.append((windowID, bundleID, minimized))
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.action, "reconcile")
        XCTAssertFalse(payload.didChangeSpace)
        XCTAssertEqual(payload.previousSpaceID, 2)
        XCTAssertTrue(minimizedCalls.isEmpty)
        XCTAssertEqual(Set(frameCalls.map(\.0)), [801])
        XCTAssertEqual(Set(positionCalls.map(\.0)), [800])
        XCTAssertGreaterThanOrEqual(frameCalls.count, 1)
        XCTAssertGreaterThanOrEqual(positionCalls.count, 1)
        XCTAssertEqual(stateStore.load().revision, 5)
    }

    func testSpaceSwitchShowsAllTargetWindowsForDestinationWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualThreeWindowConfigYAML])
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
                    lastHiddenFrame: ResolvedFrame(x: 4000, y: 23, width: 800, height: 977),
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 4300, y: 23, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 3,
                    source: .window,
                    bundleID: "com.apple.Calendar",
                    definitionFingerprint: "slot-3",
                    lastKnownTitle: "Calendar",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 802,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 4600, y: 23, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        var liveWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 2),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 802, bundleID: "com.apple.Calendar", title: "Calendar", spaceID: 7, frontIndex: 1),
        ]
        let focusedWindow = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { focusedWindow },
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
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
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
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(Set(frameCalls.map(\.0) + positionCalls.map(\.0)), Set([800, 801, 802]))
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 801 && $0.1 == ResolvedFrame(x: 0, y: 0, width: 800, height: 977) }))
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 802 && $0.1.x == 800 }))
        XCTAssertEqual(positionCalls.map(\.0), [800])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertEqual(Set(persisted.slots.compactMap(\.windowID)), Set([800, 801, 802]))
        XCTAssertEqual(
            persisted.slots.first(where: { $0.windowID == 800 })?.visibilityState,
            .hiddenOffscreen
        )
        XCTAssertEqual(
            persisted.slots.first(where: { $0.windowID == 801 })?.visibilityState,
            .visible
        )
    }

    func testSpaceSwitchFocusesMostRecentlyActivatedWindowInTargetWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualThreeWindowConfigYAML])
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
                    windowID: 801,
                    lastActivatedAt: "2026-03-15T00:00:00.000Z"
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 3,
                    source: .window,
                    bundleID: "com.apple.Calendar",
                    definitionFingerprint: "slot-3",
                    lastKnownTitle: "Calendar",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 802,
                    lastActivatedAt: "2026-03-15T01:00:00.000Z"
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        var focusedCalls: [(UInt32, String)] = []
        let activationTime = Date(timeIntervalSince1970: 1_742_000_000)
        let focusedWindow = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { focusedWindow },
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
            focusWindow: { windowID, bundleID in
                focusedCalls.append((windowID, bundleID))
                return .success
            },
            setWindowMinimized: { _, _, _ in .success },
            setWindowFrame: { _, _, _ in true },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 2),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 802, bundleID: "com.apple.Calendar", title: "Calendar", spaceID: 7, frontIndex: 1),
                ]
            },
            now: { activationTime }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedCalls.map(\.0), [802])
        let persisted = stateStore.load()
        XCTAssertEqual(
            persisted.slots.first(where: { $0.windowID == 802 })?.lastActivatedAt,
            makeRFC3339UTCFormatter().string(from: activationTime)
        )
    }

    func testSpaceSwitchHidesInactiveWindowsInMonitorCornerThatAvoidsNeighborDisplay() throws {
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let focusedWindow = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { focusedWindow },
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
                    DisplayInfo(
                        id: "display-b",
                        width: 2560,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: false,
                        frame: CGRect(x: 1600, y: 0, width: 1280, height: 1000),
                        visibleFrame: CGRect(x: 1600, y: 0, width: 1280, height: 1000)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
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
                    SpaceInfo(spaceID: 8, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        let hiddenCall = try XCTUnwrap(positionCalls.first(where: { $0.0 == 800 }))
        XCTAssertLessThan(hiddenCall.1.x, 0)
        XCTAssertEqual(hiddenCall.1.y, 0)
    }

    func testSpaceSwitchDoesNotHideTrackedWindowOnNonHostDisplay() throws {
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
                    nativeSpaceID: 8,
                    displayID: "display-b",
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let focusedWindow = WindowSnapshot(
            windowID: 800,
            bundleID: "com.apple.TextEdit",
            pid: 800,
            title: "Editor",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 1600, y: 0, width: 640, height: 480),
            spaceID: 8,
            displayID: "display-b",
            profileDirectory: nil,
            isFullscreen: false,
            frontIndex: 0
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { focusedWindow },
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
                    DisplayInfo(
                        id: "display-b",
                        width: 2560,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: false,
                        frame: CGRect(x: 1600, y: 0, width: 1280, height: 1000),
                        visibleFrame: CGRect(x: 1600, y: 0, width: 1280, height: 1000)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
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
                    SpaceInfo(spaceID: 8, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    WindowSnapshot(
                        windowID: 800,
                        bundleID: "com.apple.TextEdit",
                        pid: 800,
                        title: "Editor",
                        role: "AXWindow",
                        subrole: nil,
                        minimized: false,
                        hidden: false,
                        frame: ResolvedFrame(x: 1600, y: 0, width: 640, height: 480),
                        spaceID: 8,
                        displayID: "display-b",
                        profileDirectory: nil,
                        isFullscreen: false,
                        frontIndex: 1
                    ),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(positionCalls.allSatisfy { $0.0 != 800 })
        XCTAssertTrue(frameCalls.allSatisfy { $0.0 != 800 })
    }

    func testSpaceSwitchContinuesShowingTargetWindowWhenRestoreFromMinimizedFails() throws {
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 23, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1600, y: 23, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0) },
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
            setWindowMinimized: { windowID, _, minimized in
                if windowID == 801, minimized == false {
                    return .failed
                }
                return .success
            },
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
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1, minimized: false),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 801 && $0.1 == ResolvedFrame(x: 800, y: 0, width: 800, height: 977) }))
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchPrefersLayoutFrameWhenPersistedVisibleFrameIsOffscreen() throws {
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 5119, y: 25, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 5119, y: 25, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0) },
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
                return true
            },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 801 && $0.1 == ResolvedFrame(x: 800, y: 0, width: 800, height: 977) }))
        XCTAssertFalse(frameCalls.contains(where: { $0.0 == 801 && $0.1.x == 5119 }))
    }

    func testSpaceSwitchReturnsMissingPermissionBeforeLiveMutation() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-permission.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { false },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.missingPermission.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceSwitchPermissionDenied")

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "space.switch.permissionDenied")
        XCTAssertEqual(event.rootCauseCategory, "permissionDenied")
        XCTAssertEqual(event.permissionScope, "accessibility")
        XCTAssertEqual(event.attemptedTargetSpaceID, 2)
    }

    func testSpaceSwitchSucceedsWithUnresolvedTargetSlots() throws {
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
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Unresolved target slots are non-fatal: the switch succeeds
        // and activeVirtualSpaceID is updated.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertTrue(payload.didChangeSpace)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchRollsBackWhenFocusFails() throws {
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        var minimizedCalls: [(UInt32, Bool)] = []
        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .failed },
            setWindowMinimized: { windowID, _, minimized in
                minimizedCalls.append((windowID, minimized))
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertTrue(minimizedCalls.isEmpty)
        XCTAssertEqual(frameCalls.map(\.0), [801])
        XCTAssertEqual(positionCalls.map(\.0), [800])

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertNil(persisted.pendingSwitchTransaction)
        XCTAssertEqual(persisted.revision, 8)
    }

    func testSpaceSwitchRecordsFailedDiagnosticEventWhenFocusFailsAndRollbackSucceeds() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-switch-failed.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .failed },
            setWindowMinimized: { _, _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(diagnosticEventStore.recent(limit: 1).isEmpty)
    }

    func testSpaceSwitchRecordsRollbackFailedDiagnosticEventWhenRollbackFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-rollback-failed.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        var minimizedCallCount = 0
        var frameCallCount = 0
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .failed },
            setWindowMinimized: { _, _, _ in
                minimizedCallCount += 1
                return .success
            },
            setWindowFrame: { _, _, _ in
                frameCallCount += 1
                return frameCallCount != 3
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertNil(persisted.pendingSwitchTransaction)
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertTrue(diagnosticEventStore.recent(limit: 1).isEmpty)
    }

    func testSpaceSwitchClassifiesLivePermissionDeniedAsSwitchFailedWhenRollbackSucceeds() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-live-permission-denied.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .permissionDenied },
            setWindowMinimized: { _, _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(diagnosticEventStore.recent(limit: 1).isEmpty)
    }

    func testSpaceSwitchClassifiesLivePermissionDeniedAsRollbackFailedWhenRollbackFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-live-permission-rollback.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        var minimizeCallCount = 0
        var frameCallCount = 0
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .permissionDenied },
            setWindowMinimized: { _, _, _ in
                minimizeCallCount += 1
                return .success
            },
            setWindowFrame: { _, _, _ in
                frameCallCount += 1
                return frameCallCount != 3
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(diagnosticEventStore.recent(limit: 1).isEmpty)
    }

    func testSpaceSwitchSucceedsEvenWhenShowFrameApplyFails() throws {
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        // setWindowFrame always fails — but the switch should still succeed
        // because best-effort does not abort on individual window failures.
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in false },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertTrue(payload.didChangeSpace)

        let savedState = stateStore.load()
        XCTAssertEqual(savedState.activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchPersistsPendingVisibilityConvergenceWithoutRetryingDuringSwitch() throws {
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 4
        )

        var liveWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
            WindowSnapshot(
                windowID: 801, bundleID: "com.apple.Notes", pid: 200,
                title: "Notes", role: "AXWindow", subrole: nil,
                minimized: false, hidden: false,
                frame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                spaceID: 7, displayID: "display-a", isFullscreen: false, frontIndex: 0
            ),
        ]
        var setWindowFrameAttempts = 0
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                if windowID == 801 {
                    setWindowFrameAttempts += 1
                    if setWindowFrameAttempts == 1 {
                        return false
                    }
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { windowID, _, position in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.action, "switch")
        XCTAssertTrue(payload.didChangeSpace)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
        XCTAssertNotNil(persisted.pendingVisibilityConvergence)
        XCTAssertEqual(persisted.slots.first(where: { $0.windowID == 801 })?.visibilityState, .hiddenOffscreen)
        XCTAssertEqual(setWindowFrameAttempts, 1)
    }

    func testSpaceSwitchSameWorkspaceReconcilesWhenPendingVisibilityConvergenceExists() throws {
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
        )

        var liveWindows = [
            WindowSnapshot(
                windowID: 800, bundleID: "com.apple.TextEdit", pid: 100,
                title: "Editor", role: "AXWindow", subrole: nil,
                minimized: false, hidden: false,
                frame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                spaceID: 7, displayID: "display-a", isFullscreen: false, frontIndex: 0
            ),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
        ]
        var shouldAllowTargetShow = false
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                if windowID == 800, !shouldAllowTargetShow {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { windowID, _, position in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let firstResult = service.spaceSwitch(spaceID: 1, json: true)
        XCTAssertEqual(firstResult.exitCode, 0)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 1)
        XCTAssertNotNil(stateStore.load().pendingVisibilityConvergence)

        shouldAllowTargetShow = true

        let secondResult = service.spaceSwitch(spaceID: 1, json: true)
        XCTAssertEqual(secondResult.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: secondResult.stdout)
        XCTAssertEqual(payload.action, "reconcile")
        XCTAssertFalse(payload.didChangeSpace)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertNil(persisted.pendingVisibilityConvergence)
        XCTAssertEqual(persisted.slots.first(where: { $0.windowID == 800 })?.visibilityState, .visible)
    }

    func testReconcilePendingVirtualVisibilityIfNeededRestoresPendingHiddenWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        try stateStore.saveStrict(
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
        var liveWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            WindowSnapshot(
                windowID: 801,
                bundleID: "com.apple.Notes",
                pid: 222,
                title: "Notes",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 1599, y: 0, width: 800, height: 977),
                spaceID: 7,
                displayID: "display-a",
                profileDirectory: nil,
                isFullscreen: false,
                frontIndex: 1
            ),
        ]
        var shouldAllowTargetShow = false
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                if windowID == 800, !shouldAllowTargetShow {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { windowID, _, position in
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let firstResult = service.spaceSwitch(spaceID: 1, json: true)
        XCTAssertEqual(firstResult.exitCode, 0)
        XCTAssertNotNil(stateStore.load().pendingVisibilityConvergence)

        shouldAllowTargetShow = true

        XCTAssertTrue(service.reconcilePendingVirtualVisibilityIfNeeded())

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertNil(persisted.pendingVisibilityConvergence)
        XCTAssertEqual(persisted.slots.first(where: { $0.windowID == 800 })?.visibilityState, .visible)
    }

    func testSpaceSwitchPreservesLastVisibleFrameWhenShowFails() throws {
        // Scenario: An adopted window (slot >= 100, no layout frame) was
        // hidden offscreen.  Switching back to its workspace tries to show
        // it, but setWindowFrame fails.  The entry must keep its original
        // lastVisibleFrame and visibilityState so that the next hide does
        // not overwrite lastVisibleFrame with the offscreen coordinates.
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let originalVisibleFrame = ResolvedFrame(x: 200, y: 100, width: 600, height: 400)
        let offscreenFrame = ResolvedFrame(x: 5119, y: 100, width: 600, height: 400)
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
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                // Adopted entry in workspace 1, currently hidden offscreen
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Finder",
                    definitionFingerprint: "runtime-finder",
                    lastKnownTitle: "Desktop",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 900,
                    lastVisibleFrame: originalVisibleFrame,
                    lastHiddenFrame: offscreenFrame,
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in false }, // Show always fails
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    // Finder is still at offscreen position
                    WindowSnapshot(
                        windowID: 900, bundleID: "com.apple.Finder", pid: 200,
                        title: "Desktop", role: "AXWindow", subrole: nil,
                        minimized: false, hidden: false,
                        frame: offscreenFrame,
                        spaceID: 7, displayID: "display-a", isFullscreen: false, frontIndex: 1
                    ),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Switch to workspace 1 — Finder show will fail
        let result = service.spaceSwitch(spaceID: 1, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        let finderEntry = persisted.slots.first(where: { $0.windowID == 900 })

        // Critical: lastVisibleFrame must NOT be corrupted to the offscreen
        // coordinates.  It should still hold the original visible frame.
        XCTAssertEqual(finderEntry?.lastVisibleFrame, originalVisibleFrame,
                       "lastVisibleFrame must be preserved when show fails")
        // visibilityState should remain .hiddenOffscreen since the show failed
        XCTAssertEqual(finderEntry?.visibilityState, .hiddenOffscreen,
                       "visibilityState must stay .hiddenOffscreen when show fails")
    }

    func testSpaceSwitchPreservesLastVisibleFrameWhenHidingAlreadyHiddenWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let visibleFrame = ResolvedFrame(x: 0, y: 25, width: 800, height: 600)
        let offscreenFrame = ResolvedFrame(x: 5119, y: 25, width: 800, height: 600)
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
                    lastVisibleFrame: visibleFrame,
                    lastHiddenFrame: offscreenFrame,
                    visibilityState: .hiddenOffscreen
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
            activeVirtualSpaceID: 2,
            revision: 5
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
            focusWindow: { _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    // TextEdit is offscreen (already hidden by previous switch)
                    WindowSnapshot(
                        windowID: 800,
                        bundleID: "com.apple.TextEdit",
                        pid: 800,
                        title: "Editor",
                        role: "AXWindow",
                        subrole: nil,
                        minimized: false,
                        hidden: false,
                        frame: offscreenFrame,
                        spaceID: 7,
                        displayID: "display-a",
                        isFullscreen: false,
                        frontIndex: 1
                    ),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Switch to space 3 — TextEdit (space 1) is already hidden.
        // Its lastVisibleFrame should NOT be overwritten with the offscreen frame.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let savedState = stateStore.load()
        let textEditSlot = savedState.slots.first(where: { $0.bundleID == "com.apple.TextEdit" })
        XCTAssertNotNil(textEditSlot)
        XCTAssertEqual(textEditSlot?.lastVisibleFrame, visibleFrame)
        XCTAssertEqual(textEditSlot?.visibilityState, .hiddenOffscreen)
    }

    func testSpaceSwitchReturnsSwitchFailedWhenPendingClearSaveFailsBeforeMutation() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-pending-clear-write-failed.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            activeVirtualSpaceID: 1,
            revision: 7
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in
                try? FileManager.default.removeItem(at: workspace.stateFileURL)
                try? FileManager.default.createDirectory(at: workspace.stateFileURL, withIntermediateDirectories: false)
                return .failed
            },
            setWindowMinimized: { _, _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1, minimized: true),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 52)

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceSwitchFailed")

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.event, "space.switch.failed")
        XCTAssertEqual(event.rootCauseCategory, "runtimeStateReadFailed")
        XCTAssertEqual(event.failedOperation, "finalizeStateSave")
        XCTAssertTrue(event.manualRecoveryRequired ?? false)
    }

    func testSpaceSwitchReturnsSwitchFailedWhenRollbackInFlightSaveFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 8
        )

        let stateStore = RuntimeStateStore(
            fileManager: FailingCreateDirectoryCallFileManager(failingCallIndexes: [1]),
            stateFileURL: workspace.stateFileURL
        )
        let diagnosticEventStore = DiagnosticEventStore(
            fileURL: workspace.root.appendingPathComponent("diagnostic-events-rollback-state-save-fail.jsonl")
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in false },
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
            focusWindow: { _, _ in .failed },
            setWindowMinimized: { _, _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 52)

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceSwitchFailed")
        XCTAssertEqual(payload.recoveryContext?.attemptedTargetSpaceID, 2)
        XCTAssertNil(payload.recoveryContext?.previousActiveSpaceID)
        XCTAssertNil(payload.recoveryContext?.manualRecoveryRequired)

        let persisted = RuntimeStateStore(stateFileURL: workspace.stateFileURL).load()
        XCTAssertNil(persisted.pendingSwitchTransaction)

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.event, "space.switch.failed")
        XCTAssertEqual(event.rootCauseCategory, "runtimeStateWriteFailed")
        XCTAssertEqual(event.failedOperation, "finalizeStateSave")
        XCTAssertTrue(event.manualRecoveryRequired ?? false)
    }

    func testSpaceSwitchReturnsSwitchFailedAndRecordsDiagnosticEventWhenFinalizeSaveBecomesStale() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let replacementState = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 9,
            stateMode: .virtual,
            configGeneration: "generation-2",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: nil,
            slots: []
        )
        let stateStore = RuntimeStateStore(
            fileManager: MutatingCreateDirectoryFileManager(
                stateFileURL: workspace.stateFileURL,
                replacementState: replacementState,
                mutationCallIndex: 1
            ),
            stateFileURL: workspace.stateFileURL
        )
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-finalize-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
            focusWindow: { _, _ in .success },
            setWindowMinimized: { _, _, _ in .success },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 52)

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceSwitchFailed")

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.requestID, payload.requestID)
        XCTAssertEqual(event.event, "space.switch.failed")
        XCTAssertEqual(event.code, ErrorCode.virtualSpaceSwitchFailed.rawValue)
        XCTAssertEqual(event.subcode, "virtualSpaceSwitchFailed")
        XCTAssertEqual(event.rootCauseCategory, "staleStateWriteRejected")
        XCTAssertEqual(event.failedOperation, "finalizeStateSave")
        XCTAssertEqual(event.attemptedTargetSpaceID, 2)
        XCTAssertTrue(event.manualRecoveryRequired ?? false)
    }

    func testSpaceSwitchFallsBackToPrimaryDisplayWhenHostDisplayIsAmbiguous() throws {
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
            },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 3, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // When host display is ambiguous, falls back to primary display
        // and the switch succeeds.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchReturnsVirtualStateUnavailableBeforeNotFoundWhenPendingRecoveryLeavesNoActiveState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
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
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceSwitch(spaceID: 99, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
        XCTAssertNil(payload.recoveryContext?.attemptedTargetSpaceID)
    }

    func testSpaceSwitchReturnsVirtualStateUnavailableBeforeNotFoundWhenPendingSwitchLeavesNoActiveState() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
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
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceSwitch(spaceID: 99, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
        XCTAssertNil(payload.recoveryContext?.attemptedTargetSpaceID)
    }

    func testSpaceSwitchReturnsNotFoundBeforeHostDisplayUnavailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
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
            },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 3, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 99, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceNotFound")
    }

    func testSpaceSwitchFallsBackToPrimaryDisplayWhenUnresolvedSlotsAndAmbiguousDisplay() throws {
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
            },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 3, displayID: "display-b", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Ambiguous display + unresolved slots: both are non-fatal, switch succeeds.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchSucceedsWithExplicitDisplayAndNoVisibleNativeSpace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualExplicitDisplayConfigYAML])
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
            spaces: { [] },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Display is resolved from layout definition; no visible native space
        // check is required.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchSucceedsWithExplicitDisplayAndMultipleVisibleNativeSpaces() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualExplicitDisplayConfigYAML])
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
                    SpaceInfo(spaceID: 8, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Multiple visible native spaces on same display: no longer a blocker.
        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(stateStore.load().activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchReturnsUnsupportedInNativeMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "spaceSwitchUnsupportedInNativeMode")
    }

    func testSpaceSwitchReturnsVirtualStateUnavailableWhenActiveStateMissing() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [], stateMode: .virtual, configGeneration: "generation-1")
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceSwitch(spaceID: 2, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateUnavailable")
    }

    func testSpaceRecoverReturnsUnsupportedInNativeMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.subcode, "spaceRecoveryUnsupportedInNativeMode")
        XCTAssertFalse(payload.requestID.isEmpty)
    }

    func testSpaceRecoverRequiresConfirmation() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceRecover(forceClearPending: true, confirmed: false, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.subcode, "dangerousOperationRequiresConfirmation")
        XCTAssertEqual(payload.recoveryContext?.attemptedTargetSpaceID, 2)
    }

    func testSpaceRecoverReturnsNotRequiredWhenPendingTransactionIsMissing() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.subcode, "virtualStateRecoveryNotRequired")
        XCTAssertFalse(payload.requestID.isEmpty)
    }

    func testSpaceRecoverForceClearsEligiblePendingState() throws {
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
            activeVirtualSpaceID: 2,
            revision: 8,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceRecoveryJSON.self, from: result.stdout)
        XCTAssertTrue(payload.clearedPending)
        XCTAssertEqual(payload.previousActiveLayoutName, "work")
        XCTAssertEqual(payload.previousActiveSpaceID, 2)
        XCTAssertEqual(payload.nextActionKind, "discoverAndReconcile")
        XCTAssertEqual(payload.discoveryCommand, "shitsurae arrange <layout> --dry-run --json")
        XCTAssertEqual(payload.reconcileCommandTemplate, "shitsurae arrange <layout> --space <id>")

        let persisted = stateStore.load()
        XCTAssertNil(persisted.activeLayoutName)
        XCTAssertNil(persisted.activeVirtualSpaceID)
        XCTAssertNil(persisted.pendingSwitchTransaction)
        XCTAssertTrue(persisted.slots.isEmpty)
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.configGeneration.count, 64)
    }

    func testSpaceRecoverRejectsForceClearWhenRecoveryIsStillAvailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
            )
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.subcode, "virtualStateRecoveryForceClearNotAllowedWhileLiveRecoveryAvailable")
        XCTAssertEqual(payload.recoveryContext?.recoveryForceClearEligible, false)
    }

    func testSpaceRecoverAllowsForceClearForLegacyInFlightPendingWhenManualRecoveryIsRequired() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-inflight",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .inFlight,
                manualRecoveryRequired: true
            )
        )
        let service = workspace.makeService(stateStore: stateStore)

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, 0)

        let payload = try decode(SpaceRecoveryJSON.self, from: result.stdout)
        XCTAssertTrue(payload.clearedPending)

        let persisted = stateStore.load()
        XCTAssertNil(persisted.pendingSwitchTransaction)
        XCTAssertTrue(persisted.liveArrangeRecoveryRequired)
        XCTAssertNil(persisted.activeLayoutName)
        XCTAssertNil(persisted.activeVirtualSpaceID)
    }

    func testSpaceRecoverForceClearRequiresSubsequentLiveArrangeBeforeStateOnlyBootstrap() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let service = workspace.makeService(stateStore: stateStore)

        let recover = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(recover.exitCode, 0)
        XCTAssertTrue(stateStore.load().liveArrangeRecoveryRequired)

        let blockedStateOnly = service.arrange(
            layoutName: "work",
            spaceID: 1,
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: true
        )
        XCTAssertEqual(blockedStateOnly.exitCode, Int32(ErrorCode.validationError.rawValue))
        let blockedPayload = try decode(ArrangeExecutionJSON.self, from: blockedStateOnly.stdout)
        XCTAssertEqual(blockedPayload.subcode, "virtualStateRecoveryRequiresLiveArrange")

        let liveArrangeService = workspace.makeService(
            stateStore: stateStore,
            arrangeDriver: VirtualSuccessfulArrangeDriver()
        )
        let liveArrange = liveArrangeService.arrange(
            layoutName: "work",
            spaceID: 1,
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: false
        )
        XCTAssertEqual(liveArrange.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertFalse(persisted.liveArrangeRecoveryRequired)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
    }

    func testSpaceRecoverReturnsStateWriteFailedAndRecordsDiagnosticEventWhenForceClearSaveFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateURL = workspace.root.appendingPathComponent("runtime-state.json")
        try RuntimeStateStore(stateFileURL: stateURL).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 8,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )
        let stateStore = RuntimeStateStore(
            fileManager: AlwaysFailingCreateDirectoryFileManager(),
            stateFileURL: stateURL
        )

        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore
        )

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "spaceRecoveryStateWriteFailed")
        XCTAssertEqual(payload.recoveryContext?.manualRecoveryRequired, true)

        let events = diagnosticEventStore.recent(limit: 10)
        XCTAssertEqual(events.first?.event, "space.recovery.forceClearWriteFailed")
        XCTAssertEqual(events.first?.subcode, "spaceRecoveryStateWriteFailed")
        XCTAssertEqual(events.first?.manualRecoveryRequired, true)
    }

    func testSpaceSwitchReturnsBusyWithLockOwnerMetadataWhenStateMutationLockTimesOut() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )

        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        let primaryLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let contenderLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let diagnosticEventStore = DiagnosticEventStore(
            fileURL: workspace.root.appendingPathComponent("diagnostic-events-lock-switch.jsonl")
        )

        let owner = VirtualSpaceLockOwnerMetadata(
            pid: 4321,
            processKind: "app",
            startedAt: "2026-03-13T10:00:00Z",
            requestID: "owner-lock-1"
        )
        let group = DispatchGroup()
        group.enter()
        let releaseSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try primaryLock.withLock(owner: owner, timeoutMS: 100, pollIntervalMS: 1) {
                    group.leave()
                    _ = releaseSemaphore.wait(timeout: .now() + 5)
                }
            } catch {
                XCTFail("unexpected primary lock error: \(error)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            stateMutationLock: contenderLock,
            stateMutationLockTimeoutMS: 10,
            stateMutationLockPollIntervalMS: 1
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        releaseSemaphore.signal()

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateBusy")
        XCTAssertEqual(payload.recoveryContext?.attemptedTargetSpaceID, 2)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerPID, owner.pid)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerProcessKind, owner.processKind)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerStartedAt, owner.startedAt)
        XCTAssertEqual(payload.recoveryContext?.lockWaitTimeoutMS, 10)

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "space.switch.busy")
        XCTAssertEqual(event.subcode, "virtualStateBusy")
        XCTAssertEqual(event.lockOwnerPID, owner.pid)
        XCTAssertEqual(event.lockOwnerProcessKind, owner.processKind)
        XCTAssertEqual(event.lockOwnerStartedAt, owner.startedAt)
        XCTAssertEqual(event.lockWaitTimeoutMS, 10)
    }

    func testSpaceRecoverReturnsBusyWithLockOwnerMetadataWhenStateMutationLockTimesOut() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )

        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        let primaryLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let contenderLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let owner = VirtualSpaceLockOwnerMetadata(
            pid: 4322,
            processKind: "app",
            startedAt: "2026-03-13T10:05:00Z",
            requestID: "owner-lock-2"
        )
        let group = DispatchGroup()
        group.enter()
        let releaseSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try primaryLock.withLock(owner: owner, timeoutMS: 100, pollIntervalMS: 1) {
                    group.leave()
                    _ = releaseSemaphore.wait(timeout: .now() + 5)
                }
            } catch {
                XCTFail("unexpected primary lock error: \(error)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let service = workspace.makeService(
            stateStore: stateStore,
            stateMutationLock: contenderLock,
            stateMutationLockTimeoutMS: 10,
            stateMutationLockPollIntervalMS: 1
        )

        let result = service.spaceRecover(forceClearPending: true, confirmed: true, json: true)
        releaseSemaphore.signal()

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualStateBusy")
        XCTAssertEqual(payload.recoveryContext?.attemptedTargetSpaceID, 2)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerPID, owner.pid)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerProcessKind, owner.processKind)
        XCTAssertEqual(payload.recoveryContext?.lockOwnerStartedAt, owner.startedAt)
        XCTAssertEqual(payload.recoveryContext?.lockWaitTimeoutMS, 10)
    }

    func testArrangeReturnsBusyWhenStateMutationLockTimesOutInVirtualMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        let primaryLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let contenderLock = VirtualSpaceStateMutationLock(fileURL: lockURL, sleepHook: { _ in })
        let diagnosticEventStore = DiagnosticEventStore(
            fileURL: workspace.root.appendingPathComponent("diagnostic-events-lock-arrange.jsonl")
        )

        let owner = VirtualSpaceLockOwnerMetadata(
            pid: 4323,
            processKind: "shortcut",
            startedAt: "2026-03-13T10:10:00Z",
            requestID: "owner-lock-3"
        )
        let group = DispatchGroup()
        group.enter()
        let releaseSemaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try primaryLock.withLock(owner: owner, timeoutMS: 100, pollIntervalMS: 1) {
                    group.leave()
                    _ = releaseSemaphore.wait(timeout: .now() + 5)
                }
            } catch {
                XCTFail("unexpected primary lock error: \(error)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let service = workspace.makeService(
            diagnosticEventStore: diagnosticEventStore,
            stateMutationLock: contenderLock,
            stateMutationLockTimeoutMS: 10,
            stateMutationLockPollIntervalMS: 1
        )

        let result = service.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true)
        releaseSemaphore.signal()

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.subcode, "virtualStateBusy")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "arrange.busy")
        XCTAssertEqual(event.subcode, "virtualStateBusy")
        XCTAssertEqual(event.lockOwnerPID, owner.pid)
        XCTAssertEqual(event.lockOwnerProcessKind, owner.processKind)
        XCTAssertEqual(event.lockOwnerStartedAt, owner.startedAt)
        XCTAssertEqual(event.lockWaitTimeoutMS, 10)
    }

    func testSpaceSwitchSerializesConcurrentSameProcessMutationsViaStateMutationLock() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let blockingFileManager = BlockingCreateDirectoryFileManager()
        let stateStoreA = RuntimeStateStore(
            fileManager: blockingFileManager,
            stateFileURL: workspace.stateFileURL
        )
        let stateStoreB = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        let runtimeHooks = virtualSwitchSuccessRuntimeHooks()

        let serviceA = UnsafeSendableBox(value: workspace.makeService(
            stateStore: stateStoreA,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL),
            runtimeHooks: runtimeHooks
        ))
        let serviceB = UnsafeSendableBox(value: workspace.makeService(
            stateStore: stateStoreB,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL),
            runtimeHooks: runtimeHooks
        ))

        let firstSaveStarted = expectation(description: "first switch entered pending save")
        let secondFinished = expectation(description: "second switch finished")
        secondFinished.isInverted = true
        blockingFileManager.onBlockedCreateDirectory = {
            firstSaveStarted.fulfill()
        }

        let firstResult = LockedValueBox<CommandResult?>(nil)
        let secondResult = LockedValueBox<CommandResult?>(nil)
        let completionGroup = DispatchGroup()

        completionGroup.enter()
        DispatchQueue.global().async {
            firstResult.set(serviceA.value.spaceSwitch(spaceID: 2, json: true, reconcile: false))
            completionGroup.leave()
        }

        wait(for: [firstSaveStarted], timeout: 5.0)

        completionGroup.enter()
        DispatchQueue.global().async {
            secondResult.set(serviceB.value.spaceSwitch(spaceID: 2, json: true, reconcile: false))
            secondFinished.fulfill()
            completionGroup.leave()
        }

        wait(for: [secondFinished], timeout: 0.2)

        blockingFileManager.releaseBlockedCreateDirectory()
        XCTAssertEqual(completionGroup.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(firstResult.get()?.exitCode, 0)
        let second = try XCTUnwrap(secondResult.get())
        XCTAssertEqual(second.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: second.stdout)
        XCTAssertEqual(payload.action, "reconcile")
        XCTAssertFalse(payload.didChangeSpace)
        XCTAssertEqual(payload.space.spaceID, 2)
    }

    func testSpaceRecoverSerializesConcurrentSameProcessMutationsViaStateMutationLock() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 8,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-1",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired,
                manualRecoveryRequired: true
            )
        )

        let blockingFileManager = BlockingCreateDirectoryFileManager()
        let stateStoreA = RuntimeStateStore(
            fileManager: blockingFileManager,
            stateFileURL: workspace.stateFileURL
        )
        let stateStoreB = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")

        let serviceA = UnsafeSendableBox(value: workspace.makeService(
            stateStore: stateStoreA,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL)
        ))
        let serviceB = UnsafeSendableBox(value: workspace.makeService(
            stateStore: stateStoreB,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL)
        ))

        let firstSaveStarted = expectation(description: "first recover entered clear save")
        let secondFinished = expectation(description: "second recover finished")
        secondFinished.isInverted = true
        blockingFileManager.onBlockedCreateDirectory = {
            firstSaveStarted.fulfill()
        }

        let firstResult = LockedValueBox<CommandResult?>(nil)
        let secondResult = LockedValueBox<CommandResult?>(nil)
        let completionGroup = DispatchGroup()

        completionGroup.enter()
        DispatchQueue.global().async {
            firstResult.set(serviceA.value.spaceRecover(forceClearPending: true, confirmed: true, json: true))
            completionGroup.leave()
        }

        wait(for: [firstSaveStarted], timeout: 5.0)

        completionGroup.enter()
        DispatchQueue.global().async {
            secondResult.set(serviceB.value.spaceRecover(forceClearPending: true, confirmed: true, json: true))
            secondFinished.fulfill()
            completionGroup.leave()
        }

        wait(for: [secondFinished], timeout: 0.2)

        blockingFileManager.releaseBlockedCreateDirectory()
        XCTAssertEqual(completionGroup.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(firstResult.get()?.exitCode, 0)
        let second = try XCTUnwrap(secondResult.get())
        XCTAssertEqual(second.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: second.stdout)
        XCTAssertEqual(payload.subcode, "spaceRecoveryStateWriteFailed")
    }

    func testArrangeWaitsForCrossProcessStyleFileLockAndThenSucceeds() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        let driver = SerializingVirtualArrangeDriver()
        driver.releaseFirstQuery()
        let service = UnsafeSendableBox(value: workspace.makeService(
            arrangeDriver: driver,
            arrangeRequestDeduplicator: NeverSuppressArrangeDeduplicator(),
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL)
        ))
        let resultBox = LockedValueBox<CommandResult?>(nil)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            resultBox.set(service.value.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true))
            completion.leave()
        }

        usleep(200_000)
        XCTAssertNil(resultBox.get())

        _ = flock(fd, LOCK_UN)
        close(fd)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resultBox.get()?.exitCode, 0)
    }

    func testSpaceSwitchWaitsForCrossProcessStyleFileLockAndThenSucceeds() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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

        let service = UnsafeSendableBox(value: workspace.makeService(
            stateStore: RuntimeStateStore(stateFileURL: workspace.stateFileURL),
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL),
            runtimeHooks: virtualSwitchSuccessRuntimeHooks()
        ))
        let resultBox = LockedValueBox<CommandResult?>(nil)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            resultBox.set(service.value.spaceSwitch(spaceID: 2, json: true, reconcile: false))
            completion.leave()
        }

        usleep(200_000)
        XCTAssertNil(resultBox.get())

        _ = flock(fd, LOCK_UN)
        close(fd)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(resultBox.get()?.exitCode, 0)
    }

    func testSpaceSwitchReloadsStateAfterLockWaitAndSkipsStaleWindowMutations() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        try stateStore.saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 7
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

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        var minimizeCalls: [(UInt32, Bool)] = []
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
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
            resultBox.set(service.value.spaceSwitch(spaceID: 2, json: true, reconcile: false))
            completion.leave()
        }

        usleep(200_000)
        XCTAssertNil(resultBox.get())

        let rewrittenState = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 8,
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: nil,
            slots: try stateStore.loadStrict().slots
        )
        try stateStore.saveStrict(
            state: rewrittenState,
            expecting: RuntimeStateWriteExpectation(
                revision: 7,
                configGeneration: "generation-1"
            )
        )

        _ = flock(fd, LOCK_UN)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        let result = try XCTUnwrap(resultBox.get())
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.action, "noop")
        XCTAssertFalse(payload.didChangeSpace)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertTrue(frameCalls.isEmpty)
        XCTAssertTrue(positionCalls.isEmpty)
        XCTAssertTrue(minimizeCalls.isEmpty)
    }

    func testSpaceSwitchReloadsStateAfterCrossProcessStyleAtomicStateRewrite() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        try stateStore.saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 7
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

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        var minimizeCalls: [(UInt32, Bool)] = []
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = UnsafeSendableBox(value: workspace.makeService(
            stateStore: RuntimeStateStore(stateFileURL: workspace.stateFileURL),
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL),
            runtimeHooks: runtimeHooks
        ))
        let resultBox = LockedValueBox<CommandResult?>(nil)
        let completion = DispatchGroup()
        completion.enter()
        DispatchQueue.global().async {
            resultBox.set(service.value.spaceSwitch(spaceID: 2, json: true, reconcile: false))
            completion.leave()
        }

        usleep(200_000)
        XCTAssertNil(resultBox.get())

        let rewrittenState = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 8,
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            pendingSwitchTransaction: nil,
            slots: try stateStore.loadStrict().slots
        )
        try stateStore.saveStrict(
            state: rewrittenState,
            expecting: RuntimeStateWriteExpectation(
                revision: 7,
                configGeneration: "generation-1"
            )
        )

        _ = flock(fd, LOCK_UN)

        XCTAssertEqual(completion.wait(timeout: .now() + 5), .success)
        let result = try XCTUnwrap(resultBox.get())
        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(SpaceSwitchJSON.self, from: result.stdout)
        XCTAssertEqual(payload.action, "noop")
        XCTAssertFalse(payload.didChangeSpace)
        XCTAssertEqual(payload.space.spaceID, 2)
        XCTAssertTrue(frameCalls.isEmpty)
        XCTAssertTrue(positionCalls.isEmpty)
        XCTAssertTrue(minimizeCalls.isEmpty)

        let persisted = try stateStore.loadStrict()
        XCTAssertEqual(persisted.revision, 8)
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
    }

    func testSpaceSwitchReturnsRuntimeStateCorruptedWhenStateFileIsInvalidJSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try "{ broken".write(to: workspace.stateFileURL, atomically: true, encoding: .utf8)
        let service = workspace.makeService(stateStore: RuntimeStateStore(stateFileURL: workspace.stateFileURL))

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "runtimeStateCorrupted")
    }

    func testArrangeStateOnlyReinitializesAfterRuntimeStateCorrupted() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try "{ broken".write(to: workspace.stateFileURL, atomically: true, encoding: .utf8)
        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let service = workspace.makeService(stateStore: stateStore)

        let failed = service.spaceCurrent(json: true)
        XCTAssertEqual(failed.exitCode, Int32(ErrorCode.validationError.rawValue))
        let failedPayload = try decode(CommonErrorJSON.self, from: failed.stdout)
        XCTAssertEqual(failedPayload.subcode, "runtimeStateCorrupted")

        let stateDirectory = workspace.stateFileURL.deletingLastPathComponent()
        let backupFiles = try FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("runtime-state.corrupt-") }
        XCTAssertEqual(backupFiles.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.stateFileURL.path))

        let arrange = service.arrange(
            layoutName: "work",
            spaceID: 1,
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: true
        )
        XCTAssertEqual(arrange.exitCode, 0)
        let arrangePayload = try decode(ArrangeExecutionJSON.self, from: arrange.stdout)
        XCTAssertEqual(arrangePayload.result, "success")

        let persisted = try stateStore.loadStrict()
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.configGeneration, try workspace.currentConfigGeneration())
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertEqual(persisted.slots.first?.layoutName, "work")
        XCTAssertEqual(persisted.slots.first?.definitionFingerprint.count, 64)
    }

    func testSpaceSwitchReturnsRuntimeStateReadPermissionDeniedWhenStateFileIsUnreadable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.stateFileURL.path)
            workspace.cleanup()
        }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: workspace.stateFileURL.path)
        let service = workspace.makeService(stateStore: RuntimeStateStore(stateFileURL: workspace.stateFileURL))

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "runtimeStateReadPermissionDenied")
    }

    func testSpaceSwitchSucceedsAfterRetryWhenRuntimeStateReadPermissionIsRestored() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.stateFileURL.path)
            workspace.cleanup()
        }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: workspace.stateFileURL.path)
        let service = workspace.makeService(stateStore: RuntimeStateStore(stateFileURL: workspace.stateFileURL))

        let initialResult = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(initialResult.exitCode, Int32(ErrorCode.validationError.rawValue))
        let initialPayload = try decode(CommonErrorJSON.self, from: initialResult.stdout)
        XCTAssertEqual(initialPayload.subcode, "runtimeStateReadPermissionDenied")

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: workspace.stateFileURL.path)

        let retriedResult = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(retriedResult.exitCode, 0)
        let retriedPayload = try decode(SpaceSwitchJSON.self, from: retriedResult.stdout)
        XCTAssertEqual(retriedPayload.action, "noop")
        XCTAssertFalse(retriedPayload.didChangeSpace)
        XCTAssertEqual(retriedPayload.space.spaceID, 2)
    }

    func testSpaceSwitchReturnsStaleStateWriteRejectedAndRecordsDiagnosticEvent() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        try RuntimeStateStore(stateFileURL: workspace.stateFileURL).saveStrict(
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
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let replacementState = RuntimeState(
            updatedAt: Date.rfc3339UTC(),
            revision: 9,
            stateMode: .virtual,
            configGeneration: "generation-2",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: nil,
            slots: []
        )
        let stateStore = RuntimeStateStore(
            fileManager: MutatingCreateDirectoryFileManager(
                stateFileURL: workspace.stateFileURL,
                replacementState: replacementState
            ),
            stateFileURL: workspace.stateFileURL
        )
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 0, minimized: true),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.virtualSpaceSwitchFailed.rawValue))

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.subcode, "virtualSpaceSwitchFailed")

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "space.switch.failed")
        XCTAssertEqual(event.subcode, "virtualSpaceSwitchFailed")
    }

    func testSpaceSwitchAdoptsUntrackedWindowsIntoCurrentWorkspace() throws {
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var positionCalls: [(UInt32, CGPoint)] = []
        var onScreenWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
            // Untracked window — should be adopted into workspace 1
            Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 2),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { onScreenWindows },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
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
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                guard let index = onScreenWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = onScreenWindows[index]
                onScreenWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { onScreenWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)

        // Finder should be adopted into workspace 1 (the previous active workspace)
        let finderEntry = persisted.slots.first(where: { $0.windowID == 900 })
        XCTAssertNotNil(finderEntry)
        XCTAssertEqual(finderEntry?.spaceID, 1)
        XCTAssertEqual(finderEntry?.bundleID, "com.apple.Finder")
        // Untracked windows get slot >= 100
        XCTAssertGreaterThanOrEqual(finderEntry?.slot ?? 0, CommandService.untrackedSlotOffset)

        // Finder should have been hidden (moved offscreen) because we switched away from workspace 1
        XCTAssertTrue(positionCalls.contains(where: { $0.0 == 900 }))
        XCTAssertEqual(finderEntry?.visibilityState, .hiddenOffscreen)
    }

    func testSpaceSwitchDoesNotAdoptMinimizedOrTinyWindows() throws {
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 2
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    // Minimized — should NOT be adopted
                    Self.window(windowID: 901, bundleID: "com.apple.Preview", title: "Image", spaceID: 7, frontIndex: 1, minimized: true),
                    // Tiny window (status bar) — should NOT be adopted
                    WindowSnapshot(
                        windowID: 902, bundleID: "com.apple.SystemUIServer", pid: 100,
                        title: "", role: "AXMenuBarItem", subrole: nil,
                        minimized: false, hidden: false,
                        frame: ResolvedFrame(x: 0, y: 0, width: 30, height: 22),
                        spaceID: 7, displayID: "display-a", isFullscreen: false, frontIndex: 2
                    ),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        // Only the tracked TextEdit should be in state; no minimized or tiny windows adopted
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 901 }))
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 902 }))
    }

    func testSpaceSwitchAdoptedWindowShowsWhenSwitchingBackToItsWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        // Finder was already adopted into workspace 1 with untracked slot
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 5000, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Finder",
                    definitionFingerprint: "runtime-finder",
                    lastKnownTitle: "Desktop",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 200, y: 100, width: 600, height: 400),
                    lastHiddenFrame: ResolvedFrame(x: 5000, y: 100, width: 600, height: 400),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var liveWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
            Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 2),
        ]
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
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        // Switch back to workspace 1 — both TextEdit and Finder should be shown
        let result = service.spaceSwitch(spaceID: 1, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)

        // TextEdit (slot 1) should have been shown via setWindowFrame
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 800 }))
        // Finder (slot 100, untracked) should also have been shown via setWindowFrame
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 900 }))

        XCTAssertEqual(persisted.slots.first(where: { $0.windowID == 900 })?.visibilityState, .visible)
    }

    func testSpaceSwitchDeduplicatesTargetAndOtherResolvingToSameWindow() throws {
        // Scenario: partial arrange left a config entry for Notes (workspace 2)
        // with windowID=nil.  Adoption then created a separate entry for the
        // same Notes window (windowID=801) in workspace 1.  Without dedup,
        // switching to workspace 2 would show Notes (target, matched by
        // bundleID) then hide it (other, matched by windowID).
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
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                // Config entry for Notes in workspace 2 — windowID is nil
                // (partial arrange didn't resolve it)
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: nil,
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: nil,
                    displayID: nil,
                    windowID: nil,
                    lastVisibleFrame: nil,
                    visibilityState: nil
                ),
                // Adopted entry for Notes in workspace 1 — has real windowID
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "runtime-notes",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 400, y: 0, width: 400, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                ]
            },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
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
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        // Notes (801) should have been shown via setWindowFrame (target)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 801 }), "Notes should be shown as target")
        // Notes (801) should NOT have been hidden via setWindowPosition (dedup
        // should have removed it from others)
        XCTAssertFalse(positionCalls.contains(where: { $0.0 == 801 }), "Notes should NOT be hidden — dedup should prevent it")

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
    }

    // MARK: - Adoption adopts new windows even when unresolved config entries exist
}
