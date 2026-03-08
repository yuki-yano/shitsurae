import XCTest
@testable import ShitsuraeCore

final class AgentIPCTests: XCTestCase {
    func testWithConfigDirectoryPathCreatesCopiedRequest() {
        let request = AgentCommandRequest(
            command: .arrange,
            json: true,
            dryRun: true,
            verbose: false,
            layoutName: "work",
            spaceID: 2,
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil,
            stateOnly: true
        )

        let copied = request.withConfigDirectoryPath("/tmp/shitsurae")
        XCTAssertEqual(copied.command, .arrange)
        XCTAssertEqual(copied.layoutName, "work")
        XCTAssertEqual(copied.spaceID, 2)
        XCTAssertEqual(copied.stateOnly, true)
        XCTAssertEqual(copied.configDirectoryPath, "/tmp/shitsurae")
    }

    func testAgentCommandRequestCodableRoundTrip() throws {
        let request = AgentCommandRequest(
            command: .windowSet,
            json: false,
            dryRun: nil,
            verbose: nil,
            layoutName: nil,
            spaceID: 3,
            slot: nil,
            includeAllSpaces: nil,
            x: .expression("10%"),
            y: .pt(20),
            width: .expression("50%"),
            height: .expression("60%"),
            windowID: 42,
            bundleID: "com.apple.TextEdit",
            windowTitle: "Draft",
            configDirectoryPath: "/Users/example/.config/shitsurae",
            stateOnly: true
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AgentCommandRequest.self, from: encoded)
        XCTAssertEqual(decoded.command, .windowSet)
        XCTAssertEqual(decoded.spaceID, 3)
        XCTAssertEqual(decoded.x, .expression("10%"))
        XCTAssertEqual(decoded.y, .pt(20))
        XCTAssertEqual(decoded.windowID, 42)
        XCTAssertEqual(decoded.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(decoded.windowTitle, "Draft")
        XCTAssertEqual(decoded.configDirectoryPath, "/Users/example/.config/shitsurae")
        XCTAssertEqual(decoded.stateOnly, true)
    }

    func testAgentCommandCodableSupportsDisplayAndSpaceCommands() throws {
        let commands: [AgentCommand] = [.displayList, .displayCurrent, .spaceList, .spaceCurrent]

        let encoded = try JSONEncoder().encode(commands)
        let decoded = try JSONDecoder().decode([AgentCommand].self, from: encoded)

        XCTAssertEqual(decoded, commands)
    }

    func testLaunchAgentPlistURLUsesLaunchAgentLabel() {
        let url = AgentXPCConstants.launchAgentPlistURL.path
        XCTAssertTrue(url.hasSuffix("/Library/LaunchAgents/\(AgentXPCConstants.launchAgentLabel).plist"))
    }
}
