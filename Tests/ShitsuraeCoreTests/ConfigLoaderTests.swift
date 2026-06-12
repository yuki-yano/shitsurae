import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("ConfigLoader")
struct ConfigLoaderTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ yaml: String, as name: String, in directory: URL) throws {
        try yaml.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private let basicLayout = """
    layouts:
      work:
        initialFocus:
          slot: 1
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
              - slot: 2
                launch: false
                match:
                  bundleID: com.apple.Terminal
                frame:
                  x: "50%"
                  y: "0%"
                  width: "50%"
                  height: "100%"
    """

    @Test func loadsBasicLayout() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.layouts.count == 1)
        #expect(loaded.config.layouts["work"]?.spaces.first?.windows.count == 2)
        #expect(loaded.configGeneration.count == 64)
        #expect(loaded.configFiles.allSatisfy { $0.loaded })
    }

    @Test func rejectsModeSpaceKey() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)
        try write(
            """
            mode:
              space: virtual
            """,
            as: "02-mode.yaml",
            in: dir
        )

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            #expect(error.errors.contains { $0.message.contains("mode.space was removed") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func rejectsExecutionPolicySection() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)
        try write(
            """
            executionPolicy:
              spaceMoveMethod: drag
            """,
            as: "02-policy.yaml",
            in: dir
        )

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            #expect(error.errors.contains { $0.message.contains("executionPolicy was removed") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func acceptsModeFollowFocus() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)
        try write(
            """
            mode:
              followFocus: false
            """,
            as: "02-mode.yaml",
            in: dir
        )

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.resolvedFollowFocus == false)
    }

    @Test func rejectsDuplicateLayoutAcrossFiles() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)
        try write(basicLayout, as: "02-duplicate.yaml", in: dir)

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            #expect(error.code == .configMergeConflict)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func mergesIgnoreAppsAsUnion() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)
        try write(
            """
            ignore:
              apply:
                apps:
                  - com.apple.finder
            """,
            as: "02-ignore-a.yaml",
            in: dir
        )
        try write(
            """
            ignore:
              apply:
                apps:
                  - com.apple.finder
                  - com.apple.Safari
            """,
            as: "03-ignore-b.yaml",
            in: dir
        )

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.ignore?.apply?.apps == ["com.apple.finder", "com.apple.Safari"])
    }

    @Test func rejectsEmptyDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: ConfigLoadError.self) {
            try ConfigLoader().load(from: dir)
        }
    }

    @Test func reportsYAMLSyntaxError() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("layouts: [unclosed", as: "01-broken.yaml", in: dir)

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            #expect(error.code == .invalidYAMLSyntax)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func configGenerationChangesWithContent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(basicLayout, as: "01-basic.yaml", in: dir)

        let first = try ConfigLoader().load(from: dir)
        try write(basicLayout + "\n# comment\n", as: "01-basic.yaml", in: dir)
        let second = try ConfigLoader().load(from: dir)

        #expect(first.configGeneration != second.configGeneration)
    }
}
