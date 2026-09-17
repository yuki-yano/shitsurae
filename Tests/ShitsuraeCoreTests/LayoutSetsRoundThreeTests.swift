import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Layout sets Round 3", .serialized)
struct LayoutSetsRoundThreeTests {
    private let reason = "retainedAdoptedGeometryBlocked"
    private struct Fixture {
        let engine: VirtualSpaceEngine
        let control: MockWindowControl
        let store: RuntimeStateStore
        let directory: URL
        let config: LoadedConfig
        let adopted: SlotEntry
        let blocked: WindowSnapshot
    }

    private func fixture(clock: TestMonotonicClock? = nil) throws -> Fixture {
        let good = TestFixtures.window(id: 1, bundleID: "Good", isAXBacked: true)
        let blocked = TestFixtures.window(id: 2, bundleID: "Extra",
            frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), geometryBlocked: true, isAXBacked: true)
        let side = TestFixtures.window(id: 3, bundleID: "Side", isAXBacked: true, displayID: "uuid-sub")
        func definition(_ bundle: String) -> WindowDefinition {
            WindowDefinition(match: WindowMatchRule(bundleID: bundle), slot: 1, launch: false,
                frame: TestFixtures.frameDef("0%", "0%", "100%", "100%"))
        }
        let main = LayoutDefinition(initialFocus: InitialFocusDefinition(slot: 1),
            spaces: [SpaceDefinition(spaceID: 1, windows: [definition("Good")])])
        let secondary = LayoutDefinition(display: DisplayDefinition(id: "uuid-sub"),
            spaces: [SpaceDefinition(spaceID: 1, windows: [definition("Side")])])
        let config = TestFixtures.loadedConfig(layouts: ["main": main, "side": secondary],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main", "side"])])
        var adopted = SlotEntry.makeEntry(layoutName: "main", spaceID: 2,
            definition: WindowDefinition(match: WindowMatchRule(bundleID: "Extra"), slot: 7, launch: false)).bound(to: blocked)
        adopted.origin = .adopted
        adopted.layoutSpaceID = nil
        adopted.visibilityState = .hiddenOffscreen
        adopted.lastHiddenFrame = blocked.frame
        adopted.lastVisibleFrame = ResolvedFrame(x: 30, y: 30, width: 500, height: 400)
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main", "side"], definitionDigest: "old"),
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 2)], slots: [adopted])
        let (store, url) = TestFixtures.tempStateStore()
        try store.saveStrict(state: state)
        let control = MockWindowControl(windows: [good, blocked, side], displays: [TestFixtures.display, TestFixtures.secondaryDisplay()])
        let coordinator = ArrangeOperationCoordinator(uptimeNanoseconds: { clock?.now ?? DispatchTime.now().uptimeNanoseconds })
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: TestFixtures.nullLogger(), retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10, operationCoordinator: coordinator)
        return Fixture(engine: engine, control: control, store: store, directory: url.deletingLastPathComponent(),
            config: config, adopted: adopted, blocked: blocked)
    }

    private func expectProtectedRecovery(_ f: Fixture) throws {
        let saved = try f.store.loadStrict()
        let entry = try #require(saved.slots.first { $0.id == f.adopted.id })
        #expect(saved.pendingLayoutTransition?.phase == .postcommit)
        #expect(entry.spaceID == 1 && entry.slot == f.adopted.slot && entry.origin == .adopted)
        #expect(entry.boundIdentity == f.adopted.boundIdentity && entry.definitionFingerprint == f.adopted.definitionFingerprint)
        #expect(entry.lastVisibleFrame == f.adopted.lastVisibleFrame && entry.lastHiddenFrame == f.adopted.lastHiddenFrame)
        #expect(entry.visibilityState == .hiddenOffscreen && saved.releasedWindowIdentities.isEmpty)
        #expect(f.control.window(f.blocked.windowID)?.frame == f.blocked.frame)
        #expect(!f.control.frameMutationAttemptWindowIDs.contains(f.blocked.windowID))
        #expect(!f.control.minimizeAttempts.contains { $0.windowID == f.blocked.windowID })
        #expect(!f.control.focusedWindowIDs.contains(f.blocked.windowID))
    }

    @Test(arguments: [false, true])
    func protectedAdoptedReportsPartialWithActualSlotAndRecovery(single: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        if single {
            let result = try await f.engine.arrange(layoutName: "main", spaceID: nil, config: f.config)
            #expect(result.result == "partial" && result.exitCode == 51)
            #expect(result.hardErrors.isEmpty && result.unresolvedSlots.isEmpty)
            #expect(result.softErrors == [ErrorItem(code: 51, message: reason, spaceID: 1, slot: 7)])
        } else {
            let result = try await f.engine.arrangeSet(setName: "home", requestID: "blocked-set", config: f.config)
            #expect(result.result == "partial" && result.exitCode == 51 && result.recoveryRequired)
            #expect(result.unresolved == [PendingUnresolvedSlot(slot: 7, spaceID: 1, reason: reason)])
            #expect(result.memberResults.first { $0.layout == "main" }?.result == "partial")
            #expect(result.memberResults.first { $0.layout == "main" }?.reason == reason)
            #expect(result.memberResults.first { $0.layout == "side" }?.result == "success")
            #expect(result.memberResults.first { $0.layout == "side" }?.reason == nil)
            #expect(result.focusOutcome == "focused")
        }
        try expectProtectedRecovery(f)
        let status = f.engine.operationCoordinator.status()
        #expect(status.active == nil && status.lastOutcome?.result == "partial" && status.lastOutcome?.exitCode == 51)
        #expect(status.lastOutcome?.detail?.contains(reason) == true && status.lastOutcome?.recoveryRequired == true)
        #expect(f.control.window(1)?.frame == ResolvedFrame(x: 0, y: 0, width: 1440, height: 875))
    }

    @Test(arguments: [false, true])
    func protectedAdoptedDeadlineTakesPriorityOverPartial(single: Bool) async throws {
        let clock = TestMonotonicClock()
        let f = try fixture(clock: clock); defer { try? FileManager.default.removeItem(at: f.directory) }
        var revisionAtDeadline: UInt64?
        f.control.onFocusAttempt = {
            revisionAtDeadline = try? f.store.loadStrict().revision
            clock.advance(milliseconds: 61_000)
        }
        if single {
            let result = try await f.engine.arrange(layoutName: "main", spaceID: nil, config: f.config)
            #expect(result.result == "failed" && result.exitCode == 50)
        } else {
            let result = try await f.engine.arrangeSet(setName: "home", requestID: "blocked-deadline", config: f.config)
            #expect(result.result == "failed" && result.exitCode == 50 && result.recoveryRequired)
        }
        let finalRevision = try f.store.loadStrict().revision
        #expect(revisionAtDeadline != nil && finalRevision == revisionAtDeadline)
        #expect(f.engine.operationCoordinator.status().lastOutcome?.exitCode == 50)
        #expect(f.control.activatedBundles.isEmpty)
        try expectProtectedRecovery(f)
    }

    @Test(arguments: [false, true])
    func cliRouterReportsProtectedAdoptedPartialWithoutLiveIPC(single: Bool) async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.directory) }
        let configDirectory = f.directory.appendingPathComponent("config")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        layouts:
          main:
            initialFocus: {slot: 1}
            spaces:
              - spaceID: 1
                windows:
                  - slot: 1
                    launch: false
                    match: {bundleID: Good}
                    frame: {x: "0%", y: "0%", width: "100%", height: "100%"}
        layoutSets:
          home:
            layouts: [main]
        """.write(to: configDirectory.appendingPathComponent("config.yml"), atomically: true, encoding: .utf8)
        let logger = TestFixtures.nullLogger()
        let manager = ConfigManager(directoryURL: configDirectory, logger: logger)
        #expect(manager.reload(trigger: "r3-test"))
        let router = CommandRouter(engine: f.engine, configManager: manager, logger: logger)
        var request = CommandRequest(command: single ? "arrange" : "arrangeSet")
        request.requestID = "cli-protected"
        if single { request.layouts = ["main"] } else { request.setName = "home" }
        let response = await router.handle(requestData: try JSONEncoder().encode(request))
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let payload = try #require(json["payload"] as? [String: Any])
        #expect(json["exitCode"] as? Int == 51 && payload["result"] as? String == "partial")
        if single {
            let errors = try #require(payload["softErrors"] as? [[String: Any]])
            #expect(errors.first?["message"] as? String == reason && errors.first?["slot"] as? Int == 7)
        } else {
            let unresolved = try #require(payload["unresolved"] as? [[String: Any]])
            #expect(unresolved.first?["reason"] as? String == reason && unresolved.first?["slot"] as? Int == 7)
        }
        #expect(f.engine.operationCoordinator.status().lastOutcome?.result == "partial")
        #expect(f.engine.operationCoordinator.status().lastOutcome?.exitCode == 51)
        #expect(f.engine.operationCoordinator.status().lastOutcome?.detail?.contains(reason) == true)
        try expectProtectedRecovery(f)
    }
}
