import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("CommandRouter")
struct CommandRouterTests {
    private func makeRouter(
        windows: [WindowSnapshot]
    ) throws -> (router: CommandRouter, engine: VirtualSpaceEngine, control: MockWindowControl, cleanup: () -> Void) {
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display])
        let (store, stateURL) = TestFixtures.tempStateStore()
        let logger = TestFixtures.nullLogger()
        let engine = VirtualSpaceEngine(
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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", frontIndex: 2),
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
        let candidates = try #require(payload["candidates"] as? [[String: Any]])
        #expect(candidates.first?["bundleID"] as? String == "com.apple.Terminal")
        #expect(candidates.first?["quickKey"] as? String == "1")
    }

    @Test func diagnosticsIncludesStateSummary() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        let response = try await send(router, CommandRequest(command: "diagnostics"))
        let payload = try #require(response["payload"] as? [String: Any])
        #expect(payload["permissions"] != nil)
        #expect(payload["state"] != nil)
        #expect((payload["configFiles"] as? [[String: Any]])?.isEmpty == false)
    }
}

@Suite("CommandServer", .serialized)
struct CommandServerTests {
    @Test func endToEndOverUnixSocket() async throws {
        let control = MockWindowControl(
            windows: [TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit")],
            displays: [TestFixtures.display]
        )
        let (store, stateURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        let logger = TestFixtures.nullLogger()
        let engine = VirtualSpaceEngine(store: store, control: control, logger: logger, retryDelaysMS: [1])

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
        let auth = PeerAuthService(identityProvider: { _ in
            PeerIdentity(teamIdentifier: nil, bundleIdentifier: "shitsurae-tests", executablePath: nil)
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
}
