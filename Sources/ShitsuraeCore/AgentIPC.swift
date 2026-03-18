import Foundation

public enum AgentCommand: String, Codable {
    case arrange
    case layoutsList
    case validate
    case diagnostics
    case displayList
    case displayCurrent
    case spaceList
    case spaceCurrent
    case spaceSwitch
    case spaceRecover
    case windowCurrent
    case windowWorkspace
    case windowMove
    case windowResize
    case windowSet
    case focus
    case switcherList
}

public struct AgentCommandRequest: Codable {
    public let command: AgentCommand
    public let json: Bool?
    public let dryRun: Bool?
    public let verbose: Bool?
    public let layoutName: String?
    public let spaceID: Int?
    public let slot: Int?
    public let includeAllSpaces: Bool?
    public let x: LengthValue?
    public let y: LengthValue?
    public let width: LengthValue?
    public let height: LengthValue?
    public let windowID: UInt32?
    public let bundleID: String?
    public let windowTitle: String?
    public let configDirectoryPath: String?
    public let stateOnly: Bool?
    public let reconcile: Bool?
    public let forceClearPending: Bool?
    public let confirm: Bool?

    public init(
        command: AgentCommand,
        json: Bool? = nil,
        dryRun: Bool? = nil,
        verbose: Bool? = nil,
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
        configDirectoryPath: String? = nil,
        stateOnly: Bool? = nil,
        reconcile: Bool? = nil,
        forceClearPending: Bool? = nil,
        confirm: Bool? = nil
    ) {
        self.command = command
        self.json = json
        self.dryRun = dryRun
        self.verbose = verbose
        self.layoutName = layoutName
        self.spaceID = spaceID
        self.slot = slot
        self.includeAllSpaces = includeAllSpaces
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.windowID = windowID
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.configDirectoryPath = configDirectoryPath
        self.stateOnly = stateOnly
        self.reconcile = reconcile
        self.forceClearPending = forceClearPending
        self.confirm = confirm
    }

    public func withConfigDirectoryPath(_ path: String?) -> AgentCommandRequest {
        AgentCommandRequest(
            command: command,
            json: json,
            dryRun: dryRun,
            verbose: verbose,
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
            configDirectoryPath: path,
            stateOnly: stateOnly,
            reconcile: reconcile,
            forceClearPending: forceClearPending,
            confirm: confirm
        )
    }
}

public struct AgentCommandResponse: Codable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum AgentXPCConstants {
    public static let machServiceName = "com.yuki-yano.shitsurae.agent"
    public static let launchAgentLabel = "com.yuki-yano.shitsurae.agent"

    public static var launchAgentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }
}

public enum AgentXPCSubcode {
    public static let connectionFailed = "xpc.connectionFailed"
    public static let clientNotAllowed = "xpc.clientNotAllowed"
    public static let timedOut = "xpc.timedOut"
}

@objc public protocol ShitsuraeAgentXPCProtocol {
    func execute(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
    func ping(withReply reply: @escaping (Bool) -> Void)
}
