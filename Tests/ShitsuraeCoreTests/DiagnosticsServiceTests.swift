import Foundation
import XCTest
@testable import ShitsuraeCore

final class DiagnosticsServiceTests: XCTestCase {
    func testRecentErrorStoreKeepsLatest50AndSorts() {
        let store = RecentErrorStore()
        for index in 0 ..< 60 {
            store.record(.validationError, summary: "error-\(index)")
        }

        let listed = store.list()
        XCTAssertEqual(listed.count, 50)
        XCTAssertTrue(listed.allSatisfy { $0.code == ErrorCode.validationError.rawValue })
    }

    func testCollectUsesLoadErrorConfigFilesWhenConfigMissing() throws {
        let loadError = ConfigLoadError(
            code: .invalidYAMLSyntax,
            errors: [
                ValidateErrorItem(code: .invalidYAMLSyntax, path: "/tmp/b.yaml", message: "broken B"),
                ValidateErrorItem(code: .invalidYAMLSyntax, path: "/tmp/a.yaml", message: "broken A"),
            ]
        )

        let diagnostics = DiagnosticsService.collect(
            loadedConfig: nil,
            loadError: loadError,
            lastConfigReload: ConfigReloadStatus(
                status: "failed",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: ErrorCode.invalidYAMLSyntax.rawValue,
                message: "broken config"
            ),
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL
        )

        XCTAssertEqual(diagnostics.schemaVersion, 4)
        XCTAssertEqual(diagnostics.configFiles.map(\.path), ["/tmp/a.yaml", "/tmp/b.yaml"])
        XCTAssertTrue(diagnostics.layouts.isEmpty)
    }

    func testCollectSpacesIncludesMonitorRoleAndSortsByDisplayIDThenSpaceID() {
        let left = SpaceDefinition(
            spaceID: 2,
            display: DisplayDefinition(monitor: .secondary, id: "display-b", width: nil, height: nil),
            windows: [defaultWindowDefinition(slot: 1)]
        )
        let right = SpaceDefinition(
            spaceID: 1,
            display: DisplayDefinition(monitor: .primary, id: "display-a", width: nil, height: nil),
            windows: [defaultWindowDefinition(slot: 2)]
        )

        let config = ShitsuraeConfig(
            app: nil,
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: [
                "work": LayoutDefinition(initialFocus: nil, spaces: [left, right]),
            ],
            shortcuts: nil
        )

        let loaded = LoadedConfig(config: config, configFiles: [], directoryURL: URL(fileURLWithPath: "/tmp"))
        let diagnostics = DiagnosticsService.collect(
            loadedConfig: loaded,
            loadError: nil,
            lastConfigReload: ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: nil,
                message: nil
            ),
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL
        )

        XCTAssertEqual(diagnostics.layouts, ["work"])
        XCTAssertEqual(diagnostics.spaces.map(\.displayID), ["display-a", "display-b"])
        XCTAssertEqual(diagnostics.spaces.map(\.spaceID), [1, 2])
        XCTAssertEqual(diagnostics.spaces.map(\.monitorRole), [.primary, .secondary])
        XCTAssertEqual(diagnostics.configuredSpaceMode, .native)
        XCTAssertEqual(diagnostics.effectiveSpaceMode, .native)
    }

    func testCollectEncodedJSONDoesNotIncludeWatchSection() throws {
        let config = ShitsuraeConfig(
            app: nil,
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: [
                "work": LayoutDefinition(initialFocus: nil, spaces: [
                    SpaceDefinition(spaceID: 1, display: nil, windows: [defaultWindowDefinition(slot: 1)]),
                ]),
            ],
            shortcuts: nil
        )

        let diagnostics = DiagnosticsService.collect(
            loadedConfig: LoadedConfig(
                config: config,
                configFiles: [],
                directoryURL: URL(fileURLWithPath: "/tmp")
            ),
            loadError: nil,
            lastConfigReload: ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: nil,
                message: nil
            ),
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL
        )

        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostics)) as? [String: Any]
        XCTAssertNil(payload?["watch"])
    }

    func testCollectIncludesConfiguredAndEffectiveVirtualSpaceModeAndActiveState() {
        let config = ShitsuraeConfig(
            app: nil,
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: [
                "work": LayoutDefinition(initialFocus: nil, spaces: [
                    SpaceDefinition(spaceID: 1, display: nil, windows: [defaultWindowDefinition(slot: 1)]),
                ]),
            ],
            shortcuts: nil,
            mode: ModeDefinition(space: .virtual)
        )
        let tempStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-state-\(UUID().uuidString).json")
        let store = RuntimeStateStore(stateFileURL: tempStateURL)
        store.save(
            slots: [],
            stateMode: .virtual,
            configGeneration: "test-generation",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2
        )

        let diagnostics = DiagnosticsService.collect(
            loadedConfig: LoadedConfig(config: config, configFiles: [], directoryURL: URL(fileURLWithPath: "/tmp")),
            loadError: nil,
            lastConfigReload: ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: nil,
                message: nil
            ),
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL,
            runtimeStateStore: store
        )

        XCTAssertEqual(diagnostics.configuredSpaceMode, .virtual)
        XCTAssertEqual(diagnostics.effectiveSpaceMode, .virtual)
        XCTAssertEqual(diagnostics.activeLayoutName, "work")
        XCTAssertEqual(diagnostics.activeVirtualSpaceID, 2)
    }

    func testCollectIncludesDiagnosticEventsAndFieldManifest() {
        let diagnosticEventsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-events-\(UUID().uuidString).jsonl")
        let diagnosticEventStore = DiagnosticEventStore(fileURL: diagnosticEventsURL)
        diagnosticEventStore.record(
            DiagnosticEvent(
                event: "space.switch.rollbackFailed",
                requestID: "request-rollback",
                code: ErrorCode.virtualSpaceSwitchRollbackFailed.rawValue,
                subcode: "virtualSpaceSwitchRollbackFailed"
            )
        )

        let diagnostics = DiagnosticsService.collect(
            loadedConfig: nil,
            loadError: nil,
            lastConfigReload: ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: "manual",
                errorCode: nil,
                message: nil
            ),
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL,
            diagnosticEventStore: diagnosticEventStore
        )

        XCTAssertEqual(diagnostics.diagnosticEventFields, [
            "requestID",
            "lockOwnerPID",
            "lockOwnerProcessKind",
            "lockOwnerStartedAt",
            "lockWaitTimeoutMS",
            "manualRecoveryRequired",
        ])
        XCTAssertEqual(diagnostics.diagnosticEvents.first?.requestID, "request-rollback")
    }

    func testDiagnosticEventStoreRecordsAndReadsRecentEvents() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-events-\(UUID().uuidString).jsonl")
        let store = DiagnosticEventStore(fileURL: fileURL)

        store.record(
            DiagnosticEvent(
                at: "2026-03-12T01:00:00Z",
                event: "space.switch.failed",
                requestID: "request-1",
                code: ErrorCode.virtualSpaceSwitchFailed.rawValue,
                subcode: "virtualSpaceSwitchFailed"
            )
        )
        store.record(
            DiagnosticEvent(
                at: "2026-03-12T02:00:00Z",
                event: "space.recovery.forceClearWriteFailed",
                requestID: "request-2",
                code: ErrorCode.validationError.rawValue,
                subcode: "spaceRecoveryStateWriteFailed",
                rootCauseCategory: "runtimeStateWriteFailed"
            )
        )

        let events = store.recent(limit: 10)
        XCTAssertEqual(events.map(\.event), [
            "space.recovery.forceClearWriteFailed",
            "space.switch.failed",
        ])
        XCTAssertEqual(events.first?.rootCauseCategory, "runtimeStateWriteFailed")
    }

    private func defaultWindowDefinition(slot: Int) -> WindowDefinition {
        WindowDefinition(
            source: .window,
            match: WindowMatchRule(
                bundleID: "com.apple.TextEdit",
                title: nil,
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            ),
            slot: slot,
            launch: false,
            frame: FrameDefinition(
                x: .expression("0%"),
                y: .expression("0%"),
                width: .expression("50%"),
                height: .expression("50%")
            )
        )
    }
}
