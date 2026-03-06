import XCTest
@testable import ShitsuraeCore

final class AgentCommandExecutorTests: XCTestCase {
    func testExecuteArrangeRoutesToCommandService() {
        let handler = StubCommandHandler()
        handler.arrangeResult = CommandResult(exitCode: 0, stdout: "ok\n", stderr: "")
        let executor = AgentCommandExecutor(commandHandler: handler)

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
            height: nil
        )

        let response = executor.execute(request)
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(response.stdout, "ok\n")
        XCTAssertEqual(handler.arrangeCalls.count, 1)
        XCTAssertEqual(handler.arrangeCalls.first?.layoutName, "work")
        XCTAssertEqual(handler.arrangeCalls.first?.spaceID, 2)
        XCTAssertEqual(handler.arrangeCalls.first?.dryRun, true)
        XCTAssertEqual(handler.arrangeCalls.first?.json, true)
    }

    func testExecuteFocusRoutesSlot() {
        let handler = StubCommandHandler()
        handler.focusResult = CommandResult(exitCode: 0)
        let executor = AgentCommandExecutor(commandHandler: handler)

        let request = AgentCommandRequest(
            command: .focus,
            json: nil,
            dryRun: nil,
            verbose: nil,
            layoutName: nil,
            slot: 3,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil
        )

        let response = executor.execute(request)
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(handler.focusCalls, [3])
    }

    func testExecuteRoutesBasicCommands() {
        let handler = StubCommandHandler()
        handler.validateResult = CommandResult(exitCode: 11)
        handler.layoutsListResult = CommandResult(exitCode: 0, stdout: "work\n")
        handler.diagnosticsResult = CommandResult(exitCode: 0, stdout: "{ }\n")
        handler.windowCurrentResult = CommandResult(exitCode: 40)
        handler.windowMoveResult = CommandResult(exitCode: 50)
        handler.windowResizeResult = CommandResult(exitCode: 51)
        handler.windowSetResult = CommandResult(exitCode: 0)
        handler.switcherListResult = CommandResult(exitCode: 0)
        let executor = AgentCommandExecutor(commandHandler: handler)

        XCTAssertEqual(executor.execute(request(command: .validate, json: true)).exitCode, 11)
        XCTAssertEqual(executor.execute(request(command: .layoutsList, json: nil)).stdout, "work\n")
        XCTAssertEqual(executor.execute(request(command: .diagnostics, json: true)).exitCode, 0)
        XCTAssertEqual(executor.execute(request(command: .windowCurrent, json: true)).exitCode, 40)
        XCTAssertEqual(
            executor.execute(
                request(command: .windowMove, json: nil, x: .expression("10%"), y: .expression("20%"))
            ).exitCode,
            50
        )
        XCTAssertEqual(
            executor.execute(
                request(command: .windowResize, json: nil, width: .expression("50%"), height: .expression("60%"))
            ).exitCode,
            51
        )
        XCTAssertEqual(
            executor.execute(
                request(
                    command: .windowSet,
                    json: nil,
                    x: .expression("0%"),
                    y: .expression("0%"),
                    width: .expression("100%"),
                    height: .expression("100%")
                )
            ).exitCode,
            0
        )
        XCTAssertEqual(
            executor.execute(request(command: .switcherList, json: true, includeAllSpaces: false)).exitCode,
            0
        )

        XCTAssertEqual(handler.validateCalls, [true])
        XCTAssertEqual(handler.layoutsListCalls, 1)
        XCTAssertEqual(handler.diagnosticsCalls, [true])
        XCTAssertEqual(handler.windowCurrentCalls, [true])
        XCTAssertEqual(handler.windowMoveCalls.count, 1)
        XCTAssertEqual(handler.windowResizeCalls.count, 1)
        XCTAssertEqual(handler.windowSetCalls.count, 1)
        XCTAssertEqual(handler.switcherListCalls.count, 1)
        XCTAssertEqual(handler.switcherListCalls.first?.0, true)
        XCTAssertEqual(handler.switcherListCalls.first?.1, false)
    }

    func testExecuteReturnsValidationErrorWhenRequiredFieldsMissing() {
        let executor = AgentCommandExecutor(commandHandler: StubCommandHandler())

        XCTAssertEqual(
            executor.execute(request(command: .arrange, json: nil, layoutName: nil)).stderr,
            "layoutName is required\n"
        )
        XCTAssertEqual(
            executor.execute(request(command: .windowMove, json: nil, x: .expression("1%"), y: nil)).stderr,
            "x and y are required\n"
        )
        XCTAssertEqual(
            executor.execute(request(command: .windowResize, json: nil, width: .expression("1%"), height: nil)).stderr,
            "width and height are required\n"
        )
        XCTAssertEqual(
            executor.execute(
                request(command: .windowSet, json: nil, x: .expression("1%"), y: .expression("1%"), width: nil, height: .expression("1%"))
            ).stderr,
            "x,y,width,height are required\n"
        )
        XCTAssertEqual(executor.execute(request(command: .focus, json: nil, slot: nil)).stderr, "slot is required\n")
    }

    private func request(
        command: AgentCommand,
        json: Bool?,
        layoutName: String? = nil,
        spaceID: Int? = nil,
        slot: Int? = nil,
        includeAllSpaces: Bool? = nil,
        x: LengthValue? = nil,
        y: LengthValue? = nil,
        width: LengthValue? = nil,
        height: LengthValue? = nil
    ) -> AgentCommandRequest {
        AgentCommandRequest(
            command: command,
            json: json,
            dryRun: false,
            verbose: false,
            layoutName: layoutName,
            spaceID: spaceID,
            slot: slot,
            includeAllSpaces: includeAllSpaces,
            x: x,
            y: y,
            width: width,
            height: height
        )
    }
}

private final class StubCommandHandler: CommandHandling {
    struct ArrangeCall {
        let layoutName: String
        let spaceID: Int?
        let dryRun: Bool
        let verbose: Bool
        let json: Bool
    }

    var arrangeResult = CommandResult(exitCode: 0)
    var focusResult = CommandResult(exitCode: 0)
    var validateResult = CommandResult(exitCode: 0)
    var layoutsListResult = CommandResult(exitCode: 0)
    var diagnosticsResult = CommandResult(exitCode: 0)
    var windowCurrentResult = CommandResult(exitCode: 0)
    var windowMoveResult = CommandResult(exitCode: 0)
    var windowResizeResult = CommandResult(exitCode: 0)
    var windowSetResult = CommandResult(exitCode: 0)
    var switcherListResult = CommandResult(exitCode: 0)

    var arrangeCalls: [ArrangeCall] = []
    var focusCalls: [Int] = []
    var validateCalls: [Bool] = []
    var layoutsListCalls = 0
    var diagnosticsCalls: [Bool] = []
    var windowCurrentCalls: [Bool] = []
    var windowMoveCalls: [(LengthValue, LengthValue)] = []
    var windowResizeCalls: [(LengthValue, LengthValue)] = []
    var windowSetCalls: [(LengthValue, LengthValue, LengthValue, LengthValue)] = []
    var switcherListCalls: [(Bool, Bool?)] = []

    func validate(json: Bool) -> CommandResult {
        validateCalls.append(json)
        return validateResult
    }

    func layoutsList() -> CommandResult {
        layoutsListCalls += 1
        return layoutsListResult
    }

    func diagnostics(json: Bool) -> CommandResult {
        diagnosticsCalls.append(json)
        return diagnosticsResult
    }

    func windowCurrent(json: Bool) -> CommandResult {
        windowCurrentCalls.append(json)
        return windowCurrentResult
    }

    func windowMove(x: LengthValue, y: LengthValue) -> CommandResult {
        windowMoveCalls.append((x, y))
        return windowMoveResult
    }

    func windowResize(width: LengthValue, height: LengthValue) -> CommandResult {
        windowResizeCalls.append((width, height))
        return windowResizeResult
    }

    func windowSet(x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) -> CommandResult {
        windowSetCalls.append((x, y, width, height))
        return windowSetResult
    }

    func switcherList(json: Bool, includeAllSpacesOverride: Bool?) -> CommandResult {
        switcherListCalls.append((json, includeAllSpacesOverride))
        return switcherListResult
    }

    func arrange(layoutName: String, spaceID: Int?, dryRun: Bool, verbose: Bool, json: Bool) -> CommandResult {
        arrangeCalls.append(.init(layoutName: layoutName, spaceID: spaceID, dryRun: dryRun, verbose: verbose, json: json))
        return arrangeResult
    }

    func focus(slot: Int) -> CommandResult {
        focusCalls.append(slot)
        return focusResult
    }
}
