import Foundation
import XCTest
@testable import ShitsuraeCore

final class BundledResourceLocatorTests: XCTestCase {
    func testResolveResourceURLPrefersAppContentsResourcesBeforeFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-resource-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let searchRoot = root
            .appendingPathComponent("Shitsurae.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let bundleRoot = searchRoot.appendingPathComponent("shitsurae_ShitsuraeCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleRoot, withIntermediateDirectories: true)

        let expectedURL = bundleRoot.appendingPathComponent("supported-macos-builds.json")
        try "{}".write(to: expectedURL, atomically: true, encoding: .utf8)

        var fallbackCallCount = 0
        let resolved = BundledResourceLocator.resolveResourceURL(
            resourceName: "supported-macos-builds",
            resourceExtension: "json",
            resourceBundleName: "shitsurae_ShitsuraeCore.bundle",
            searchRoots: [searchRoot]
        ) {
            fallbackCallCount += 1
            return nil
        }

        XCTAssertEqual(resolved.standardizedFileURL, expectedURL.standardizedFileURL)
        XCTAssertEqual(fallbackCallCount, 0)
    }

    func testResolveResourceURLFallsBackToModuleBundleWhenSearchRootsMiss() throws {
        let fallbackRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-resource-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fallbackRoot) }

        let fallbackURL = fallbackRoot.appendingPathComponent("supported-macos-builds.json")
        try "{}".write(to: fallbackURL, atomically: true, encoding: .utf8)

        var fallbackCallCount = 0
        let resolved = BundledResourceLocator.resolveResourceURL(
            resourceName: "supported-macos-builds",
            resourceExtension: "json",
            resourceBundleName: "shitsurae_ShitsuraeCore.bundle",
            searchRoots: []
        ) {
            fallbackCallCount += 1
            return fallbackURL
        }

        XCTAssertEqual(resolved.standardizedFileURL, fallbackURL.standardizedFileURL)
        XCTAssertEqual(fallbackCallCount, 1)
    }
}
