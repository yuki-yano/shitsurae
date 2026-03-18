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
            stateOnly: true,
            forceClearPending: true,
            confirm: true
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
        XCTAssertEqual(decoded.forceClearPending, true)
        XCTAssertEqual(decoded.confirm, true)
    }

    func testAgentCommandRequestFieldsPopulateExpectedValues() {
        let arrange = AgentCommandRequest(
            command: .arrange,
            json: true,
            dryRun: true,
            verbose: false,
            layoutName: "work",
            spaceID: 2,
            stateOnly: true
        ).withConfigDirectoryPath("/tmp/config")
        XCTAssertEqual(arrange.command, .arrange)
        XCTAssertEqual(arrange.layoutName, "work")
        XCTAssertEqual(arrange.spaceID, 2)
        XCTAssertEqual(arrange.dryRun, true)
        XCTAssertEqual(arrange.stateOnly, true)
        XCTAssertEqual(arrange.configDirectoryPath, "/tmp/config")

        let switchRequest = AgentCommandRequest(
            command: .spaceSwitch,
            json: true,
            spaceID: 9,
            reconcile: true
        ).withConfigDirectoryPath("/tmp/config")
        XCTAssertEqual(switchRequest.command, .spaceSwitch)
        XCTAssertEqual(switchRequest.spaceID, 9)
        XCTAssertEqual(switchRequest.reconcile, true)

        let recover = AgentCommandRequest(
            command: .spaceRecover,
            json: true,
            forceClearPending: true,
            confirm: true
        ).withConfigDirectoryPath("/tmp/config")
        XCTAssertEqual(recover.command, .spaceRecover)
        XCTAssertEqual(recover.forceClearPending, true)
        XCTAssertEqual(recover.confirm, true)

        let target = WindowTargetSelector(windowID: 42, bundleID: "com.apple.TextEdit", title: "Draft")
        let workspace = AgentCommandRequest(
            command: .windowWorkspace,
            json: true,
            spaceID: 3,
            windowID: target.windowID,
            bundleID: target.bundleID,
            windowTitle: target.title
        ).withConfigDirectoryPath("/tmp/config")
        XCTAssertEqual(workspace.command, .windowWorkspace)
        XCTAssertEqual(workspace.spaceID, 3)
        XCTAssertEqual(workspace.windowID, 42)
        XCTAssertEqual(workspace.bundleID, "com.apple.TextEdit")
        XCTAssertEqual(workspace.windowTitle, "Draft")
    }

    func testAgentCommandCodableSupportsDisplayAndSpaceCommands() throws {
        let commands: [AgentCommand] = [.displayList, .displayCurrent, .spaceList, .spaceCurrent, .spaceSwitch, .spaceRecover]

        let encoded = try JSONEncoder().encode(commands)
        let decoded = try JSONDecoder().decode([AgentCommand].self, from: encoded)

        XCTAssertEqual(decoded, commands)
    }

    func testLaunchAgentPlistURLUsesLaunchAgentLabel() {
        let url = AgentXPCConstants.launchAgentPlistURL.path
        XCTAssertTrue(url.hasSuffix("/Library/LaunchAgents/\(AgentXPCConstants.launchAgentLabel).plist"))
    }
}
