import Foundation
import ShitsuraeCore
import Testing
@testable import ShitsuraeCLI

@Suite("CLI request mapping")
struct RequestMappingTests {
    private let selector = CLIWindowSelector(
        windowID: 42,
        pid: 314,
        processStartTime: 2_718,
        bundleID: "com.example.Editor",
        title: "Document"
    )

    @Test func arrangeMapsEveryOption() {
        let request = CLIRequestBuilder.arrange(
            layouts: ["work", "calendar"],
            dryRun: true,
            stateOnly: true,
            spaceID: 3
        )

        #expect(request.command == "arrange")
        #expect(request.layouts == ["work", "calendar"])
        #expect(request.dryRun == true)
        #expect(request.stateOnly == true)
        #expect(request.spaceID == 3)
    }

    @Test func disabledArrangeFlagsRemainAbsent() {
        let request = CLIRequestBuilder.arrange(
            layouts: ["work"],
            dryRun: false,
            stateOnly: false,
            spaceID: nil
        )

        #expect(request.dryRun == nil)
        #expect(request.stateOnly == nil)
        #expect(request.spaceID == nil)
    }

    @Test func arrangeCommandParsesMultipleLayouts() throws {
        let command = try Arrange.parse(["work", "calendar", "--json"])

        #expect(command.layouts == ["work", "calendar"])
        #expect(command.jsonFlag.json)
    }

    @Test func arrangeCommandRejectsSingleLayoutOptionsInBatch() {
        #expect(throws: Error.self) {
            _ = try Arrange.parse(["work", "calendar", "--space", "2"])
        }
    }

    @Test func spaceCommandsMapEveryOption() {
        let listRequest = CLIRequestBuilder.spaceQuery(command: "spaceList", layout: "calendar")
        let currentRequest = CLIRequestBuilder.spaceQuery(command: "spaceCurrent", layout: nil)
        let switchRequest = CLIRequestBuilder.spaceSwitch(
            spaceID: 7,
            layout: nil,
            monitor: "research",
            focus: .preserve,
            reconcile: true
        )
        let recoverRequest = CLIRequestBuilder.spaceRecover()

        #expect(listRequest.command == "spaceList")
        #expect(listRequest.layout == "calendar")
        #expect(currentRequest.command == "spaceCurrent")
        #expect(currentRequest.layout == nil)
        #expect(switchRequest.command == "spaceSwitch")
        #expect(switchRequest.spaceID == 7)
        #expect(switchRequest.layout == nil)
        #expect(switchRequest.monitor == "research")
        #expect(switchRequest.focus == .preserve)
        #expect(switchRequest.reconcile == true)
        #expect(recoverRequest.command == "spaceRecover")
        #expect(recoverRequest.forceClearPending == true)
    }

    @Test func spaceCommandsParseLayoutSelector() throws {
        let list = try Space.List.parse(["--layout", "calendar"])
        let current = try Space.Current.parse(["--layout", "calendar"])
        let switchCommand = try Space.Switch.parse(["2", "--layout", "calendar", "--reconcile"])

        #expect(list.layout == "calendar")
        #expect(current.layout == "calendar")
        #expect(switchCommand.layout == "calendar")
        #expect(switchCommand.spaceID == 2)
        #expect(switchCommand.reconcile)
    }

    @Test func spaceSwitchParsesMonitorAndFocusPolicy() throws {
        let command = try Space.Switch.parse([
            "2",
            "--monitor", "research",
            "--focus", "preserve",
        ])

        #expect(command.monitor == "research")
        #expect(command.focus == "preserve")
    }

    @Test(arguments: [
        "windowWorkspace",
        "windowMove",
        "windowResize",
        "windowSet",
    ])
    func windowCommandsMapGeometryAndSelector(command: String) {
        let request = CLIRequestBuilder.window(
            command: command,
            selector: selector,
            spaceID: 5,
            x: "10pt",
            y: "20pt",
            width: "60%",
            height: "40%"
        )

        #expect(request.command == command)
        #expect(request.spaceID == 5)
        #expect(request.x == "10pt")
        #expect(request.y == "20pt")
        #expect(request.width == "60%")
        #expect(request.height == "40%")
        expectSelector(request)
    }

    @Test func focusMapsSlotAndSelector() {
        let request = CLIRequestBuilder.focus(slot: 8, selector: selector)

        #expect(request.command == "focus")
        #expect(request.slot == 8)
        expectSelector(request)
    }

    @Test func switcherMapsAllSpacesFlagExplicitly() {
        let request = CLIRequestBuilder.switcherList(includeAllSpaces: true)

        #expect(request.command == "switcherList")
        #expect(request.includeAllSpaces == true)
    }

    private func expectSelector(_ request: CommandRequest) {
        #expect(request.windowID == selector.windowID)
        #expect(request.pid == selector.pid)
        #expect(request.processStartTime == selector.processStartTime)
        #expect(request.bundleID == selector.bundleID)
        #expect(request.title == selector.title)
    }
}

@Suite("CLI error formatting")
struct CLIErrorFormattingTests {
    @Test func jsonErrorsUseTheWireErrorSchemaOnStandardOutput() throws {
        let output = CLIOutputFormatter.error(
            code: .backendUnavailable,
            message: "app unavailable",
            json: true
        )
        let decoded = try JSONDecoder().decode(CommonErrorJSON.self, from: output.standardOutput)

        #expect(decoded.schemaVersion == 2)
        #expect(decoded.code == ErrorCode.backendUnavailable.rawValue)
        #expect(decoded.message == "app unavailable")
        #expect(decoded.subcode == nil)
        #expect(!decoded.requestID.isEmpty)
        #expect(output.standardOutput.last == Character("\n").asciiValue)
        #expect(output.standardError.isEmpty)
    }

    @Test func humanReadableErrorsUseStandardError() {
        let output = CLIOutputFormatter.error(
            code: .ipcCommunicationError,
            message: "socket closed",
            json: false
        )

        #expect(output.standardOutput.isEmpty)
        #expect(String(decoding: output.standardError, as: UTF8.self) == "error: socket closed\n")
    }
}
