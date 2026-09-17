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
    private var ids: [String] = []
    private let finished = DispatchSemaphore(value: 0)
    var requestIDs: [String] { lock.lock(); defer { lock.unlock() }; return ids }

    init(_ behavior: Behavior) throws {
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
        guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EIO) }
        DispatchQueue.global().async { [self] in
            defer { finished.signal() }
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
            while DispatchTime.now().uptimeNanoseconds < deadline {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 50) > 0 else { continue }
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
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
                        for byte in response { var value = byte; _ = Darwin.write(client, &value, 1); Thread.sleep(forTimeInterval: 0.012) }
                    } else { _ = response.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) } }
                }
                Darwin.close(client)
            }
        }
    }
    deinit { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) }
    func wait() { _ = finished.wait(timeout: .now() + 4) }
}

@Suite("CLI isolated IPC acceptance", .serialized)
struct IPCOutcomeTests {
    @Test(arguments: [CLIOutcomeSocket.Behavior.malformed, .eof, .partial, .slowChunks])
    fileprivate func originalIDOneJSONAndFiniteCLIWithoutRealApp(behavior: CLIOutcomeSocket.Behavior) throws {
        let server = try CLIOutcomeSocket(behavior)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/shitsurae-cli")
        process.arguments = ["arrange", "--status", "--json"]
        process.environment = server.environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        let started = DispatchTime.now().uptimeNanoseconds
        try process.run()
        if terminated.wait(timeout: .now() + 4) != .success { process.terminate(); Issue.record("CLI exceeded isolated test deadline"); return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let json = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any])
        server.wait() // keep listening through the complete no-retry interval
        #expect(server.requestIDs.count == 1)
        #expect(json["requestID"] as? String == server.requestIDs.first)
        #expect(elapsed < 4_000_000_000)
        #expect(errors.contains("requestID=") && errors.contains("elapsedMS="))
        if case .slowChunks = behavior {
            #expect(process.terminationStatus == 0)
            #expect(errors.contains("elapsedMS=1"))
        } else {
            #expect(process.terminationStatus == 31)
            #expect(json["result"] as? String == "outcomeUnknown")
        }
    }
}
