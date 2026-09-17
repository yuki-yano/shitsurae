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
        source.setCancelHandler { [listenFD = fd] in
            close(listenFD)
        }
        acceptSource = source
        source.resume()

        logger.log(event: "server.started", fields: ["path": path])
        return true
    }

    public func stop() {
        let shouldUnlink = ownsSocket
        acceptSource?.cancel()
        acceptSource = nil
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
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }

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
        // Probe without an unbounded connect. If it is pending, the endpoint
        // is live and must not be unlinked as stale.
        return connectResult == 0 || errno == EINPROGRESS || errno == EAGAIN
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

            guard let requestData = Self.readRequest(fd: clientFD) else {
                close(clientFD)
                return
            }

            let response = await router.handle(requestData: requestData)
            Self.writeAll(fd: clientFD, data: response + Data("\n".utf8))
            close(clientFD)
        }
    }

    static func configureTimeouts(fd: Int32, seconds: Int = 5) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    }

    static func readRequest(fd: Int32, maxBytes: Int = 1 << 20) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000

        while data.count < maxBytes {
            guard waitForIO(fd: fd, events: Int16(POLLIN), deadline: deadline) else { return nil }
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead < 0, errno == EINTR || errno == EAGAIN { continue }
            if bytesRead <= 0 { return nil }
            data.append(contentsOf: buffer[0 ..< bytesRead])
            if let last = data.last, last == UInt8(ascii: "\n") {
                break
            }
        }

        guard data.last == UInt8(ascii: "\n") else {
            return nil
        }
        if let last = data.last, last == UInt8(ascii: "\n") {
            data.removeLast()
        }
        return data
    }

    static func writeAll(fd: Int32, data: Data) {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                guard waitForIO(fd: fd, events: Int16(POLLOUT), deadline: deadline) else { break }
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR || errno == EAGAIN { continue }
                if written <= 0 {
                    break
                }
                offset += written
            }
        }
    }

    private static func waitForIO(fd: Int32, events: Int16, deadline: UInt64) -> Bool {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(1_000, (deadline - now) / 1_000_000))))
            if result > 0 { return true }
            if result < 0, errno != EINTR { return false }
        }
    }
}

public enum CommandClientError: Error, Equatable {
    case serverUnavailable
    case invalidResponse
    case outcomeUnknown(requestID: String)
}

/// CLI-side connector. When the app isn't running it launches it
/// (`open -b`) and retries until the socket answers.
public enum CommandClient {
    public static let appBundleID = "com.yuki-yano.shitsurae"

    public static func send(
        request: CommandRequest,
        socketURL: URL = CommandSocket.socketURL(),
        autoLaunch: Bool = true,
        timeoutSeconds: TimeInterval = 8,
        responseTimeoutSeconds: TimeInterval = 65,
        progress: @escaping (Int) -> Void = { _ in },
        startupLaunch: (TimeInterval) -> Void = { launchApp(timeoutSeconds: $0) }
    ) throws -> Data {
        let payload = try JSONEncoder().encode(request)
        let requestID = request.requestID ?? "unknown"
        let started = DispatchTime.now().uptimeNanoseconds
        let startupDeadline = started + UInt64(max(0, timeoutSeconds) * 1_000_000_000)
        let overallDeadline = startupDeadline + UInt64(max(0, responseTimeoutSeconds) * 1_000_000_000)
        var lastProgressMS = -1_000
        let reportProgress = {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            if elapsed - lastProgressMS >= 1_000 { lastProgressMS = elapsed; progress(elapsed) }
        }
        reportProgress()

        do {
            return try sendOnce(
                payload: payload,
                socketURL: socketURL,
                responseTimeoutSeconds: responseTimeoutSeconds,
                requestID: requestID,
                absoluteDeadlineUptimeNS: overallDeadline,
                connectionDeadlineUptimeNS: startupDeadline,
                progress: reportProgress
            )
        } catch CommandClientError.serverUnavailable {
            // Only a pre-send connection failure is retryable.
        } catch {
            throw error
        }

        guard autoLaunch else {
            throw CommandClientError.serverUnavailable
        }

        let launchRemaining = max(0, Double(startupDeadline - min(startupDeadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000_000)
        guard launchRemaining > 0 else { throw CommandClientError.serverUnavailable }
        startupLaunch(launchRemaining)

        while DispatchTime.now().uptimeNanoseconds < startupDeadline {
            reportProgress()
            let remaining = Double(startupDeadline - min(startupDeadline, DispatchTime.now().uptimeNanoseconds)) / 1_000_000_000
            Thread.sleep(forTimeInterval: min(0.2, remaining))
            do {
                return try sendOnce(
                    payload: payload,
                    socketURL: socketURL,
                    responseTimeoutSeconds: responseTimeoutSeconds,
                    requestID: requestID,
                    absoluteDeadlineUptimeNS: overallDeadline,
                    connectionDeadlineUptimeNS: startupDeadline,
                    progress: reportProgress
                )
            } catch CommandClientError.serverUnavailable {
                continue
            } catch {
                throw error
            }
        }

        throw CommandClientError.serverUnavailable
    }

    static func sendOnce(
        payload: Data,
        socketURL: URL,
        responseTimeoutSeconds: TimeInterval = 65,
        requestID: String = "unknown",
        absoluteDeadlineUptimeNS: UInt64? = nil,
        connectionDeadlineUptimeNS: UInt64? = nil,
        progress: () -> Void = {}
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CommandClientError.serverUnavailable
        }
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw CommandClientError.serverUnavailable }
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let overallDeadline = absoluteDeadlineUptimeNS ?? (DispatchTime.now().uptimeNanoseconds
            + UInt64((8 + max(0, responseTimeoutSeconds)) * 1_000_000_000))
        let connectDeadline = min(overallDeadline, connectionDeadlineUptimeNS ?? (DispatchTime.now().uptimeNanoseconds + 8_000_000_000))

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
        if connectResult != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  (try? waitForFD(fd, events: Int16(POLLOUT), deadlineUptimeNS: connectDeadline, progress: progress)) == true
            else { throw CommandClientError.serverUnavailable }
            var socketError: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                throw CommandClientError.serverUnavailable
            }
            var peer = sockaddr_un()
            var peerSize = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &peerSize) }
            }
            guard connected == 0 else { throw CommandClientError.serverUnavailable }
        }
        let deadline = min(overallDeadline, DispatchTime.now().uptimeNanoseconds + UInt64(max(0, responseTimeoutSeconds) * 1_000_000_000))
        var sentAnyByte = false
        do {
            try writeAll(
                fd: fd,
                data: payload + Data("\n".utf8),
                deadlineUptimeNS: deadline,
                sentAnyByte: &sentAnyByte,
                progress: progress
            )
        } catch {
            if sentAnyByte {
                throw CommandClientError.outcomeUnknown(requestID: requestID)
            }
            throw CommandClientError.outcomeUnknown(requestID: requestID)
        }
        shutdown(fd, SHUT_WR)

        do {
            guard let response = try readResponse(
                fd: fd,
                maxBytes: 8 << 20,
                deadlineUptimeNS: deadline,
                progress: progress
            ) else {
                throw CommandClientError.outcomeUnknown(requestID: requestID)
            }
            guard (try? JSONDecoder().decode(CommandResponseProbe.self, from: response)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object["payload"] != nil || object["error"] != nil
            else { throw CommandClientError.outcomeUnknown(requestID: requestID) }
            return response
        } catch let error as CommandClientError {
            throw error
        } catch {
            throw CommandClientError.outcomeUnknown(requestID: requestID)
        }
    }

    private static func writeAll(
        fd: Int32,
        data: Data,
        deadlineUptimeNS: UInt64,
        sentAnyByte: inout Bool,
        progress: () -> Void
    ) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                guard try waitForFD(fd, events: Int16(POLLOUT), deadlineUptimeNS: deadlineUptimeNS, progress: progress) else {
                    throw CommandClientError.invalidResponse
                }
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0, errno == EINTR || errno == EAGAIN { continue }
                guard written > 0 else { throw CommandClientError.invalidResponse }
                sentAnyByte = true
                offset += written
            }
        }
    }

    private static func readResponse(
        fd: Int32,
        maxBytes: Int,
        deadlineUptimeNS: UInt64,
        progress: () -> Void
    ) throws -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxBytes {
            guard try waitForFD(fd, events: Int16(POLLIN), deadlineUptimeNS: deadlineUptimeNS, progress: progress) else {
                return nil
            }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return nil }
            guard count > 0 else {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.last == UInt8(ascii: "\n"),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                data.removeLast()
                return data
            }
        }
        return nil
    }

    private static func waitForFD(
        _ fd: Int32,
        events: Int16,
        deadlineUptimeNS: UInt64,
        progress: () -> Void
    ) throws -> Bool {
        while true {
            progress()
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadlineUptimeNS else { return false }
            let remainingMS = max(1, Int((deadlineUptimeNS - now) / 1_000_000))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remainingMS, 1_000)))
            if result > 0 { return true }
            if result == 0 { progress(); continue }
            if errno != EINTR { throw CommandClientError.invalidResponse }
        }
    }

    @usableFromInline static func launchApp(timeoutSeconds: TimeInterval) {
        _ = SystemProbe.runProcess(executable: "/usr/bin/open", arguments: ["-g", "-b", appBundleID], timeoutSeconds: max(0, timeoutSeconds - 0.4))
    }
}
