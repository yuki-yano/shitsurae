import Foundation
import XCTest

final class AppShellConfigurationTests: XCTestCase {
    func testAppAndAgentPlistsHaveExpectedIdentifiersAndDoNotUseLSUIElement() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let appPlist = try loadPlist(root.appendingPathComponent("Shitsurae/Info.plist"))
        let agentPlist = try loadPlist(root.appendingPathComponent("ShitsuraeAgent/Info.plist"))

        XCTAssertEqual(appPlist["CFBundleIdentifier"] as? String, "com.yuki-yano.shitsurae")
        XCTAssertEqual(agentPlist["CFBundleIdentifier"] as? String, "com.yuki-yano.shitsurae.agent")
        XCTAssertNil(appPlist["LSUIElement"])
        XCTAssertNil(agentPlist["LSUIElement"])
    }

    private func loadPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
