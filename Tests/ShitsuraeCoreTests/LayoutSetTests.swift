import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Layout sets")
struct LayoutSetTests {
    private func fullFrame() -> FrameDefinition {
        TestFixtures.frameDef("0%", "0%", "100%", "100%")
    }

    private func layout(
        bundleID: String,
        display: DisplayDefinition? = nil,
        initialFocus: Int? = nil,
        extraSpaces: [SpaceDefinition] = [],
        title: TitleMatcher? = nil,
        index: Int? = nil
    ) -> LayoutDefinition {
        LayoutDefinition(
            initialFocus: initialFocus.map(InitialFocusDefinition.init(slot:)),
            display: display,
            spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: bundleID, title: title, index: index),
                        slot: 1,
                        launch: false,
                        frame: fullFrame()
                    ),
                ]),
            ] + extraSpaces
        )
    }

    private func config(
        mobileIncludesMissingWindow: Bool = false,
        ignore: IgnoreDefinition? = nil
    ) -> LoadedConfig {
        var mobileWindows = [
            WindowDefinition(
                match: WindowMatchRule(bundleID: "com.example.Editor"),
                slot: 1,
                launch: false,
                frame: fullFrame()
            ),
        ]
        if mobileIncludesMissingWindow {
            mobileWindows.append(
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.example.Missing"),
                    slot: 2,
                    launch: false,
                    frame: fullFrame()
                )
            )
        }
        let layouts = [
            "default": layout(bundleID: "com.example.Editor", initialFocus: 1),
            "calendar": layout(
                bundleID: "com.example.Calendar",
                display: DisplayDefinition(monitor: "calendar"),
                extraSpaces: [SpaceDefinition(spaceID: 2, windows: [])]
            ),
            "research": layout(
                bundleID: "com.example.Research",
                display: DisplayDefinition(id: "uuid-research")
            ),
            "macbook-pro": LayoutDefinition(
                initialFocus: InitialFocusDefinition(slot: 1),
                spaces: [SpaceDefinition(spaceID: 1, windows: mobileWindows)]
            ),
        ]
        return TestFixtures.loadedConfig(
            layouts: layouts,
            layoutSets: [
                "home": LayoutSetDefinition(layouts: ["default", "calendar", "research"]),
                "mobile": LayoutSetDefinition(layouts: ["macbook-pro"]),
            ],
            ignore: ignore,
            monitors: MonitorsDefinition([
                "main": MonitorTargetDefinition(primary: true),
                "calendar": MonitorTargetDefinition(id: "uuid-sub"),
                "research": MonitorTargetDefinition(id: "uuid-research"),
            ])
        )
    }

    private func displays(includeResearch: Bool = true) -> [DisplayInfo] {
        var result = [TestFixtures.display, TestFixtures.secondaryDisplay()]
        if includeResearch {
            result.append(
                DisplayInfo(
                    id: "uuid-research",
                    width: 2560,
                    height: 1440,
                    scale: 2,
                    isPrimary: false,
                    frame: CGRect(x: -1280, y: 0, width: 1280, height: 720),
                    visibleFrame: CGRect(x: -1280, y: 0, width: 1280, height: 720)
                )
            )
        }
        return result
    }

    private func windows(includeResearch: Bool = true) -> [WindowSnapshot] {
        var result = [
            TestFixtures.window(id: 1, bundleID: "com.example.Editor", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(
                id: 2,
                bundleID: "com.example.Calendar",
                frame: ResolvedFrame(x: 1500, y: 20, width: 600, height: 500),
                isAXBacked: true,
                frontIndex: 1,
                displayID: "uuid-sub"
            ),
        ]
        if includeResearch {
            result.append(
                TestFixtures.window(
                    id: 3,
                    bundleID: "com.example.Research",
                    frame: ResolvedFrame(x: -1200, y: 20, width: 600, height: 500),
                    isAXBacked: true,
                    frontIndex: 2,
                    displayID: "uuid-research"
                )
            )
        }
        return result
    }

    private func makeEngine(
        windows: [WindowSnapshot],
        displays: [DisplayInfo],
        coordinator: ArrangeOperationCoordinator = ArrangeOperationCoordinator()
    ) -> (VirtualSpaceEngine, MockWindowControl, URL) {
        let control = MockWindowControl(windows: windows, displays: displays)
        let (store, url) = TestFixtures.tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10,
            operationCoordinator: coordinator
        )
        return (engine, control, url)
    }

    private func apply(
        _ setName: String,
        engine: VirtualSpaceEngine,
        config: LoadedConfig
    ) async throws -> LayoutSetExecutionJSON {
        let requestID = UUID().uuidString.lowercased()
        let token = try engine.operationCoordinator.tryAdmit(
            requestID: requestID,
            operation: .arrangeSet
        )
        defer { engine.operationCoordinator.abandon(token: token) }
        let result = try await engine.arrangeSet(
            setName: setName,
            requestID: requestID,
            config: config,
            token: token
        )
        engine.operationCoordinator.finish(token: token, result: result.result, exitCode: result.exitCode)
        return result
    }

    @Test func homeAndMobileReplaceTheCompleteManagedScope() async throws {
        let loaded = config()
        let (engine, control, url) = makeEngine(windows: windows(), displays: displays())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let home = try await apply("home", engine: engine, config: loaded)
        #expect(home.result == "success")
        var state = await engine.currentState
        #expect(Set(state.activeWorkspaces.map(\.layoutName)) == Set(["default", "calendar", "research"]))
        #expect(state.selectedLayoutSet?.name == "home")
        #expect(Set(state.slots.compactMap(\.boundIdentity)).count == state.slots.compactMap(\.boundIdentity).count)

        _ = try await engine.switchSpace(
            layoutName: "calendar",
            to: 2,
            config: loaded,
            shouldFocusTarget: false
        )
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: try #require(control.window(2)).frame,
            displays: displays()
        ))

        let mobile = try await apply("mobile", engine: engine, config: loaded)
        #expect(mobile.result == "success")
        state = await engine.currentState
        #expect(state.activeWorkspaces.map(\.layoutName) == ["macbook-pro"])
        #expect(state.selectedLayoutSet?.name == "mobile")
        #expect(!state.slots.contains { $0.layoutName == "calendar" || $0.layoutName == "research" })
        #expect(state.releasedWindowIdentities.contains(try #require(control.window(2)).identity))
        #expect(state.releasedWindowIdentities.contains(try #require(control.window(3)).identity))
        #expect(TestFixtures.display.visibleFrame.intersects(try #require(control.window(2)).frame.cgRect))
    }

    @Test func missingWindowCommitsPartialAndReapplyFillsTheSlot() async throws {
        let loaded = config(mobileIncludesMissingWindow: true)
        let (engine, control, url) = makeEngine(
            windows: [TestFixtures.window(id: 1, bundleID: "com.example.Editor", isAXBacked: true)],
            displays: [TestFixtures.display]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let partial = try await apply("mobile", engine: engine, config: loaded)
        #expect(partial.result == "partial")
        #expect(partial.ownershipCommitted)
        #expect(partial.unresolved.contains { $0.slot == 2 && $0.reason == "windowNotFound" })
        var state = await engine.currentState
        #expect(state.selectedLayoutSet?.name == "mobile")
        #expect(state.pendingLayoutTransition == nil)
        #expect(state.slots.contains { $0.slot == 2 && $0.boundIdentity == nil })

        control.addWindow(
            TestFixtures.window(id: 4, bundleID: "com.example.Missing", isAXBacked: true, frontIndex: 1)
        )
        let completed = try await apply("mobile", engine: engine, config: loaded)
        #expect(completed.result == "success")
        state = await engine.currentState
        #expect(state.slots.contains { $0.slot == 2 && $0.windowID == 4 })
    }

    @Test func dryRunUsesPlannerWithoutMutatingStateOrWindows() async throws {
        let loaded = config()
        let (engine, control, url) = makeEngine(windows: windows(), displays: displays())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = await engine.currentState

        let result = try await engine.arrangeSetDryRun(
            setName: "home",
            requestID: "dry-run",
            config: loaded
        )

        #expect(result.result == "dryRun")
        #expect(result.members.map(\.layout) == ["default", "calendar", "research"])
        #expect(await engine.currentState == before)
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
        #expect(control.focusedWindowIDs.isEmpty)
        #expect(control.launchedRequests.isEmpty)
    }

    @Test func displayCollisionAndMissingDisplayFailBeforeMutation() async throws {
        let collisionConfig = TestFixtures.loadedConfig(
            layouts: [
                "a": layout(bundleID: "com.example.A"),
                "b": layout(bundleID: "com.example.B"),
            ],
            layoutSets: ["bad": LayoutSetDefinition(layouts: ["a", "b"])]
        )
        let (collisionEngine, collisionControl, collisionURL) = makeEngine(
            windows: [],
            displays: [TestFixtures.display]
        )
        defer { try? FileManager.default.removeItem(at: collisionURL.deletingLastPathComponent()) }
        await #expect(throws: ShitsuraeError.self) {
            _ = try await collisionEngine.arrangeSetDryRun(
                setName: "bad",
                requestID: "collision",
                config: collisionConfig
            )
        }
        #expect(collisionControl.frameMutationAttemptWindowIDs.isEmpty)

        let loaded = config()
        let (engine, control, url) = makeEngine(windows: windows(includeResearch: false), displays: displays(includeResearch: false))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await #expect(throws: ShitsuraeError.self) {
            _ = try await apply("home", engine: engine, config: loaded)
        }
        #expect((await engine.currentState).pendingLayoutTransition == nil)
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
        #expect(control.launchedRequests.isEmpty)
    }

    @Test func missingAccessibilityFailsBeforeStateOrWindowSideEffects() async throws {
        let loaded = config()
        let (engine, control, url) = makeEngine(windows: windows(), displays: displays())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        control.accessibilityAvailable = false

        do {
            _ = try await apply("home", engine: engine, config: loaded)
            Issue.record("expected missing permission")
        } catch let error as ShitsuraeError {
            #expect(error.code == .missingPermission)
        }

        #expect((await engine.currentState).revision == 0)
        #expect(control.launchedRequests.isEmpty)
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
        #expect(control.focusedWindowIDs.isEmpty)
    }

    @Test func globalIndexConflictIsReportedBeforeMutation() async throws {
        let layouts = [
            "main": layout(bundleID: "com.example.Browser", index: 1),
            "side": layout(
                bundleID: "com.example.Browser",
                display: DisplayDefinition(monitor: "calendar"),
                title: TitleMatcher(contains: "Doc"),
                index: 1
            ),
        ]
        let loaded = TestFixtures.loadedConfig(
            layouts: layouts,
            layoutSets: ["conflict": LayoutSetDefinition(layouts: ["main", "side"])]
        )
        let (engine, control, url) = makeEngine(
            windows: [
                TestFixtures.window(
                    id: 9,
                    bundleID: "com.example.Browser",
                    title: "Doc",
                    isAXBacked: true
                ),
            ],
            displays: [TestFixtures.display, TestFixtures.secondaryDisplay()]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        do {
            _ = try await engine.arrangeSetDryRun(
                setName: "conflict",
                requestID: "candidate-conflict",
                config: loaded
            )
            Issue.record("expected candidate conflict")
        } catch let error as ShitsuraeError {
            #expect(error.subcode == "candidateConflict")
        }
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
        #expect((await engine.currentState).revision == 0)
    }

    @Test func titleBasedInitialFocusIgnoreIsRuntimePartial() async throws {
        let ignored = IgnoreDefinition(
            apply: IgnoreRuleSet(windows: [IgnoreWindowRule(titleRegex: "^Ignore")])
        )
        let focusLayout = layout(bundleID: "com.example.Editor", initialFocus: 1)
        let loaded = TestFixtures.loadedConfig(
            layouts: ["mobile": focusLayout],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["mobile"])],
            ignore: ignored
        )
        let (engine, _, url) = makeEngine(
            windows: [
                TestFixtures.window(
                    id: 1,
                    bundleID: "com.example.Editor",
                    title: "Ignore this window",
                    isAXBacked: true
                ),
            ],
            displays: [TestFixtures.display]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await apply("mobile", engine: engine, config: loaded)
        #expect(result.result == "partial")
        #expect(result.ownershipCommitted)
        #expect(result.focusOutcome == "unavailable")
        #expect(result.unresolved.contains { $0.reason == "initialFocusIgnored" })
    }

    @Test func finalFocusRespectsAUserOverrideDuringPlacement() async throws {
        let loaded = TestFixtures.loadedConfig(
            layouts: ["mobile": layout(bundleID: "com.example.Editor", initialFocus: 1)],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["mobile"])]
        )
        let editor = TestFixtures.window(id: 1, bundleID: "com.example.Editor", isAXBacked: true)
        let notes = TestFixtures.window(id: 2, bundleID: "com.example.Notes", isAXBacked: true)
        let (engine, control, url) = makeEngine(
            windows: [editor, notes],
            displays: [TestFixtures.display]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        control.setFocusedWindowID(1)
        control.userFocusOnFrameMutationAttempt = 2

        let result = try await apply("mobile", engine: engine, config: loaded)

        #expect(result.result == "success")
        #expect(result.focusOutcome == "userOverridden")
        #expect(control.focusedWindowIdentity() == notes.identity)
        #expect(control.focusedWindowIDs == [1])
    }

    @Test func releasedWindowIsNotReadoptedByFocusButExplicitWorkspaceClaimRestoresOwnership() async throws {
        let loaded = config()
        let notes = TestFixtures.window(
            id: 8,
            bundleID: "com.example.Notes",
            isAXBacked: true,
            frontIndex: 3
        )
        let (engine, control, url) = makeEngine(
            windows: windows() + [notes],
            displays: displays()
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await apply("home", engine: engine, config: loaded)
        _ = try await apply("mobile", engine: engine, config: loaded)
        var state = await engine.currentState
        #expect(state.releasedWindowIdentities.contains(notes.identity))
        #expect(!state.slots.contains { $0.boundIdentity == notes.identity })

        control.setFocusedWindowID(notes.windowID)
        let focusOutcome = await engine.processFocusEvent(
            sequence: 1,
            windowID: notes.windowID,
            pid: notes.pid,
            processStartTime: notes.processStartTime,
            bundleID: notes.bundleID,
            config: loaded
        )
        #expect(focusOutcome?.spaceID == nil)
        #expect(try await engine.adoptUntrackedWindows(config: loaded) == 0)
        state = await engine.currentState
        #expect(!state.slots.contains { $0.boundIdentity == notes.identity })

        _ = try await engine.windowWorkspace(
            selector: WindowTargetSelector(
                windowID: notes.windowID,
                pid: notes.pid,
                processStartTime: notes.processStartTime,
                bundleID: notes.bundleID
            ),
            toSpaceID: 1,
            config: loaded
        )
        state = await engine.currentState
        #expect(!state.releasedWindowIdentities.contains(notes.identity))
        #expect(state.slots.contains { $0.boundIdentity == notes.identity })
    }

    @Test func needsReapplyBlocksGeometryAndSpaceChangesButAllowsExactVisibleFocus() async throws {
        let loaded = TestFixtures.loadedConfig(
            layouts: ["mobile": layout(bundleID: "com.example.Editor", initialFocus: 1)],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["mobile"])]
        )
        let editor = TestFixtures.window(id: 1, bundleID: "com.example.Editor", isAXBacked: true)
        let (engine, control, url) = makeEngine(
            windows: [editor],
            displays: [TestFixtures.display]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await apply("mobile", engine: engine, config: loaded)
        let attemptsBefore = control.frameMutationAttemptWindowIDs.count

        let changedLayout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 1),
            spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.example.Editor"),
                        slot: 1,
                        launch: false,
                        frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                    ),
                ]),
            ]
        )
        let changed = TestFixtures.loadedConfig(
            layouts: ["mobile": changedLayout],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["mobile"])]
        )

        await #expect(throws: ShitsuraeError.self) {
            _ = try await engine.switchSpace(
                layoutName: "mobile",
                to: 1,
                config: changed,
                reconcile: true
            )
        }
        await #expect(throws: ShitsuraeError.self) {
            _ = try await engine.setWindowFrame(
                selector: WindowTargetSelector(),
                x: nil,
                y: nil,
                width: .expression("50%"),
                height: nil,
                config: changed
            )
        }
        #expect(control.frameMutationAttemptWindowIDs.count == attemptsBefore)

        let focus = try await engine.focusSlot(1, config: changed)
        #expect(focus.windowID == editor.windowID)
    }

    @Test func blockingWindowWriteLeavesGateHeldAndStatusResponsivePastDeadline() async throws {
        let clock = TestMonotonicClock()
        let coordinator = ArrangeOperationCoordinator(uptimeNanoseconds: { clock.now })
        let loaded = TestFixtures.loadedConfig(
            layouts: ["mobile": layout(bundleID: "com.example.Editor")],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["mobile"])]
        )
        let (engine, control, url) = makeEngine(
            windows: [TestFixtures.window(id: 1, bundleID: "com.example.Editor", isAXBacked: true)],
            displays: [TestFixtures.display],
            coordinator: coordinator
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let releaseWrite = DispatchSemaphore(value: 0)
        defer { releaseWrite.signal() }
        let enteredWrite = TestSignal()
        control.onFrameMutationAttempt = {
            enteredWrite.signal()
            releaseWrite.wait()
        }
        let token = try engine.operationCoordinator.tryAdmit(
            requestID: "blocking-write",
            operation: .arrangeSet,
            budgetMS: 60_000
        )
        let task = Task {
            try await engine.arrangeSet(
                setName: "mobile",
                requestID: "blocking-write",
                config: loaded,
                token: token
            )
        }
        var observedInFlight = false
        for _ in 0 ..< 200 {
            if enteredWrite.isSet {
                observedInFlight = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(observedInFlight)
        clock.advance(milliseconds: 61_000)

        let status = engine.operationCoordinator.status()
        #expect(status.active?.requestID == "blocking-write")
        #expect(status.active?.deadlineExceeded == true)
        #expect(status.active?.inFlight == true)
        #expect(status.lastOutcome == nil)
        #expect(throws: ShitsuraeError.self) {
            _ = try engine.operationCoordinator.tryAdmit(requestID: "too-early", operation: .focus)
        }

        releaseWrite.signal()
        let result = try await task.value
        #expect(result.exitCode == ErrorCode.operationTimedOut.rawValue)
        #expect(result.ownershipCommitted)
        #expect(control.setFrameAttemptWindowIDs.count == 1)
        engine.operationCoordinator.finish(
            token: token,
            result: result.result,
            exitCode: result.exitCode
        )
        #expect(engine.operationCoordinator.status().lastOutcome?.exitCode == ErrorCode.operationTimedOut.rawValue)
    }
}
