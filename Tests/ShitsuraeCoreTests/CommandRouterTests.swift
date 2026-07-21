import Darwin
import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("CommandRouter")
struct CommandRouterTests {
    @Test func mutatingStateOnlyArrangeInvalidatesPendingFocus() {
        var stateOnly = CommandRequest(command: "arrange")
        stateOnly.stateOnly = true
        #expect(CommandRouter.invalidatesPendingFocus(stateOnly))

        var dryRun = CommandRequest(command: "arrange")
        dryRun.dryRun = true
        #expect(!CommandRouter.invalidatesPendingFocus(dryRun))
    }

    private func makeRouter(
        windows: [WindowSnapshot]
    ) throws -> (router: CommandRouter, engine: VirtualSpaceEngine, control: MockWindowControl, cleanup: () -> Void) {
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display])
        let (store, stateURL) = TestFixtures.tempStateStore()
        let logger = TestFixtures.nullLogger()
        let engine = try VirtualSpaceEngine(
            store: store,
            control: control,
            logger: logger,
            retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 50
        )

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-router-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try """
        layouts:
          work:
            initialFocus:
              slot: 1
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.TextEdit
                    frame: { x: "0%", y: "0%", width: "50%", height: "100%" }
                  - slot: 2
                    launch: false
                    match:
                      bundleID: com.apple.Terminal
                    frame: { x: "50%", y: "0%", width: "50%", height: "100%" }
              - spaceID: 2
                windows:
                  - slot: 1
                    launch: false
                    match:
                      bundleID: com.apple.Notes
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """.write(to: configDir.appendingPathComponent("01-test.yaml"), atomically: true, encoding: .utf8)

        let configManager = ConfigManager(directoryURL: configDir, logger: logger)
        configManager.start()

        let router = CommandRouter(engine: engine, configManager: configManager, logger: logger)
        let cleanup = {
            configManager.stop()
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }
        return (router, engine, control, cleanup)
    }

    private func standardWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
        ]
    }

    private func send(_ router: CommandRouter, _ request: CommandRequest) async throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        let response = await router.handle(requestData: data)
        return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    @Test func layoutsListReturnsLayouts() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        let response = try await send(router, CommandRequest(command: "layoutsList"))
        #expect(response["ok"] as? Bool == true)
        let payload = try #require(response["payload"] as? [String: Any])
        let layouts = try #require(payload["layouts"] as? [[String: Any]])
        #expect(layouts.first?["name"] as? String == "work")
        #expect(layouts.first?["spaceIDs"] as? [Int] == [1, 2])
    }

    @Test func arrangeStateOnlyThenSpaceSwitchRoundTrip() async throws {
        let (router, _, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        var bootstrap = CommandRequest(command: "arrange")
        bootstrap.layout = "work"
        bootstrap.stateOnly = true
        bootstrap.spaceID = 1
        let bootstrapResponse = try await send(router, bootstrap)
        #expect(bootstrapResponse["ok"] as? Bool == true)

        var switchRequest = CommandRequest(command: "spaceSwitch")
        switchRequest.spaceID = 2
        let switchResponse = try await send(router, switchRequest)
        #expect(switchResponse["ok"] as? Bool == true)
        let payload = try #require(switchResponse["payload"] as? [String: Any])
        #expect(payload["didChangeSpace"] as? Bool == true)
        #expect(payload["spaceID"] as? Int == 2)

        // TextEdit hidden offscreen after switching away from space 1.
        let textEdit = control.window(1)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: textEdit.frame, displays: [TestFixtures.display]))
    }

    @Test func spaceCurrentReportsActiveSpace() async throws {
        let (router, engine, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        var bootstrap = CommandRequest(command: "arrange")
        bootstrap.layout = "work"
        bootstrap.stateOnly = true
        bootstrap.spaceID = 1
        _ = try await send(router, bootstrap)
        _ = engine

        let response = try await send(router, CommandRequest(command: "spaceCurrent"))
        let payload = try #require(response["payload"] as? [String: Any])
        let space = try #require(payload["space"] as? [String: Any])
        #expect(space["spaceID"] as? Int == 1)
        #expect(space["isActive"] as? Bool == true)
        #expect(payload["recoveryRequired"] as? Bool == false)
    }

    @Test func unknownCommandFailsCleanly() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: [])
        defer { cleanup() }

        let response = try await send(router, CommandRequest(command: "bogus"))
        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("unknown command") == true)
    }

    @Test func missingArgumentFailsValidation() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: [])
        defer { cleanup() }

        let response = try await send(router, CommandRequest(command: "spaceSwitch"))
        #expect(response["ok"] as? Bool == false)
        #expect(response["exitCode"] as? Int == ErrorCode.validationError.rawValue)
    }

    @Test func windowIDSelectorRequiresAndUsesCompleteIdentity() async throws {
        let (router, _, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        let target = control.window(2)!

        var incomplete = CommandRequest(command: "focus")
        incomplete.windowID = target.windowID
        let rejected = try await send(router, incomplete)
        #expect(rejected["ok"] as? Bool == false)
        #expect(rejected["exitCode"] as? Int == ErrorCode.validationError.rawValue)

        var exact = incomplete
        exact.pid = target.pid
        exact.processStartTime = target.processStartTime
        exact.bundleID = target.bundleID

        var reusedProcess = exact
        reusedProcess.processStartTime = target.processStartTime + 1
        let staleRejected = try await send(router, reusedProcess)
        #expect(staleRejected["ok"] as? Bool == false)

        let accepted = try await send(router, exact)
        #expect(accepted["ok"] as? Bool == true)
        #expect(control.focusedWindow()?.identity == target.identity)
    }

    @Test func switcherListReturnsMRUCandidatesWithQuickKeys() async throws {
        let (router, engine, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        var bootstrap = CommandRequest(command: "arrange")
        bootstrap.layout = "work"
        bootstrap.stateOnly = true
        bootstrap.spaceID = 1
        _ = try await send(router, bootstrap)

        // Activate Terminal so it leads the MRU order.
        await engine.markActivated(window: control.window(2)!)

        let response = try await send(router, CommandRequest(command: "switcherList"))
        let payload = try #require(response["payload"] as? [String: Any])
        #expect(payload["schemaVersion"] as? Int == 4)
        let candidates = try #require(payload["candidates"] as? [[String: Any]])
        #expect(candidates.first?["bundleID"] as? String == "com.apple.Terminal")
        #expect(candidates.first?["pid"] as? Int == control.window(2)?.pid)
        #expect(candidates.first?["processStartTime"] as? UInt64 == control.window(2)?.processStartTime)
        #expect(candidates.first?["quickKey"] as? String == "1")
    }

    @Test func diagnosticsIncludesStateSummary() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        let response = try await send(router, CommandRequest(command: "diagnostics"))
        let payload = try #require(response["payload"] as? [String: Any])
        #expect(payload["permissions"] != nil)
        #expect(payload["state"] != nil)
        #expect(payload["schemaVersion"] as? Int == 3)
        let privateAPIs = try #require(payload["privateAPIs"] as? [String: Any])
        #expect(privateAPIs["operatingSystemVersion"] is String)
        #expect(privateAPIs["targetedWindowFocusSymbolsAvailable"] is Bool)
        #expect(privateAPIs["symbolicHotKeySymbolAvailable"] is Bool)
        #expect(privateAPIs["axWindowIDBridgeSymbolAvailable"] is Bool)
        #expect(privateAPIs["keyWindowEventRecordBytes"] as? Int == 0xF8)
        #expect((payload["configFiles"] as? [[String: Any]])?.isEmpty == false)
    }
}

@Suite("CommandServer", .serialized)
struct CommandServerTests {
    @Test func endToEndOverUnixSocket() async throws {
        let control = MockWindowControl(
            windows: [TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true)],
            displays: [TestFixtures.display]
        )
        let (store, stateURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let logger = TestFixtures.nullLogger()
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: logger, retryDelaysMS: [1])

        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-server-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: configDir) }
        try """
        layouts:
          solo:
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match: { bundleID: com.apple.TextEdit }
                    frame: { x: "0%", y: "0%", width: "100%", height: "100%" }
        """.write(to: configDir.appendingPathComponent("01.yaml"), atomically: true, encoding: .utf8)

        let configManager = ConfigManager(directoryURL: configDir, logger: logger)
        configManager.start()
        defer { configManager.stop() }

        let router = CommandRouter(engine: engine, configManager: configManager, logger: logger)
        // Short socket path: sockaddr_un limit is 104 bytes.
        let socketURL = URL(fileURLWithPath: "/tmp/shitsurae-test-\(UInt32.random(in: 0 ..< 99999)).sock")
        // The test runner is not an allowlisted binary; stub the identity.
        let testCodeHash = Data([1, 2, 3, 4])
        let auth = PeerAuthService(adHocAllowlist: [
            PeerAllowedAdHocIdentity(
                bundleIdentifier: "shitsurae-tests",
                codeDirectoryHash: testCodeHash
            ),
        ], identityProvider: { _ in
            PeerIdentity(
                teamIdentifier: nil,
                bundleIdentifier: "shitsurae-tests",
                executablePath: nil,
                codeDirectoryHash: testCodeHash,
                signatureValid: true,
                appleAnchored: false
            )
        })
        let server = CommandServer(router: router, logger: logger, socketURL: socketURL, auth: auth)
        #expect(server.start())
        defer { server.stop() }

        let response = try CommandClient.send(
            request: CommandRequest(command: "layoutsList"),
            socketURL: socketURL,
            autoLaunch: false
        )
        let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        #expect(object["ok"] as? Bool == true)
        let payload = try #require(object["payload"] as? [String: Any])
        let layouts = try #require(payload["layouts"] as? [[String: Any]])
        #expect(layouts.first?["name"] as? String == "solo")
    }

    @Test func secondServerDoesNotStealLiveSocket() async throws {
        let control = MockWindowControl(
            windows: [TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true)],
            displays: [TestFixtures.display]
        )
        let (store, stateURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let logger = TestFixtures.nullLogger()
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: logger, retryDelaysMS: [1])
        let configManager = ConfigManager(directoryURL: FileManager.default.temporaryDirectory, logger: logger)
        let router = CommandRouter(engine: engine, configManager: configManager, logger: logger)
        let socketURL = URL(fileURLWithPath: "/tmp/shitsurae-test-\(UInt32.random(in: 0 ..< 99999)).sock")
        let testCodeHash = Data([1, 2, 3, 4])
        let auth = PeerAuthService(adHocAllowlist: [
            PeerAllowedAdHocIdentity(
                bundleIdentifier: "shitsurae-tests",
                codeDirectoryHash: testCodeHash
            ),
        ], identityProvider: { _ in
            PeerIdentity(
                teamIdentifier: nil,
                bundleIdentifier: "shitsurae-tests",
                executablePath: nil,
                codeDirectoryHash: testCodeHash,
                signatureValid: true,
                appleAnchored: false
            )
        })
        let first = CommandServer(router: router, logger: logger, socketURL: socketURL, auth: auth)
        #expect(first.start())
        defer { first.stop() }

        let second = CommandServer(router: router, logger: logger, socketURL: socketURL, auth: auth)
        #expect(!second.start())
        second.stop()

        #expect(CommandServer.canConnect(socketURL: socketURL))

        for _ in 0 ..< 25 {
            first.stop()
            #expect(first.start())
            #expect(CommandServer.canConnect(socketURL: socketURL))
        }
    }

    @Test func clientFailsFastWhenServerAbsent() {
        let socketURL = URL(fileURLWithPath: "/tmp/shitsurae-absent-\(UInt32.random(in: 0 ..< 99999)).sock")
        #expect(throws: CommandClientError.self) {
            try CommandClient.send(
                request: CommandRequest(command: "layoutsList"),
                socketURL: socketURL,
                autoLaunch: false
            )
        }
    }

    @Test func socketReadEnforcesPayloadBoundary() throws {
        #expect(try readMessage(Data("1234567\n".utf8), maxBytes: 8) == .data(Data("1234567".utf8)))
        #expect(try readMessage(Data("12345678\n".utf8), maxBytes: 8) == .data(Data("12345678".utf8)))
        #expect(try readMessage(Data("123456789\n".utf8), maxBytes: 8) == .tooLarge)
        #expect(try readMessage(Data("12345678".utf8), maxBytes: 8) == .tooLarge)
    }

    @Test func eofFramedResponsePreservesInternalNewlines() throws {
        let response = Data("{\n  \"ok\": true\n}\n".utf8)
        #expect(try readMessage(
            response,
            maxBytes: response.count - 1,
            termination: .endOfFile
        ) == .data(Data("{\n  \"ok\": true\n}".utf8)))
    }

    @Test func socketReadTimeoutIsReported() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        try #require(CommandServer.configureTimeouts(fd: sockets[0], seconds: 0.02))

        let startedAt = Date()
        #expect(CommandServer.readMessage(fd: sockets[0], maxBytes: 8) == .timedOut)
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }

    @Test func clientTimesOutWhenConnectedServerNeverResponds() throws {
        let socketURL = URL(fileURLWithPath: "/tmp/shitsurae-hung-\(UInt32.random(in: 0 ..< 99999)).sock")
        let serverFD = try makeListeningSocket(at: socketURL)
        defer {
            close(serverFD)
            unlink(socketURL.path)
        }

        let accepted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            accepted.signal()
            Thread.sleep(forTimeInterval: 0.2)
            close(clientFD)
        }

        let startedAt = Date()
        #expect(throws: CommandClientError.timedOut) {
            try CommandClient.sendOnce(
                payload: Data("{}".utf8),
                socketURL: socketURL,
                timeoutSeconds: 0.03
            )
        }
        #expect(accepted.wait(timeout: .now() + 0.5) == .success)
        #expect(Date().timeIntervalSince(startedAt) < 0.5)
    }

    @Test func socketWriteReturnsCapturedErrorCode() throws {
        var sockets = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]) }
        try #require(CommandServer.configureTimeouts(fd: sockets[0]))
        close(sockets[1])

        #expect(CommandServer.writeAll(fd: sockets[0], data: Data("request".utf8)) == EPIPE)
    }

    private func readMessage(
        _ bytes: Data,
        maxBytes: Int,
        termination: CommandServer.SocketMessageTermination = .newline
    ) throws -> CommandServer.SocketReadResult {
        var sockets = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer {
            close(sockets[0])
            close(sockets[1])
        }
        try #require(CommandServer.writeAll(fd: sockets[1], data: bytes) == 0)
        shutdown(sockets[1], SHUT_WR)
        return CommandServer.readMessage(fd: sockets[0], maxBytes: maxBytes, termination: termination)
    }

    private func makeListeningSocket(at socketURL: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let maxLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        try #require(path.utf8.count <= maxLength)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: source.prefix(maxLength)))
            }
        }

        unlink(path)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw CommandClientError.serverUnavailable
        }
        return fd
    }
}

@Suite("PeerAuthService")
struct PeerAuthServiceTests {
    private let teamIdentity = PeerAllowedIdentity(
        teamIdentifier: "TEAM123",
        bundleIdentifier: "com.yuki-yano.shitsurae.cli"
    )
    private let adHocHash = Data([0xaa, 0xbb, 0xcc])

    private var service: PeerAuthService {
        PeerAuthService(
            allowlist: [teamIdentity],
            adHocAllowlist: [PeerAllowedAdHocIdentity(
                bundleIdentifier: "com.yuki-yano.shitsurae.cli",
                codeDirectoryHash: adHocHash
            )]
        )
    }

    @Test func acceptsValidTeamSignedIdentity() {
        #expect(service.authorize(identity: PeerIdentity(
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.yuki-yano.shitsurae.cli",
            executablePath: "/tmp/anything",
            codeDirectoryHash: Data([1]),
            signatureValid: true,
            appleAnchored: true
        )))
    }

    @Test func rejectsInvalidSignatureEvenWhenIdentifiersMatch() {
        #expect(!service.authorize(identity: PeerIdentity(
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.yuki-yano.shitsurae.cli",
            executablePath: nil,
            codeDirectoryHash: Data([1]),
            signatureValid: false,
            appleAnchored: true
        )))
    }

    @Test func rejectsSelfSignedTeamIdentity() {
        #expect(!service.authorize(identity: PeerIdentity(
            teamIdentifier: "TEAM123",
            bundleIdentifier: "com.yuki-yano.shitsurae.cli",
            executablePath: "/tmp/forged-cli",
            codeDirectoryHash: Data([1]),
            signatureValid: true,
            appleAnchored: false
        )))
    }

    @Test func acceptsOnlyExactBundledAdHocCodeHash() {
        #expect(service.authorize(identity: PeerIdentity(
            teamIdentifier: nil,
            bundleIdentifier: "com.yuki-yano.shitsurae.cli",
            executablePath: "/tmp/shitsurae",
            codeDirectoryHash: adHocHash,
            signatureValid: true,
            appleAnchored: false
        )))

        #expect(!service.authorize(identity: PeerIdentity(
            teamIdentifier: nil,
            bundleIdentifier: "com.yuki-yano.shitsurae.cli.attacker",
            executablePath: "/tmp/shitsurae",
            codeDirectoryHash: adHocHash,
            signatureValid: true,
            appleAnchored: false
        )))
        #expect(!service.authorize(identity: PeerIdentity(
            teamIdentifier: nil,
            bundleIdentifier: "com.yuki-yano.shitsurae.cli",
            executablePath: "/tmp/shitsurae",
            codeDirectoryHash: Data([0xde, 0xad]),
            signatureValid: true,
            appleAnchored: false
        )))
    }
}
