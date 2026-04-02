import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceFocusContractTests: CommandServiceContractTestCase {
    func testFocusOutOfRangeReturnsValidationErrorToStderr() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let runtimeHooks = makeRuntimeHooks()
        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let result = service.focus(slot: 10)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "slot must be 1..9\n")
    }

    func testFocusTransitionAssignedSlotReturns0AndUnassignedReturns40() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    title: "Editor",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
            ]
        )

        let runtimeHooks = makeRuntimeHooks()

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        XCTAssertEqual(service.focus(slot: 1).exitCode, 0)
        XCTAssertEqual(service.focus(slot: 2).exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
    }

    func testFocusPrefersSlotEntryOnCurrentSpaceWhenSlotsOverlapAcrossSpaces() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.google.Chrome",
                    title: "Chrome",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.hnc.Discord",
                    title: "Discord",
                    spaceID: 2,
                    displayID: "display-a",
                    windowID: 202,
                ),
            ]
        )

        var focusedTargets: [(UInt32, String)] = []
        let focusedWindow = Self.window(windowID: 202, bundleID: "com.hnc.Discord", title: "Discord", spaceID: 2, frontIndex: 0)
        let runtimeHooks = makeRuntimeHooks(
            listWindows: { [focusedWindow] },
            focusedWindow: { focusedWindow },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.hnc.Discord"])
    }

    func testFocusPrefersVisibleCurrentSpaceWhenFocusedWindowIsUnavailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.google.Chrome",
                    title: "Chrome",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.hnc.Discord",
                    title: "Discord",
                    spaceID: 2,
                    displayID: "display-a",
                    windowID: 202,
                ),
            ]
        )

        let windows = [
            Self.window(windowID: 101, bundleID: "com.google.Chrome", title: "Chrome", spaceID: 1, frontIndex: 1),
            Self.window(windowID: 202, bundleID: "com.hnc.Discord", title: "Discord", spaceID: 2, frontIndex: 0),
        ]
        var focusedTargets: [(UInt32, String)] = []
        let runtimeHooks = makeRuntimeHooks(
            listWindows: { windows },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            },
            spaces: {
                [
                    SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: false, isNativeFullscreen: false),
                    SpaceInfo(spaceID: 2, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.hnc.Discord"])
    }

    func testFocusReturnsNotFoundWhenStateIsEmpty() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [])

        let runtimeHooks = makeRuntimeHooks()

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
    }

    func testFocusReturnsVirtualStateUnavailableWhenActiveVirtualStateIsMissing() throws {
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
            configGeneration: "generation-1"
        )

        let runtimeHooks = makeRuntimeHooks(
            listWindows: { [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)] },
            spaces: { [] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(result.stderr, "active virtual space is unavailable\n")
    }

    func testFocusReturnsVirtualStateUnavailableWhenStateGenerationIsStale() throws {
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
            configGeneration: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(result.stderr, "active virtual space is unavailable\n")
    }

    func testFocusReturnsVirtualStateUnavailableWhilePendingRecoveryLeavesNoActiveState() throws {
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
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(result.stderr, "active virtual space is unavailable\n")
    }

    func testFocusReturnsVirtualStateUnavailableWhilePendingSwitchLeavesNoActiveState() throws {
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
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(result.stderr, "active virtual space is unavailable\n")
    }

    func testFocusRecordsStaleGenerationDiagnosticEvent() throws {
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
        let diagnosticEventsURL = workspace.root.appendingPathComponent("diagnostic-events-focus-stale.jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
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
        let service = workspace.makeService(
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            runtimeHooks: runtimeHooks
        )

        let result = service.focus(slot: 1)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))

        let event = try XCTUnwrap(diagnosticEventStore.recent(limit: 1).first)
        XCTAssertEqual(event.event, "state.read.staleGeneration")
        XCTAssertEqual(event.subcode, "virtualStateUnavailable")
        XCTAssertEqual(event.rootCauseCategory, "staleStateRead")
        XCTAssertEqual(event.failedOperation, "focus.slot")
        XCTAssertEqual(event.activeLayoutName, "work")
        XCTAssertEqual(event.activeVirtualSpaceID, 1)
    }

    func testFocusSlotUsesTrackedWindowIDWhenAvailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    title: "Draft",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 202
                ),
            ]
        )

        let windows = [
            Self.window(windowID: 101, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 202, bundleID: "com.apple.TextEdit", title: "Draft", spaceID: 1, frontIndex: 1),
        ]
        var focusedTargets: [(UInt32, String)] = []
        var activatedBundleIDs: [String] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { bundleID in
                activatedBundleIDs.append(bundleID)
                return true
            },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.apple.TextEdit"])
        XCTAssertTrue(activatedBundleIDs.isEmpty)
    }

    func testShouldHandleFocusShortcutReturnsFalseWhenSlotStateIsEmpty() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(slots: [])

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
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testShouldHandleFocusShortcutReturnsTrueForTrackedNativeWindowOnCurrentSpace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    title: "Editor",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
            ]
        )

        let trackedWindow = Self.window(windowID: 101, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [trackedWindow] },
            focusedWindow: { trackedWindow },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: {
                [SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        XCTAssertTrue(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testShouldHandleFocusShortcutReturnsFalseForStaleSlotEntry() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    title: "Editor",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
            ]
        )

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
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testShouldHandleFocusShortcutReturnsFalseWhenActiveVirtualStateIsMissing() throws {
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
            configGeneration: "generation-1"
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testShouldHandleFocusShortcutReturnsFalseWhenVirtualRecoveryIsRequired() throws {
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
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testShouldHandleFocusShortcutReturnsFalseWhenVirtualSwitchIsBusy() throws {
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
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testFocusReturnsNotFoundWhenNativeConfigOnlyHasStaleVirtualSlotState() throws {
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
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
    }

    func testShouldHandleFocusShortcutReturnsFalseWhenNativeConfigOnlyHasStaleVirtualSlotState() throws {
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
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            spaces: { [] }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        XCTAssertFalse(service.shouldHandleFocusShortcut(slot: 1))
    }

    func testFocusSlotRespectsIgnoreFocusRule() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.ignoreFocusConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    title: "Editor",
                    spaceID: 1,
                    displayID: "display-a",
                    windowID: 101,
                ),
            ]
        )

        var activationCalls = 0
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [Self.window(windowID: 101, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)] },
            focusedWindow: { nil },
            activateBundle: { _ in
                activationCalls += 1
                return true
            },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: 1)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        XCTAssertEqual(activationCalls, 0)
    }

    func testFocusCanTargetWindowID() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            Self.window(windowID: 101, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 202, bundleID: "com.apple.TextEdit", title: "Draft", spaceID: 1, frontIndex: 1),
        ]
        var focusedTargets: [(UInt32, String)] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.focus(slot: nil, target: WindowTargetSelector(windowID: 202, bundleID: nil, title: nil))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.apple.TextEdit"])
    }

    func testFocusTargetWindowIDFallsBackToBundleActivationWhenTargetedFocusFails() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            Self.window(windowID: 202, bundleID: "org.alacritty", title: "Alacritty", spaceID: 1, frontIndex: 0),
        ]
        var focusedTargets: [(UInt32, String)] = []
        var activatedBundleIDs: [String] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { bundleID in
                activatedBundleIDs.append(bundleID)
                return true
            },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .failed
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.focus(slot: nil, target: WindowTargetSelector(windowID: 202, bundleID: nil, title: nil))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["org.alacritty"])
        XCTAssertEqual(activatedBundleIDs, ["org.alacritty"])
    }

    func testFocusTargetWindowIDRestoresHiddenOffscreenVirtualWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let offscreenFrame = ResolvedFrame(x: 5119, y: 0, width: 800, height: 977)
        let expectedVisibleFrame = ResolvedFrame(x: 800, y: 0, width: 800, height: 977)
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
                    lastVisibleFrame: expectedVisibleFrame,
                    lastHiddenFrame: offscreenFrame,
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 4
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var focusedTargets: [(UInt32, String)] = []
        var activatedBundleIDs: [String] = []
        let runtimeHooks = makeRuntimeHooks(
            listWindows: { [] },
            activateBundle: { bundleID in
                activatedBundleIDs.append(bundleID)
                return true
            },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 1),
                    WindowSnapshot(
                        windowID: 801,
                        bundleID: "com.apple.Notes",
                        pid: 801,
                        title: "Notes",
                        role: "AXWindow",
                        subrole: nil,
                        minimized: false,
                        hidden: false,
                        frame: offscreenFrame,
                        spaceID: 7,
                        displayID: "display-a",
                        isFullscreen: false,
                        frontIndex: 0
                    ),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: nil as Int?, target: WindowTargetSelector(windowID: 801, bundleID: nil, title: nil))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(frameCalls.count, 1)
        XCTAssertEqual(frameCalls.first?.0, 801)
        XCTAssertEqual(frameCalls.first?.1, expectedVisibleFrame)
        XCTAssertEqual(focusedTargets.map(\.0), [801])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.apple.Notes"])
        XCTAssertTrue(activatedBundleIDs.isEmpty)

        let updated = try stateStore.loadStrict()
        let notesEntry = try XCTUnwrap(updated.slots.first(where: { $0.windowID == 801 }))
        XCTAssertEqual(notesEntry.visibilityState, .visible)
        XCTAssertEqual(notesEntry.lastVisibleFrame, expectedVisibleFrame)
        XCTAssertNotNil(notesEntry.lastActivatedAt)
    }

    func testFocusTargetWindowIDReturnsNotFoundWhenHiddenOffscreenVirtualWindowCannotBeRestored() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let offscreenFrame = ResolvedFrame(x: 5119, y: 0, width: 800, height: 977)
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
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    lastHiddenFrame: offscreenFrame,
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 1
        )

        var focusCalls = 0
        let runtimeHooks = makeRuntimeHooks(
            focusWindow: { _, _ in
                focusCalls += 1
                return .success
            },
            setWindowFrame: { _, _, _ in false },
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
            spaces: {
                [
                    SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false),
                ]
            },
            listWindowsOnAllSpaces: {
                [
                    WindowSnapshot(
                        windowID: 801,
                        bundleID: "com.apple.Notes",
                        pid: 801,
                        title: "Notes",
                        role: "AXWindow",
                        subrole: nil,
                        minimized: false,
                        hidden: false,
                        frame: offscreenFrame,
                        spaceID: 7,
                        displayID: "display-a",
                        isFullscreen: false,
                        frontIndex: 0
                    ),
                ]
            }
        )

        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)
        let result = service.focus(slot: nil as Int?, target: WindowTargetSelector(windowID: 801, bundleID: nil, title: nil))

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
        XCTAssertEqual(focusCalls, 0)

        let updated = try stateStore.loadStrict()
        XCTAssertEqual(updated.slots.first?.visibilityState, .hiddenOffscreen)
    }

    func testFocusCanTargetBundleIDAndTitle() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        var titledActivationCalls: [(String, String)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            activateWindowWithTitle: { bundleID, title in
                titledActivationCalls.append((bundleID, title))
                return true
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.focus(
            slot: nil,
            target: WindowTargetSelector(windowID: nil, bundleID: "com.apple.TextEdit", title: "Draft")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(titledActivationCalls.map(\.0), ["com.apple.TextEdit"])
        XCTAssertEqual(titledActivationCalls.map(\.1), ["Draft"])
    }

    func testFocusBundleIDAndTitleUsesExactWindowWhenEnumerated() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let windows = [
            Self.window(windowID: 101, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0),
            Self.window(windowID: 202, bundleID: "com.apple.TextEdit", title: "Draft", spaceID: 1, frontIndex: 1),
        ]
        var focusedTargets: [(UInt32, String)] = []
        var titledActivationCalls: [(String, String)] = []

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { windows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            activateWindowWithTitle: { bundleID, title in
                titledActivationCalls.append((bundleID, title))
                return true
            },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.focus(
            slot: nil,
            target: WindowTargetSelector(windowID: nil, bundleID: "com.apple.TextEdit", title: "Draft")
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.apple.TextEdit"])
        XCTAssertTrue(titledActivationCalls.isEmpty)
    }

    func testFocusRejectsInvalidSelectorCombinations() throws {
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

        XCTAssertEqual(
            service.focus(slot: 1, target: WindowTargetSelector(windowID: 42, bundleID: nil, title: nil)).exitCode,
            Int32(ErrorCode.validationError.rawValue)
        )
        XCTAssertEqual(
            service.focus(slot: nil, target: WindowTargetSelector(windowID: nil, bundleID: nil, title: "Draft")).exitCode,
            Int32(ErrorCode.validationError.rawValue)
        )
    }
}
