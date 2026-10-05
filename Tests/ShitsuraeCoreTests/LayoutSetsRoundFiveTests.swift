import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Layout sets Round 5")
struct LayoutSetsRoundFiveTests {
    private let yaml = """
    layouts:
      main:
        spaces:
          - spaceID: 1
            windows:
              - slot: 1
                launch: false
                match: {bundleID: Good}
                frame: {x: "0%", y: "0%", width: "50%", height: "100%"}
              - slot: 2
                launch: false
                match: {bundleID: Another}
                frame: {x: "50%", y: "0%", width: "50%", height: "100%"}
      side:
        display: {id: uuid-sub}
        spaces:
          - spaceID: 1
            windows: []
    """
    private struct Fixture {
        let router: CommandRouter
        let engine: VirtualSpaceEngine
        let control: MockWindowControl
        let store: RuntimeStateStore
        let directory: URL
    }
    private func fixture(state: RuntimeState = RuntimeState(), windows: [WindowSnapshot] = []) throws -> Fixture {
        let (store, url) = TestFixtures.tempStateStore()
        try store.saveStrict(state: state)
        let directory = url.deletingLastPathComponent()
        let configDirectory = directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try yaml.write(to: configDirectory.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
        let logger = TestFixtures.nullLogger()
        let manager = ConfigManager(directoryURL: configDirectory, logger: logger)
        #expect(manager.reload(trigger: "r5-test"))
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display, TestFixtures.secondaryDisplay()])
        let waitClock = ArrangeWaitTestClock.connected(to: control)
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: logger, retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10, arrangeUptimeNanoseconds: { waitClock.now }, operationCoordinator: ArrangeOperationCoordinator())
        return Fixture(router: CommandRouter(engine: engine, configManager: manager, logger: logger),
            engine: engine, control: control, store: store, directory: directory)
    }
    private func send(_ f: Fixture, command: String = "arrange", batch: Bool = false, requestID: String) async throws -> [String: Any] {
        var request = CommandRequest(command: command)
        request.requestID = requestID
        if command == "arrange" { request.layouts = batch ? ["main", "side"] : ["main"] }
        let response = await f.router.handle(requestData: try JSONEncoder().encode(request))
        return try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    @Test(arguments: [false, true])
    func routerSuccessClearsPreviousPartialDetailAndRecoveryHasNoRemainingCount(batch: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let partial = try await send(f, batch: batch, requestID: "partial-before-success")
        let payload = try #require(partial["payload"] as? [String: Any])
        #expect(partial["exitCode"] as? Int == 51 && payload["result"] as? String == "partial")
        let outcome = try #require(f.engine.operationCoordinator.status().lastOutcome)
        #expect(outcome.requestID == "partial-before-success" && outcome.result == "partial" && outcome.exitCode == 51)
        let detail = try #require(outcome.detail)
        #expect(detail.contains("target window not found: Good") && detail.contains("target window not found: Another"))
        if batch { #expect(detail.contains("main: ")) }
        let status = try await send(f, command: "arrangeStatus", requestID: "status")
        let statusPayload = try #require(status["payload"] as? [String: Any])
        let last = try #require(statusPayload["lastOutcome"] as? [String: Any])
        #expect(last["detail"] as? String == detail)
        #expect(try f.store.loadStrict().pendingLayoutTransition == nil)
        let good = TestFixtures.window(id: 1, bundleID: "Good", isAXBacked: true)
        let another = TestFixtures.window(id: 2, bundleID: "Another", isAXBacked: true)
        f.control.addWindow(good)
        f.control.addWindow(another)
        let json = try await send(f, batch: batch, requestID: "success")
        #expect(json["exitCode"] as? Int == 0)
        #expect(f.engine.operationCoordinator.status().lastOutcome?.result == "success")
        #expect(f.engine.operationCoordinator.status().lastOutcome?.detail == nil)
        #expect(try f.store.loadStrict().pendingLayoutTransition == nil)
        let beforeRecovery = await f.engine.currentState
        // The extra batch member has no windows: both paths present the same
        // two visible bound targets and no journal to the configless recovery.
        #expect(beforeRecovery.slots.count == 2)
        #expect(Set(beforeRecovery.slots.map(\.layoutName)) == ["main"])
        #expect(Set(beforeRecovery.slots.compactMap(\.boundIdentity)) == [good.identity, another.identity])
        #expect(beforeRecovery.slots.allSatisfy { $0.visibilityState == .visible })
        #expect(beforeRecovery.pendingLayoutTransition == nil)
        if !batch {
            let recovered = try await send(f, command: "arrangeRecover", requestID: "recovery-success")
            let recoveryPayload = try #require(recovered["payload"] as? [String: Any])
            #expect(recovered["exitCode"] as? Int == 0 && recoveryPayload["remainingCount"] as? Int == 0)
            #expect(f.engine.operationCoordinator.status().lastOutcome?.result == "success")
            #expect(f.engine.operationCoordinator.status().lastOutcome?.detail == nil)
        }
    }

    @Test func routerRecoverPartialPublishesRemainingCountAndKeepsProtectedBindings() async throws {
        let windows = [UInt32(1), 2].map { TestFixtures.window(id: $0, bundleID: "Blocked\($0)",
            frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), geometryBlocked: true, isAXBacked: true) }
        let slots = windows.map { window in
            var entry = SlotEntry.makeEntry(layoutName: "main", spaceID: 1,
                definition: WindowDefinition(match: WindowMatchRule(bundleID: window.bundleID), slot: Int(window.windowID))).bound(to: window)
            entry.visibilityState = .hiddenOffscreen
            entry.lastHiddenFrame = window.frame
            entry.lastVisibleFrame = ResolvedFrame(x: 30, y: 30, width: 500, height: 400)
            return entry
        }
        let journal = PendingLayoutTransition(requestID: "interrupted", scopeKind: .local, phase: .postcommit,
            sourceLayoutNames: ["main"], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil,
            definitionDigest: "old", topologyDigest: "old")
        let f = try fixture(state: RuntimeState(pendingLayoutTransition: journal, slots: slots), windows: windows)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let before = try f.store.loadStrict()
        let json = try await send(f, command: "arrangeRecover", requestID: "recovery-partial")
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(json["exitCode"] as? Int == 51 && payload["remainingCount"] as? Int == 2)
        let outcome = try #require(f.engine.operationCoordinator.status().lastOutcome)
        #expect(outcome.result == "partial" && outcome.exitCode == 51 && outcome.detail == "2 windows still need recovery")
        #expect(outcome.recoveryRequired)
        #expect(try f.store.loadStrict() == before)
        #expect(f.control.frameMutationAttemptWindowIDs.isEmpty && f.control.minimizeAttempts.isEmpty && f.control.focusedWindowIDs.isEmpty)
    }

    @Test func sharedDetailIncludesHardSoftUnresolvedReasonsAndLayoutContext() {
        let execution = ArrangeExecutionJSON(layout: "main", result: "partial", subcode: nil,
            unresolvedSlots: [PendingUnresolvedSlot(slot: 3, spaceID: 1, reason: "reservedExactIdentity")],
            hardErrors: [ErrorItem(code: 50, message: "hard reason", spaceID: 1, slot: 1)],
            softErrors: [ErrorItem(code: 51, message: "soft reason", spaceID: 1, slot: 2)],
            skipped: [], warnings: [], exitCode: 51)
        #expect(execution.outcomeDetail == "hard reason; soft reason; reservedExactIdentity")
        #expect(ArrangeBatchExecutionJSON(layouts: [execution]).outcomeDetail == "main: hard reason; soft reason; reservedExactIdentity")
    }
}
