import Foundation
import XCTest
@testable import ShitsuraeCore

final class RemoteCommandServiceTests: XCTestCase {
    func testArrangeUsesAgentRequestWithConfigDirectoryPath() throws {
        let client = RecordingRemoteCommandClient(result: CommandResult(exitCode: 0, stdout: "ok\n"))
        let service = RemoteCommandService(
            client: client,
            configDirectoryPathProvider: { "/tmp/shitsurae-config" }
        )

        let result = service.arrange(layoutName: "default", spaceID: 2, dryRun: false, verbose: false, json: false)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "ok\n")

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.command, .arrange)
        XCTAssertEqual(request.layoutName, "default")
        XCTAssertEqual(request.spaceID, 2)
        XCTAssertEqual(request.dryRun, false)
        XCTAssertEqual(request.verbose, false)
        XCTAssertEqual(request.json, false)
        XCTAssertEqual(request.configDirectoryPath, "/tmp/shitsurae-config")
    }

    func testArrangeForwardsFlagsToAgentRequest() throws {
        let client = RecordingRemoteCommandClient(result: CommandResult(exitCode: 0))
        let service = RemoteCommandService(
            client: client,
            configDirectoryPathProvider: { "/tmp/config" }
        )

        _ = service.arrange(layoutName: "work", spaceID: nil, dryRun: true, verbose: true, json: true)

        let request = try XCTUnwrap(client.requests.first)
        XCTAssertEqual(request.layoutName, "work")
        XCTAssertEqual(request.dryRun, true)
        XCTAssertEqual(request.verbose, true)
        XCTAssertEqual(request.json, true)
    }
}

private final class RecordingRemoteCommandClient: RemoteCommandExecuting {
    private let result: CommandResult
    private(set) var requests: [AgentCommandRequest] = []

    init(result: CommandResult) {
        self.result = result
    }

    func execute(_ request: AgentCommandRequest) -> CommandResult {
        requests.append(request)
        return result
    }
}
