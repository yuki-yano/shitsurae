import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceDiagnosticsContractTests: XCTestCase {
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
        XCTAssertEqual(diagnostics.schemaVersion, 4)
        XCTAssertTrue(Self.isRFC3339UTCWithFractionalSeconds(diagnostics.generatedAt))
        XCTAssertTrue(Self.isRFC3339UTCWithFractionalSeconds(diagnostics.lastConfigReload.at))
        XCTAssertEqual(diagnostics.permissions.automation.required, false)
        XCTAssertEqual(diagnostics.configuredSpaceMode, .native)
        XCTAssertEqual(diagnostics.effectiveSpaceMode, .native)
        XCTAssertEqual(diagnostics.diagnosticEventFields, [
            "requestID",
            "lockOwnerPID",
            "lockOwnerProcessKind",
            "lockOwnerStartedAt",
            "lockWaitTimeoutMS",
            "manualRecoveryRequired",
        ])
        let payload = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        XCTAssertNotNil(payload?["diagnosticEvents"])
        XCTAssertNil(payload?["watch"])
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

    private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
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

    private static func isRFC3339UTCWithFractionalSeconds(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value) != nil
    }
}
