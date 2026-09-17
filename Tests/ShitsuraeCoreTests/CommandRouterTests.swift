import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("CommandRouter")
struct CommandRouterTests {
    @Test func rejectedRequestCannotReleaseAnotherOperationWithSameRequestID() async throws {
        let (router, engine, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        let token = try engine.operationCoordinator.tryAdmit(requestID: "owner", operation: .arrangeSet)
        defer { engine.operationCoordinator.abandon(token: token) }
        engine.operationCoordinator.update(token: token, phase: .placing, inFlight: true)
        for command in ["unknown", "focus"] {
            var request = CommandRequest(command: command)
            request.requestID = "owner"
            _ = try await send(router, request)
            #expect(engine.operationCoordinator.status().active?.requestID == "owner")
            #expect(engine.operationCoordinator.status().active?.inFlight == true)
            #expect(engine.operationCoordinator.status().lastOutcome == nil)
        }
    }

    @Test func admittedCLIFailurePublishesOutcomeForGUIPoll() async throws {
        let (router, engine, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        var request = CommandRequest(command: "arrangeSet")
        request.setName = "missing"
        request.requestID = "failure"
        let response = try await send(router, request)
        #expect(response["ok"] as? Bool == false)
        let status = engine.operationCoordinator.status()
        #expect(status.active == nil)
        #expect(status.lastOutcome?.requestID == "failure")
        #expect(status.lastOutcome?.result == "failed")
        #expect(status.lastOutcome?.operation == .arrangeSet)
        #expect(status.lastOutcome?.detail?.isEmpty == false)
    }
    @Test func mutatingStateOnlyArrangeInvalidatesPendingFocus() {
        var stateOnly = CommandRequest(command: "arrange")
        stateOnly.stateOnly = true
        #expect(CommandRouter.invalidatesPendingFocus(stateOnly))

        var dryRun = CommandRequest(command: "arrange")
        dryRun.dryRun = true
        #expect(!CommandRouter.invalidatesPendingFocus(dryRun))
    }

    @Test func multiDisplayArrangeRejectsSingleLayoutOnlyOptions() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: [])
        defer { cleanup() }

        var request = CommandRequest(command: "arrange")
        request.layouts = ["work", "calendar"]
        request.spaceID = 1
        let response = try await send(router, request)

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["subcode"] as? String == "invalidArrangeBatchOptions")
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
        monitors:
          main:
            primary: true
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
        layoutSets:
          mobile:
            layouts: [work]
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

    @Test func layoutSetListAndApplyUseDedicatedContracts() async throws {
        let (router, engine, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        let listResponse = try await send(router, CommandRequest(command: "layoutSetsList"))
        #expect(listResponse["ok"] as? Bool == true)
        let listPayload = try #require(listResponse["payload"] as? [String: Any])
        let sets = try #require(listPayload["sets"] as? [[String: Any]])
        #expect(sets.first?["name"] as? String == "mobile")
        #expect(sets.first?["layouts"] as? [String] == ["work"])

        var applyRequest = CommandRequest(command: "arrangeSet")
        applyRequest.setName = "mobile"
        let applyResponse = try await send(router, applyRequest)
        #expect(applyResponse["ok"] as? Bool == true)
        let applyPayload = try #require(applyResponse["payload"] as? [String: Any])
        #expect(applyPayload["setName"] as? String == "mobile")
        #expect(applyPayload["ownershipCommitted"] as? Bool == true)
        #expect((await engine.currentState).selectedLayoutSet?.name == "mobile")
    }

    @Test func completedRequestIDReplaysTheSavedResponseWithoutExecutingAgain() async throws {
        let (router, engine, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        var request = CommandRequest(command: "arrangeSet")
        request.requestID = "stable-request-id"
        request.setName = "mobile"

        let first = try await send(router, request)
        let revision = (await engine.currentState).revision
        let frameAttempts = control.frameMutationAttemptWindowIDs.count
        let second = try await send(router, request)

        #expect(first["ok"] as? Bool == true)
        #expect(second["ok"] as? Bool == true)
        #expect((second["payload"] as? [String: Any])?["requestID"] as? String == "stable-request-id")
        #expect((await engine.currentState).revision == revision)
        #expect(control.frameMutationAttemptWindowIDs.count == frameAttempts)

        var conflict = request
        conflict.setName = "different"
        let conflictResponse = try await send(router, conflict)
        #expect(conflictResponse["exitCode"] as? Int == ErrorCode.validationError.rawValue)
        #expect((conflictResponse["error"] as? [String: Any])?["subcode"] as? String == "requestIDConflict")
    }

    @Test func duplicateActiveRequestReturnsInProgressSnapshotWithoutASecondExecution() async throws {
        let (router, engine, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        control.onFrameMutationAttempt = {
            control.onFrameMutationAttempt = nil
            release.wait()
        }
        var request = CommandRequest(command: "arrangeSet")
        request.requestID = "active-duplicate"
        request.setName = "mobile"
        let requestData = try JSONEncoder().encode(request)
        let first = Task { await router.handle(requestData: requestData) }
        var observedInFlight = false
        for _ in 0 ..< 100 {
            if engine.operationCoordinator.status().active?.inFlight == true {
                observedInFlight = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(observedInFlight)

        let duplicateData = await router.handle(requestData: requestData)
        let duplicate = try #require(
            JSONSerialization.jsonObject(with: duplicateData) as? [String: Any]
        )
        #expect(duplicate["exitCode"] as? Int == ErrorCode.operationBusy.rawValue)
        #expect((duplicate["error"] as? [String: Any])?["subcode"] as? String == "inProgress")
        #expect((duplicate["payload"] as? [String: Any])?["active"] as? [String: Any] != nil)

        release.signal()
        _ = await first.value
    }

    @Test func arrangeStatusIsActorIndependentAndBusyIsImmediate() async throws {
        let (router, engine, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }
        let token = try engine.operationCoordinator.tryAdmit(
            requestID: "active-request",
            operation: .arrangeSet
        )
        defer { engine.operationCoordinator.abandon(token: token) }
        engine.operationCoordinator.update(token: token, phase: .placing, layout: "work", inFlight: true)

        let statusResponse = try await send(router, CommandRequest(command: "arrangeStatus"))
        #expect(statusResponse["ok"] as? Bool == true)
        let payload = try #require(statusResponse["payload"] as? [String: Any])
        let active = try #require(payload["active"] as? [String: Any])
        #expect(active["requestID"] as? String == "active-request")
        #expect(active["inFlight"] as? Bool == true)

        var focus = CommandRequest(command: "focus")
        focus.slot = 1
        let busy = try await send(router, focus)
        #expect(busy["ok"] as? Bool == false)
        #expect(busy["exitCode"] as? Int == ErrorCode.operationBusy.rawValue)
        #expect((busy["error"] as? [String: Any])?["subcode"] as? String == "operationBusy")
    }

    @Test func statusAndRecoveryDoNotRequireValidConfig() async throws {
        let control = MockWindowControl(windows: standardWindows(), displays: [TestFixtures.display])
        let (store, stateURL) = TestFixtures.tempStateStore()
        let logger = TestFixtures.nullLogger()
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: logger, retryDelaysMS: [1])
        let configDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-invalid-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "unknownTopLevel: true\n".write(
            to: configDir.appendingPathComponent("01-invalid.yaml"),
            atomically: true,
            encoding: .utf8
        )
        let configManager = ConfigManager(directoryURL: configDir, logger: logger)
        configManager.start()
        defer {
            configManager.stop()
            try? FileManager.default.removeItem(at: configDir)
            try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent())
        }
        #expect(configManager.configIfLoaded() == nil)
        #expect(!configManager.configErrors().isEmpty)
        let router = CommandRouter(engine: engine, configManager: configManager, logger: logger)

        let status = try await send(router, CommandRequest(command: "arrangeStatus"))
        #expect(status["ok"] as? Bool == true)

        let recover = try await send(router, CommandRequest(command: "arrangeRecover"))
        #expect(recover["ok"] as? Bool == true)
        let payload = try #require(recover["payload"] as? [String: Any])
        #expect(payload["recoveryRequired"] as? Bool == false)
    }

    @Test func arrangeStateOnlyThenSpaceSwitchRoundTrip() async throws {
        let (router, _, control, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        var bootstrap = CommandRequest(command: "arrange")
        bootstrap.layouts = ["work"]
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
        bootstrap.layouts = ["work"]
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

        var scoped = CommandRequest(command: "spaceCurrent")
        scoped.layout = "work"
        let scopedResponse = try await send(router, scoped)
        let scopedPayload = try #require(scopedResponse["payload"] as? [String: Any])
        #expect(scopedPayload["layoutName"] as? String == "work")
        #expect((scopedPayload["space"] as? [String: Any])?["spaceID"] as? Int == 1)
    }

    @Test func spaceSwitchSupportsMonitorAliasAndFocusPolicy() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: standardWindows())
        defer { cleanup() }

        var bootstrap = CommandRequest(command: "arrange")
        bootstrap.layouts = ["work"]
        bootstrap.stateOnly = true
        bootstrap.spaceID = 1
        _ = try await send(router, bootstrap)

        var request = CommandRequest(command: "spaceSwitch")
        request.spaceID = 2
        request.monitor = "main"
        request.focus = .preserve
        let response = try await send(router, request)

        #expect(response["ok"] as? Bool == true)
        let payload = try #require(response["payload"] as? [String: Any])
        #expect(payload["spaceID"] as? Int == 2)
    }

    @Test func spaceSwitchRejectsLayoutAndMonitorTogether() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: [])
        defer { cleanup() }

        var request = CommandRequest(command: "spaceSwitch")
        request.spaceID = 1
        request.layout = "work"
        request.monitor = "main"
        let response = try await send(router, request)

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect((error["message"] as? String)?.contains("mutually exclusive") == true)
    }

    @Test func spaceSwitchDistinguishesUndefinedMonitorAlias() async throws {
        let (router, _, _, cleanup) = try makeRouter(windows: [])
        defer { cleanup() }

        var request = CommandRequest(command: "spaceSwitch")
        request.spaceID = 1
        request.monitor = "missing"
        let response = try await send(router, request)

        #expect(response["ok"] as? Bool == false)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["subcode"] as? String == "monitorNotFound")
        #expect((error["message"] as? String)?.contains("missing") == true)
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
        exact.requestID = UUID().uuidString.lowercased()
        exact.pid = target.pid
        exact.processStartTime = target.processStartTime
        exact.bundleID = target.bundleID

        var reusedProcess = exact
        reusedProcess.requestID = UUID().uuidString.lowercased()
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
        bootstrap.layouts = ["work"]
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
