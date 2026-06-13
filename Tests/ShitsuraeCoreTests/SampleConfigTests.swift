import Foundation
import Testing
@testable import ShitsuraeCore

/// Loads the shipped sample configs through the real loader so the samples
/// can never drift out of sync with the v2 format.
@Suite("SampleConfigs")
struct SampleConfigTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ShitsuraeCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    @Test func loadsTopLevelSamples() throws {
        let dir = repoRoot.appendingPathComponent("samples/xdg-config-home/shitsurae")
        try #require(FileManager.default.fileExists(atPath: dir.path))

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.layouts.keys.sorted() == ["browser", "work"])
    }

    @Test func loadsVirtualSample() throws {
        let dir = repoRoot.appendingPathComponent("samples/xdg-config-home/shitsurae/virtual")
        try #require(FileManager.default.fileExists(atPath: dir.path))

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.layouts.keys.sorted() == ["virtualWork"])
        #expect(loaded.config.layouts["virtualWork"]?.spaces.count == 2)
    }
}
