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
                windows:
                  - match:
                      bundleID: "com.example.app"
                    slot: 1
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """
        try write(yaml: yaml, named: "01-base.yaml")

        let loaded = try ConfigLoader().load(from: tempDirectory)
        XCTAssertEqual(loaded.config.layouts.keys.sorted(), ["work"])
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

    private func write(yaml: String, named: String) throws {
        let fileURL = tempDirectory.appendingPathComponent(named)
        try yaml.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
