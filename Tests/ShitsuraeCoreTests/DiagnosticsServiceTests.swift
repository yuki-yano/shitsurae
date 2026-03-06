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
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL,
            watchOverride: WatchStatus(debounceMs: 1000, watcherRunning: true)
        )

        XCTAssertEqual(diagnostics.schemaVersion, 1)
        XCTAssertEqual(diagnostics.watch.debounceMs, 1000)
        XCTAssertTrue(diagnostics.watch.watcherRunning)
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
            supportedBuildCatalogURL: CommandService.bundledSupportedBuildCatalogURL,
            watchOverride: nil
        )

        XCTAssertEqual(diagnostics.layouts, ["work"])
        XCTAssertEqual(diagnostics.spaces.map(\.displayID), ["display-a", "display-b"])
        XCTAssertEqual(diagnostics.spaces.map(\.spaceID), [1, 2])
        XCTAssertEqual(diagnostics.spaces.map(\.monitorRole), [.primary, .secondary])
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
