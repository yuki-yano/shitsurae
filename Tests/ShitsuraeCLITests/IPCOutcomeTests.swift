import Darwin
import Foundation
@testable import ShitsuraeCore
import Testing

private final class CLIOutcomeSocket: @unchecked Sendable {
    enum Behavior: Sendable { case malformed, eof, partial, slowChunks }
    let directory: URL
    let environment: [String: String]
    let socketURL: URL
    private let fd: Int32
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "shitsurae.cli-outcome-socket")
    private var ids: [String] = []
    private var draining = false
    private var workerFailed = false
    private let finished = DispatchGroup()
    var requestIDs: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    private var isDraining: Bool { lock.lock(); defer { lock.unlock() }; return draining }

    init(_ behavior: Behavior, workerGate: DispatchSemaphore? = nil) throws {
        directory = URL(fileURLWithPath: "/tmp/sht-cli-\(UUID().uuidString.prefix(8))")
        var env = ProcessInfo.processInfo.environment
        env["XDG_STATE_HOME"] = directory.path
        environment = env
        socketURL = CommandSocket.socketURL(environment: env)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            socketURL.path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
        }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        queue.async(group: finished) { [self] in
            if let workerGate, workerGate.wait(timeout: .now() + 4) != .success {
                lock.lock(); workerFailed = true; lock.unlock()
                return
            }
            while true {
                // A drain request must still inspect the listener backlog. A
                // previous blocking poll cannot establish that it is empty.
                let drainingAtPoll = isDraining
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, drainingAtPoll ? 0 : 50)
                if ready == 0 {
                    if drainingAtPoll { break }
                    continue
                }
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                    lock.lock(); workerFailed = true; lock.unlock()
                    break
                }
                let client = accept(fd, nil, nil)
                if client < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard client >= 0 else {
                    lock.lock(); workerFailed = true; lock.unlock()
                    break
                }
                var noSigpipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                CommandServer.configureTimeouts(fd: client)
                if let data = CommandServer.readRequest(fd: client),
                   let request = try? JSONDecoder().decode(CommandRequest.self, from: data) {
                    lock.lock(); ids.append(request.requestID ?? "missing"); lock.unlock()
                    let response: Data
                    switch behavior {
                    case .malformed: response = Data("{broken}\n".utf8)
                    case .eof: response = Data()
                    case .partial: response = Data("{\"ok\":true".utf8)
                    case .slowChunks:
                        response = try! JSONSerialization.data(withJSONObject: ["ok": true, "exitCode": 0,
                            "payload": ["requestID": request.requestID!, "result": "success"]]) + Data("\n".utf8)
                    }
                    if case .slowChunks = behavior {
                        _ = response.prefix(1).withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                        Thread.sleep(forTimeInterval: 1.1)
                        _ = response.dropFirst().withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
                    } else { _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } }
                }
                Darwin.close(client)
            }
        }
    }
    deinit { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) }
    /// Call after the producer has exited: accept every queued connection,
    /// finish reading it, and join the worker before inspecting requestIDs.
    func drainAndJoin() -> Bool {
        lock.lock()
        draining = true
        lock.unlock()
        guard finished.wait(timeout: .now() + 4) == .success else { return false }
        lock.lock(); defer { lock.unlock() }
        return !workerFailed
    }

    func enqueue(_ request: CommandRequest) throws -> Int32 {
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0 else { throw POSIXError(.ENOTSOCK) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                socketURL.path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
            }
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            let data = try JSONEncoder().encode(request) + Data("\n".utf8)
            let written = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
            guard written == data.count else { throw POSIXError(.EIO) }
            _ = Darwin.shutdown(client, SHUT_WR)
            return client
        } catch {
            Darwin.close(client)
            throw error
        }
    }
}

@Suite("CLI isolated IPC acceptance")
struct IPCOutcomeTests {
    @Test(arguments: [CLIOutcomeSocket.Behavior.malformed, .eof, .partial, .slowChunks])
    fileprivate func originalIDOneJSONAndFiniteCLIWithoutRealApp(behavior: CLIOutcomeSocket.Behavior) async throws {
        let server = try CLIOutcomeSocket(behavior)
        defer { #expect(server.drainAndJoin()) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/shitsurae-cli")
        process.arguments = ["arrange", "--status", "--json"]
        process.environment = server.environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let started = DispatchTime.now().uptimeNanoseconds
        try process.run()
        // Yield the test worker so server IO and process completion can run
        // even when all test targets share one heavily loaded runner.
        while process.isRunning && DispatchTime.now().uptimeNanoseconds - started < 4_000_000_000 {
            try await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            Issue.record("CLI exceeded isolated test deadline")
            return
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let json = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        // CLI exit closes its producer side. Drain already queued duplicates
        // before joining; stopping at exit would hide an unaccepted retry.
        try #require(server.drainAndJoin())
        #expect(server.requestIDs.count == 1)
        let originalID = try #require(server.requestIDs.first)
        #expect(json["requestID"] as? String == originalID)
        #expect(elapsed < 4_000_000_000)
        #expect(errors.contains("requestID=") && errors.contains("elapsedMS="))
        if case .slowChunks = behavior {
            #expect(process.terminationStatus == 0)
            #expect(json["result"] as? String == "success")
            let progress = errors.split(separator: "\n").compactMap { line -> Int? in
                let fields = line.split(separator: " ")
                guard fields.contains(Substring("requestID=\(originalID)")),
                      let elapsedField = fields.first(where: { $0.hasPrefix("elapsedMS=") }) else { return nil }
                return Int(elapsedField.dropFirst("elapsedMS=".count))
            }
            #expect(progress.first.map { $0 >= 0 } == true)
            #expect(progress.dropFirst().contains { $0 >= 1_000 })
        } else {
            #expect(process.terminationStatus == 31)
            #expect(json["result"] as? String == "outcomeUnknown")
        }
    }

    @Test func drainObservesDuplicateAlreadyQueuedBeforeWorkerStarts() throws {
        let gate = DispatchSemaphore(value: 0)
        let server = try CLIOutcomeSocket(.malformed, workerGate: gate)
        defer { gate.signal(); #expect(server.drainAndJoin()) }
        var request = CommandRequest(command: "arrangeStatus")
        request.requestID = "queued-duplicate"
        let first = try server.enqueue(request)
        defer { Darwin.close(first) }
        let second = try server.enqueue(request)
        defer { Darwin.close(second) }
        // Both requests are in the listener backlog while acceptance is held.
        gate.signal()
        try #require(server.drainAndJoin())
        #expect(server.requestIDs == ["queued-duplicate", "queued-duplicate"])
    }
}
