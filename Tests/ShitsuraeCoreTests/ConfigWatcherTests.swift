import Foundation
import XCTest
@testable import ShitsuraeCore

final class ConfigWatcherTests: XCTestCase {
    func testStartAndStopReturnsTrueForWritableDirectory() throws {
        let workspace = try ConfigWatcherTestWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let watcher = ConfigWatcher(
            directoryURL: workspace.configDirectory,
            debounceMs: 10,
            configLoader: ConfigLoader()
        ) { _ in }

        XCTAssertTrue(watcher.start())
        watcher.stop()
    }

    func testStartReturnsFalseWhenTargetCannotBeOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-invalid-\(UUID().uuidString)")
        let fileURL = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)

        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let watcher = ConfigWatcher(
            directoryURL: fileURL.appendingPathComponent("nested"),
            debounceMs: 10,
            configLoader: ConfigLoader()
        ) { _ in }

        XCTAssertFalse(watcher.start())
        watcher.stop()
    }

    func testReloadSuccessOnConfigFileUpdate() throws {
        let workspace = try ConfigWatcherTestWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let reloadExpectation = expectation(description: "reload success")

        let watcher = ConfigWatcher(
            directoryURL: workspace.configDirectory,
            debounceMs: 20,
            configLoader: ConfigLoader()
        ) { result in
            if case .success = result {
                reloadExpectation.fulfill()
            }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        try Self.validConfigYAMLWithDifferentLayout.write(
            to: workspace.configDirectory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [reloadExpectation], timeout: 3.0)
    }

    func testReloadFailureOnInvalidYAML() throws {
        let workspace = try ConfigWatcherTestWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let reloadExpectation = expectation(description: "reload failure")

        let watcher = ConfigWatcher(
            directoryURL: workspace.configDirectory,
            debounceMs: 20,
            configLoader: ConfigLoader()
        ) { result in
            if case let .failure(error) = result,
               error.code == .invalidYAMLSyntax
            {
                reloadExpectation.fulfill()
            }
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }

        try "version: [".write(
            to: workspace.configDirectory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [reloadExpectation], timeout: 3.0)
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

    private static let validConfigYAMLWithDifferentLayout = """
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
                  x: "10%"
                  y: "0%"
                  width: "60%"
                  height: "100%"
    """
}

private struct ConfigWatcherTestWorkspace {
    let root: URL
    let configDirectory: URL

    init(files: [String: String]) throws {
        let fm = FileManager.default
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("shitsurae-configwatcher-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = tempBase.appendingPathComponent("shitsurae", isDirectory: true)
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: configDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        self.root = tempBase
        self.configDirectory = configDirectory
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
