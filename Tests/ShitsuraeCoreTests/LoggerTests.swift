import Foundation
import XCTest
@testable import ShitsuraeCore

final class LoggerTests: XCTestCase {
    func testLogWritesJSONLineWithCoreFields() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("shitsurae.log")
        let logger = ShitsuraeLogger(logFileURL: logURL)

        logger.log(event: "arrange.start", fields: ["layout": "work", "exitCode": 0])

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        let lastLine = try XCTUnwrap(lines.last)
        let data = Data(lastLine.utf8)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["event"] as? String, "arrange.start")
        XCTAssertEqual(json["level"] as? String, "info")
        XCTAssertEqual(json["layout"] as? String, "work")
        XCTAssertEqual(json["exitCode"] as? Int, 0)
        XCTAssertNotNil(json["timestamp"] as? String)
    }

    func testRotateKeepsAtMostFiveGenerations() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("shitsurae.log")
        let logger = ShitsuraeLogger(logFileURL: logURL)

        for generation in 1 ... 5 {
            let url = logURL.appendingPathExtension("\(generation)")
            try "gen-\(generation)\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let tenMB = 10 * 1024 * 1024
        let oversized = Data(repeating: 65, count: tenMB)
        try oversized.write(to: logURL)

        logger.log(event: "rotate.trigger")

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("5").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("6").path))
    }

    func testPruneExpiredLogsRemovesFilesOlderThan14Days() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("shitsurae.log")
        let oldURL = logURL.appendingPathExtension("1")
        let recentURL = logURL.appendingPathExtension("2")

        try "old\n".write(to: oldURL, atomically: true, encoding: .utf8)
        try "recent\n".write(to: recentURL, atomically: true, encoding: .utf8)

        let oldDate = Date().addingTimeInterval(-(15 * 24 * 60 * 60))
        let recentDate = Date().addingTimeInterval(-(2 * 24 * 60 * 60))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: recentURL.path)

        _ = ShitsuraeLogger(logFileURL: logURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentURL.path))
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-logger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
