import Foundation

public protocol CommandHandling {
    func validate(json: Bool) -> CommandResult
    func layoutsList() -> CommandResult
    func diagnostics(json: Bool) -> CommandResult
    func arrange(layoutName: String, spaceID: Int?, dryRun: Bool, verbose: Bool, json: Bool) -> CommandResult
    func windowCurrent(json: Bool) -> CommandResult
    func windowMove(x: LengthValue, y: LengthValue) -> CommandResult
    func windowResize(width: LengthValue, height: LengthValue) -> CommandResult
    func windowSet(x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) -> CommandResult
    func focus(slot: Int) -> CommandResult
    func switcherList(json: Bool, includeAllSpacesOverride: Bool?) -> CommandResult
}

extension CommandService: CommandHandling {}

public final class AgentCommandExecutor {
    private let commandHandler: CommandHandling

    public init(commandHandler: CommandHandling = CommandService(enableAutoReloadMonitor: true)) {
        self.commandHandler = commandHandler
    }

    public func execute(_ request: AgentCommandRequest) -> AgentCommandResponse {
        let commandHandler = resolvedCommandHandler(for: request)
        let result: CommandResult

        switch request.command {
        case .arrange:
            guard let layoutName = request.layoutName else {
                return asResponse(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "layoutName is required\n"))
            }
            result = commandHandler.arrange(
                layoutName: layoutName,
                spaceID: request.spaceID,
                dryRun: request.dryRun ?? false,
                verbose: request.verbose ?? false,
                json: request.json ?? false
            )
        case .layoutsList:
            result = commandHandler.layoutsList()
        case .validate:
            result = commandHandler.validate(json: request.json ?? false)
        case .diagnostics:
            result = commandHandler.diagnostics(json: request.json ?? false)
        case .windowCurrent:
            result = commandHandler.windowCurrent(json: request.json ?? false)
        case .windowMove:
            guard let x = request.x, let y = request.y else {
                return asResponse(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "x and y are required\n"))
            }
            result = commandHandler.windowMove(x: x, y: y)
        case .windowResize:
            guard let width = request.width, let height = request.height else {
                return asResponse(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "width and height are required\n"))
            }
            result = commandHandler.windowResize(width: width, height: height)
        case .windowSet:
            guard let x = request.x, let y = request.y, let width = request.width, let height = request.height else {
                return asResponse(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "x,y,width,height are required\n"))
            }
            result = commandHandler.windowSet(x: x, y: y, width: width, height: height)
        case .focus:
            guard let slot = request.slot else {
                return asResponse(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "slot is required\n"))
            }
            result = commandHandler.focus(slot: slot)
        case .switcherList:
            result = commandHandler.switcherList(
                json: request.json ?? false,
                includeAllSpacesOverride: request.includeAllSpaces
            )
        }

        return asResponse(result)
    }

    private func asResponse(_ result: CommandResult) -> AgentCommandResponse {
        AgentCommandResponse(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    private func resolvedCommandHandler(for request: AgentCommandRequest) -> CommandHandling {
        guard let path = request.configDirectoryPath,
              !path.isEmpty
        else {
            return commandHandler
        }

        return CommandService(
            enableAutoReloadMonitor: false,
            configDirectoryOverride: URL(fileURLWithPath: path)
        )
    }
}
