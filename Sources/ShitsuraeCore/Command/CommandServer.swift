import Darwin
import Foundation

public enum CommandSocket {
    /// Unix domain socket the GUI app listens on. Lives in the state
    /// directory so CLI and app resolve the same path from the environment.
    public static func socketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        ConfigPathResolver.stateDirectoryURL(environment: environment)
            .appendingPathComponent("shitsurae.sock")
    }
}

/// Newline-delimited JSON over a unix domain socket. One request per
/// connection. Peer authentication = same UID (getpeereid).
///
/// This replaces v1's Agent + XPC + launchctl stack: the GUI app is the
/// single state owner and serves the CLI directly.
public final class CommandServer: @unchecked Sendable {
    private let router: CommandRouter
    private let logger: ShitsuraeLogger
    private let socketURL: URL
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "shitsurae.command-server")

    public init(
        router: CommandRouter,
        logger: ShitsuraeLogger,
        socketURL: URL = CommandSocket.socketURL()
    ) {
        self.router = router
        self.logger = logger
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        stop()

        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error(event: "server.socketFailed", fields: ["errno": errno])
            return false
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maxLength else {
            close(fd)
            logger.error(event: "server.socketPathTooLong", fields: ["path": path])
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(maxLength)))
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            logger.error(event: "server.bindFailed", fields: ["errno": errno, "path": path])
            return false
        }

        // Owner-only access on top of the UID check.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            close(fd)
            logger.error(event: "server.listenFailed", fields: ["errno": errno])
            return false
        }

        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [listenFD = fd] in
            close(listenFD)
        }
        acceptSource = source
        source.resume()

        logger.log(event: "server.started", fields: ["path": path])
        return true
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(socketURL.path)
    }

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else {
            return
        }

        guard Self.peerIsSameUser(fd: clientFD) else {
            logger.log(level: "warn", event: "server.peerRejected", fields: [:])
            close(clientFD)
            return
        }

        let requestData = Self.readRequest(fd: clientFD)
        guard let requestData else {
            close(clientFD)
            return
        }

        Task { [router] in
            let response = await router.handle(requestData: requestData)
            Self.writeAll(fd: clientFD, data: response + Data("\n".utf8))
            close(clientFD)
        }
    }

    static func peerIsSameUser(fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            return false
        }
        return uid == getuid()
    }

    static func readRequest(fd: Int32, maxBytes: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while data.count < maxBytes {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< bytesRead])
            if let last = data.last, last == UInt8(ascii: "\n") {
                break
            }
        }

        guard !data.isEmpty else {
            return nil
        }
        if let last = data.last, last == UInt8(ascii: "\n") {
            data.removeLast()
        }
        return data
    }

    static func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written <= 0 {
                    break
                }
                offset += written
            }
        }
    }
}

public enum CommandClientError: Error, Equatable {
    case serverUnavailable
    case invalidResponse
}

/// CLI-side connector. When the app isn't running it launches it
/// (`open -b`) and retries until the socket answers.
public enum CommandClient {
    public static let appBundleID = "com.yuki-yano.shitsurae"

    public static func send(
        request: CommandRequest,
        socketURL: URL = CommandSocket.socketURL(),
        autoLaunch: Bool = true,
        timeoutSeconds: TimeInterval = 8
    ) throws -> Data {
        let payload = try JSONEncoder().encode(request)

        if let response = try? sendOnce(payload: payload, socketURL: socketURL) {
            return response
        }

        guard autoLaunch else {
            throw CommandClientError.serverUnavailable
        }

        launchApp()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            if let response = try? sendOnce(payload: payload, socketURL: socketURL) {
                return response
            }
        }

        throw CommandClientError.serverUnavailable
    }

    static func sendOnce(payload: Data, socketURL: URL) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CommandClientError.serverUnavailable
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maxLength else {
            throw CommandClientError.serverUnavailable
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(maxLength)))
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw CommandClientError.serverUnavailable
        }

        CommandServer.writeAll(fd: fd, data: payload + Data("\n".utf8))
        shutdown(fd, SHUT_WR)

        guard let response = CommandServer.readRequest(fd: fd, maxBytes: 8 << 20) else {
            throw CommandClientError.invalidResponse
        }
        return response
    }

    static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-b", appBundleID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}
