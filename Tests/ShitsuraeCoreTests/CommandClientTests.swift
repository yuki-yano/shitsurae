import Darwin
import Foundation
import Testing
@testable import ShitsuraeCore

final class ScriptedUnixServer: @unchecked Sendable {
    enum Behavior: Sendable {
        case disconnectAfterRequest
        case partialResponseThenDelay(TimeInterval)
        case malformed
        case slowChunks
        case doNotRead
    }

    let socketURL: URL
    private let listenFD: Int32
    private let behavior: Behavior
    private let lock = NSLock()
    private var _connectionCount = 0
    private let finished = DispatchSemaphore(value: 0)

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _connectionCount
    }

    init(behavior: Behavior, observe: Bool = true) throws {
        self.behavior = behavior
        socketURL = URL(fileURLWithPath: "/tmp/shitsurae-client-\(UUID().uuidString.prefix(8)).sock")
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        listenFD = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count - 1)))
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        if observe {
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                observeConnections()
            }
        }
    }

    deinit {
        Darwin.close(listenFD)
        unlink(socketURL.path)
    }

    func waitUntilFinished(timeout: TimeInterval = 1) {
        _ = finished.wait(timeout: .now() + timeout)
    }

    private func observeConnections() {
        defer { finished.signal() }
        let deadline = DispatchTime.now().uptimeNanoseconds + 700_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var descriptor = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 50) > 0 else { continue }
            runOnce()
        }
    }

    private func runOnce() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        lock.lock()
        _connectionCount += 1
        lock.unlock()
        var noSigpipe: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        if case .doNotRead = behavior { Thread.sleep(forTimeInterval: 0.2); return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            if buffer.prefix(count).contains(UInt8(ascii: "\n")) { break }
        }

        switch behavior {
        case .disconnectAfterRequest:
            return
        case let .partialResponseThenDelay(delay):
            _ = Data("{".utf8).withUnsafeBytes { raw in
                Darwin.write(client, raw.baseAddress, raw.count)
            }
            Thread.sleep(forTimeInterval: delay)
        case .malformed:
            _ = Data("{broken}\n".utf8).withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        case .slowChunks:
            for byte in Data("{\"ok\":true,\"exitCode\":0,\"payload\":{}}\n".utf8) {
                var value = byte
                _ = Darwin.write(client, &value, 1)
                Thread.sleep(forTimeInterval: 0.02)
            }
        case .doNotRead: break
        }
    }
}

@Suite("Command client", .serialized)
struct CommandClientTests {
    @Test func backloggedConnectIsFiniteBeforeAnyRequestIsSent() throws {
        let server = try ScriptedUnixServer(behavior: .doNotRead, observe: false)
        var queuedFDs: [Int32] = []
        defer { queuedFDs.forEach { Darwin.close($0) } }
        var pendingConnect = false
        for _ in 0..<32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(fd >= 0)
            queuedFDs.append(fd)
            #expect(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                server.socketURL.path.utf8CString.withUnsafeBytes { source in
                    buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(buffer.count - 1)))
                }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result != 0 {
                let code = errno
                // Darwin can immediately refuse a full Unix backlog rather
                // than leave connect pending; neither form may block.
                #expect(code == EINPROGRESS || code == EAGAIN || code == ECONNREFUSED, "errno=\(code)")
                pendingConnect = true
                break
            }
        }
        #expect(pendingConnect)
        let started = DispatchTime.now().uptimeNanoseconds
        _ = CommandServer.canConnect(socketURL: server.socketURL)
        do {
            _ = try CommandClient.sendOnce(payload: Data("{}".utf8), socketURL: server.socketURL,
                responseTimeoutSeconds: 0.05, requestID: "backlogged",
                absoluteDeadlineUptimeNS: started + 50_000_000, connectionDeadlineUptimeNS: started + 50_000_000)
            Issue.record("expected unavailable before request send")
        } catch let error as CommandClientError { #expect(error == .serverUnavailable) }
        #expect(DispatchTime.now().uptimeNanoseconds - started < 150_000_000)
        #expect(server.connectionCount == 0)
    }

    @Test func doesNotRetryAfterRequestBytesWereSent() throws {
        let server = try ScriptedUnixServer(behavior: .disconnectAfterRequest)
        let requestID = "single-execution"
        var request = CommandRequest(command: "arrangeSet")
        request.requestID = requestID
        request.setName = "mobile"

        do {
            _ = try CommandClient.send(
                request: request,
                socketURL: server.socketURL,
                autoLaunch: true,
                timeoutSeconds: 0.2,
                responseTimeoutSeconds: 0.1,
                startupLaunch: { _ in Issue.record("post-send retry attempted startup") }
            )
            Issue.record("expected outcomeUnknown")
        } catch let error as CommandClientError {
            #expect(error == .outcomeUnknown(requestID: requestID))
        }
        server.waitUntilFinished()
        #expect(server.connectionCount == 1)
    }

    @Test func partialResponseUsesOneAbsoluteMonotonicDeadline() throws {
        let server = try ScriptedUnixServer(behavior: .partialResponseThenDelay(0.2))
        var request = CommandRequest(command: "arrangeStatus")
        request.requestID = "partial-deadline"
        let started = DispatchTime.now().uptimeNanoseconds

        do {
            _ = try CommandClient.send(
                request: request,
                socketURL: server.socketURL,
                autoLaunch: false,
                responseTimeoutSeconds: 0.05
            )
            Issue.record("expected outcomeUnknown")
        } catch let error as CommandClientError {
            #expect(error == .outcomeUnknown(requestID: "partial-deadline"))
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        #expect(elapsed < 0.15)
        #expect(server.connectionCount == 1)
        server.waitUntilFinished()
    }

    @Test(arguments: [ScriptedUnixServer.Behavior.malformed, .slowChunks, .doNotRead])
    func corruptSlowAndBackpressuredConnectionsKeepOriginalIDAndNeverResend(behavior: ScriptedUnixServer.Behavior) throws {
        let server = try ScriptedUnixServer(behavior: behavior)
        var request = CommandRequest(command: "arrangeSet")
        request.requestID = "original-id"
        if case .doNotRead = behavior { request.title = String(repeating: "x", count: 4 << 20) }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try CommandClient.send(request: request, socketURL: server.socketURL, autoLaunch: true, timeoutSeconds: 0.2,
                responseTimeoutSeconds: 0.05, startupLaunch: { _ in Issue.record("unexpected startup/retry") })
            Issue.record("expected unknown")
        } catch let error as CommandClientError { #expect(error == .outcomeUnknown(requestID: "original-id")) }
        #expect(DispatchTime.now().uptimeNanoseconds - started < 300_000_000)
        server.waitUntilFinished(timeout: 2)
        #expect(server.connectionCount == 1)
    }
}
