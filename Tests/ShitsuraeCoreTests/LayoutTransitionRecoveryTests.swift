import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Layout transition recovery")
struct LayoutTransitionRecoveryTests {
    private final class SaveFailureController: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private let error: RuntimeStateStoreError

        init(failAt: Int, fileURL: URL) {
            remaining = failAt
            error = .writeFailed(fileURL: fileURL, reason: "injected save failure")
        }

        func failure(for _: RuntimeState) -> RuntimeStateStoreError? {
            lock.lock()
            defer { lock.unlock() }
            remaining -= 1
            return remaining == 0 ? error : nil
        }
    }

    private func fixture(
        inventoryAvailable: Bool = true,
        includeJournal: Bool = true
    ) throws -> (VirtualSpaceEngine, MockWindowControl, URL, WindowIdentity) {
        let window = TestFixtures.window(
            id: 7,
            bundleID: "com.example.Hidden",
            frame: ResolvedFrame(x: 2500, y: 20, width: 600, height: 500),
            isAXBacked: true,
            displayID: "disconnected"
        )
        var entry = SlotEntry(
            layoutName: "retired",
            spaceID: 1,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "retired-fingerprint",
            layoutSpaceID: 1,
            bundleID: window.bundleID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            windowID: window.windowID,
            displayID: "disconnected",
            lastVisibleFrame: ResolvedFrame(x: 100, y: 100, width: 600, height: 500),
            lastHiddenFrame: window.frame,
            visibilityState: .hiddenOffscreen
        )
        entry.lastKnownTitle = window.title
        let journal = includeJournal ? PendingLayoutTransition(
            requestID: "interrupted",
            scopeKind: .layoutSet,
            phase: .precommit,
            sourceLayoutNames: ["retired"],
            targetLayoutNames: ["target"],
            sourceSelectedSet: nil,
            targetSet: SelectedLayoutSet(name: "mobile", memberNames: ["target"], definitionDigest: "digest"),
            definitionDigest: "digest",
            topologyDigest: "topology"
        ) : nil
        let state = RuntimeState(
            pendingLayoutTransition: journal,
            activeWorkspaces: [ActiveWorkspace(displayID: "disconnected", layoutName: "retired", spaceID: 1)],
            slots: [entry]
        )
        let (store, url) = TestFixtures.tempStateStore()
        try store.saveStrict(state: state)
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])
        control.windowInventoryAvailable = inventoryAvailable
        let engine = try VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        return (engine, control, url, window.identity)
    }

    private func recover(_ engine: VirtualSpaceEngine) async throws -> LayoutRecoveryJSON {
        let token = try engine.operationCoordinator.tryAdmit(
            requestID: "recover",
            operation: .recover,
            permitsRecovery: true
        )
        defer { engine.operationCoordinator.abandon(token: token) }
        let result = try await engine.recoverLayoutTransition(requestID: "recover", token: token)
        engine.operationCoordinator.finish(token: token, result: result.result, exitCode: result.exitCode)
        return result
    }

    @Test func recoveryNeedsNoConfigAndReleasesExactLiveIdentity() async throws {
        let (engine, control, url, identity) = try fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await recover(engine)

        #expect(result.result == "success")
        #expect(result.recoveryRequired == false)
        #expect(result.releasedCount == 1)
        let state = await engine.currentState
        #expect(state.pendingLayoutTransition == nil)
        #expect(state.activeWorkspaces.isEmpty)
        #expect(state.slots.isEmpty)
        #expect(state.releasedWindowIdentities.contains(identity))
        #expect(TestFixtures.display.visibleFrame.intersects(try #require(control.window(7)).frame.cgRect))
    }

    @Test func unavailableInventoryKeepsJournalAndEntryForRetry() async throws {
        let (engine, _, url, _) = try fixture(inventoryAvailable: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await recover(engine)

        #expect(result.result == "partial")
        #expect(result.recoveryRequired)
        #expect(result.remainingCount == 1)
        let state = await engine.currentState
        #expect(state.pendingLayoutTransition?.requestID == "interrupted")
        #expect(state.slots.count == 1)
        #expect(state.activeWorkspaces.count == 1)
    }

    @Test func recoveryWithoutJournalIncludesInactiveHiddenRecords() async throws {
        let (engine, _, url, identity) = try fixture(includeJournal: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await recover(engine)

        #expect(result.result == "success")
        #expect((await engine.currentState).releasedWindowIdentities.contains(identity))
    }

    @Test func coordinatorMirrorBlocksMutationButPermitsRecovery() throws {
        let coordinator = ArrangeOperationCoordinator()
        let journal = PendingLayoutTransition(
            requestID: "stale",
            scopeKind: .layoutSet,
            phase: .postcommit,
            sourceLayoutNames: ["home"],
            targetLayoutNames: ["mobile"],
            sourceSelectedSet: nil,
            targetSet: nil,
            definitionDigest: "digest",
            topologyDigest: "topology"
        )
        coordinator.updateJournalMirror(state: RuntimeState(revision: 4, pendingLayoutTransition: journal))

        #expect(throws: ShitsuraeError.self) {
            _ = try coordinator.tryAdmit(requestID: "normal", operation: .arrangeSet)
        }
        let token = try coordinator.tryAdmit(
            requestID: "recover",
            operation: .recover,
            permitsRecovery: true
        )
        coordinator.abandon(token: token)
    }

    @Test func coordinatorReportsBusyAndMonotonicDeadline() throws {
        let coordinator = ArrangeOperationCoordinator()
        let token = try coordinator.tryAdmit(
            requestID: "slow",
            operation: .arrangeSet,
            budgetMS: 1
        )
        #expect(throws: ShitsuraeError.self) {
            _ = try coordinator.tryAdmit(requestID: "second", operation: .arrange)
        }
        Thread.sleep(forTimeInterval: 0.01)
        let status = coordinator.status()
        #expect(status.active?.requestID == "slow")
        #expect(status.active?.deadlineExceeded == true)
        #expect(!coordinator.permitsNewSideEffect(token: token))
        coordinator.abandon(token: token)
    }

    @Test func failedJournalSaveDoesNotAdvanceMirrorOrStartPhysicalSideEffects() async throws {
        let window = TestFixtures.window(
            id: 1,
            bundleID: "com.example.Target",
            isAXBacked: true
        )
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let failure = SaveFailureController(failAt: 1, fileURL: url)
        store.saveFailureInjector = { failure.failure(for: $0) }
        let engine = try VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10
        )
        let targetLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.example.Target"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(
            layouts: ["target": targetLayout],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["target"])]
        )
        let token = try engine.operationCoordinator.tryAdmit(
            requestID: "persist-failure",
            operation: .arrangeSet
        )
        defer { engine.operationCoordinator.abandon(token: token) }

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.arrangeSet(
                setName: "mobile",
                requestID: "persist-failure",
                config: config,
                token: token
            )
        }

        #expect(engine.operationCoordinator.status().pendingTransition == nil)
        #expect(control.launchedRequests.isEmpty)
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
        #expect(control.focusedWindowIDs.isEmpty)
        #expect((await engine.currentState).revision == 0)
    }

    @Test func sixPersistenceBoundariesRemainRecoverableAfterRestart() async throws {
        for failAt in 1 ... 6 {
            let sourceWindow = TestFixtures.window(
                id: 7,
                bundleID: "com.example.Source",
                frame: ResolvedFrame(x: 2500, y: 40, width: 500, height: 400),
                isAXBacked: true,
                displayID: "disconnected"
            )
            let targetOne = TestFixtures.window(
                id: 1,
                bundleID: "com.example.One",
                isAXBacked: true
            )
            let targetTwo = TestFixtures.window(
                id: 2,
                bundleID: "com.example.Two",
                frame: ResolvedFrame(x: 720, y: 10, width: 700, height: 400),
                isAXBacked: true
            )
            var sourceEntry = SlotEntry(
                layoutName: "source",
                spaceID: 1,
                slot: 1,
                origin: .layout,
                definitionFingerprint: "source-fingerprint",
                layoutSpaceID: 1,
                bundleID: sourceWindow.bundleID,
                pid: sourceWindow.pid,
                processStartTime: sourceWindow.processStartTime,
                windowID: sourceWindow.windowID,
                displayID: "disconnected",
                lastVisibleFrame: ResolvedFrame(x: 50, y: 50, width: 500, height: 400),
                lastHiddenFrame: sourceWindow.frame,
                visibilityState: .hiddenOffscreen
            )
            sourceEntry.lastKnownTitle = sourceWindow.title
            let initial = RuntimeState(
                selectedLayoutSet: SelectedLayoutSet(
                    name: "home",
                    memberNames: ["source"],
                    definitionDigest: "old"
                ),
                activeWorkspaces: [
                    ActiveWorkspace(displayID: "disconnected", layoutName: "source", spaceID: 1),
                ],
                slots: [sourceEntry]
            )
            let targetLayout = LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: targetOne.bundleID),
                        slot: 1,
                        launch: false,
                        frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                    ),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: targetTwo.bundleID),
                        slot: 1,
                        launch: false,
                        frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                    ),
                ]),
            ])
            let config = TestFixtures.loadedConfig(
                layouts: ["target": targetLayout],
                layoutSets: ["mobile": LayoutSetDefinition(layouts: ["target"])]
            )
            let (store, url) = TestFixtures.tempStateStore()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try store.saveStrict(state: initial)
            let failure = SaveFailureController(failAt: failAt, fileURL: url)
            store.saveFailureInjector = { failure.failure(for: $0) }
            let control = MockWindowControl(
                windows: [sourceWindow, targetOne, targetTwo],
                displays: [TestFixtures.display]
            )
            var engine = try VirtualSpaceEngine(
                store: store,
                control: control,
                logger: TestFixtures.nullLogger(),
                retryDelaysMS: [1],
                arrangeWaitTimeoutMS: 10
            )
            let token = try engine.operationCoordinator.tryAdmit(
                requestID: "failure-\(failAt)",
                operation: .arrangeSet
            )
            do {
                _ = try await engine.arrangeSet(
                    setName: "mobile",
                    requestID: "failure-\(failAt)",
                    config: config,
                    token: token
                )
                Issue.record("boundary \(failAt) unexpectedly completed")
            } catch {
                // Expected: the injected durable-state failure interrupts the operation.
            }
            engine.operationCoordinator.abandon(token: token)
            store.saveFailureInjector = nil

            let interrupted = try store.loadStrict()
            let identities = interrupted.slots.compactMap(\.boundIdentity)
            #expect(identities.count == Set(identities).count)

            engine = try VirtualSpaceEngine(
                store: store,
                control: control,
                logger: TestFixtures.nullLogger(),
                retryDelaysMS: [1],
                arrangeWaitTimeoutMS: 10
            )
            let result = try await recover(engine)
            #expect(result.result == "success")
            let recovered = await engine.currentState
            #expect(recovered.pendingLayoutTransition == nil)
            #expect(recovered.slots.isEmpty)
            #expect(recovered.activeWorkspaces.isEmpty)
            var expectedReleased: Set<WindowIdentity> = [sourceWindow.identity]
            if failAt >= 4 {
                expectedReleased.formUnion([targetOne.identity, targetTwo.identity])
            }
            #expect(Set(recovered.releasedWindowIdentities).isSuperset(of: expectedReleased))
            for windowID in [sourceWindow.windowID, targetOne.windowID, targetTwo.windowID] {
                #expect(TestFixtures.display.visibleFrame.intersects(try #require(control.window(windowID)).frame.cgRect))
            }
        }
    }
}
