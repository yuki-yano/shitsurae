import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("VirtualSpaceEngine")
struct VirtualSpaceEngineTests {
    private func makeEngine(
        windows: [WindowSnapshot]
    ) -> (engine: VirtualSpaceEngine, control: MockWindowControl, stateURL: URL) {
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display])
        let (store, url) = TestFixtures.tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        return (engine, control, url)
    }

    private var config: LoadedConfig {
        TestFixtures.loadedConfig(layouts: ["work": TestFixtures.twoSpaceLayout()])
    }

    private var threeSpaceConfig: LoadedConfig {
        let fullFrame = TestFixtures.frameDef("0%", "0%", "100%", "100%")
        return TestFixtures.loadedConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                        slot: 1,
                        frame: fullFrame
                    ),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.Notes"),
                        slot: 1,
                        frame: fullFrame
                    ),
                ]),
                SpaceDefinition(spaceID: 3, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.Terminal"),
                        slot: 1,
                        frame: fullFrame
                    ),
                ]),
            ]),
        ])
    }

    private func standardWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
        ]
    }

    private func helperUIAdoptedEntry() -> SlotEntry {
        SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 0,
            origin: .adopted,
            definitionFingerprint: "adopted\u{0}com.apple.TextInputUI.xpc.CursorUIViewService\u{0}9",
            bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
            pid: 90,
            processStartTime: 90_000_000,
            windowID: 9,
            lastKnownTitle: "",
            displayID: TestFixtures.display.id,
            lastVisibleFrame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
            visibilityState: .visible
        )
    }

    @Test func bootstrapCreatesEntriesAndActiveSpace() async throws {
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        let state = await engine.currentState
        #expect(state.activeLayoutName == "work")
        #expect(state.primaryActiveSpaceID == 1)
        #expect(state.slots.count == 3)
        #expect(state.slots.allSatisfy { $0.origin == .layout })
    }

    @Test func switchSpaceShowsTargetsAndHidesOthers() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.didChangeSpace)
        #expect(outcome.shownCount == 1) // Notes
        #expect(outcome.hiddenCount == 2) // TextEdit + Terminal
        #expect(outcome.converged)
        #expect(outcome.unresolvedSlots.isEmpty)

        // Notes window focused.
        #expect(control.focusedWindowIDs.last == 3)

        // TextEdit / Terminal parked offscreen; Notes shown on screen.
        let textEdit = control.window(1)!
        let notes = control.window(3)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: textEdit.frame, displays: [TestFixtures.display]))
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: notes.frame, displays: [TestFixtures.display]))

        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        let hidden = state.slots.filter { $0.visibilityState == .hiddenOffscreen }
        #expect(hidden.count == 2)
        #expect(state.pendingVisibilityConvergence == nil)
    }

    @Test func terminationFocusRestoreKeepsActiveWorkspaceAndUsesMRU() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let terminated = try #require(control.window(1))
        await engine.markActivated(window: try #require(control.window(2)))
        control.removeWindow(terminated.windowID)
        control.setFocusedWindowID(3)

        let focused = try await engine.focusPreferredWindowInActiveWorkspace(
            excludingPID: terminated.pid,
            bundleID: terminated.bundleID,
            config: config
        )

        #expect(focused == control.window(2)?.identity)
        #expect(control.focusedWindow()?.windowID == 2)
        #expect(await engine.activeSpaceID() == 1)
    }

    @Test func terminationFocusRestoreFallsBackWhenMRUTargetRejectsFocus() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: try #require(control.window(2)))
        control.failFocusWindowIDs = [2]

        let focused = try await engine.focusPreferredWindowInActiveWorkspace(
            excludingPID: 999,
            bundleID: "com.example.Terminated",
            config: config
        )

        #expect(focused == control.window(1)?.identity)
        #expect(control.focusedWindow()?.windowID == 1)
        #expect(control.focusedWindowIDs == [1])
        #expect(await engine.activeSpaceID() == 1)
    }

    @Test func switchSpaceDoesNotTreatBundleActivationAsConfirmedFocus() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.failFocusWindowIDs = [3]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.focusedWindowID == nil)
        #expect(!control.activatedBundles.isEmpty)
        #expect(control.activatedBundles.allSatisfy { $0 == "com.apple.Notes" })
        #expect(!control.focusedWindowIDs.contains(3))
    }

    @Test func switchSpaceFallsBackToAnotherTargetWindowWhenPreferredFocusFails() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 4, bundleID: "com.apple.Safari", isAXBacked: true, frontIndex: 2),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Safari"),
                    slot: 2,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["work": layout])
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(3)!)
        control.failFocusWindowIDs = [3]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.focusedWindowID == 4)
        #expect(control.focusedWindowIDs.last == 4)
        #expect(control.activatedBundles == ["com.apple.Notes"])
    }

    @Test func switchSpaceWaitsForTransientMRUFailureBeforeTryingFallback() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 4, bundleID: "com.apple.Safari", isAXBacked: true, frontIndex: 2),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Safari"),
                    slot: 2,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["work": layout])
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(3)!)
        control.failFocusAttemptsRemainingByWindowID = [3: 2]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.focusedWindowID == 3)
        #expect(control.focusedWindowIDs == [3])
        #expect(control.activatedBundles == ["com.apple.Notes"])
    }

    @Test func switchSpaceFocusesIntendedWindowOnceAfterConvergenceStealsFocus() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        // win1 (TextEdit) is the MRU window we expect to restore on return to space 1.
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Reproduce the race: while returning to space 1, hiding the space-2
        // window (win3) keeps failing so convergence retries its position
        // mutation, and each such mutation steals key focus to a sibling of
        // the target workspace (win2).
        control.acceptedButPinnedFrameWindowIDs = [3: control.window(3)!.frame]
        control.stealFocusOnPositionAttempt = 2

        let outcome = try await engine.switchSpace(to: 1, config: config)

        // The engine waits for convergence, then focuses the intended MRU once.
        #expect(outcome.focusedWindowID == 1)
        #expect(control.focusedWindowIDs.last == 1)
        #expect(control.focusedWindowIDs.count(where: { $0 == 1 }) == 1)
    }

    @Test func switchSpaceKeepsUserChosenWindowWhenFocusLeavesTargetWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // During the return to space 1, the user focuses a newly opened window
        // in space 2 while the switch is still settling. It differs from the
        // pre-switch focus and is not a target candidate, so the engine must
        // leave that newer choice alone.
        let userTarget = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.Finder",
            isAXBacked: true,
            frontIndex: 3
        )
        control.addWindow(userTarget)
        control.acceptedButPinnedFrameWindowIDs = [3: control.window(3)!.frame]
        control.stealFocusOnPositionAttempt = 9

        _ = try await engine.switchSpace(to: 1, config: config)

        #expect(control.focusedWindowIDs.last == 9)
    }

    @Test func switchSpaceDoesNotFocusMRUWhenUserLeavesTargetWorkspaceDuringConvergence() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        let userTarget = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.Finder",
            isAXBacked: true,
            frontIndex: 3
        )
        control.addWindow(userTarget)
        control.failPositionWindowIDs = [3]
        control.stealFocusOnPositionAttempt = 9

        let outcome = try await engine.switchSpace(to: 1, config: config)

        #expect(outcome.focusedWindowID == nil)
        #expect(control.focusedWindowIDs.last == 9)
        #expect(!control.focusedWindowIDs.contains(1))
        #expect(!control.focusedWindowIDs.contains(2))
    }

    @Test func switchSpaceKeepsRecoveryPendingWhenWindowsRefuseDesiredVisibility() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // Simulate special windows that refuse offscreen parking. The switch
        // keeps their persisted state truthful (rolled back to visible), but
        // the requested switch remains incomplete until quarantine takes over.
        control.failPositionWindowIDs = [1, 2]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(!outcome.converged)
        let state = await engine.currentState
        #expect(state.pendingVisibilityConvergence != nil)
        #expect(state.recoveryRequired)
        #expect(state.slots.first { $0.bundleID == "com.apple.TextEdit" }?.visibilityState == .visible)
        #expect(state.slots.first { $0.bundleID == "com.apple.Terminal" }?.visibilityState == .visible)
    }

    @Test func fullscreenHideRefusalRemainsUnconvergedWithoutPriorWindowedFrame() async throws {
        var windows = standardWindows()
        windows[0] = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: 0, y: 0, width: 1440, height: 900),
            isAXBacked: true,
            isFullscreen: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.failPositionWindowIDs = [1]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(!outcome.converged)
        #expect((await engine.currentState).pendingVisibilityConvergence != nil)
        #expect(control.window(1)?.frame == windows[0].frame)
    }

    @Test func fullscreenAdoptionDoesNotPersistDisplayFrameAsWindowedRestoreFrame() async throws {
        let fullscreen = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            frame: ResolvedFrame(x: 0, y: 0, width: 1440, height: 900),
            isAXBacked: true,
            isFullscreen: true
        )
        let (engine, _, url) = makeEngine(windows: standardWindows() + [fullscreen])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        #expect(try await engine.adoptWindowIntoActiveWorkspace(fullscreen, config: config))

        let entry = (await engine.currentState).slots.first { $0.boundIdentity == fullscreen.identity }
        #expect(entry?.lastVisibleFrame == nil)
    }

    @Test func switchUnknownVerificationKeepsConservativeWriteAheadState() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.onFrameMutationAttempt = {
            control.windowInventoryAvailable = false
        }

        let outcome = try await engine.switchSpace(to: 1, config: config)

        #expect(!outcome.converged)
        let state = await engine.currentState
        #expect(state.pendingVisibilityConvergence != nil)
        #expect(state.slots.filter { $0.spaceID == 1 }
            .allSatisfy { $0.visibilityState == .hiddenOffscreen })
    }

    @Test func switchSpaceQuarantinesPersistentlyUnconvergedWindow() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // Establish real visible+hidden frames for window 1 via one clean
        // hide, then let the "app" pin it to a foreign frame that matches
        // neither. Now window 1 (TextEdit, space 1) behaves like Chrome's
        // remote-debug popup: planned on every switch (show on →1, hide on →2)
        // and unconvergeable, because rollback lands on a stored frame the
        // pinned window is not at.
        _ = try await engine.switchSpace(to: 2, config: config)
        control.pinnedFrameWindowIDs = [1: ResolvedFrame(x: 500, y: 500, width: 320, height: 252)]

        // Each switch that plans window 1 stays unconverged until quarantine.
        let first = try await engine.switchSpace(to: 1, config: config)
        #expect(!first.converged)
        let second = try await engine.switchSpace(to: 2, config: config)
        #expect(!second.converged)
        // Third failure crosses the threshold and quarantines window 1.
        let third = try await engine.switchSpace(to: 1, config: config)
        #expect(!third.converged)

        // From now on window 1 is excluded from planning, so switches converge
        // again and recovery state stops being pinned — the whole point.
        let recovered = try await engine.switchSpace(to: 2, config: config)
        #expect(recovered.converged)
        let state = await engine.currentState
        #expect(state.pendingVisibilityConvergence == nil)
        #expect(!state.recoveryRequired)

        let afterAgain = try await engine.switchSpace(to: 1, config: config)
        #expect(afterAgain.converged)
    }

    @Test func closingQuarantinedWindowClearsBookkeepingSoASharedIDStartsFresh() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.pinnedFrameWindowIDs = [1: ResolvedFrame(x: 500, y: 500, width: 320, height: 252)]

        // Drive window 1 into quarantine (three unconverged switches that plan it).
        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)
        #expect(try await engine.switchSpace(to: 2, config: config).converged)

        // The window closes and another process immediately reuses its ID,
        // without an intervening cleanup switch.
        control.removeWindow(1)
        control.pinnedFrameWindowIDs = [:]
        control.addWindow(
            TestFixtures.window(
                id: 1,
                bundleID: "com.apple.TextEdit",
                pid: 999,
                isAXBacked: true,
                frontIndex: 0
            )
        )

        // The new identity is managed immediately:
        let arrival = try await engine.switchSpace(to: 1, config: config)
        #expect(arrival.focusedWindowID == 1)
        // switching away parks it offscreen instead of leaving it quarantined.
        let outcome = try await engine.switchSpace(to: 2, config: config)
        #expect(outcome.converged)
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: control.window(1)!.frame, displays: [TestFixtures.display]))
    }

    @Test func quarantinedWindowRemainsHardNoOpWhenAppStartsAcceptingMoves() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.pinnedFrameWindowIDs = [1: ResolvedFrame(x: 500, y: 500, width: 320, height: 252)]

        // Drive window 1 into quarantine (three unconverged switches that plan it).
        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        // The app starts honoring geometry writes again while the window stays
        // open. Quarantine remains a strict no-op because even a setter that
        // reports failure may already have moved a Chrome companion surface.
        control.pinnedFrameWindowIDs = [:]
        let attemptsBefore = control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count
        let release = try await engine.switchSpace(to: 2, config: config)
        #expect(release.converged)
        #expect(control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count == attemptsBefore)
        #expect(!VisibilityPlanner.isHiddenWindowFrame(
            frame: control.window(1)!.frame,
            displays: [TestFixtures.display]
        ))

        // Ordinary space switches never probe the quarantined identity.
        let back = try await engine.switchSpace(to: 1, config: config)
        #expect(back.converged)
        #expect(control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count == attemptsBefore)
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: control.window(1)!.frame, displays: [TestFixtures.display]))
    }

    @Test func quarantinedWindowDoesNotAttemptGeometryDuringInventoryChanges() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.pinnedFrameWindowIDs = [1: ResolvedFrame(x: 500, y: 500, width: 320, height: 252)]
        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)
        control.pinnedFrameWindowIDs = [:]
        let attemptsBefore = control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count
        control.onFrameMutationAttempt = {
            if control.frameMutationAttemptWindowIDs.last == 1 {
                control.windowInventoryAvailable = false
            }
        }
        _ = try await engine.switchSpace(to: 2, config: config)

        let state = await engine.currentState
        #expect(state.slots.first { $0.windowID == 1 }?.visibilityState == .hiddenOffscreen)
        #expect(control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count == attemptsBefore)
        #expect(control.windowInventoryAvailable)

        control.onFrameMutationAttempt = nil
        _ = try await engine.switchSpace(to: 1, config: config)
        #expect(control.frameMutationAttemptWindowIDs.filter { $0 == 1 }.count == attemptsBefore)
    }

    @Test func rawOnlyInventoryGapDoesNotReleaseExistingQuarantine() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        let pinnedFrame = ResolvedFrame(x: 500, y: 500, width: 320, height: 252)
        control.pinnedFrameWindowIDs = [1: pinnedFrame]
        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let quarantinedWindow = control.window(1)!
        control.removeWindow(1)
        control.liveWindowHandlesOverride = Set(control.currentWindows().map(\.handle) + [quarantinedWindow.handle])
        _ = try await engine.switchSpace(to: 2, config: config)

        control.addWindow(quarantinedWindow.withFrame(pinnedFrame))
        control.liveWindowHandlesOverride = nil
        let attemptsBefore = control.frameMutationAttemptWindowIDs.count
        _ = try await engine.switchSpace(to: 1, config: config)
        let windowOneAttempts = control.frameMutationAttemptWindowIDs
            .dropFirst(attemptsBefore)
            .filter { $0 == 1 }
        #expect(windowOneAttempts.isEmpty)
    }

    @Test func movingQuarantinedWindowToWorkspaceClearsQuarantine() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.pinnedFrameWindowIDs = [1: ResolvedFrame(x: 500, y: 500, width: 320, height: 252)]

        // Drive window 1 into quarantine (three unconverged switches that plan it).
        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        // An explicit user move is a fresh chance: quarantine bookkeeping is
        // dropped, so the very next switch plans the window again with full
        // convergence (unconverged here because the app still refuses).
        try await engine.clearPending()
        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.moveWindowToWorkspace(
                window: control.window(1)!,
                toSpaceID: 2,
                config: self.config
            )
        }
        let replanned = try await engine.switchSpace(to: 2, config: config)
        #expect(!replanned.converged)

        // Once the app accepts writes again the window is managed normally.
        control.pinnedFrameWindowIDs = [:]
        let recovered = try await engine.switchSpace(to: 1, config: config)
        #expect(recovered.converged)
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: control.window(1)!.frame, displays: [TestFixtures.display]))
    }

    @Test func switchBackRestoresOriginalWindows() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        try await engine.switchSpace(to: 2, config: config)
        let outcome = try await engine.switchSpace(to: 1, config: config)

        #expect(outcome.shownCount == 2)
        #expect(outcome.hiddenCount == 1)

        let textEdit = control.window(1)!
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: textEdit.frame, displays: [TestFixtures.display]))
        #expect(
            textEdit.frame == TestFixtures.window(
                id: 1,
                bundleID: "com.apple.TextEdit",
                isAXBacked: true
            ).frame
        )
    }

    @Test func switchBackPreservesManualResize() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let resizedFrame = ResolvedFrame(x: 40, y: 50, width: 900, height: 500)
        let initialTextEdit = try #require(control.window(1))
        #expect(control.setWindowFrame(
            windowID: 1,
            pid: initialTextEdit.pid,
            processStartTime: initialTextEdit.processStartTime,
            bundleID: "com.apple.TextEdit",
            frame: resizedFrame
        ))

        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let textEdit = control.window(1)!
        #expect(textEdit.frame == resizedFrame)
    }

    // バグ1 回帰: 同一アプリ複数ウィンドウでもスペース遷移する
    @Test func multiWindowSameAppStillSwitches() async throws {
        let windows = [
            TestFixtures.window(
                id: 1,
                bundleID: "com.apple.Terminal",
                title: "t1",
                isAXBacked: true,
                frontIndex: 0
            ),
            TestFixtures.window(
                id: 2,
                bundleID: "com.apple.Terminal",
                title: "t2",
                isAXBacked: true,
                frontIndex: 1
            ),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal", index: 1),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal", index: 2),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["term": layout])

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "term", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 2, config: config)

        // One terminal shown, the other hidden — never the same window.
        #expect(outcome.shownCount == 1)
        #expect(outcome.hiddenCount == 1)
        #expect(outcome.unresolvedSlots.isEmpty)

        let frames = [control.window(1)!.frame, control.window(2)!.frame]
        let hiddenCount = frames.filter {
            VisibilityPlanner.isHiddenWindowFrame(frame: $0, displays: [TestFixtures.display])
        }.count
        #expect(hiddenCount == 1)
    }

    // バグ2-b 回帰: 手動最小化されたウィンドウが show 時に復元される
    @Test func minimizedWindowIsRestoredOnShow() async throws {
        var windows = standardWindows()
        windows[2] = TestFixtures.window(
            id: 3,
            bundleID: "com.apple.Notes",
            isAXBacked: true,
            minimized: true,
            frontIndex: 2
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.converged)
        let notes = control.window(3)!
        #expect(notes.minimized == false)
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: notes.frame, displays: [TestFixtures.display]))
    }

    @Test func unresolvedSlotRecordsPending() async throws {
        // Notes app not running → space 2 slot unresolved.
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
        ]
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.unresolvedSlots == [PendingUnresolvedSlot(slot: 1, spaceID: 2, reason: "windowUnresolved")])
        #expect(outcome.shownCount == 0)
        #expect(outcome.hiddenCount == 2)
        #expect(!outcome.converged)
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: control.window(1)!.frame,
            displays: [TestFixtures.display]
        ))
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: control.window(2)!.frame,
            displays: [TestFixtures.display]
        ))
        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        #expect(state.pendingVisibilityConvergence != nil)
        #expect(state.recoveryRequired)
    }

    @Test func moveWindowToWorkspaceParksItOffscreen() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let textEdit = control.window(1)!
        let outcome = try await engine.moveWindowToWorkspace(window: textEdit, toSpaceID: 2, config: config)

        #expect(outcome.fromSpaceID == 1)
        #expect(outcome.toSpaceID == 2)

        let moved = control.window(1)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: moved.frame, displays: [TestFixtures.display]))

        let state = await engine.currentState
        let entry = state.slots.first { $0.bundleID == "com.apple.TextEdit" }
        #expect(entry?.spaceID == 2)
        #expect(entry?.visibilityState == .hiddenOffscreen)
    }

    @Test func visibilityPendingDoesNotBlockExplicitWorkspaceMove() async throws {
        let zoom = TestFixtures.window(
            id: 9,
            bundleID: "us.zoom.xos",
            pid: 90,
            isAXBacked: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(windows: standardWindows() + [zoom])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var state = await engine.currentState
        let previousPending = PendingVisibilityConvergence(
            requestID: "unrelated-unresolved-slot",
            startedAt: Date.rfc3339UTC(),
            layoutName: "work",
            targetSpaceID: 1,
            unresolvedSlots: [PendingUnresolvedSlot(
                slot: 1,
                spaceID: 2,
                reason: "windowUnresolved"
            )]
        )
        state.pendingVisibilityConvergence = previousPending
        try await engine.replaceState(state)
        control.setFocusedWindowID(zoom.windowID)

        let outcome = try await engine.windowWorkspace(
            selector: WindowTargetSelector(),
            toSpaceID: 2,
            config: config
        )

        #expect(outcome.bundleID == "us.zoom.xos")
        #expect(outcome.previousSpaceID == 1)
        #expect(outcome.spaceID == 2)
        #expect(outcome.didCreateTrackingEntry)
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: try #require(control.window(zoom.windowID)).frame,
            displays: [TestFixtures.display]
        ))
        state = await engine.currentState
        #expect(state.pendingVisibilityConvergence == previousPending)
        #expect(state.slots.first { $0.boundIdentity == zoom.identity }?.spaceID == 2)
    }

    @Test func liveArrangeRecoveryStillBlocksExplicitWorkspaceMove() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var state = await engine.currentState
        state.liveArrangeRecoveryRequired = true
        try await engine.replaceState(state)
        control.setFocusedWindowID(1)

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(),
                toSpaceID: 2,
                config: self.config
            )
        }
        #expect(control.frameMutationAttemptWindowIDs.isEmpty)
    }

    @Test func moveUpdatesExactlyTheGloballyAssignedEntry() async throws {
        // Two terminals, two unbound index entries. The move must update the
        // same entry the next switch's bulk resolution would bind to window 1
        // (index:1 by z-order), never a guessed/first entry, and must leave
        // the sibling entry untouched.
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal", index: 1),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal", index: 2),
                    slot: 2,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: []),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["term": layout])

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "term", activeSpaceID: 1, config: config)

        let outcome = try await engine.moveWindowToWorkspace(
            window: control.window(1)!,
            toSpaceID: 2,
            config: config
        )

        #expect(outcome.toSpaceID == 2)
        let state = await engine.currentState
        let moved = state.slots.first { $0.windowID == 1 }
        #expect(moved?.slot == 1)
        #expect(moved?.spaceID == 2)
        let sibling = state.slots.first { $0.slot == 2 }
        #expect(sibling?.spaceID == 1)
        #expect(sibling?.windowID == nil)
    }

    @Test func relaunchedAppFocusRebindsLayoutEntryInsteadOfDuplicating() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        var state = await engine.currentState
        let boundEntry = try #require(state.slots.first { $0.bundleID == "com.apple.TextEdit" })
        #expect(boundEntry.windowID == 1)

        // TextEdit relaunches: the layout entry still carries the dead
        // pid/windowID when the new window receives focus, before any
        // workspace switch runs.
        control.removeWindow(1)
        let relaunched = TestFixtures.window(
            id: 21,
            bundleID: "com.apple.TextEdit",
            pid: 210,
            isAXBacked: true,
            frontIndex: 0
        )
        control.addWindow(relaunched)
        control.setFocusedWindowID(relaunched.windowID)
        let enumerationCountBefore = control.listAllWindowsCallCount

        // One focus event through the single-snapshot API: target lookup,
        // global assignment, rebind and MRU all on the same enumeration.
        let outcome = await engine.processFocusEvent(
            sequence: 1,
            windowID: relaunched.windowID,
            pid: relaunched.pid,
            processStartTime: relaunched.processStartTime,
            bundleID: relaunched.bundleID,
            config: config
        )
        #expect(outcome?.spaceID == 1)
        #expect(outcome?.didAdopt == false)
        #expect(control.listAllWindowsCallCount == enumerationCountBefore + 1)

        state = await engine.currentState
        let textEditEntries = state.slots.filter { $0.bundleID == "com.apple.TextEdit" }
        #expect(textEditEntries.count == 1)
        #expect(textEditEntries.first?.origin == .layout)
        #expect(textEditEntries.first?.id == boundEntry.id)
        #expect(textEditEntries.first?.pid == 210)
        #expect(textEditEntries.first?.windowID == 21)
        #expect(textEditEntries.first?.spaceID == 1)
        #expect(textEditEntries.first?.lastActivatedAt != nil)
    }

    @Test func modalFocusDoesNotRebindExistingLayoutEntry() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)
        let before = await engine.currentState
        let oldEntry = try #require(before.slots.first { $0.bundleID == "com.apple.TextEdit" })
        #expect(oldEntry.lastVisibleFrame != nil)

        control.removeWindow(1)
        let relaunchedMain = TestFixtures.window(
            id: 21,
            bundleID: "com.apple.TextEdit",
            pid: 210,
            processStartTime: 210_000_000,
            frame: ResolvedFrame(x: 350, y: 220, width: 780, height: 510),
            isAXBacked: true
        )
        let sheet = TestFixtures.window(
            id: 22,
            bundleID: "com.apple.TextEdit",
            pid: 210,
            processStartTime: 210_000_000,
            subrole: "AXSheet",
            modal: true,
            isAXBacked: true,
            frontIndex: 0
        )
        control.addWindow(relaunchedMain)
        control.addWindow(sheet)
        control.setFocusedWindowID(sheet.windowID)
        control.setMainWindowID(relaunchedMain.windowID)
        let attemptsBefore = control.frameMutationAttemptWindowIDs.count

        let outcome = try #require(await engine.processFocusEvent(
            sequence: 1,
            windowID: sheet.windowID,
            pid: sheet.pid,
            processStartTime: sheet.processStartTime,
            bundleID: sheet.bundleID,
            config: config
        ))

        #expect(outcome.identity == sheet.identity)
        #expect(outcome.spaceID == nil)
        #expect(!outcome.didAdopt)
        #expect(control.frameMutationAttemptWindowIDs.count == attemptsBefore)
        let after = await engine.currentState
        let entries = after.slots.filter { $0.bundleID == "com.apple.TextEdit" }
        #expect(entries.count == 1)
        #expect(entries.first?.id == oldEntry.id)
        #expect(entries.first?.boundIdentity == oldEntry.boundIdentity)
        #expect(entries.first?.spaceID == 1)
        #expect(entries.first?.visibilityState == oldEntry.visibilityState)
        #expect(entries.first?.lastVisibleFrame == oldEntry.lastVisibleFrame)
        #expect(entries.first?.lastHiddenFrame == oldEntry.lastHiddenFrame)
        #expect(entries.first?.lastActivatedAt == oldEntry.lastActivatedAt)
    }

    @Test func focusedCompanionStaysVisibleWhileOtherWindowsSwitchSpaces() async throws {
        let main = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            title: "Main",
            isAXBacked: true,
            frontIndex: 2
        )
        let otherOrdinaryWindow = TestFixtures.window(
            id: 8,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            title: "Other",
            isAXBacked: true,
            frontIndex: 1
        )
        let confirmationSheet = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            title: "Confirm",
            subrole: "AXSheet",
            modal: true,
            isAXBacked: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(
            windows: standardWindows() + [main, otherOrdinaryWindow, confirmationSheet]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // The main Chrome window already belongs to the current virtual
        // workspace before the DevTools confirmation sheet appears.
        control.setFocusedWindowID(main.windowID)
        control.setMainWindowID(main.windowID)
        let initial = try #require(await engine.processFocusEvent(
            sequence: 1,
            windowID: main.windowID,
            pid: main.pid,
            processStartTime: main.processStartTime,
            bundleID: main.bundleID,
            config: config
        ))
        #expect(initial.didAdopt)

        control.setFocusedWindowID(confirmationSheet.windowID)
        control.setMainWindowID(main.windowID)
        let outcome = try #require(await engine.processFocusEvent(
            sequence: 2,
            windowID: confirmationSheet.windowID,
            pid: confirmationSheet.pid,
            processStartTime: confirmationSheet.processStartTime,
            bundleID: confirmationSheet.bundleID,
            config: config
        ))

        #expect(outcome.identity == confirmationSheet.identity)
        #expect(outcome.spaceID == 1)
        #expect(!outcome.didAdopt)
        var state = await engine.currentState
        let chromeEntries = state.slots.filter { $0.bundleID == "com.google.Chrome" }
        #expect(chromeEntries.count == 1)
        #expect(chromeEntries.first?.boundIdentity == main.identity)
        #expect(chromeEntries.first?.lastActivatedAt != nil)

        // Freshness always compares the real focused sheet, not its projected
        // main. A continuation carrying the main identity is stale.
        #expect(try await engine.switchSpaceForFocusEvent(
            sequence: 2,
            identity: main.identity,
            to: 2,
            config: config
        ) == nil)

        let attemptsBefore = control.frameMutationAttemptWindowIDs.count
        let switchOutcome = try #require(await engine.switchSpaceForFocusEvent(
            sequence: 2,
            identity: confirmationSheet.identity,
            to: 2,
            config: config
        ))
        #expect(switchOutcome.didChangeSpace)
        #expect(switchOutcome.converged)
        #expect(switchOutcome.focusedWindowID == nil)
        #expect(control.frameMutationAttemptWindowIDs.dropFirst(attemptsBefore).allSatisfy {
            $0 != main.windowID && $0 != confirmationSheet.windowID
        })
        #expect(control.focusedWindow()?.identity == confirmationSheet.identity)

        var moveWasBlocked = false
        do {
            _ = try await engine.moveWindowToWorkspace(window: main, toSpaceID: 2, config: config)
        } catch {
            moveWasBlocked = true
        }
        #expect(moveWasBlocked)
        #expect(control.frameMutationAttemptWindowIDs.allSatisfy { $0 != main.windowID })

        state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        #expect(state.slots.first { $0.boundIdentity == main.identity }?.spaceID == 1)
        #expect(state.slots.first { $0.boundIdentity == main.identity }?.visibilityState == .visible)
        #expect(state.pendingVisibilityConvergence == nil)
        let otherEntry = try #require(state.slots.first {
            $0.boundIdentity == otherOrdinaryWindow.identity
        })
        #expect(otherEntry.origin == .adopted)
        #expect(otherEntry.spaceID == 1)
        #expect(otherEntry.visibilityState == .hiddenOffscreen)
    }

    @Test func focusedUnknownBlocksExactMainWithoutTrackingMutation() async throws {
        let main = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            isAXBacked: true
        )
        let unknown = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            role: nil,
            subrole: nil,
            modal: nil,
            isAXBacked: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(windows: standardWindows() + [main, unknown])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        control.setFocusedWindowID(unknown.windowID)
        control.setMainWindowID(main.windowID)
        #expect(await engine.processFocusEvent(
            sequence: 1,
            windowID: unknown.windowID,
            pid: unknown.pid,
            processStartTime: unknown.processStartTime,
            bundleID: unknown.bundleID,
            config: config
        ) == nil)

        let state = await engine.currentState
        #expect(!state.slots.contains { $0.bundleID == "com.google.Chrome" })
        #expect(await engine.resolveTargetWindow(selector: WindowTargetSelector(
            windowID: main.windowID,
            pid: main.pid,
            processStartTime: main.processStartTime,
            bundleID: main.bundleID
        )) == nil)
    }

    @Test func untrackedCompanionMainReturnsToOriginalSpaceAfterDialogCloses() async throws {
        let main = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            title: "New Chrome window",
            isAXBacked: true
        )
        let sheet = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            pid: 90,
            processStartTime: 90_000_000,
            title: "DevTools confirmation",
            subrole: "AXSheet",
            modal: true,
            isAXBacked: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(windows: standardWindows() + [main, sheet])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        control.setFocusedWindowID(sheet.windowID)
        control.setMainWindowID(main.windowID)
        let focusOutcome = try #require(await engine.processFocusEvent(
            sequence: 1,
            windowID: sheet.windowID,
            pid: sheet.pid,
            processStartTime: sheet.processStartTime,
            bundleID: sheet.bundleID,
            config: config
        ))
        #expect(focusOutcome.spaceID == nil)
        #expect(!focusOutcome.didAdopt)
        #expect(!(await engine.currentState).slots.contains { $0.bundleID == main.bundleID })

        let attemptsBefore = control.frameMutationAttemptWindowIDs.count
        let switched = try await engine.switchSpace(to: 2, config: config)
        #expect(switched.didChangeSpace)
        #expect(switched.converged)
        #expect(switched.focusedWindowID == nil)
        #expect(control.frameMutationAttemptWindowIDs.dropFirst(attemptsBefore).allSatisfy {
            $0 != main.windowID && $0 != sheet.windowID
        })
        #expect((await engine.currentState).primaryActiveSpaceID == 2)

        control.removeWindow(sheet.windowID)
        control.setFocusedWindowID(main.windowID)
        control.setMainWindowID(main.windowID)
        let resumed = await engine.processFocusEvent(
            sequence: 2,
            windowID: main.windowID,
            pid: main.pid,
            processStartTime: main.processStartTime,
            bundleID: main.bundleID,
            config: config
        )
        #expect(resumed == nil)

        let state = await engine.currentState
        let mainEntry = try #require(state.slots.first { $0.boundIdentity == main.identity })
        #expect(mainEntry.origin == .adopted)
        #expect(mainEntry.spaceID == 1)
        #expect(mainEntry.visibilityState == .hiddenOffscreen)
        #expect(state.primaryActiveSpaceID == 2)
        #expect(state.pendingVisibilityConvergence == nil)
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: try #require(control.window(main.windowID)).frame,
            displays: [TestFixtures.display]
        ))
        #expect(control.focusedWindow()?.bundleID == "com.apple.Notes")
        #expect(!(try await engine.switchSpace(to: 2, config: config).didChangeSpace))
        #expect((await engine.currentState).primaryActiveSpaceID == 2)
    }

    @Test func focusEventRejectsBackgroundOrStaleIdentityBeforeStateMutation() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        control.setFocusedWindowID(1)
        let rejected = await engine.processFocusEvent(
            sequence: 1,
            windowID: 3,
            pid: control.window(3)!.pid,
            processStartTime: control.window(3)!.processStartTime,
            bundleID: control.window(3)!.bundleID,
            config: config
        )
        #expect(rejected == nil)
        var state = await engine.currentState
        #expect(state.slots.first { $0.bundleID == "com.apple.Notes" }?.windowID == nil)

        control.setFocusedWindowID(3)
        let rejectedGeneration = await engine.processFocusEvent(
            sequence: 2,
            windowID: 3,
            pid: control.window(3)!.pid,
            processStartTime: control.window(3)!.processStartTime + 1,
            bundleID: control.window(3)!.bundleID,
            config: config
        )
        #expect(rejectedGeneration == nil)

        let accepted = await engine.processFocusEvent(
            sequence: 3,
            windowID: 3,
            pid: control.window(3)!.pid,
            processStartTime: control.window(3)!.processStartTime,
            bundleID: control.window(3)!.bundleID,
            config: config
        )
        #expect(accepted?.spaceID == 2)

        // The focused window changed before the follow-focus continuation.
        control.setFocusedWindowID(1)
        let staleSwitch = try await engine.switchSpaceForFocusEvent(
            sequence: 3,
            identity: control.window(3)!.identity,
            to: 2,
            config: config
        )
        #expect(staleSwitch == nil)
        state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 1)

        // A newer generation also invalidates an otherwise matching old event.
        await engine.invalidateFocusEvents(upTo: 4)
        control.setFocusedWindowID(3)
        #expect(try await engine.switchSpaceForFocusEvent(
            sequence: 3,
            identity: control.window(3)!.identity,
            to: 2,
            config: config
        ) == nil)
    }

    @Test func focusEventIgnoresAXDropoutAndRebindsAfterRecovery() async throws {
        // The old flow resolved the target on one enumeration and adopted on
        // a later one, so an AX dropout in between produced a duplicate
        // adopted entry from the stale snapshot. The single-snapshot API
        // decides everything on the enumeration current at event time.
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // TextEdit relaunches; the layout entry still holds the dead
        // identity (stale) when the focus events below arrive.
        control.removeWindow(1)
        let tail = [control.window(2)!, control.window(3)!]
        let backed = TestFixtures.window(
            id: 21,
            bundleID: "com.apple.TextEdit",
            pid: 210,
            isAXBacked: true,
            frontIndex: 0
        )
        let invisible = TestFixtures.window(
            id: 21,
            bundleID: "com.apple.TextEdit",
            pid: 210,
            isAXBacked: false,
            frontIndex: 0
        )
        control.windowListSequence = [
            tail + [invisible], // the focus event's snapshot: dropped out of AX
            tail + [backed], // AX recovered
        ]
        control.addWindow(invisible)
        control.setFocusedWindowID(21)

        // Dropout: the event is ignored — no adoption, stale binding intact.
        let during = await engine.processFocusEvent(
            sequence: 1,
            windowID: 21,
            pid: 210,
            processStartTime: backed.processStartTime,
            bundleID: "com.apple.TextEdit",
            config: config
        )
        #expect(during == nil)
        var state = await engine.currentState
        #expect(!state.slots.contains { $0.origin == .adopted && $0.bundleID == "com.apple.TextEdit" })
        #expect(state.slots.first { $0.bundleID == "com.apple.TextEdit" }?.windowID == 1)

        // Recovery: the same identity is AX-backed again — the layout entry
        // rebinds, keeps its workspace, and still no adopted entry appears.
        let after = await engine.processFocusEvent(
            sequence: 2,
            windowID: 21,
            pid: 210,
            processStartTime: backed.processStartTime,
            bundleID: "com.apple.TextEdit",
            config: config
        )
        #expect(after?.spaceID == 1)
        #expect(after?.didAdopt == false)
        state = await engine.currentState
        let textEditEntries = state.slots.filter { $0.bundleID == "com.apple.TextEdit" }
        #expect(textEditEntries.count == 1)
        #expect(textEditEntries.first?.origin == .layout)
        #expect(textEditEntries.first?.windowID == 21)
        #expect(textEditEntries.first?.spaceID == 1)
    }

    @Test func axInvisibleExactLayoutBindingReservesSiblingUntilCGDisappears() async throws {
        let exact = TestFixtures.window(
            id: 31,
            bundleID: "com.google.Chrome",
            pid: 310,
            isAXBacked: true,
            frontIndex: 0
        )
        let sibling = TestFixtures.window(
            id: 32,
            bundleID: "com.google.Chrome",
            pid: 310,
            isAXBacked: true,
            frontIndex: 1
        )
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.google.Chrome"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: []),
        ])
        let localConfig = TestFixtures.loadedConfig(layouts: ["chrome": layout])
        let (engine, control, url) = makeEngine(windows: [exact, sibling])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "chrome", activeSpaceID: 1, config: localConfig)

        control.setFocusedWindowID(exact.windowID)
        _ = await engine.processFocusEvent(
            sequence: 1,
            windowID: exact.windowID,
            pid: exact.pid,
            processStartTime: exact.processStartTime,
            bundleID: exact.bundleID,
            config: localConfig
        )
        let entryID = try #require((await engine.currentState).slots.first?.id)

        control.removeWindow(exact.windowID)
        control.addWindow(TestFixtures.window(
            id: exact.windowID,
            bundleID: exact.bundleID,
            pid: exact.pid,
            isAXBacked: false,
            frontIndex: 0
        ))
        control.setFocusedWindowID(sibling.windowID)
        let reserved = await engine.processFocusEvent(
            sequence: 2,
            windowID: sibling.windowID,
            pid: sibling.pid,
            processStartTime: sibling.processStartTime,
            bundleID: sibling.bundleID,
            config: localConfig
        )
        #expect(reserved?.spaceID == nil)
        #expect(reserved?.didAdopt == false)
        var state = await engine.currentState
        #expect(state.slots.count == 1)
        #expect(state.slots.first?.id == entryID)
        #expect(state.slots.first?.windowID == exact.windowID)

        control.removeWindow(exact.windowID)
        let rebound = await engine.processFocusEvent(
            sequence: 3,
            windowID: sibling.windowID,
            pid: sibling.pid,
            processStartTime: sibling.processStartTime,
            bundleID: sibling.bundleID,
            config: localConfig
        )
        #expect(rebound?.spaceID == 1)
        #expect(rebound?.didAdopt == false)
        state = await engine.currentState
        #expect(state.slots.count == 1)
        #expect(state.slots.first?.id == entryID)
        #expect(state.slots.first?.windowID == sibling.windowID)
    }

    @Test func unavailableInventoryRejectsSwitchWithoutAdvancingState() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        let before = await engine.currentState

        control.windowInventoryAvailable = false
        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.switchSpace(to: 2, config: self.config)
        }
        let after = await engine.currentState
        #expect(after.primaryActiveSpaceID == before.primaryActiveSpaceID)
        #expect(after.slots.first { $0.bundleID == "com.apple.TextEdit" }?.boundIdentity
            == before.slots.first { $0.bundleID == "com.apple.TextEdit" }?.boundIdentity)
        #expect(!after.slots.contains { $0.origin == .adopted })
    }

    @Test func authoritativeCGWithAllExactBindingsAXInvisibleRejectsWithoutAdvancingState() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let before = await engine.currentState
        let framesBefore = Dictionary(uniqueKeysWithValues: control.currentWindows().map { ($0.identity, $0.frame) })
        let mutationAttemptsBefore = control.frameMutationAttemptWindowIDs.count
        let focusAttemptsBefore = control.focusedWindowIDs.count
        for window in control.currentWindows() {
            control.addWindow(window.withAXBacked(false))
        }
        let untracked = TestFixtures.window(
            id: 99,
            bundleID: "com.apple.finder",
            isAXBacked: true,
            frontIndex: 9
        )
        control.addWindow(untracked)

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.switchSpace(to: 2, config: self.config)
        }

        let after = await engine.currentState
        #expect(after == before)
        #expect(control.frameMutationAttemptWindowIDs.count == mutationAttemptsBefore)
        #expect(control.focusedWindowIDs.count == focusAttemptsBefore)
        #expect(!after.slots.contains { $0.origin == .adopted })
        for window in control.currentWindows() where window.windowID != untracked.windowID {
            #expect(window.frame == framesBefore[window.identity])
        }
    }

    @Test func transientAXDropoutRecoversWithinSingleSwitchRequest() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let recovered = control.currentWindows()
        let droppedOut = recovered.map { $0.withAXBacked(false) }
        control.windowListSequence = [droppedOut, recovered]
        let sleepsBefore = control.sleptMilliseconds.count

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.didChangeSpace)
        #expect(outcome.targetSpaceID == 2)
        #expect(outcome.converged)
        #expect(control.sleptMilliseconds.dropFirst(sleepsBefore).first == 1)
        #expect(await engine.currentState.primaryActiveSpaceID == 2)
    }

    @Test func targetReservedExactBindingRejectsBeforeHidingCurrentWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let before = await engine.currentState
        let framesBefore = Dictionary(uniqueKeysWithValues: control.currentWindows().map { ($0.identity, $0.frame) })
        let mutationAttemptsBefore = control.frameMutationAttemptWindowIDs.count
        let focusAttemptsBefore = control.focusedWindowIDs.count
        control.addWindow(control.window(3)!.withAXBacked(false))

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.switchSpace(to: 2, config: self.config)
        }

        let after = await engine.currentState
        #expect(after == before)
        #expect(control.frameMutationAttemptWindowIDs.count == mutationAttemptsBefore)
        #expect(control.focusedWindowIDs.count == focusAttemptsBefore)
        for window in control.currentWindows() {
            #expect(window.frame == framesBefore[window.identity])
        }
    }

    @Test func oneAssignedTargetAndOneReservedTargetAllowsPartialSwitch() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 4, bundleID: "com.apple.Safari", isAXBacked: true, frontIndex: 2),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Safari"),
                    slot: 2,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let localConfig = TestFixtures.loadedConfig(layouts: ["work": layout])
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: localConfig)
        _ = try await engine.switchSpace(to: 2, config: localConfig)
        _ = try await engine.switchSpace(to: 1, config: localConfig)

        let safariFrame = control.window(4)!.frame
        let mutationAttemptsBefore = control.frameMutationAttemptWindowIDs.count
        control.addWindow(control.window(4)!.withAXBacked(false))
        let outcome = try await engine.switchSpace(to: 2, config: localConfig)

        #expect(outcome.didChangeSpace)
        #expect(!outcome.converged)
        #expect(outcome.focusedWindowID == 3)
        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        #expect(state.pendingVisibilityConvergence != nil)
        #expect(control.window(4)?.frame == safariFrame)
        #expect(!control.frameMutationAttemptWindowIDs.dropFirst(mutationAttemptsBefore).contains(4))
    }

    @Test func unrelatedWorkspaceAssignmentDoesNotMaskCurrentAXDropout() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: threeSpaceConfig)
        _ = try await engine.switchSpace(to: 3, config: threeSpaceConfig)
        _ = try await engine.switchSpace(to: 1, config: threeSpaceConfig)

        let before = await engine.currentState
        let mutationAttemptsBefore = control.frameMutationAttemptWindowIDs.count
        control.addWindow(control.window(1)!.withAXBacked(false))
        control.removeWindow(3)

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.switchSpace(to: 2, config: self.threeSpaceConfig)
        }

        let after = await engine.currentState
        #expect(after == before)
        #expect(control.frameMutationAttemptWindowIDs.count == mutationAttemptsBefore)
    }

    @Test func unrelatedWorkspaceReservationDoesNotRejectValidSwitch() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: threeSpaceConfig)
        _ = try await engine.switchSpace(to: 3, config: threeSpaceConfig)
        _ = try await engine.switchSpace(to: 1, config: threeSpaceConfig)

        let terminalFrame = control.window(2)!.frame
        let mutationAttemptsBefore = control.frameMutationAttemptWindowIDs.count
        control.addWindow(control.window(2)!.withAXBacked(false))

        let outcome = try await engine.switchSpace(to: 2, config: threeSpaceConfig)

        #expect(outcome.didChangeSpace)
        #expect(!outcome.converged)
        #expect(outcome.focusedWindowID == 3)
        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        #expect(control.window(2)?.frame == terminalFrame)
        #expect(!control.frameMutationAttemptWindowIDs.dropFirst(mutationAttemptsBefore).contains(2))
    }

    @Test func staleSnapshotNeverCreatesAdoptedEntry() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // A snapshot resolved earlier claims the window was manageable, but
        // the window has since closed entirely.
        let vanished = TestFixtures.window(
            id: 50,
            bundleID: "com.apple.finder",
            isAXBacked: true,
            frontIndex: 0
        )
        #expect(try await engine.adoptWindowIntoActiveWorkspace(vanished, config: config) == false)
        control.setFocusedWindowID(vanished.windowID)
        #expect(await engine.processFocusEvent(
            sequence: 1,
            windowID: 50,
            pid: vanished.pid,
            processStartTime: vanished.processStartTime,
            bundleID: vanished.bundleID,
            config: config
        ) == nil)

        // Same identity alive in CG but not AX-visible: still no adoption.
        control.addWindow(
            TestFixtures.window(
                id: 50,
                bundleID: "com.apple.finder",
                isAXBacked: false,
                frontIndex: 0
            )
        )
        #expect(try await engine.adoptWindowIntoActiveWorkspace(vanished, config: config) == false)

        let state = await engine.currentState
        #expect(!state.slots.contains { $0.bundleID == "com.apple.finder" })
    }

    @Test func windowWorkspaceDoesNotAdoptWhenWindowDropsOutBetweenEnumerations() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        let backed = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            isAXBacked: true,
            frontIndex: 3
        )
        let invisible = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            isAXBacked: false,
            frontIndex: 3
        )
        let tail = standardWindows()
        control.windowListSequence = [
            tail + [backed], // selector resolution sees the window
            tail + [invisible], // the tracking snapshot: dropped out of AX
        ]

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(
                    windowID: 9,
                    pid: backed.pid,
                    processStartTime: backed.processStartTime,
                    bundleID: backed.bundleID
                ),
                toSpaceID: 2,
                config: self.config
            )
        }

        let state = await engine.currentState
        #expect(!state.slots.contains { $0.bundleID == "com.apple.finder" })
    }

    @Test func windowWorkspaceUsesTrackedSnapshotAndPersistsWriteAheadBeforeMoving() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        let backed = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: true,
            frontIndex: 3
        )
        let invisible = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: false,
            frontIndex: 3
        )
        let tail = standardWindows()
        control.windowListSequence = [
            tail + [backed], // selector
            tail + [backed], // tracking and assignment
            tail + [backed], // final companion-safety preflight
            tail + [invisible], // convergence after the move started
        ]

        let revisionBefore = (await engine.currentState).revision
        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }

        let result = try await engine.windowWorkspace(
            selector: WindowTargetSelector(
                windowID: 9,
                pid: backed.pid,
                processStartTime: backed.processStartTime,
                bundleID: backed.bundleID
            ),
            toSpaceID: 2,
            config: config
        )
        #expect(result.didCreateTrackingEntry)
        #expect(result.spaceID == 2)
        #expect(writeAheadState?.pendingVisibilityConvergence != nil)
        #expect(writeAheadState?.slots.contains {
            $0.bundleID == backed.bundleID
                && $0.boundIdentity == backed.identity
                && $0.spaceID == 2
        } == true)
        let finalState = await engine.currentState
        #expect(finalState.revision == revisionBefore + 2)
        let finderEntries = finalState.slots.filter {
            $0.bundleID == "com.apple.finder"
        }
        #expect(finderEntries.count == 1)
        #expect(finderEntries.first?.spaceID == 2)
        #expect(finderEntries.first?.boundIdentity == backed.identity)
    }

    @Test func refusedWorkspaceMoveRollsBackMembershipButKeepsTracking() async throws {
        var windows = standardWindows()
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: true,
            frontIndex: 3
        )
        windows.append(finder)
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.failPositionWindowIDs = [finder.windowID]

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(
                    windowID: finder.windowID,
                    pid: finder.pid,
                    processStartTime: finder.processStartTime,
                    bundleID: finder.bundleID
                ),
                toSpaceID: 2,
                config: self.config
            )
        }

        let state = await engine.currentState
        let entry = state.slots.first { $0.bundleID == finder.bundleID }
        #expect(entry?.boundIdentity == finder.identity)
        #expect(entry?.spaceID == 1)
        #expect(entry?.visibilityState == .visible)
        #expect(state.pendingVisibilityConvergence == nil)
        #expect(control.window(finder.windowID)?.frame == finder.frame)
    }

    @Test func ambiguousWorkspaceMoveFailureKeepsDurableRecoveryIntent() async throws {
        var windows = standardWindows()
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: true,
            frontIndex: 3
        )
        windows.append(finder)
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.pinnedFrameWindowIDs[finder.windowID] = ResolvedFrame(
            x: 500,
            y: 500,
            width: finder.frame.width,
            height: finder.frame.height
        )

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(
                    windowID: finder.windowID,
                    pid: finder.pid,
                    processStartTime: finder.processStartTime,
                    bundleID: finder.bundleID
                ),
                toSpaceID: 2,
                config: self.config
            )
        }

        let state = await engine.currentState
        let entry = state.slots.first { $0.bundleID == finder.bundleID }
        #expect(entry?.boundIdentity == finder.identity)
        #expect(entry?.spaceID == 2)
        #expect(entry?.visibilityState == .hiddenOffscreen)
        #expect(state.recoveryRequired)

        let currentFinder = control.window(finder.windowID)!
        control.removeWindow(finder.windowID)
        control.addWindow(TestFixtures.window(
            id: finder.windowID,
            bundleID: finder.bundleID,
            pid: finder.pid,
            frame: currentFinder.frame,
            isAXBacked: false,
            frontIndex: finder.frontIndex
        ))
        control.pinnedFrameWindowIDs = [:]
        _ = try await engine.switchSpace(to: 2, config: config)
        #expect((await engine.currentState).recoveryRequired)
    }

    @Test func workspaceMoveUnknownVerificationKeepsWriteAheadPending() async throws {
        var windows = standardWindows()
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: true,
            frontIndex: 3
        )
        windows.append(finder)
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.onFrameMutationAttempt = {
            control.windowInventoryAvailable = false
        }

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(
                    windowID: finder.windowID,
                    pid: finder.pid,
                    processStartTime: finder.processStartTime,
                    bundleID: finder.bundleID
                ),
                toSpaceID: 2,
                config: self.config
            )
        }

        let state = await engine.currentState
        let entry = state.slots.first { $0.bundleID == finder.bundleID }
        #expect(entry?.spaceID == 2)
        #expect(entry?.visibilityState == .hiddenOffscreen)
        #expect(state.pendingVisibilityConvergence != nil)
    }

    @Test func workspaceMovePreservesPendingVisibilityRecovery() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var pending = await engine.currentState
        let previousPending = PendingVisibilityConvergence(
            requestID: "pending",
            startedAt: Date.rfc3339UTC(),
            layoutName: "work",
            targetSpaceID: 1
        )
        pending.pendingVisibilityConvergence = previousPending
        try await engine.replaceState(pending)

        let outcome = try await engine.moveWindowToWorkspace(
            window: control.window(1)!,
            toSpaceID: 2,
            config: self.config
        )

        #expect(outcome.fromSpaceID == 1)
        #expect(outcome.toSpaceID == 2)
        let state = await engine.currentState
        #expect(state.pendingVisibilityConvergence == previousPending)
        #expect(state.slots.first { $0.windowID == 1 }?.spaceID == 2)
        #expect(control.frameMutationAttemptWindowIDs == [1])
    }

    @Test func invalidWorkspaceNeverAdoptsUntrackedWindow() async throws {
        var windows = standardWindows()
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            isAXBacked: true,
            frontIndex: 3
        )
        windows.append(finder)
        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(
                    windowID: finder.windowID,
                    pid: finder.pid,
                    processStartTime: finder.processStartTime,
                    bundleID: finder.bundleID
                ),
                toSpaceID: 99,
                config: self.config
            )
        }
        #expect(!(await engine.currentState).slots.contains { $0.bundleID == finder.bundleID })
    }

    @Test func overlappingCloneRuleAssignmentSurvivesPersistRoundTrip() async throws {
        // Two clone-rule slots of identical specificity: the assignment must
        // not flap across state update → save → reload.
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.Terminal", title: "t1", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", title: "t2", isAXBacked: true, frontIndex: 1),
        ]
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal"),
                    slot: 2,
                    launch: false,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: []),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["term": layout])
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "term", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let stateBefore = await engine.currentState
        #expect(stateBefore.slots.map(\.slot) == [1, 2])

        // Fresh engine loads the exact state currently held in memory.
        let reloaded = try VirtualSpaceEngine(
            store: RuntimeStateStore(stateFileURL: url),
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        #expect((await reloaded.currentState).slots == stateBefore.slots)

        // Invalidate all exact bindings so both engines must use clone-rule
        // fallback. Their input order must still be identical.
        control.removeWindow(1)
        control.removeWindow(2)
        control.addWindow(TestFixtures.window(
            id: 11,
            bundleID: "com.apple.Terminal",
            pid: 110,
            title: "new-1",
            isAXBacked: true,
            frontIndex: 0
        ))
        control.addWindow(TestFixtures.window(
            id: 12,
            bundleID: "com.apple.Terminal",
            pid: 120,
            title: "new-2",
            isAXBacked: true,
            frontIndex: 1
        ))

        _ = try await engine.switchSpace(to: 1, config: config)
        _ = try await reloaded.switchSpace(to: 1, config: config)

        let inMemoryAfter = await engine.currentState
        let reloadedAfter = await reloaded.currentState
        #expect(inMemoryAfter.slots.map(\.id) == reloadedAfter.slots.map(\.id))
        let inMemoryBinding = Dictionary(
            uniqueKeysWithValues: inMemoryAfter.slots.map { ($0.slot, $0.boundIdentity) }
        )
        let reloadedBinding = Dictionary(
            uniqueKeysWithValues: reloadedAfter.slots.map { ($0.slot, $0.boundIdentity) }
        )
        #expect(inMemoryBinding == reloadedBinding)
    }

    @Test func shutdownRestoreReportsIncompleteWhenHiddenWindowLosesAXVisibility() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Terminal stays alive in CG but drops out of AX visibility while
        // parked offscreen.
        control.removeWindow(2)
        control.addWindow(
            TestFixtures.window(
                id: 2,
                bundleID: "com.apple.Terminal",
                isAXBacked: false,
                frontIndex: 1
            )
        )
        let terminalSibling = TestFixtures.window(
            id: 22,
            bundleID: "com.apple.Terminal",
            pid: 220,
            isAXBacked: true,
            frontIndex: 0
        )
        control.addWindow(terminalSibling)

        #expect(await engine.restoreAllForShutdown(config: config) == false)
        let state = await engine.currentState
        let terminal = state.slots.first { $0.bundleID == "com.apple.Terminal" }
        #expect(terminal?.visibilityState == .hiddenOffscreen)
        #expect(!control.frameMutationAttemptWindowIDs.contains(terminalSibling.windowID))

        // Once the exact CG identity is truly gone, the layout rule may fall
        // back to the sibling and complete the restore.
        control.removeWindow(2)
        #expect(await engine.restoreAllForShutdown(config: config) == true)
    }

    @Test func shutdownRestoreReportsIncompleteWhenInventoryIsUnavailable() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        let before = await engine.currentState
        #expect(before.slots.contains { $0.visibilityState == .hiddenOffscreen })

        control.windowInventoryAvailable = false
        #expect(await engine.restoreAllForShutdown(config: config) == false)
        #expect(await engine.currentState == before)
    }

    @Test func shutdownUnknownVerificationKeepsHiddenEntryRecoverable() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        control.onFrameMutationAttempt = {
            control.windowInventoryAvailable = false
        }

        #expect(await engine.restoreAllForShutdown(config: config) == false)

        let state = await engine.currentState
        #expect(state.slots.filter { $0.spaceID == 1 }
            .allSatisfy { $0.visibilityState == .hiddenOffscreen })
    }

    @Test func rawCGHandleWithoutSnapshotKeepsHiddenEntryRecoverable() async throws {
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            pid: 90,
            isAXBacked: true,
            frontIndex: 3
        )
        let (engine, control, url) = makeEngine(windows: standardWindows() + [finder])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        #expect(try await engine.adoptWindowIntoActiveWorkspace(finder, config: config))
        _ = try await engine.switchSpace(to: 2, config: config)

        control.removeWindow(finder.windowID)
        control.liveWindowHandlesOverride = Set(control.currentWindows().map(\.handle) + [finder.handle])

        #expect(await engine.restoreAllForShutdown(config: config) == false)
        _ = try await engine.switchSpace(to: 1, config: config)
        let state = await engine.currentState
        #expect(state.slots.contains {
            $0.origin == .adopted && $0.boundIdentity == finder.identity
        })
    }

    @Test func markActivatedWritesOnlyUnambiguousEntries() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(2)!)

        let state = await engine.currentState
        let terminal = state.slots.first { $0.bundleID == "com.apple.Terminal" }
        #expect(terminal?.lastActivatedAt != nil)
        #expect(terminal?.windowID == 2)

        let others = state.slots.filter { $0.bundleID != "com.apple.Terminal" }
        #expect(others.allSatisfy { $0.lastActivatedAt == nil })
        #expect(others.allSatisfy { $0.windowID == nil })
    }

    // 未定義ウィンドウは「見えていた(切替元)ワークスペース」に採用される
    @Test func untrackedWindowIsAdoptedIntoPreSwitchSpace() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Adopted into space 1 (where it was visible), hidden with it.
        let state = await engine.currentState
        let finderEntry = state.slots.first { $0.bundleID == "com.apple.finder" }
        #expect(finderEntry?.origin == .adopted)
        #expect(finderEntry?.spaceID == 1)
        #expect(finderEntry?.visibilityState == .hiddenOffscreen)

        let finderWindow = control.window(9)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: finderWindow.frame, displays: [TestFixtures.display]))

        // Switching back restores it.
        _ = try await engine.switchSpace(to: 1, config: config)
        let restored = control.window(9)!
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: restored.frame, displays: [TestFixtures.display]))
    }

    @Test func switchSpacePersistsRecoveryIntentBeforeHidingAdoptedWindow() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let before = await engine.currentState
        #expect(before.revision == 1)
        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }

        _ = try await engine.switchSpace(to: 2, config: config)

        let after = await engine.currentState
        #expect(after.revision == before.revision + 2)
        #expect(writeAheadState?.pendingVisibilityConvergence != nil)
        #expect(writeAheadState?.slots.contains {
            $0.origin == .adopted
                && $0.windowID == 9
                && $0.visibilityState == .hiddenOffscreen
        } == true)
        #expect(after.slots.contains { $0.origin == .adopted && $0.windowID == 9 })
    }

    @Test func showWriteAheadStateRemainsShutdownRecoverableBeforeMutation() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        let physicallyHidden = control.currentWindows()

        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }
        _ = try await engine.switchSpace(to: 1, config: config)

        let captured = try #require(writeAheadState)
        #expect(captured.pendingVisibilityConvergence != nil)
        #expect(captured.slots.filter { $0.bundleID != "com.apple.Notes" }
            .allSatisfy { $0.visibilityState == .hiddenOffscreen })

        let (recoveryStore, recoveryURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: recoveryURL.deletingLastPathComponent()) }
        _ = try recoveryStore.saveStrict(state: captured)
        let recoveryControl = MockWindowControl(windows: physicallyHidden, displays: [TestFixtures.display])
        let recoveryEngine = try VirtualSpaceEngine(
            store: recoveryStore,
            control: recoveryControl,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        #expect(await recoveryEngine.restoreAllForShutdown(config: config))
        #expect(recoveryControl.currentWindows().allSatisfy {
            !VisibilityPlanner.isHiddenWindowFrame(frame: $0.frame, displays: [TestFixtures.display])
        })
    }

    @Test func switchWriteAheadDoesNotClaimManuallyMinimizedWindowWasHidden() async throws {
        var windows = standardWindows()
        windows[1] = TestFixtures.window(
            id: 2,
            bundleID: "com.apple.Terminal",
            isAXBacked: true,
            minimized: true,
            frontIndex: 1
        )
        let physicalStateBeforeMutation = windows
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }
        let outcome = try await engine.switchSpace(to: 2, config: config)

        let captured = try #require(writeAheadState)
        let terminal = try #require(captured.slots.first { $0.bundleID == "com.apple.Terminal" })
        #expect(terminal.visibilityState == .visible)

        #expect(outcome.converged)
        let finalState = await engine.currentState
        #expect(finalState.pendingVisibilityConvergence == nil)
        #expect(finalState.slots.first { $0.bundleID == "com.apple.Terminal" }?.visibilityState == .visible)
        #expect(control.window(2)?.minimized == true)

        let (recoveryStore, recoveryURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: recoveryURL.deletingLastPathComponent()) }
        _ = try recoveryStore.saveStrict(state: captured)
        let recoveryControl = MockWindowControl(
            windows: physicalStateBeforeMutation,
            displays: [TestFixtures.display]
        )
        let recoveryEngine = try VirtualSpaceEngine(
            store: recoveryStore,
            control: recoveryControl,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )

        #expect(await recoveryEngine.restoreAllForShutdown(config: config))
        #expect(recoveryControl.window(2)?.minimized == true)
    }

    @Test func showWriteAheadKeepsOriginallyVisibleMinimizedWindowVisible() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let notesBeforeMinimize = try #require(control.window(3))
        #expect(control.setWindowMinimized(
            windowID: notesBeforeMinimize.windowID,
            pid: notesBeforeMinimize.pid,
            processStartTime: notesBeforeMinimize.processStartTime,
            bundleID: notesBeforeMinimize.bundleID,
            minimized: true
        ).isSuccess)
        let physicalStateBeforeMutation = control.currentWindows()

        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }
        _ = try await engine.switchSpace(to: 2, config: config, reconcile: true)

        let captured = try #require(writeAheadState)
        let notes = try #require(captured.slots.first { $0.bundleID == "com.apple.Notes" })
        #expect(notes.visibilityState == .visible)

        let (recoveryStore, recoveryURL) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: recoveryURL.deletingLastPathComponent()) }
        _ = try recoveryStore.saveStrict(state: captured)
        let recoveryControl = MockWindowControl(
            windows: physicalStateBeforeMutation,
            displays: [TestFixtures.display]
        )
        let recoveryEngine = try VirtualSpaceEngine(
            store: recoveryStore,
            control: recoveryControl,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )

        #expect(await recoveryEngine.restoreAllForShutdown(config: config))
        #expect(recoveryControl.window(3)?.minimized == true)
    }

    @Test func switchWriteAheadReplacesStalePendingTransactionMetadata() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        var pending = await engine.currentState
        pending.pendingVisibilityConvergence = PendingVisibilityConvergence(
            requestID: "old-target-1",
            startedAt: Date.rfc3339UTC(),
            layoutName: "work",
            targetSpaceID: 1
        )
        try await engine.replaceState(pending)

        var writeAheadState: RuntimeState?
        control.onFrameMutationAttempt = {
            guard writeAheadState == nil else { return }
            writeAheadState = try? RuntimeStateStore(stateFileURL: url).loadStrict()
        }
        _ = try await engine.switchSpace(to: 2, config: config)

        let captured = try #require(writeAheadState)
        #expect(captured.primaryActiveSpaceID == 2)
        #expect(captured.pendingVisibilityConvergence?.targetSpaceID == 2)
        #expect(captured.pendingVisibilityConvergence?.requestID != "old-target-1")
    }

    @Test func shutdownKeepsPendingStateWhenNoHiddenEntryCanBeVerified() async throws {
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var pending = await engine.currentState
        pending.pendingVisibilityConvergence = PendingVisibilityConvergence(
            requestID: "pending-visible",
            startedAt: Date.rfc3339UTC(),
            layoutName: "work",
            targetSpaceID: 1
        )
        try await engine.replaceState(pending)

        #expect(await engine.restoreAllForShutdown(config: config) == false)
        #expect((await engine.currentState).pendingVisibilityConvergence != nil)
    }

    @Test func focusedUntrackedWindowIsAdoptedIntoCurrentActiveSpace() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 0
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let adopted = try await engine.adoptWindowIntoActiveWorkspace(control.window(9)!, config: config)

        #expect(adopted)
        let state = await engine.currentState
        let finderEntry = state.slots.first { $0.bundleID == "com.apple.finder" && $0.windowID == 9 }
        #expect(finderEntry?.origin == .adopted)
        #expect(finderEntry?.spaceID == 1)
    }

    @Test func cgOnlyChromeSurfaceIsNeverAdoptedOrMoved() async throws {
        // The AX-backed Chrome main window and a CG-only auxiliary surface
        // coexist under the same PID (the live incident shape): the main
        // window is adopted and managed, the surface is never touched.
        var windows = standardWindows()
        let chromePID = 900
        let mainWindow = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            pid: chromePID,
            title: "main",
            isAXBacked: true,
            frontIndex: 3
        )
        let surface = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            pid: chromePID,
            title: "",
            frame: ResolvedFrame(x: 40, y: 40, width: 500, height: 500),
            isAXBacked: false,
            frontIndex: 0
        )
        windows.append(contentsOf: [mainWindow, surface])

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let state = await engine.currentState
        #expect(state.slots.contains { $0.pid == mainWindow.pid && $0.windowID == mainWindow.windowID })
        #expect(!state.slots.contains { $0.windowID == surface.windowID })
        #expect(control.window(surface.windowID)?.frame == surface.frame)
        #expect(!control.frameMutationAttemptWindowIDs.contains(surface.windowID))
        #expect(!control.focusedWindowIDs.contains(surface.windowID))
        #expect(!state.recoveryRequired)
    }

    @Test func adoptedEntrySurvivesWindowLosingAXVisibility() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        var state = await engine.currentState
        let adopted = try #require(
            state.slots.first { $0.origin == .adopted && $0.windowID == 9 }
        )

        // The window drops out of Finder's AX window list while staying
        // alive in CG — a transient AX failure, a hop to another native
        // Space, and an unreported minimized state all look like this.
        control.removeWindow(9)
        control.addWindow(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: false,
                frontIndex: 3
            )
        )
        let attemptsBeforeUnknownPass = control.frameMutationAttemptWindowIDs.count
        _ = try await engine.switchSpace(to: 1, config: config)

        state = await engine.currentState
        #expect(state.slots.contains { $0.id == adopted.id })
        #expect(
            !control.frameMutationAttemptWindowIDs
                .dropFirst(attemptsBeforeUnknownPass)
                .contains(9)
        )

        // AX answers again: the same entry resolves; no duplicate appears.
        control.removeWindow(9)
        control.addWindow(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 3
            )
        )
        _ = try await engine.switchSpace(to: 2, config: config)

        state = await engine.currentState
        let finderEntries = state.slots.filter { $0.bundleID == "com.apple.finder" }
        #expect(finderEntries.count == 1)
        #expect(finderEntries.first?.id == adopted.id)
        #expect(finderEntries.first?.windowID == 9)
    }

    @Test func focusSlotNeverBindsCGOnlySurface() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // The bound TextEdit window (slot 1) goes away and only a CG-only
        // surface of the same app remains: focusSlot must fail instead of
        // rebinding the slot to the surface via the application rule.
        control.removeWindow(1)
        control.addWindow(
            TestFixtures.window(
                id: 99,
                bundleID: "com.apple.TextEdit",
                pid: 10,
                title: "",
                frame: ResolvedFrame(x: 40, y: 40, width: 500, height: 500),
                isAXBacked: false,
                frontIndex: 0
            )
        )

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.focusSlot(1, config: self.config)
        }
        #expect(!control.focusedWindowIDs.contains(99))
        var state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 99 })

        // The surface never shows up as a switcher/cycle candidate either.
        let candidates = try await engine.switcherCandidates(includeAllSpaces: true, config: config)
        #expect(!candidates.contains { $0.windowID == 99 })
        let cycle = try await engine.cycleCandidates(config: config)
        #expect(!cycle.contains { $0.windowID == 99 })
        state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 99 })
    }

    @Test func focusEventRequiresMatchingPIDAndBundleID() async throws {
        let window = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            isAXBacked: true
        )
        let (engine, control, url) = makeEngine(windows: [window])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.setFocusedWindowID(window.windowID)

        #expect(await engine.processFocusEvent(
            sequence: 1,
            windowID: window.windowID,
            pid: window.pid + 1,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            config: config
        ) == nil)
        #expect(await engine.processFocusEvent(
            sequence: 2,
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: "com.example.other",
            config: config
        ) == nil)

        let outcome = await engine.processFocusEvent(
            sequence: 3,
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            config: config
        )
        #expect(outcome?.didAdopt == true)
        #expect(outcome?.spaceID == 1)
    }

    @Test func focusedOffscreenWindowIsNotAdoptedIntoCurrentWorkspace() async throws {
        let window = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            isAXBacked: true
        )
        let (engine, control, url) = makeEngine(windows: [window])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.setFocusedWindowID(window.windowID)
        control.onScreenWindowIdentitiesOverride = []

        let outcome = await engine.processFocusEvent(
            sequence: 1,
            windowID: window.windowID,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: window.bundleID,
            config: config
        )

        #expect(outcome == nil)
        let state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == window.windowID })
    }

    @Test func helperUIWindowIsNotAdoptedIntoWorkspace() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                title: "",
                frame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
                isAXBacked: true,
                frontIndex: 0
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let adopted = try await engine.adoptWindowIntoActiveWorkspace(control.window(9)!, config: config)

        #expect(!adopted)
        let state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 9 })
    }

    @Test func helperUIWindowIsNotBulkAdoptedIntoWorkspace() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                title: "",
                frame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
                isAXBacked: true,
                frontIndex: 0
            )
        )

        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switcherCandidates(includeAllSpaces: false, config: config)

        let state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 9 })
    }

    @Test func existingHelperUIAdoptedWindowIsPrunedFromSwitcherState() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                title: "",
                frame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
                isAXBacked: true,
                frontIndex: 0
            )
        )

        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var state = await engine.currentState
        state.slots.append(helperUIAdoptedEntry())
        try await engine.replaceState(state)

        _ = try await engine.switcherCandidates(includeAllSpaces: false, config: config)

        state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 9 })
    }

    @Test func existingHelperUIAdoptedWindowIsPrunedBeforeSwitch() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                title: "",
                frame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
                isAXBacked: true,
                frontIndex: 0
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var state = await engine.currentState
        state.slots.append(helperUIAdoptedEntry())
        try await engine.replaceState(state)

        _ = try await engine.switchSpace(to: 2, config: config)

        state = await engine.currentState
        #expect(!state.slots.contains { $0.windowID == 9 })
        #expect(!control.focusedWindowIDs.contains(9))
    }

    // ピッカー候補から「存在しない/見えない」ウィンドウを除外する
    @Test func switcherCandidatesExcludePhantomWindows() async throws {
        let windows = standardWindows()
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // Baseline: TextEdit + Terminal on the active space.
        var candidates = try await engine.switcherCandidates(includeAllSpaces: false, config: config)
        #expect(candidates.compactMap(\.bundleID).sorted() == ["com.apple.TextEdit", "com.apple.Terminal"].sorted())

        // Minimized window disappears from the picker.
        let terminal = try #require(control.window(2))
        _ = control.setWindowMinimized(
            windowID: 2,
            pid: terminal.pid,
            processStartTime: terminal.processStartTime,
            bundleID: "com.apple.Terminal",
            minimized: true
        )
        candidates = try await engine.switcherCandidates(includeAllSpaces: false, config: config)
        #expect(candidates.compactMap(\.bundleID) == ["com.apple.TextEdit"])
        _ = control.setWindowMinimized(
            windowID: 2,
            pid: terminal.pid,
            processStartTime: terminal.processStartTime,
            bundleID: "com.apple.Terminal",
            minimized: false
        )

        // A tracked-but-not-on-screen window (e.g. on another native Space)
        // disappears too — unless it is parked offscreen by us.
        control.onScreenWindowIdentitiesOverride = Set([2, 3].compactMap { control.window(UInt32($0))?.identity })
        candidates = try await engine.switcherCandidates(includeAllSpaces: false, config: config)
        #expect(candidates.compactMap(\.bundleID) == ["com.apple.Terminal"])
        control.onScreenWindowIdentitiesOverride = nil
    }

    @Test func switcherAndCycleReturnNoCandidatesForUnavailableInventory() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let before = await engine.currentState
        control.windowInventoryAvailable = false

        let switcher = try await engine.switcherCandidates(includeAllSpaces: true, config: config)
        let cycle = try await engine.cycleCandidates(config: config)

        #expect(switcher.isEmpty)
        #expect(cycle.isEmpty)
        #expect(await engine.currentState == before)
    }

    @Test func switcherIdentityNeverFocusesReusedWindowID() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        let candidates = try await engine.switcherCandidates(
            includeAllSpaces: false,
            config: config
        )
        let candidate = try #require(candidates.first { $0.windowID == 1 })
        control.removeWindow(candidate.windowID)
        control.addWindow(TestFixtures.window(
            id: candidate.windowID,
            bundleID: "com.apple.finder",
            pid: 999,
            isAXBacked: true,
            frontIndex: 0
        ))

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.focusWindow(identity: candidate.identity, config: self.config)
        }
        #expect(control.focusedWindowIDs.isEmpty)
    }

    @Test func explicitFocusDoesNotTreatApplicationActivationAsWindowFocus() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let target = try #require(control.window(1))
        control.failFocusWindowIDs = [target.windowID]

        await #expect(throws: VirtualSpaceEngineError.self) {
            _ = try await engine.focusWindow(identity: target.identity, config: self.config)
        }

        #expect(control.activatedBundles == [target.bundleID])
        #expect(!control.focusedWindowIDs.contains(target.windowID))
    }

    @Test func hiddenOffscreenWindowsRemainInAllSpacesCandidates() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Parked space-1 windows are NOT on screen but stay reachable in the
        // all-spaces candidate list (they are ours, not phantoms).
        control.onScreenWindowIdentitiesOverride = Set([3].compactMap { control.window(UInt32($0))?.identity })
        let candidates = try await engine.switcherCandidates(includeAllSpaces: true, config: config)
        #expect(Set(candidates.compactMap(\.bundleID)) == [
            "com.apple.TextEdit", "com.apple.Terminal", "com.apple.Notes",
        ])
        control.onScreenWindowIdentitiesOverride = nil
    }

    @Test func synchronousInteractiveInvalidationPreventsStaleFollowFocusRollback() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        control.setFocusedWindowID(1)
        let pending = await engine.processFocusEvent(
            sequence: 1,
            windowID: 1,
            pid: control.window(1)!.pid,
            processStartTime: control.window(1)!.processStartTime,
            bundleID: control.window(1)!.bundleID,
            config: config
        )
        #expect(pending?.spaceID == 1)

        engine.invalidatePendingFocusEvents()
        _ = try await engine.switchSpace(to: 2, config: config)
        let stale = try await engine.switchSpaceForFocusEvent(
            sequence: 1,
            identity: control.window(1)!.identity,
            to: 1,
            config: config
        )

        #expect(stale == nil)
        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
    }

    @Test func switchToSameSpaceIsIdempotent() async throws {
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 1, config: config)
        #expect(outcome.didChangeSpace == false)
        #expect(outcome.shownCount == 0)
    }

    // Codex指摘回帰: 閉じられた adopted ウィンドウは prune され recovery を汚染しない
    @Test func closedAdoptedWindowIsPrunedOnSwitch() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.finder",
                title: "Downloads",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config) // adopts Finder into space 1

        var state = await engine.currentState
        #expect(state.slots.contains { $0.origin == .adopted })

        // The Finder window goes away (app quit).
        control.removeWindow(9)

        let outcome = try await engine.switchSpace(to: 1, config: config)
        #expect(outcome.unresolvedSlots.isEmpty)
        #expect(outcome.converged)

        state = await engine.currentState
        #expect(!state.slots.contains { $0.origin == .adopted })
        #expect(!state.recoveryRequired)
    }

    @Test func staleAdoptedWindowDoesNotRebindToSameBundleReplacement() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.google.Chrome",
                title: "Old",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        var state = await engine.currentState
        let staleEntry = try #require(
            state.slots.first { $0.origin == .adopted && $0.windowID == 9 }
        )

        control.removeWindow(9)
        control.addWindow(
            TestFixtures.window(
                id: 10,
                bundleID: "com.google.Chrome",
                title: "Replacement",
                isAXBacked: true,
                frontIndex: 3
            )
        )

        _ = try await engine.switchSpace(to: 1, config: config)

        state = await engine.currentState
        let chromeEntries = state.slots.filter {
            $0.origin == .adopted && $0.bundleID == "com.google.Chrome"
        }
        #expect(chromeEntries.count == 1)
        #expect(chromeEntries.first?.id != staleEntry.id)
        #expect(chromeEntries.first?.windowID == 10)
        #expect(chromeEntries.first?.pid == 100)
    }

    @Test func clearPendingResetsRecovery() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true),
        ]
        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config) // Notes missing → pending

        var state = await engine.currentState
        #expect(state.recoveryRequired)

        try await engine.clearPending()
        state = await engine.currentState
        #expect(!state.recoveryRequired)
    }
}
