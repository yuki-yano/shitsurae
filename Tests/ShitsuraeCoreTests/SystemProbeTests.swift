import Foundation
import XCTest
@testable import ShitsuraeCore

private final class TestStringBox: @unchecked Sendable {
    var value: String?
}

final class SystemProbeTests: XCTestCase {
    func testWaitForRunningApplicationPollsUntilCheckerSucceeds() {
        var checks = 0
        let succeeded = SystemProbe.waitForRunningApplication(
            bundleID: "com.example.app",
            attempts: 5,
            intervalSeconds: 0,
            isRunning: { _ in
                checks += 1
                return checks >= 3
            },
            sleep: { _ in }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(checks, 3)
    }

    func testWaitForRunningApplicationReturnsFalseAfterAllAttempts() {
        var checks = 0
        let succeeded = SystemProbe.waitForRunningApplication(
            bundleID: "com.example.app",
            attempts: 4,
            intervalSeconds: 0,
            isRunning: { _ in
                checks += 1
                return false
            },
            sleep: { _ in }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(checks, 4)
    }

    func testSupportedBackendAvailableReturnsCatalogNotFound() {
        let missingURL = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).json")
        let result = SystemProbe.supportedBackendAvailable(catalogURL: missingURL)
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "catalogNotFound")
    }

    func testSupportedBackendAvailableReturnsCatalogDecodeFailed() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-catalog-\(UUID().uuidString).json")
        try "{not-json}".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = SystemProbe.supportedBackendAvailable(catalogURL: tempURL)
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "catalogDecodeFailed")
    }

    func testSupportedBackendAvailableReturnsUnsupportedOSBuildForNonMatchingCatalog() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsupported-catalog-\(UUID().uuidString).json")
        let json = """
        {
          "allowStatusesForRuntime": ["supported"],
          "builds": [
            { "productVersion": "0.0.0", "productBuildVersion": "NON_MATCHING_BUILD", "status": "supported" }
          ]
        }
        """
        try json.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let result = SystemProbe.supportedBackendAvailable(catalogURL: tempURL)
        XCTAssertEqual(result.0, false)
        XCTAssertEqual(result.1, "unsupportedOSBuild")
    }

    func testCurrentBuildVersionAndActualSpacesModeDoNotCrash() {
        let build = SystemProbe.currentBuildVersion()
        if let build {
            XCTAssertFalse(build.isEmpty)
        }

        let mode = SystemProbe.actualSpacesMode()
        if let mode {
            XCTAssertTrue(mode == .global || mode == .perDisplay)
        }
    }

    func testRunProcessConsumesLargeStdoutWithoutBlocking() {
        let finished = expectation(description: "runProcess finished")
        let payloadLineCount = 20000
        let output = TestStringBox()

        DispatchQueue.global().async {
            output.value = SystemProbe.runProcess(
                executable: "/bin/zsh",
                arguments: ["-lc", "yes x | head -n \(payloadLineCount)"]
            )
            finished.fulfill()
        }

        wait(for: [finished], timeout: 2.0)
        XCTAssertNotNil(output.value)
        XCTAssertEqual(output.value?.split(separator: "\n").count, payloadLineCount)
    }
}
