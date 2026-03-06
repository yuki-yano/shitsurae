import Foundation
import XCTest
@testable import ShitsuraeCore

final class ConfigPathResolverTests: XCTestCase {
    func testConfigDirectoryURLUsesXDGConfigHomeWhenPresent() {
        let url = ConfigPathResolver.configDirectoryURL(
            environment: [
                "HOME": "/Users/example",
                "XDG_CONFIG_HOME": "/tmp/xdg-config"
            ]
        )

        XCTAssertEqual(url.path, "/tmp/xdg-config/shitsurae")
    }

    func testStateDirectoryURLUsesXDGStateHomeWhenPresent() {
        let url = ConfigPathResolver.stateDirectoryURL(
            environment: [
                "HOME": "/Users/example",
                "XDG_STATE_HOME": "/tmp/xdg-state"
            ]
        )

        XCTAssertEqual(url.path, "/tmp/xdg-state/shitsurae")
    }

    func testStateDirectoryURLFallsBackToLocalStateUnderHome() {
        let url = ConfigPathResolver.stateDirectoryURL(
            environment: [
                "HOME": "/Users/example"
            ]
        )

        XCTAssertEqual(url.path, "/Users/example/.local/state/shitsurae")
    }
}
