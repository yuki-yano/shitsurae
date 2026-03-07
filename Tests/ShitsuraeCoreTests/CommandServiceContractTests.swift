import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceContractTests: XCTestCase {
    func testBundledSupportedBuildCatalogResourceIsAvailable() throws {
        let data = try Data(contentsOf: CommandService.bundledSupportedBuildCatalogURL)
        let catalog = try JSONDecoder().decode(SupportedBuildCatalog.self, from: data)
        XCTAssertFalse(catalog.allowStatusesForRuntime.isEmpty)
        XCTAssertFalse(catalog.builds.isEmpty)
    }

    func testValidateNonJSONSuccessWritesValidToStdout() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.validate(json: false)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "valid\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testValidateJSONFailureWritesErrorJSONToStdout() throws {
        let workspace = try TestConfigWorkspace(files: ["broken.yaml": "version: ["])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.validate(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.invalidYAMLSyntax.rawValue))
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(ValidateJSON.self, from: result.stdout)
        XCTAssertFalse(payload.valid)
        XCTAssertFalse(payload.errors.isEmpty)
        XCTAssertEqual(payload.errors.first?.code, ErrorCode.invalidYAMLSyntax.rawValue)
    }

    func testLayoutsListOutputsSortedOnePerLine() throws {
        let yaml = """
        layouts:
          zeta:
            spaces:
              - spaceID: 1
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
          alpha:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame:
                      x: "50%"
                      y: "0%"
                      width: "50%"
                      height: "100%"
        """

        let workspace = try TestConfigWorkspace(files: ["layouts.yaml": yaml])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.layoutsList()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "alpha\nzeta\n")
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testDiagnosticsJSONSchemaIsReturnedToStdout() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.diagnostics(json: true)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stderr.isEmpty)

        let diagnostics = try decode(DiagnosticsJSON.self, from: result.stdout)
        XCTAssertEqual(diagnostics.schemaVersion, 1)
        XCTAssertTrue(Self.isRFC3339UTCWithFractionalSeconds(diagnostics.generatedAt))
        XCTAssertTrue(Self.isRFC3339UTCWithFractionalSeconds(diagnostics.lastConfigReload.at))
        XCTAssertEqual(diagnostics.permissions.automation.required, false)
        XCTAssertGreaterThanOrEqual(diagnostics.watch.debounceMs, 0)
    }

    func testDiagnosticsScreenRecordingRequiredWhenOverlayThumbnailsEnabled() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.overlayThumbnailConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.diagnostics(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let diagnostics = try decode(DiagnosticsJSON.self, from: result.stdout)
        XCTAssertTrue(diagnostics.permissions.screenRecording.required)
    }

    func testDiagnosticsUsesRuntimeEventTapReasonFromStatusStore() throws {
        EventTapRuntimeStatusStore.shared.set(
            EventTapStatus(enabled: false, reason: "eventTapUnavailable")
        )
        defer {
            EventTapRuntimeStatusStore.shared.set(EventTapStatus(enabled: true, reason: nil))
        }

        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let result = service.diagnostics(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let diagnostics = try decode(DiagnosticsJSON.self, from: result.stdout)
        XCTAssertFalse(diagnostics.eventTap.enabled)
        XCTAssertEqual(diagnostics.eventTap.reason, "eventTapUnavailable")
    }

    func testDiagnosticsUnsupportedBuildReportsUnsupportedOSBuild() throws {
        guard SystemProbe.currentBuildVersion() != nil else {
            throw XCTSkip("sw_vers unavailable")
        }

        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let unsupportedCatalogURL = workspace.configDirectory.appendingPathComponent("unsupported-catalog.json")
        try """
        {
          "schemaVersion": 1,
          "owner": "@tests",
          "updateTrigger": ["release"],
          "comparisonKey": "sw_vers -buildVersion",
          "statusEnum": ["supported"],
          "allowStatusesForRuntime": ["supported"],
          "builds": [
            { "productVersion": "0.0.0", "productBuildVersion": "NONMATCHING", "status": "supported" }
          ]
        }
        """.write(to: unsupportedCatalogURL, atomically: true, encoding: .utf8)

        let service = workspace.makeService(supportedBuildCatalogURL: unsupportedCatalogURL)
        let result = service.diagnostics(json: true)
        XCTAssertEqual(result.exitCode, 0)
        let diagnostics = try decode(DiagnosticsJSON.self, from: result.stdout)
        XCTAssertEqual(diagnostics.backend.reason, "unsupportedOSBuild")
    }

    func testDiagnosticsInternalFailureReturnsCode30JSON() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let invalidPath = workspace.root.appendingPathComponent("not-a-directory")
        try "content".write(to: invalidPath, atomically: true, encoding: .utf8)

        let service = workspace.makeService(configDirectoryOverride: invalidPath)
        let result = service.diagnostics(json: true)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.backendUnavailable.rawValue))
        XCTAssertTrue(result.stderr.isEmpty)

        let payload = try decode(CommonErrorJSON.self, from: result.stdout)
        XCTAssertEqual(payload.code, ErrorCode.backendUnavailable.rawValue)
    }







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

    func testFocusOutOfRangeReturnsValidationErrorToStderr() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

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
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [focusedWindow] },
            focusedWindow: { focusedWindow },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return true
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
        let result = service.focus(slot: 1)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.targetWindowNotFound.rawValue))
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
                return true
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
                return true
            }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)
        let result = service.focus(slot: nil, target: WindowTargetSelector(windowID: 202, bundleID: nil, title: nil))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [202])
        XCTAssertEqual(focusedTargets.map(\.1), ["com.apple.TextEdit"])
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
                return true
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
        XCTAssertNil(payload.slot)
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
    }

    func testSwitcherRequiresJSONFlag() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }
        let service = workspace.makeService()

        let switcher = service.switcherList(json: false, includeAllSpacesOverride: nil)
        XCTAssertEqual(switcher.exitCode, Int32(ErrorCode.validationError.rawValue))
        XCTAssertEqual(switcher.stderr, "switcher list supports --json only\n")
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

    func testPermissionBranchReturns20ForWindowCurrentFocusAndArrange() throws {
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

        let current = service.windowCurrent(json: true)
        XCTAssertEqual(current.exitCode, Int32(ErrorCode.missingPermission.rawValue))

        let focus = service.focus(slot: 1)
        XCTAssertEqual(focus.exitCode, Int32(ErrorCode.missingPermission.rawValue))

        let arrangeService = workspace.makeService(arrangeDriver: MissingPermissionArrangeDriver())
        let arrange = arrangeService.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertEqual(arrange.exitCode, Int32(ErrorCode.missingPermission.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: arrange.stdout)
        XCTAssertEqual(payload.hardErrors.first?.code, ErrorCode.missingPermission.rawValue)
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



    private static let validConfigYAML = """
    layouts:
      work:
        spaces:
          - spaceID: 1
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

    private static let multiSpaceConfigYAML = """
    layouts:
      work:
        spaces:
          - spaceID: 1
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
            windows:
              - slot: 2
                launch: false
                match:
                  bundleID: com.apple.Notes
                frame:
                  x: "50%"
                  y: "0%"
                  width: "50%"
                  height: "100%"
    """

    private static let overlayThumbnailConfigYAML = """
    overlay:
      showThumbnails: true
    layouts:
      work:
        spaces:
          - spaceID: 1
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

    private static let switcherConfigYAML = """
    shortcuts:
      switcher:
        quickKeys: "abc"
        sources: ["window"]
    layouts:
      work:
        spaces:
          - spaceID: 1
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

    private static let ignoreFocusConfigYAML = """
    ignore:
      focus:
        apps:
          - com.apple.TextEdit
    layouts:
      work:
        spaces:
          - spaceID: 1
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



    private static func isRFC3339UTCWithFractionalSeconds(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value) != nil
    }

    private static func window(
        windowID: UInt32,
        bundleID: String,
        title: String,
        spaceID: Int?,
        frontIndex: Int
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: Int(windowID),
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 640, height: 480),
            spaceID: spaceID,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }
}

private struct TestConfigWorkspace {
    let root: URL
    let xdgConfigHome: URL
    let configDirectory: URL
    let stateFileURL: URL
    let supportedBuildCatalogURL: URL

    init(files: [String: String]) throws {
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("shitsurae-tests-\(UUID().uuidString)", isDirectory: true)
        let xdgConfigHome = tempBase.appendingPathComponent("xdg", isDirectory: true)
        let configDirectory = xdgConfigHome.appendingPathComponent("shitsurae", isDirectory: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)

        for (name, content) in files {
            let url = configDirectory.appendingPathComponent(name)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let stateFileURL = tempBase.appendingPathComponent("runtime-state.json")
        let supportedBuildCatalogURL = tempBase.appendingPathComponent("supported-build-catalog.json")
        let currentBuildVersion = SystemProbe.currentBuildVersion() ?? "UNKNOWN_BUILD"
        try """
        {
          "allowStatusesForRuntime": ["supported"],
          "builds": [
            { "productVersion": "0.0.0", "productBuildVersion": "\(currentBuildVersion)", "status": "supported" }
          ]
        }
        """.write(to: supportedBuildCatalogURL, atomically: true, encoding: .utf8)

        self.root = tempBase
        self.xdgConfigHome = xdgConfigHome
        self.configDirectory = configDirectory
        self.stateFileURL = stateFileURL
        self.supportedBuildCatalogURL = supportedBuildCatalogURL
    }

    func makeService(
        stateStore: RuntimeStateStore = RuntimeStateStore(),
        supportedBuildCatalogURL: URL? = nil,
        arrangeDriver: ArrangeDriver = ContractTestArrangeDriver(),
        arrangeRequestDeduplicator: ArrangeRequestDeduplicating? = nil,
        runtimeHooks: CommandServiceRuntimeHooks = .live,
        configDirectoryOverride: URL? = nil
    ) -> CommandService {
        CommandService(
            stateStore: stateStore,
            supportedBuildCatalogURL: supportedBuildCatalogURL ?? self.supportedBuildCatalogURL,
            arrangeDriver: arrangeDriver,
            arrangeRequestDeduplicator: arrangeRequestDeduplicator,
            enableAutoReloadMonitor: false,
            environment: [
                "XDG_CONFIG_HOME": xdgConfigHome.path,
                "HOME": root.path,
            ],
            configDirectoryOverride: configDirectoryOverride,
            runtimeHooks: runtimeHooks
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ContractTestArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] {
        [
            DisplayInfo(
                id: "display-a",
                width: 1440,
                height: 900,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
        ]
    }

    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}

private struct BackendUnavailableArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] { [] }
    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { true }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (false, "unsupportedOSBuild") }
}

private struct MissingPermissionArrangeDriver: ArrangeDriver {
    func displays() -> [DisplayInfo] { [] }
    func queryWindows() -> [WindowSnapshot] { [] }
    func queryWindowsOnAllSpaces() -> [WindowSnapshot] { [] }
    func launch(request _: ApplicationLaunchRequest) -> Bool { true }
    func moveWindowToSpace(
        windowID _: UInt32,
        bundleID _: String,
        displayID _: String?,
        spaceID _: Int,
        spacesMode _: SpacesMode,
        method _: SpaceMoveMethod
    ) -> Bool { true }
    func setWindowFrame(windowID _: UInt32, bundleID _: String, frame _: ResolvedFrame) -> Bool { true }
    func activate(bundleID _: String) -> Bool { true }
    func sleep(milliseconds _: Int) {}
    func accessibilityGranted() -> Bool { false }
    func actualSpacesMode() -> SpacesMode? { .perDisplay }
    func backendAvailable(catalogURL _: URL) -> (Bool, String?) { (true, nil) }
}
