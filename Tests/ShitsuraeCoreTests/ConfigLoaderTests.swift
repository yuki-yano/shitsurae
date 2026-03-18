import Foundation
import XCTest
@testable import ShitsuraeCore

final class ConfigLoaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testLoadSingleConfig() throws {
        let yaml = """
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "01-base.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.layouts.keys.sorted(), ["work"])
        XCTAssertFalse(loaded.configGeneration.isEmpty)
    }

    func testLoadWindowMatchProfile() throws {
        let yaml = """
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.google.Chrome"
                      profile: "Default"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "01-base.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.layouts["work"]?.spaces.first?.windows.first?.match.profile, "Default")
    }

    func testMergeIgnoreAppsUnion() throws {
        let base = """
        ignore:
          apply:
            apps:
              - com.apple.finder
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        let second = """
        ignore:
          apply:
            apps:
              - com.apple.TextEdit
        layouts:
          home:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app2"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        try write(yaml: base, named: "01-base.yaml")
        try write(yaml: second, named: "02-extra.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        let apps = loaded.config.ignore?.apply?.apps ?? []
        XCTAssertEqual(Set(apps), Set(["com.apple.finder", "com.apple.TextEdit"]))
        XCTAssertEqual(loaded.config.layouts.keys.sorted(), ["home", "work"])
    }

    func testDuplicateSingletonReturnsMergeConflict() throws {
        let first = """
        shortcuts:
          nextWindow: { key: "j", modifiers: ["cmd", "shift"] }
        layouts:
          a:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.a"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        let second = """
        shortcuts:
          prevWindow: { key: "k", modifiers: ["cmd", "shift"] }
        layouts:
          b:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.example.b"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        try write(yaml: first, named: "01.yaml")
        try write(yaml: second, named: "02.yaml")

        XCTAssertThrowsError(try ConfigLoader().load(from: tempDirectory)) { error in
            guard let loadError = error as? ConfigLoadError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(loadError.code, .configMergeConflict)
        }
    }

    func testSlotConflictReturnsCode13() throws {
        let yaml = """
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.example.a"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
                  - match:
                      bundleID: "com.example.b"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        try write(yaml: yaml, named: "config.yaml")

        XCTAssertThrowsError(try ConfigLoader().load(from: tempDirectory)) { error in
            guard let loadError = error as? ConfigLoadError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(loadError.code, .slotConflict)
        }
    }

    func testInvalidYAMLReturnsCode10() throws {
        let yaml = """
        layouts:
          work
            spaces:
              - spaceID: 1
        """

        try write(yaml: yaml, named: "broken.yaml")

        XCTAssertThrowsError(try ConfigLoader().load(from: tempDirectory)) { error in
            guard let loadError = error as? ConfigLoadError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(loadError.code, .invalidYAMLSyntax)
        }
    }

    func testRemovedSwitcherKeysAreIgnoredAtRuntime() throws {
        let yaml = """
        shortcuts:
          switcher:
            trigger: { key: "tab", modifiers: ["cmd"] }
            includeAllSpaces: true
            prioritizeCurrentSpace: false
            acceptOnModifierRelease: false
            quickKeys: "asdf"
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.resolvedShortcuts.switcherTrigger, HotkeyDefinition(key: "tab", modifiers: ["cmd"]))
        XCTAssertEqual(loaded.config.resolvedShortcuts.quickKeys, "asdf")
    }

    func testLoadOverlayCommandKeysWithBracketCharacter() throws {
        let yaml = """
        shortcuts:
          cycle:
            mode: overlay
            cancelKeys: [esc, "["]
          switcher:
            trigger: { key: "tab", modifiers: ["cmd"] }
            cancelKeys: [esc, "["]
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.resolvedShortcuts.cycleMode, .overlay)
        XCTAssertEqual(loaded.config.resolvedShortcuts.cycleCancelKeys, ["esc", "["])
        XCTAssertEqual(loaded.config.resolvedShortcuts.cancelKeys, ["esc", "["])
    }

    func testLoadMoveCurrentWindowToSpaceShortcuts() throws {
        let yaml = """
        shortcuts:
          moveCurrentWindowToSpace:
            - slot: 2
              key: "2"
              modifiers: ["shift", "alt"]
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.resolvedShortcuts.moveCurrentWindowToSpace[1], HotkeyDefinition(key: "1", modifiers: ["alt"]))
        XCTAssertEqual(loaded.config.resolvedShortcuts.moveCurrentWindowToSpace[2], HotkeyDefinition(key: "2", modifiers: ["shift", "alt"]))
        XCTAssertEqual(loaded.config.resolvedShortcuts.moveCurrentWindowToSpace[9], HotkeyDefinition(key: "9", modifiers: ["alt"]))
    }

    func testLoadSwitchVirtualSpaceShortcuts() throws {
        let yaml = """
        shortcuts:
          switchVirtualSpace:
            - slot: 3
              key: "3"
              modifiers: ["shift", "ctrl"]
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.resolvedShortcuts.switchVirtualSpace[1], HotkeyDefinition(key: "1", modifiers: ["ctrl"]))
        XCTAssertEqual(loaded.config.resolvedShortcuts.switchVirtualSpace[3], HotkeyDefinition(key: "3", modifiers: ["shift", "ctrl"]))
        XCTAssertEqual(loaded.config.resolvedShortcuts.switchVirtualSpace[9], HotkeyDefinition(key: "9", modifiers: ["ctrl"]))
    }

    func testLoadAppLaunchAtLoginSetting() throws {
        let yaml = """
        app:
          launchAtLogin: true
        layouts:
          work:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.app?.launchAtLogin, true)
    }

    func testLoadModeAndConfigGeneration() throws {
        let yaml = """
        mode:
          space: virtual
        layouts:
          work:
            spaces:
              - spaceID: 1
                display:
                  monitor: primary
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "config.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.resolvedSpaceInterpretationMode, .virtual)
        XCTAssertEqual(loaded.configGeneration.count, 64)
    }

    func testVirtualSpaceModeSampleConfigLoadsFromCanonicalDirectory() throws {
        let sampleDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("samples/xdg-config-home/shitsurae/virtual", isDirectory: true)

        let loaded = try ConfigLoader().load(from: sampleDirectory)

        XCTAssertEqual(loaded.config.resolvedSpaceInterpretationMode, .virtual)
        let layout = try XCTUnwrap(loaded.config.layouts["virtualWork"])
        XCTAssertEqual(layout.spaces.map(\.spaceID), [1, 2])
        XCTAssertEqual(layout.spaces[0].windows.map(\.slot), [1, 2])
        XCTAssertEqual(layout.spaces[1].windows.map(\.slot), [1, 2])
    }

    func testConfigLoadErrorLocalizedDescriptionUsesValidationMessage() {
        let error = ConfigLoadError(
            code: .validationError,
            errors: [
                ValidateErrorItem(
                    code: .validationError,
                    path: "/tmp/config.yaml",
                    line: 12,
                    column: 3,
                    message: "virtual mode requires an explicit display definition for every space in layout work"
                ),
            ]
        )

        XCTAssertEqual(
            error.localizedDescription,
            "/tmp/config.yaml:12:3: virtual mode requires an explicit display definition for every space in layout work"
        )
    }

    func testDuplicateModeReturnsMergeConflict() throws {
        let first = """
        mode:
          space: native
        layouts:
          a:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.a"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """
        let second = """
        mode:
          space: virtual
        layouts:
          b:
            spaces:
              - spaceID: 1
                windows:
                  - match:
                      bundleID: "com.example.b"
                    slot: 1
                    frame: { x: "0", y: "0", width: "100", height: "100" }
        """

        try write(yaml: first, named: "01.yaml")
        try write(yaml: second, named: "02.yaml")

        XCTAssertThrowsError(try ConfigLoader().load(from: tempDirectory)) { error in
            guard let loadError = error as? ConfigLoadError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(loadError.code, .configMergeConflict)
        }
    }

    private func write(yaml: String, named: String) throws {
        let fileURL = tempDirectory.appendingPathComponent(named)
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
