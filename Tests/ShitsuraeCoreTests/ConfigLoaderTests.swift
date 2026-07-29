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

    @Test func loadsWindowWithoutFrame() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            """
            layouts:
              work:
                spaces:
                  - spaceID: 1
                    windows:
                      - slot: 1
                        launch: false
                        match:
                          bundleID: com.apple.TextEdit
            """,
            as: "01-track-only.yaml",
            in: dir
        )

        let loaded = try ConfigLoader().load(from: dir)
        let window = try #require(loaded.config.layouts["work"]?.spaces.first?.windows.first)
        #expect(window.frame == nil)
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

    @Test func rejectsSpaceLevelDisplayKeyWithMigrationHint() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            """
            layouts:
              work:
                spaces:
                  - spaceID: 1
                    display:
                      monitor: primary
                    windows:
                      - slot: 1
                        match:
                          bundleID: com.apple.TextEdit
                        frame:
                          x: "0%"
                          y: "0%"
                          width: "100%"
                          height: "100%"
            """,
            as: "01-legacy-display.yaml",
            in: dir
        )

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            // The dedicated removed-key diagnostic (with the migration hint)
            // must survive the Yams decoding path — a bare "unknown key"
            // would leave users without the layouts.<name>.display pointer.
            #expect(error.errors.contains { $0.message.contains("spaces[].display was removed") })
            #expect(error.errors.contains { $0.message.contains("layouts.<name>.display") })
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func acceptsLayoutLevelDisplayDeclaration() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(
            """
            monitors:
              calendar:
                id: uuid-sub
            layouts:
              calendar:
                display:
                  monitor: calendar
                spaces:
                  - spaceID: 1
                    windows:
                      - slot: 1
                        match:
                          bundleID: com.example.Calendar
                        frame:
                          x: "0%"
                          y: "0%"
                          width: "100%"
                          height: "100%"
            """,
            as: "01-layout-display.yaml",
            in: dir
        )

        let loaded = try ConfigLoader().load(from: dir)
        #expect(loaded.config.layouts["calendar"]?.display?.monitor == "calendar")
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

    @Test func rejectsUnknownKeysAtEverySchemaLevel() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let yaml = """
        applcation:
          launchAtLogin: false
        \(basicLayout.replacingOccurrences(
            of: "width: \"50%\"",
            with: "widht: \"50%\""
        ))
        """
        try write(yaml, as: "01-unknown.yaml", in: dir)

        do {
            _ = try ConfigLoader().load(from: dir)
            Issue.record("expected ConfigLoadError")
        } catch let error as ConfigLoadError {
            #expect(error.code == .validationError)
            #expect(error.errors.contains {
                $0.message == "unknown config key: applcation"
            })
            #expect(error.errors.contains {
                $0.message.contains("frame.widht")
            })
            #expect(error.errors.allSatisfy { $0.line != nil && $0.column != nil })
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
