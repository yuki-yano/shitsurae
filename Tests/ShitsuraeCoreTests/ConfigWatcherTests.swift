import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("ConfigWatcher")
struct ConfigWatcherTests {
    private let config = """
    layouts:
      work:
        spaces:
          - spaceID: 1
            windows:
              - slot: 1
                launch: false
                match:
                  bundleID: com.apple.TextEdit
                frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
    """

    @Test func rearmsAfterWatchedDirectoryIsRenamed() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-watcher-\(UUID().uuidString)", isDirectory: true)
        let watched = parent.appendingPathComponent("config", isDirectory: true)
        let moved = parent.appendingPathComponent("config-old", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try config.write(
            to: watched.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let firstReload = DispatchSemaphore(value: 0)
        let secondReload = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var successfulGenerations: [String] = []
        let watcher = ConfigWatcher(directoryURL: watched, debounceMs: 30) { result in
            guard case let .success(loaded) = result else { return }
            lock.lock()
            successfulGenerations.append(loaded.configGeneration)
            let count = successfulGenerations.count
            lock.unlock()
            if count == 1 {
                firstReload.signal()
            } else if count == 2 {
                secondReload.signal()
            }
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        try FileManager.default.moveItem(at: watched, to: moved)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try (config + "\n# replacement\n").write(
            to: watched.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        #expect(firstReload.wait(timeout: .now() + 3) == .success)

        try (config + "\n# edited after rearm\n").write(
            to: watched.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )
        #expect(secondReload.wait(timeout: .now() + 3) == .success)

        lock.lock()
        let generations = successfulGenerations
        lock.unlock()
        #expect(generations.count >= 2)
        #expect(generations[0] != generations[1])
    }

    @Test func concurrentReloadAndStopNeverDeadlocks() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-manager-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try config.write(
            to: directory.appendingPathComponent("config.yaml"),
            atomically: true,
            encoding: .utf8
        )

        for _ in 0 ..< 100 {
            let manager = ConfigManager(directoryURL: directory, logger: TestFixtures.nullLogger())
            manager.start()

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                _ = manager.reload(trigger: "concurrent-stop-test")
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                manager.stop()
                group.leave()
            }

            try #require(group.wait(timeout: .now() + 5) == .success)
            manager.stop()
        }
    }
}
