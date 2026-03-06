import Foundation
import XCTest
@testable import ShitsuraeCore

final class AgentXPCTransportTests: XCTestCase {
    func testClientUsesLongerDefaultTimeoutForArrangeRequests() {
        let client = AgentXPCClient()
        let request = AgentCommandRequest(
            command: .arrange,
            json: true,
            dryRun: false,
            verbose: false,
            layoutName: "default",
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        XCTAssertEqual(client.timeoutSeconds(for: request), 120.0)
    }

    func testClientKeepsExplicitTimeoutOverrideForArrangeRequests() {
        let client = AgentXPCClient(timeoutSeconds: 0.05)
        let request = AgentCommandRequest(
            command: .arrange,
            json: true,
            dryRun: false,
            verbose: false,
            layoutName: "default",
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        XCTAssertEqual(client.timeoutSeconds(for: request), 0.05)
    }

    func testLaunchAgentPlistEncodesRequiredFields() throws {
        let plist = LaunchAgentPlist(
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            executablePath: "/tmp/ShitsuraeAgent"
        )

        let data = try plist.encodedData()
        let raw = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertEqual(raw["Label"] as? String, "com.example.agent")
        XCTAssertEqual(raw["ProgramArguments"] as? [String], ["/tmp/ShitsuraeAgent"])
        XCTAssertEqual(raw["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(raw["LimitLoadToSessionType"] as? [String], ["Aqua"])

        let machServices = try XCTUnwrap(raw["MachServices"] as? [String: Bool])
        XCTAssertEqual(machServices["com.example.agent.service"], true)
    }

    func testLaunchAgentPlistDoesNotUseShellExecution() throws {
        let plist = LaunchAgentPlist(
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            executablePath: "/tmp/ShitsuraeAgent"
        )

        let raw = try XCTUnwrap(plist.propertyList()["ProgramArguments"] as? [String])
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(raw.first, "/tmp/ShitsuraeAgent")
    }

    func testClientReturnsConnectionFailedJSONWhenServiceUnavailable() throws {
        let launcher = StubLaunchAgentController(result: false)
        let client = AgentXPCClient(
            machServiceName: "com.example.unreachable.\(UUID().uuidString)",
            timeoutSeconds: 0.05,
            launchAgentController: launcher
        )

        let request = AgentCommandRequest(
            command: .diagnostics,
            json: true,
            dryRun: nil,
            verbose: nil,
            layoutName: nil,
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        let result = client.execute(request)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.xpcCommunicationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)

        let data = try XCTUnwrap(result.stderr.data(using: .utf8))
        let payload = try JSONDecoder().decode(CommonErrorJSON.self, from: data)
        XCTAssertEqual(payload.code, ErrorCode.xpcCommunicationError.rawValue)
        XCTAssertEqual(payload.subcode, AgentXPCSubcode.connectionFailed)
    }

    func testClientReturnsConnectionFailedTextWhenNonJSONMode() {
        let launcher = StubLaunchAgentController(result: false)
        let client = AgentXPCClient(
            machServiceName: "com.example.unreachable.\(UUID().uuidString)",
            timeoutSeconds: 0.05,
            launchAgentController: launcher
        )

        let request = AgentCommandRequest(
            command: .layoutsList,
            json: false,
            dryRun: nil,
            verbose: nil,
            layoutName: nil,
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        let result = client.execute(request)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.xpcCommunicationError.rawValue))
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertEqual(result.stderr, "xpc communication failed (\(AgentXPCSubcode.connectionFailed))\n")
    }

    func testClientDoesNotRetryWhenRequestTimesOut() throws {
        let launcher = CountingLaunchAgentController(result: true)
        let transport = StubAgentXPCTransport(results: [.failure(.timedOut)])
        let client = AgentXPCClient(
            timeoutSeconds: 0.05,
            launchAgentController: launcher,
            transport: transport
        )

        let request = AgentCommandRequest(
            command: .arrange,
            json: true,
            dryRun: false,
            verbose: false,
            layoutName: "default",
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        let result = client.execute(request)
        XCTAssertEqual(result.exitCode, Int32(ErrorCode.xpcCommunicationError.rawValue))
        XCTAssertEqual(transport.executeCallCount, 1)
        XCTAssertEqual(launcher.callCount, 0)

        let data = try XCTUnwrap(result.stderr.data(using: .utf8))
        let payload = try JSONDecoder().decode(CommonErrorJSON.self, from: data)
        XCTAssertEqual(payload.subcode, AgentXPCSubcode.timedOut)
    }

    func testLaunchAgentControllerReturnsFalseWhenResolverFails() {
        let plistURL = temporaryPlistURL()
        defer { try? FileManager.default.removeItem(at: plistURL.deletingLastPathComponent()) }

        let controller = LaunchAgentController(
            plistURL: plistURL,
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            fileManager: .default,
            processRunner: { _, _ in 0 },
            agentExecutableResolver: { nil }
        )

        XCTAssertFalse(controller.ensureAgentReachable())
    }

    func testLaunchAgentControllerWritesPlistAndRunsLaunchctlSequence() throws {
        let plistURL = temporaryPlistURL()
        let agentURL = plistURL.deletingLastPathComponent().appendingPathComponent("ShitsuraeAgent")
        try "binary".write(to: agentURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentURL.path)
        defer { try? FileManager.default.removeItem(at: plistURL.deletingLastPathComponent()) }

        var commands: [[String]] = []
        let controller = LaunchAgentController(
            plistURL: plistURL,
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            fileManager: .default,
            processRunner: { _, arguments in
                commands.append(arguments)
                return 0
            },
            agentExecutableResolver: { agentURL }
        )

        XCTAssertTrue(controller.ensureAgentReachable())
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0].first, "bootout")
        XCTAssertEqual(commands[1].first, "bootstrap")
        XCTAssertEqual(commands[2].first, "kickstart")

        let plistData = try Data(contentsOf: plistURL)
        let raw = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(raw["Label"] as? String, "com.example.agent")
        XCTAssertEqual(raw["ProgramArguments"] as? [String], [agentURL.path])
    }

    func testLaunchAgentControllerFailsOnBootstrapOrKickstartError() {
        let plistURL = temporaryPlistURL()
        let agentURL = plistURL.deletingLastPathComponent().appendingPathComponent("ShitsuraeAgent")
        try? "binary".write(to: agentURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentURL.path)
        defer { try? FileManager.default.removeItem(at: plistURL.deletingLastPathComponent()) }

        let bootstrapFail = LaunchAgentController(
            plistURL: plistURL,
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            fileManager: .default,
            processRunner: { _, arguments in
                arguments.first == "bootstrap" ? 1 : 0
            },
            agentExecutableResolver: { agentURL }
        )
        XCTAssertFalse(bootstrapFail.ensureAgentReachable())

        let kickstartFail = LaunchAgentController(
            plistURL: plistURL,
            label: "com.example.agent",
            machServiceName: "com.example.agent.service",
            fileManager: .default,
            processRunner: { _, arguments in
                arguments.first == "kickstart" ? 1 : 0
            },
            agentExecutableResolver: { agentURL }
        )
        XCTAssertFalse(kickstartFail.ensureAgentReachable())
    }

    func testLaunchAgentControllerRunProcessReturnsStatusAndFailureCode() {
        XCTAssertEqual(LaunchAgentController.runProcess(executable: "/usr/bin/true", arguments: []), 0)
        XCTAssertEqual(LaunchAgentController.runProcess(executable: "/path/to/missing", arguments: []), -1)
    }

    func testResolveAgentExecutableFindsSiblingBinary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-agent-sibling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let appExecutable = directory.appendingPathComponent("Shitsurae")
        let agentExecutable = directory.appendingPathComponent("ShitsuraeAgent")
        try writeExecutable(at: appExecutable)
        try writeExecutable(at: agentExecutable)

        let resolved = LaunchAgentController.resolveAgentExecutable(
            executablePath: appExecutable.path,
            fileManager: .default
        )
        XCTAssertEqual(resolved?.path, agentExecutable.path)
    }

    func testResolveAgentExecutableFindsResourcesBinaryInsideAppBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve-agent-bundle-\(UUID().uuidString)", isDirectory: true)
        let macOS = root
            .appendingPathComponent("Shitsurae.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let resources = root
            .appendingPathComponent("Shitsurae.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)

        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let appExecutable = macOS.appendingPathComponent("Shitsurae")
        let agentExecutable = resources.appendingPathComponent("ShitsuraeAgent")
        try writeExecutable(at: appExecutable)
        try writeExecutable(at: agentExecutable)

        let resolved = LaunchAgentController.resolveAgentExecutable(
            executablePath: appExecutable.path,
            fileManager: .default
        )
        XCTAssertEqual(resolved?.path, agentExecutable.path)
    }

    private func temporaryPlistURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("com.example.agent.plist")
    }

    private func writeExecutable(at url: URL) throws {
        try "binary".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private final class StubLaunchAgentController: LaunchAgentControlling {
    private let result: Bool

    init(result: Bool) {
        self.result = result
    }

    func ensureAgentReachable() -> Bool {
        result
    }
}

private final class CountingLaunchAgentController: LaunchAgentControlling {
    private let result: Bool
    private(set) var callCount = 0

    init(result: Bool) {
        self.result = result
    }

    func ensureAgentReachable() -> Bool {
        callCount += 1
        return result
    }
}

private final class StubAgentXPCTransport: AgentXPCTransporting {
    private let results: [Result<AgentCommandResponse, AgentTransportFailure>]
    private(set) var executeCallCount = 0

    init(results: [Result<AgentCommandResponse, AgentTransportFailure>]) {
        self.results = results
    }

    func execute(
        _ request: AgentCommandRequest,
        machServiceName _: String,
        timeoutSeconds _: TimeInterval,
        pingTimeoutSeconds _: TimeInterval
    ) -> Result<AgentCommandResponse, AgentTransportFailure> {
        let index = min(executeCallCount, results.count - 1)
        executeCallCount += 1
        return results[index]
    }
}
