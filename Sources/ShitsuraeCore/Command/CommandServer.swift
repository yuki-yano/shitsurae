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
/// connection. Peers must be the same UID AND carry an allowlisted
/// code-signing identity (PeerAuthService).
///
/// This replaces v1's Agent + XPC + launchctl stack: the GUI app is the
/// single state owner and serves the CLI directly.
public final class CommandServer: @unchecked Sendable {
    private let router: CommandRouter
    private let logger: ShitsuraeLogger
    private let socketURL: URL
    private let auth: PeerAuthService
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "shitsurae.command-server")
    private let queueKey = DispatchSpecificKey<Void>()
    private var ownsSocket = false

    public init(
        router: CommandRouter,
        logger: ShitsuraeLogger,
        socketURL: URL = CommandSocket.socketURL(),
        auth: PeerAuthService = PeerAuthService()
    ) {
        self.router = router
        self.logger = logger
        self.socketURL = socketURL
        self.auth = auth
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        performOnQueue {
            startLocked()
        }
    }

    private func startLocked() -> Bool {
        stopLocked()

        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: socketURL.path),
           Self.canConnect(socketURL: socketURL)
        {
            logger.error(event: "server.alreadyRunning", fields: ["path": socketURL.path])
            return false
        }

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
            unlink(socketURL.path)
            logger.error(event: "server.listenFailed", fields: ["errno": errno])
            return false
        }

        listenFD = fd
        ownsSocket = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource = source
        source.resume()

        logger.log(event: "server.started", fields: ["path": path])
        return true
    }

    public func stop() {
        performOnQueue {
            stopLocked()
        }
    }

    private func stopLocked() {
        let shouldUnlink = ownsSocket
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            // The event handler also runs on `queue`, so there can be no
            // concurrent accept here. Close synchronously to prevent a
            // delayed cancel handler from closing a reused descriptor after
            // an immediate restart.
            close(listenFD)
        }
        listenFD = -1
        ownsSocket = false
        if shouldUnlink {
            unlink(socketURL.path)
        }
    }

    static func canConnect(socketURL: URL) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard path.utf8.count <= maxLength else {
            return false
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
        return connectResult == 0
    }

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else {
            return
        }

        // Hand the connection off immediately: auth + read run per
        // connection so one slow client can never stall the accept loop.
        Task.detached { [router, logger, auth] in
            Self.configureTimeouts(fd: clientFD)

            guard auth.authorize(fd: clientFD) else {
                logger.log(level: "warn", event: "server.peerRejected", fields: [:])
                close(clientFD)
                return
            }

            guard case let .data(requestData) = Self.readMessage(fd: clientFD) else {
                close(clientFD)
                return
            }

            let response = await router.handle(requestData: requestData)
            _ = Self.writeAll(fd: clientFD, data: response + Data("\n".utf8))
            close(clientFD)
        }
    }

    @discardableResult
    static func configureTimeouts(fd: Int32, seconds: TimeInterval = 5) -> Bool {
        let clamped = max(0.001, seconds)
        let wholeSeconds = floor(clamped)
        var timeout = timeval(
            tv_sec: Int(wholeSeconds),
            tv_usec: Int32((clamped - wholeSeconds) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        let receiveResult = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        let sendResult = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
        var noSigPipe: Int32 = 1
        let noSigPipeResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        return receiveResult == 0 && sendResult == 0 && noSigPipeResult == 0
    }

    enum SocketReadResult: Equatable {
        case data(Data)
        case empty
        case timedOut
        case tooLarge
        case failed(Int32)
    }

    enum SocketMessageTermination {
        case newline
        case endOfFile
    }

    static func readMessage(
        fd: Int32,
        maxBytes: Int = 1 << 20,
        termination: SocketMessageTermination = .newline
    ) -> SocketReadResult {
        guard maxBytes >= 0 else { return .tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            // Read one byte beyond the remaining payload capacity so an
            // oversized message is rejected instead of truncated. EOF-framed
            // responses may also carry one final framing newline.
            let framingAllowance = termination == .endOfFile ? 1 : 0
            let readLimit = min(
                buffer.count,
                max(1, maxBytes + framingAllowance - data.count + 1)
            )
            let bytesRead = read(fd, &buffer, readLimit)
            if bytesRead == 0 {
                if data.isEmpty { return .empty }
                guard termination == .endOfFile else {
                    return data.count == maxBytes ? .tooLarge : .failed(EPROTO)
                }
                if data.last == UInt8(ascii: "\n") {
                    data.removeLast()
                }
                return data.count <= maxBytes ? .data(data) : .tooLarge
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .timedOut
                }
                return .failed(errno)
            }

            let chunk = buffer[0 ..< bytesRead]
            if termination == .newline,
               let delimiter = chunk.firstIndex(of: UInt8(ascii: "\n"))
            {
                data.append(contentsOf: chunk[..<delimiter])
                return data.count <= maxBytes ? .data(data) : .tooLarge
            }
            data.append(contentsOf: chunk)
            guard data.count <= maxBytes + framingAllowance else {
                return .tooLarge
            }
        }
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data) -> Int32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int32 in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR {
                    continue
                }
                if written < 0 {
                    return errno
                }
                if written == 0 {
                    return EPIPE
                }
                offset += written
            }
            return 0
        }
    }

    private func performOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}

public enum CommandClientError: Error, Equatable {
    case serverUnavailable
    case invalidResponse
    case timedOut
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
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        do {
            return try sendOnce(
                payload: payload,
                socketURL: socketURL,
                timeoutSeconds: max(0.001, deadline.timeIntervalSinceNow)
            )
        } catch CommandClientError.timedOut {
            throw CommandClientError.timedOut
        } catch {
            // A missing server is expected before auto-launch.
        }

        guard autoLaunch else {
            throw CommandClientError.serverUnavailable
        }

        launchApp()

        while Date() < deadline {
            Thread.sleep(forTimeInterval: min(0.2, max(0, deadline.timeIntervalSinceNow)))
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            do {
                let response = try sendOnce(
                    payload: payload,
                    socketURL: socketURL,
                    timeoutSeconds: remaining
                )
                return response
            } catch CommandClientError.timedOut {
                throw CommandClientError.timedOut
            } catch {
                continue
            }
        }

        throw CommandClientError.serverUnavailable
    }

    static func sendOnce(
        payload: Data,
        socketURL: URL,
        timeoutSeconds: TimeInterval = 5
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CommandClientError.serverUnavailable
        }
        defer { close(fd) }

        guard CommandServer.configureTimeouts(fd: fd, seconds: timeoutSeconds) else {
            throw CommandClientError.serverUnavailable
        }

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
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                throw CommandClientError.timedOut
            }
            throw CommandClientError.serverUnavailable
        }

        let writeResult = CommandServer.writeAll(fd: fd, data: payload + Data("\n".utf8))
        guard writeResult == 0 else {
            if writeResult == EAGAIN || writeResult == EWOULDBLOCK {
                throw CommandClientError.timedOut
            }
            throw CommandClientError.serverUnavailable
        }
        shutdown(fd, SHUT_WR)

        switch CommandServer.readMessage(
            fd: fd,
            maxBytes: 8 << 20,
            termination: .endOfFile
        ) {
        case let .data(response):
            return response
        case .timedOut:
            throw CommandClientError.timedOut
        case .tooLarge, .empty, .failed:
            throw CommandClientError.invalidResponse
        }
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
