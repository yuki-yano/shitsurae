import Foundation
import Darwin

public final class AgentXPCServer: NSObject {
    private let listener: NSXPCListener
    private let listenerDelegate: AgentXPCListenerDelegate

    public init(
        machServiceName: String = AgentXPCConstants.machServiceName,
        executor: AgentCommandExecutor = AgentCommandExecutor(),
        authService: XPCAuthService = XPCAuthService()
    ) {
        listener = NSXPCListener(machServiceName: machServiceName)
        listenerDelegate = AgentXPCListenerDelegate(executor: executor, authService: authService)
        super.init()
        listener.delegate = listenerDelegate
    }

    public func start() {
        listener.resume()
    }
}

private final class AgentXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let executor: AgentCommandExecutor
    private let authService: XPCAuthService

    init(executor: AgentCommandExecutor, authService: XPCAuthService) {
        self.executor = executor
        self.authService = authService
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ShitsuraeAgentXPCProtocol.self)
        newConnection.exportedObject = AgentXPCService(executor: executor, authService: authService)
        newConnection.resume()
        return true
    }
}

private final class AgentXPCService: NSObject, ShitsuraeAgentXPCProtocol {
    private let executor: AgentCommandExecutor
    private let authService: XPCAuthService

    init(executor: AgentCommandExecutor, authService: XPCAuthService) {
        self.executor = executor
        self.authService = authService
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        guard let connection = NSXPCConnection.current() else {
            reply(false)
            return
        }
        reply(authService.authorize(connection: connection))
    }

    func execute(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let connection = NSXPCConnection.current(),
              authService.authorize(connection: connection)
        else {
            reply(nil, AgentXPCSubcode.clientNotAllowed)
            return
        }

        guard let request = try? JSONDecoder().decode(AgentCommandRequest.self, from: requestData) else {
            let response = AgentCommandResponse(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stdout: "",
                stderr: "invalid xpc request payload\n"
            )
            let encoded = try? JSONEncoder().encode(response)
            reply(encoded, nil)
            return
        }

        let response = executor.execute(request)
        let encoded = try? JSONEncoder().encode(response)
        reply(encoded, nil)
    }
}

public final class AgentXPCClient {
    static let defaultTimeoutSeconds: TimeInterval = 5.0
    static let defaultArrangeTimeoutSeconds: TimeInterval = 120.0

    private let machServiceName: String
    private let timeoutSeconds: TimeInterval
    private let usesDefaultTimeout: Bool
    private let launchAgentController: LaunchAgentControlling
    private let transport: AgentXPCTransporting

    public convenience init(
        machServiceName: String = AgentXPCConstants.machServiceName,
        timeoutSeconds: TimeInterval = 5.0,
        launchAgentController: LaunchAgentControlling? = nil
    ) {
        self.init(
            machServiceName: machServiceName,
            timeoutSeconds: timeoutSeconds,
            launchAgentController: launchAgentController,
            transport: AgentXPCTransport()
        )
    }

    init(
        machServiceName: String = AgentXPCConstants.machServiceName,
        timeoutSeconds: TimeInterval = 5.0,
        launchAgentController: LaunchAgentControlling? = nil,
        transport: AgentXPCTransporting
    ) {
        self.machServiceName = machServiceName
        self.timeoutSeconds = timeoutSeconds
        self.usesDefaultTimeout = timeoutSeconds == AgentXPCClient.defaultTimeoutSeconds
        self.launchAgentController = launchAgentController ?? LaunchAgentController()
        self.transport = transport
    }

    public func execute(_ request: AgentCommandRequest) -> CommandResult {
        let first = executeOnce(request)
        switch first {
        case let .success(response):
            return CommandResult(exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
        case let .failure(failure):
            if shouldRetry(after: failure), launchAgentIfPossible() {
                let second = executeOnce(request)
                switch second {
                case let .success(response):
                    return CommandResult(exitCode: response.exitCode, stdout: response.stdout, stderr: response.stderr)
                case let .failure(retryFailure):
                    return transportError(for: retryFailure, expectsJSON: request.json ?? false)
                }
            }
            return transportError(for: failure, expectsJSON: request.json ?? false)
        }
    }

    func timeoutSeconds(for request: AgentCommandRequest) -> TimeInterval {
        if usesDefaultTimeout, request.command == .arrange {
            return AgentXPCClient.defaultArrangeTimeoutSeconds
        }
        return timeoutSeconds
    }

    private func executeOnce(_ request: AgentCommandRequest) -> Result<AgentCommandResponse, AgentTransportFailure> {
        transport.execute(
            request,
            machServiceName: machServiceName,
            timeoutSeconds: timeoutSeconds(for: request),
            pingTimeoutSeconds: timeoutSeconds
        )
    }

    private func transportError(for failure: AgentTransportFailure, expectsJSON: Bool) -> CommandResult {
        if expectsJSON {
            let payload = CommonErrorJSON(
                code: .xpcCommunicationError,
                message: failure.message,
                subcode: failure.subcode
            )
            let data = (try? JSONEncoder.pretty.encode(payload)) ?? Data("{}".utf8)
            let text = String(decoding: data, as: UTF8.self) + "\n"
            return CommandResult(
                exitCode: Int32(ErrorCode.xpcCommunicationError.rawValue),
                stdout: "",
                stderr: text
            )
        }

        return CommandResult(
            exitCode: Int32(ErrorCode.xpcCommunicationError.rawValue),
            stdout: "",
            stderr: "\(failure.message) (\(failure.subcode))\n"
        )
    }

    private func shouldRetry(after failure: AgentTransportFailure) -> Bool {
        failure == .connectionFailed
    }

    @discardableResult
    private func launchAgentIfPossible() -> Bool {
        launchAgentController.ensureAgentReachable()
    }
}

protocol AgentXPCTransporting {
    func execute(
        _ request: AgentCommandRequest,
        machServiceName: String,
        timeoutSeconds: TimeInterval,
        pingTimeoutSeconds: TimeInterval
    ) -> Result<AgentCommandResponse, AgentTransportFailure>
}

final class AgentXPCTransport: AgentXPCTransporting {
    func execute(
        _ request: AgentCommandRequest,
        machServiceName: String,
        timeoutSeconds: TimeInterval,
        pingTimeoutSeconds: TimeInterval
    ) -> Result<AgentCommandResponse, AgentTransportFailure> {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: ShitsuraeAgentXPCProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        switch ping(connection, timeoutSeconds: pingTimeoutSeconds) {
        case .success:
            break
        case let .failure(error):
            return .failure(error)
        }

        guard let requestData = try? JSONEncoder().encode(request) else {
            return .success(
                AgentCommandResponse(
                    exitCode: Int32(ErrorCode.validationError.rawValue),
                    stdout: "",
                    stderr: "failed to encode xpc request\n"
                )
            )
        }

        let executeSemaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var resultData: Data?
        var transportSubcode: String?
        var connectionFailed = false

        guard let executeProxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard resultData == nil, transportSubcode == nil else {
                return
            }
            connectionFailed = true
            executeSemaphore.signal()
        }) as? ShitsuraeAgentXPCProtocol else {
            return .failure(.connectionFailed)
        }

        executeProxy.execute(requestData) { data, subcode in
            stateLock.lock()
            resultData = data
            transportSubcode = subcode
            stateLock.unlock()
            executeSemaphore.signal()
        }

        if executeSemaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            return .failure(.timedOut)
        }

        stateLock.lock()
        let receivedData = resultData
        let receivedSubcode = transportSubcode
        let didConnectionFail = connectionFailed
        stateLock.unlock()

        if didConnectionFail {
            return .failure(.connectionFailed)
        }

        if let receivedSubcode {
            if receivedSubcode == AgentXPCSubcode.clientNotAllowed {
                return .failure(.clientNotAllowed)
            }
            return .failure(.connectionFailed)
        }

        guard let receivedData,
              let response = try? JSONDecoder().decode(AgentCommandResponse.self, from: receivedData)
        else {
            return .failure(.connectionFailed)
        }

        return .success(response)
    }

    private func ping(
        _ connection: NSXPCConnection,
        timeoutSeconds: TimeInterval
    ) -> Result<Void, AgentTransportFailure> {
        let semaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var authorizationGranted: Bool?
        var connectionFailed = false

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            stateLock.lock()
            defer { stateLock.unlock() }
            guard authorizationGranted == nil else {
                return
            }
            connectionFailed = true
            semaphore.signal()
        }) as? ShitsuraeAgentXPCProtocol else {
            return .failure(.connectionFailed)
        }

        proxy.ping { granted in
            stateLock.lock()
            authorizationGranted = granted
            stateLock.unlock()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            return .failure(.connectionFailed)
        }

        stateLock.lock()
        let didConnectionFail = connectionFailed
        let granted = authorizationGranted
        stateLock.unlock()

        if didConnectionFail {
            return .failure(.connectionFailed)
        }

        guard let granted else {
            return .failure(.connectionFailed)
        }

        if !granted {
            return .failure(.clientNotAllowed)
        }

        return .success(())
    }
}

enum AgentTransportFailure: Error, Equatable {
    case connectionFailed
    case clientNotAllowed
    case timedOut

    var subcode: String {
        switch self {
        case .connectionFailed:
            return AgentXPCSubcode.connectionFailed
        case .clientNotAllowed:
            return AgentXPCSubcode.clientNotAllowed
        case .timedOut:
            return AgentXPCSubcode.timedOut
        }
    }

    var message: String {
        switch self {
        case .connectionFailed:
            return "xpc communication failed"
        case .clientNotAllowed:
            return "xpc client not allowed"
        case .timedOut:
            return "xpc request timed out"
        }
    }
}

public protocol LaunchAgentControlling {
    @discardableResult
    func ensureAgentReachable() -> Bool
}

struct LaunchAgentPlist {
    let label: String
    let machServiceName: String
    let executablePath: String

    func propertyList() -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath],
            "MachServices": [machServiceName: true],
            "LimitLoadToSessionType": ["Aqua"],
            "ProcessType": "Interactive",
        ]
    }

    func encodedData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: propertyList(),
            format: .xml,
            options: 0
        )
    }
}

final class LaunchAgentController: LaunchAgentControlling {
    private let plistURL: URL
    private let label: String
    private let machServiceName: String
    private let fileManager: FileManager
    private let processRunner: (String, [String]) -> Int32
    private let agentExecutableResolver: () -> URL?

    init(
        plistURL: URL = AgentXPCConstants.launchAgentPlistURL,
        label: String = AgentXPCConstants.launchAgentLabel,
        machServiceName: String = AgentXPCConstants.machServiceName,
        fileManager: FileManager = .default,
        processRunner: @escaping (String, [String]) -> Int32 = LaunchAgentController.runProcess,
        agentExecutableResolver: (() -> URL?)? = nil
    ) {
        self.plistURL = plistURL
        self.label = label
        self.machServiceName = machServiceName
        self.fileManager = fileManager
        self.processRunner = processRunner
        self.agentExecutableResolver = agentExecutableResolver
            ?? { LaunchAgentController.resolveAgentExecutable(fileManager: fileManager) }
    }

    @discardableResult
    func ensureAgentReachable() -> Bool {
        guard let agentURL = agentExecutableResolver() else {
            return false
        }

        guard writeLaunchAgentPlist(agentExecutablePath: agentURL.path) else {
            return false
        }

        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"

        _ = processRunner("/bin/launchctl", ["bootout", service])

        let bootstrap = processRunner("/bin/launchctl", ["bootstrap", domain, plistURL.path])
        guard bootstrap == 0 else {
            return false
        }

        let kickstart = processRunner("/bin/launchctl", ["kickstart", "-k", service])
        if kickstart != 0 {
            return false
        }

        return true
    }

    private func writeLaunchAgentPlist(agentExecutablePath: String) -> Bool {
        let directory = plistURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let plist = LaunchAgentPlist(
                label: label,
                machServiceName: machServiceName,
                executablePath: agentExecutablePath
            )
            let data = try plist.encodedData()
            try data.write(to: plistURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func resolveAgentExecutable(fileManager: FileManager) -> URL? {
        resolveAgentExecutable(
            executablePath: CommandLine.arguments[0],
            fileManager: fileManager
        )
    }

    static func resolveAgentExecutable(executablePath: String, fileManager: FileManager) -> URL? {
        let executable = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent()
        let contentsDirectory = directory.deletingLastPathComponent()
        let candidates = [
            directory.appendingPathComponent("ShitsuraeAgent"),
            contentsDirectory.appendingPathComponent("ShitsuraeAgent"),
            contentsDirectory
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ShitsuraeAgent"),
        ]

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    static func runProcess(executable: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
