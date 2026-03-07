import XCTest
@testable import ShitsuraeCore

final class ChromiumProfileSupportTests: XCTestCase {
    func testSupportsKnownChromiumBrowsers() {
        XCTAssertTrue(ChromiumProfileSupport.supports(bundleID: "com.google.Chrome"))
        XCTAssertTrue(ChromiumProfileSupport.supports(bundleID: "com.brave.Browser"))
        XCTAssertTrue(ChromiumProfileSupport.supports(bundleID: "com.microsoft.edgemac"))
        XCTAssertFalse(ChromiumProfileSupport.supports(bundleID: "com.apple.Safari"))
    }

    func testLaunchArgumentsIncludeProfileDirectoryAndNewWindow() {
        XCTAssertEqual(
            ChromiumProfileSupport.launchArguments(profileDirectory: "Profile 1"),
            ["--profile-directory=Profile 1", "--new-window", "about:blank"]
        )
    }

    func testLsofArgumentsUseNameOnlyFormat() {
        XCTAssertEqual(
            ChromiumProfileSupport.lsofArguments(pid: 1234),
            ["-Fn", "-p", "1234"]
        )
    }

    func testResolveUnambiguousProfileDirectoryReturnsObservedProfile() {
        let localState = """
        {
          "profile": {
            "info_cache": {
              "Default": { "name": "Work" },
              "Profile 1": { "name": "Personal" }
            }
          }
        }
        """.data(using: .utf8)!

        let lsofOutput = """
        Google  17449 yuki-yano txt REG 1,18 70909952 6368169 /Users/test/Library/Application Support/Google/Chrome/Default/History
        Google  17449 yuki-yano txt REG 1,18 4096 7784224 /Users/test/Library/Application Support/Google/Chrome/System Profile/SharedStorage
        """

        XCTAssertEqual(
            ChromiumProfileSupport.resolveUnambiguousProfileDirectory(
                bundleID: "com.google.Chrome",
                lsofOutput: lsofOutput,
                localStateData: localState
            ),
            "Default"
        )
    }

    func testResolveUnambiguousProfileDirectoryReturnsNilWhenMultipleProfilesAreObserved() {
        let localState = """
        {
          "profile": {
            "info_cache": {
              "Default": { "name": "Work" },
              "Profile 1": { "name": "Personal" }
            }
          }
        }
        """.data(using: .utf8)!

        let lsofOutput = """
        Google  17449 yuki-yano txt REG 1,18 70909952 6368169 /Users/test/Library/Application Support/Google/Chrome/Default/History
        Google  17449 yuki-yano txt REG 1,18 70909952 6368169 /Users/test/Library/Application Support/Google/Chrome/Profile 1/History
        """

        XCTAssertNil(
            ChromiumProfileSupport.resolveUnambiguousProfileDirectory(
                bundleID: "com.google.Chrome",
                lsofOutput: lsofOutput,
                localStateData: localState
            )
        )
    }
}
