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
            height: nil,
            stateOnly: true
        )

        let response = executor.execute(request)
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(response.stdout, "ok\n")
        XCTAssertEqual(handler.arrangeCalls.count, 1)
        XCTAssertEqual(handler.arrangeCalls.first?.layoutName, "work")
        XCTAssertEqual(handler.arrangeCalls.first?.spaceID, 2)
        XCTAssertEqual(handler.arrangeCalls.first?.dryRun, true)
        XCTAssertEqual(handler.arrangeCalls.first?.json, true)
        XCTAssertEqual(handler.arrangeCalls.first?.stateOnly, true)
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
        XCTAssertEqual(handler.focusCalls.count, 1)
        XCTAssertEqual(handler.focusCalls.first?.slot, 3)
        XCTAssertNil(handler.focusCalls.first?.target)
    }

    func testExecuteFocusRoutesWindowSelector() {
        let handler = StubCommandHandler()
        handler.focusResult = CommandResult(exitCode: 0)
        let executor = AgentCommandExecutor(commandHandler: handler)

        let request = AgentCommandRequest(
            command: .focus,
            json: nil,
            dryRun: nil,
            verbose: nil,
            layoutName: nil,
            spaceID: nil,
            slot: nil,
            includeAllSpaces: nil,
            x: nil,
            y: nil,
            width: nil,
            height: nil,
            windowID: 42,
            bundleID: nil,
            windowTitle: nil
        )

        let response = executor.execute(request)
        XCTAssertEqual(response.exitCode, 0)
        XCTAssertEqual(handler.focusCalls.count, 1)
        XCTAssertNil(handler.focusCalls.first?.slot)
        XCTAssertEqual(handler.focusCalls.first?.target, WindowTargetSelector(windowID: 42, bundleID: nil, title: nil))
    }

    func testExecuteRoutesBasicCommands() {
        let handler = StubCommandHandler()
        handler.validateResult = CommandResult(exitCode: 11)
        handler.layoutsListResult = CommandResult(exitCode: 0, stdout: "work\n")
        handler.diagnosticsResult = CommandResult(exitCode: 0, stdout: "{ }\n")
        handler.displayListResult = CommandResult(exitCode: 0, stdout: "{ \"displays\": [] }\n")
        handler.displayCurrentResult = CommandResult(exitCode: 40)
        handler.spaceListResult = CommandResult(exitCode: 0, stdout: "{ \"spaces\": [] }\n")
        handler.spaceCurrentResult = CommandResult(exitCode: 40)
        handler.windowCurrentResult = CommandResult(exitCode: 40)
        handler.windowMoveResult = CommandResult(exitCode: 50)
        handler.windowResizeResult = CommandResult(exitCode: 51)
        handler.windowSetResult = CommandResult(exitCode: 0)
        handler.switcherListResult = CommandResult(exitCode: 0)
        let executor = AgentCommandExecutor(commandHandler: handler)

        XCTAssertEqual(executor.execute(request(command: .validate, json: true)).exitCode, 11)
        XCTAssertEqual(executor.execute(request(command: .layoutsList, json: nil)).stdout, "work\n")
        XCTAssertEqual(executor.execute(request(command: .diagnostics, json: true)).exitCode, 0)
        XCTAssertEqual(executor.execute(request(command: .displayList, json: true)).exitCode, 0)
        XCTAssertEqual(executor.execute(request(command: .displayCurrent, json: true)).exitCode, 40)
        XCTAssertEqual(executor.execute(request(command: .spaceList, json: true)).exitCode, 0)
        XCTAssertEqual(executor.execute(request(command: .spaceCurrent, json: true)).exitCode, 40)
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
        XCTAssertEqual(handler.displayListCalls, [true])
        XCTAssertEqual(handler.displayCurrentCalls, [true])
        XCTAssertEqual(handler.spaceListCalls, [true])
        XCTAssertEqual(handler.spaceCurrentCalls, [true])
        XCTAssertEqual(handler.windowCurrentCalls, [true])
        XCTAssertEqual(handler.windowMoveCalls.count, 1)
        XCTAssertNil(handler.windowMoveCalls.first?.target)
        XCTAssertEqual(handler.windowResizeCalls.count, 1)
        XCTAssertNil(handler.windowResizeCalls.first?.target)
        XCTAssertEqual(handler.windowSetCalls.count, 1)
        XCTAssertNil(handler.windowSetCalls.first?.target)
        XCTAssertEqual(handler.switcherListCalls.count, 1)
        XCTAssertEqual(handler.switcherListCalls.first?.0, true)
        XCTAssertEqual(handler.switcherListCalls.first?.1, false)
    }

    func testExecuteRoutesWindowCommandsWithSelector() {
        let handler = StubCommandHandler()
        handler.windowMoveResult = CommandResult(exitCode: 0)
        handler.windowResizeResult = CommandResult(exitCode: 0)
        handler.windowSetResult = CommandResult(exitCode: 0)
        let executor = AgentCommandExecutor(commandHandler: handler)

        let selector = WindowTargetSelector(
            windowID: nil,
            bundleID: "com.apple.TextEdit",
            title: "Draft"
        )

        XCTAssertEqual(
            executor.execute(
                request(
                    command: .windowMove,
                    json: nil,
                    x: .expression("10%"),
                    y: .expression("20%"),
                    bundleID: selector.bundleID,
                    windowTitle: selector.title
                )
            ).exitCode,
            0
        )
        XCTAssertEqual(
            executor.execute(
                request(
                    command: .windowResize,
                    json: nil,
                    width: .expression("50%"),
                    height: .expression("60%"),
                    bundleID: selector.bundleID,
                    windowTitle: selector.title
                )
            ).exitCode,
            0
        )
        XCTAssertEqual(
            executor.execute(
                request(
                    command: .windowSet,
                    json: nil,
                    x: .expression("0%"),
                    y: .expression("0%"),
                    width: .expression("100%"),
                    height: .expression("100%"),
                    bundleID: selector.bundleID,
                    windowTitle: selector.title
                )
            ).exitCode,
            0
        )

        XCTAssertEqual(handler.windowMoveCalls.first?.target, selector)
        XCTAssertEqual(handler.windowResizeCalls.first?.target, selector)
        XCTAssertEqual(handler.windowSetCalls.first?.target, selector)
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
        XCTAssertEqual(
            executor.execute(request(command: .focus, json: nil, slot: nil)).stderr,
            "slot, windowID, or bundleID is required\n"
        )
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
        height: LengthValue? = nil,
        windowID: UInt32? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        stateOnly: Bool? = nil
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
            height: height,
            windowID: windowID,
            bundleID: bundleID,
            windowTitle: windowTitle,
            stateOnly: stateOnly
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
        let stateOnly: Bool
    }

    struct FocusCall: Equatable {
        let slot: Int?
        let target: WindowTargetSelector?
    }

    struct WindowMoveCall: Equatable {
        let target: WindowTargetSelector?
        let x: LengthValue
        let y: LengthValue
    }

    struct WindowResizeCall: Equatable {
        let target: WindowTargetSelector?
        let width: LengthValue
        let height: LengthValue
    }

    struct WindowSetCall: Equatable {
        let target: WindowTargetSelector?
        let x: LengthValue
        let y: LengthValue
        let width: LengthValue
        let height: LengthValue
    }

    var arrangeResult = CommandResult(exitCode: 0)
    var focusResult = CommandResult(exitCode: 0)
    var validateResult = CommandResult(exitCode: 0)
    var layoutsListResult = CommandResult(exitCode: 0)
    var diagnosticsResult = CommandResult(exitCode: 0)
    var displayListResult = CommandResult(exitCode: 0)
    var displayCurrentResult = CommandResult(exitCode: 0)
    var spaceListResult = CommandResult(exitCode: 0)
    var spaceCurrentResult = CommandResult(exitCode: 0)
    var windowCurrentResult = CommandResult(exitCode: 0)
    var windowMoveResult = CommandResult(exitCode: 0)
    var windowResizeResult = CommandResult(exitCode: 0)
    var windowSetResult = CommandResult(exitCode: 0)
    var switcherListResult = CommandResult(exitCode: 0)

    var arrangeCalls: [ArrangeCall] = []
    var focusCalls: [FocusCall] = []
    var validateCalls: [Bool] = []
    var layoutsListCalls = 0
    var diagnosticsCalls: [Bool] = []
    var displayListCalls: [Bool] = []
    var displayCurrentCalls: [Bool] = []
    var spaceListCalls: [Bool] = []
    var spaceCurrentCalls: [Bool] = []
    var windowCurrentCalls: [Bool] = []
    var windowMoveCalls: [WindowMoveCall] = []
    var windowResizeCalls: [WindowResizeCall] = []
    var windowSetCalls: [WindowSetCall] = []
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

    func displayList(json: Bool) -> CommandResult {
        displayListCalls.append(json)
        return displayListResult
    }

    func displayCurrent(json: Bool) -> CommandResult {
        displayCurrentCalls.append(json)
        return displayCurrentResult
    }

    func spaceList(json: Bool) -> CommandResult {
        spaceListCalls.append(json)
        return spaceListResult
    }

    func spaceCurrent(json: Bool) -> CommandResult {
        spaceCurrentCalls.append(json)
        return spaceCurrentResult
    }

    func windowCurrent(json: Bool) -> CommandResult {
        windowCurrentCalls.append(json)
        return windowCurrentResult
    }

    func windowMove(target: WindowTargetSelector?, x: LengthValue, y: LengthValue) -> CommandResult {
        windowMoveCalls.append(.init(target: target, x: x, y: y))
        return windowMoveResult
    }

    func windowResize(target: WindowTargetSelector?, width: LengthValue, height: LengthValue) -> CommandResult {
        windowResizeCalls.append(.init(target: target, width: width, height: height))
        return windowResizeResult
    }

    func windowSet(target: WindowTargetSelector?, x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) -> CommandResult {
        windowSetCalls.append(.init(target: target, x: x, y: y, width: width, height: height))
        return windowSetResult
    }

    func switcherList(json: Bool, includeAllSpacesOverride: Bool?) -> CommandResult {
        switcherListCalls.append((json, includeAllSpacesOverride))
        return switcherListResult
    }

    func arrange(layoutName: String, spaceID: Int?, dryRun: Bool, verbose: Bool, json: Bool, stateOnly: Bool) -> CommandResult {
        arrangeCalls.append(.init(layoutName: layoutName, spaceID: spaceID, dryRun: dryRun, verbose: verbose, json: json, stateOnly: stateOnly))
        return arrangeResult
    }

    func focus(slot: Int?, target: WindowTargetSelector?) -> CommandResult {
        focusCalls.append(.init(slot: slot, target: target))
        return focusResult
    }
}
