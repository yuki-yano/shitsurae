import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceArrangeContractTests: CommandServiceContractTestCase {
    func testArrangeJSONFailureWritesContractJSONToStdout() throws {
        let workspace = try TestConfigWorkspace(files: [:])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
    }

    func testArrangeNonJSONFailureWritesToStderr() throws {
        let workspace = try TestConfigWorkspace(files: [:])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: false)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertFalse(result.stderr.isEmpty)
    }

    func testArrangeSuppressesDuplicateRequestWithinDedupWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let deduplicator = FileBasedArrangeRequestDeduplicator(
            fileURL: workspace.root.appendingPathComponent("recent-arrange-request.json"),
            duplicateWindowSeconds: 60,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let service = workspace.makeService(arrangeRequestDeduplicator: deduplicator)
        let first = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        let second = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)

        XCTAssertEqual(first.exitCode, 51)
        XCTAssertEqual(second.exitCode, 0)
        let payload = try decode(ArrangeExecutionJSON.self, from: second.stdout)
        XCTAssertEqual(payload.result, "success")
        XCTAssertEqual(payload.warnings.first?.code, "arrange.duplicateSuppressed")
    }

    func testArrangeDoesNotSuppressDifferentSpaceScopedRequestWithinDedupWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.multiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let deduplicator = FileBasedArrangeRequestDeduplicator(
            fileURL: workspace.root.appendingPathComponent("recent-arrange-request.json"),
            duplicateWindowSeconds: 60,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        let service = workspace.makeService(arrangeRequestDeduplicator: deduplicator)
        _ = service.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true)
        let second = service.arrange(layoutName: "work", spaceID: 2, dryRun: false, verbose: false, json: true)

        XCTAssertNotEqual(second.exitCode, 0)
        let payload = try decode(ArrangeExecutionJSON.self, from: second.stdout)
        XCTAssertFalse(payload.warnings.contains(where: { $0.code == "arrange.duplicateSuppressed" }))
    }

    func testArrangeReturnsValidationErrorWhenSpecifiedSpaceMissingFromLayout() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.arrange(layoutName: "work", spaceID: 9, dryRun: false, verbose: false, json: true)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.message, "space not found in layout: 9")
    }

    func testArrangeStateOnlyUpdatesRuntimeStateWithoutArrangeRuntimeChecks() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let service = workspace.makeService(
            stateStore: stateStore,
            arrangeDriver: MissingPermissionArrangeDriver()
        )

        let result = service.arrange(
            layoutName: "work",
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: true
        )

        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "success")
        XCTAssertTrue(payload.hardErrors.isEmpty)
        XCTAssertTrue(payload.softErrors.isEmpty)
        XCTAssertTrue(payload.warnings.contains(where: { $0.code == "arrange.stateOnly" }))

        let persisted = stateStore.load().slots
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.slot, 1)
        XCTAssertEqual(persisted.first?.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(persisted.first?.spaceID, 1)
        XCTAssertNil(persisted.first?.windowID)
    }

    func testArrangeStateOnlyAdvancesStaleStateToCurrentGenerationWhenPendingIsNil() throws {
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
            activeVirtualSpaceID: 1,
            revision: 3
        )
        let runtimeHooks = makeRuntimeHooks()
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.arrange(
            layoutName: "work",
            spaceID: 1,
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: true
        )

        XCTAssertEqual(result.exitCode, 0)
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "success")

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.configGeneration, try workspace.currentConfigGeneration())
        XCTAssertEqual(persisted.stateMode, .virtual)
        XCTAssertEqual(persisted.activeLayoutName, "work")
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertNil(persisted.pendingSwitchTransaction)
    }

    func testArrangeStateOnlyReturnsRecoveryRequiresLiveArrangeWhenPendingRecoveryExists() throws {
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
        let focused = Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 1, frontIndex: 0)
        let runtimeHooks = makeRuntimeHooks(
            listWindows: { [focused] },
            focusedWindow: { focused },
            spaces: {
                [SpaceInfo(spaceID: 1, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { [focused] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.arrange(
            layoutName: "work",
            spaceID: 1,
            dryRun: false,
            verbose: false,
            json: true,
            stateOnly: true
        )

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.subcode, "virtualStateRecoveryRequiresLiveArrange")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
    }

    func testArrangeReturnsRecoveryTargetMismatchWhenPendingRecoveryTargetDoesNotStrictMatch() throws {
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
                requestID: "pending-recovery",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .recoveryRequired
            )
        )
        let runtimeHooks = makeRuntimeHooks()
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.arrange(
            layoutName: "work",
            spaceID: 99,
            dryRun: false,
            verbose: false,
            json: true
        )

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.subcode, "virtualStateRecoveryTargetMismatch")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
    }

    func testArrangeReturnsRecoveryTargetUnavailableWhenPendingRecoveryTargetIsMissingFromCurrentConfig() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualSingleSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: "pending-recovery",
                startedAt: "2026-03-12T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 2,
                configGeneration: "generation-1",
                status: .recoveryRequired
            )
        )
        let runtimeHooks = makeRuntimeHooks()
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.arrange(
            layoutName: "work",
            spaceID: 2,
            dryRun: false,
            verbose: false,
            json: true
        )

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.subcode, "virtualStateRecoveryTargetUnavailable")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
    }

    func testArrangeRejectsCombiningDryRunAndStateOnly() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.arrange(
            layoutName: "work",
            dryRun: true,
            verbose: false,
            json: true,
            stateOnly: true
        )

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.message, "dryRun and stateOnly cannot be combined")
    }

    func testArrangeJSONReturnsCode30WhenBackendUnavailable() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let service = workspace.makeService(arrangeDriver: BackendUnavailableArrangeDriver())
        let result = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.backendUnavailable.rawValue))
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.exitCode, ErrorCode.backendUnavailable.rawValue)
        XCTAssertEqual(payload.hardErrors.first?.code, ErrorCode.backendUnavailable.rawValue)
    }

    func testArrangeJSONReturnsVirtualHostDisplayUnavailableInVirtualMode() throws {
        let workspace = try TestConfigWorkspace(files: [
            "config.yaml": """
            mode:
              space: virtual
            layouts:
              work:
                spaces:
                  - spaceID: 1
                    display:
                      id: missing-display
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
            """
        ])
        defer { workspace.cleanup() }

        let service = workspace.makeService(arrangeDriver: VirtualHostUnavailableArrangeDriver())
        let result = service.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualHostDisplayUnavailable")
    }

    func testArrangeJSONReturnsUnresolvedSlotsWhenTrackedWindowIsOutsideHostNativeSpaceInVirtualMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let service = workspace.makeService(arrangeDriver: VirtualUnresolvedSlotsArrangeDriver())
        let result = service.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true)

        XCTAssertEqual(result.exitCode, Int32(ErrorCode.validationError.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: result.stdout)
        XCTAssertEqual(payload.schemaVersion, 2)
        XCTAssertEqual(payload.result, "failed")
        XCTAssertEqual(payload.exitCode, ErrorCode.validationError.rawValue)
        XCTAssertEqual(payload.subcode, "virtualSpaceUnresolvedSlots")
        XCTAssertEqual(payload.unresolvedSlots, [
            PendingUnresolvedSlot(slot: 1, spaceID: 1, reason: "hostNativeSpaceMismatch"),
        ])
    }

    // MARK: - Post-arrange: hide non-active workspace windows

    func testArrangeHidesNonActiveWorkspaceWindowsAfterVirtualArrange() throws {
        let workspace = try TestConfigWorkspace(files: [
            "config.yaml": Self.virtualMultiSpaceWithInitialFocusConfigYAML,
        ])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let arrangeDriver = VirtualArrangeTestDriver(windows: [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
        ])

        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                ]
            },
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
        let service = workspace.makeService(
            stateStore: stateStore,
            arrangeDriver: arrangeDriver,
            runtimeHooks: runtimeHooks
        )

        let result = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertTrue(result.exitCode == 0 || result.exitCode == Int32(ErrorCode.partialSuccess.rawValue))

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertTrue(
            positionCalls.contains(where: { $0.0 == 801 }),
            "Notes in workspace 2 should be hidden via setWindowPosition"
        )
        XCTAssertFalse(
            positionCalls.contains(where: { $0.0 == 800 }),
            "TextEdit in workspace 1 should remain visible"
        )

        let notesEntry = persisted.slots.first(where: { $0.windowID == 801 })
        XCTAssertEqual(notesEntry?.visibilityState, .hiddenOffscreen)
    }

    func testArrangeAdoptsShitsuraeWindowIntoFirstWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: [
            "config.yaml": Self.virtualMultiSpaceWithInitialFocusConfigYAML,
        ])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        let arrangeDriver = VirtualArrangeTestDriver(windows: [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
        ])

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 999, bundleID: "com.yuki-yano.shitsurae", title: "Shitsurae", spaceID: 7, frontIndex: 2),
                ]
            },
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
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                    Self.window(windowID: 999, bundleID: "com.yuki-yano.shitsurae", title: "Shitsurae", spaceID: 7, frontIndex: 2),
                ]
            }
        )
        let service = workspace.makeService(
            stateStore: stateStore,
            arrangeDriver: arrangeDriver,
            runtimeHooks: runtimeHooks
        )

        let result = service.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertTrue(result.exitCode == 0 || result.exitCode == Int32(ErrorCode.partialSuccess.rawValue))

        let persisted = stateStore.load()
        let shitsuraeEntry = persisted.slots.first(where: { $0.windowID == 999 })
        XCTAssertNotNil(shitsuraeEntry, "Shitsurae window should be adopted")
        XCTAssertEqual(shitsuraeEntry?.spaceID, 1, "Shitsurae should be in workspace 1")
        XCTAssertEqual(shitsuraeEntry?.bundleID, "com.yuki-yano.shitsurae")
    }

    // MARK: - Periodic adoption (adoptUntrackedWindowsIntoCurrentWorkspace)

    func testPeriodicAdoptionAdoptsNewWindowIntoActiveWorkspace() throws {
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
            revision: 3
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 1),
                ]
            },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 1)

        let persisted = stateStore.load()
        let finderEntry = persisted.slots.first(where: { $0.windowID == 900 })
        XCTAssertNotNil(finderEntry)
        XCTAssertEqual(finderEntry?.spaceID, 1)
        XCTAssertEqual(finderEntry?.bundleID, "com.apple.Finder")
        XCTAssertGreaterThanOrEqual(finderEntry?.slot ?? 0, CommandService.untrackedSlotOffset)
    }

    func testPeriodicAdoptionReturnsZeroWhenNoNewWindows() throws {
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
            revision: 3
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)]
            },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.slots.count, 1)
    }

    func testPeriodicAdoptionSkipsEdgePinnedHiddenWindows() throws {
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
            revision: 3
        )

        let hiddenFrame = ResolvedFrame(x: 1599, y: 120, width: 600, height: 400)
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    WindowSnapshot(
                        windowID: 900,
                        bundleID: "com.apple.Finder",
                        pid: 900,
                        title: "Desktop",
                        role: "AXWindow",
                        subrole: nil,
                        minimized: false,
                        hidden: false,
                        frame: hiddenFrame,
                        spaceID: 7,
                        displayID: "display-a",
                        isFullscreen: false,
                        frontIndex: 1
                    ),
                ]
            },
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
            focusWindow: { _, _ in .success }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)

        let persisted = stateStore.load()
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 900 }))
    }

    func testPeriodicAdoptionSkipsTransientDialogWindows() throws {
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
            revision: 3
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    WindowSnapshot(
                        windowID: 901,
                        bundleID: "com.apple.SecurityAgent",
                        pid: 901,
                        title: "Use Touch ID",
                        role: "AXWindow",
                        subrole: "AXDialog",
                        minimized: false,
                        hidden: false,
                        frame: ResolvedFrame(x: 200, y: 120, width: 480, height: 320),
                        spaceID: 7,
                        displayID: "display-a",
                        isFullscreen: false,
                        frontIndex: 1
                    ),
                ]
            },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)

        let persisted = stateStore.load()
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 901 }))
    }

    func testPeriodicAdoptionPrunesGoneRuntimeManagedWindows() throws {
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
                    slot: CommandService.untrackedSlotOffset,
                    source: .window,
                    bundleID: "com.apple.Finder",
                    definitionFingerprint: "runtimeVirtualWorkspace\u{0}work\u{0}com.apple.Finder\u{0}Desktop\u{0}AXWindow\u{0}\u{0}",
                    lastKnownTitle: "Desktop",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let allSpaceWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { allSpaceWindows },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            listWindowsOnAllSpaces: { allSpaceWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 900 }))
        XCTAssertNotNil(persisted.slots.first(where: { $0.windowID == 800 }))
    }

    func testPeriodicAdoptionKeepsUnresolvedLayoutSlots() throws {
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
                    titleMatchKind: .equals,
                    titleMatchValue: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: nil,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
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
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            listWindowsOnAllSpaces: { [] }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.slots.count, 1)
        XCTAssertEqual(persisted.slots.first?.definitionFingerprint, "slot-1")
        XCTAssertNil(persisted.slots.first?.windowID)
    }

    func testPeriodicAdoptionSkipsNonVirtualMode() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [],
            stateMode: .native,
            configGeneration: "generation-1",
            activeLayoutName: nil,
            activeVirtualSpaceID: nil
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 0)]
            },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let adopted = service.adoptUntrackedWindowsIntoCurrentWorkspace()
        XCTAssertEqual(adopted, 0)
    }
}
