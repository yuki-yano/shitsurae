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
        let engine = VirtualSpaceEngine(
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

    private func standardWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", frontIndex: 2),
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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", frontIndex: 0),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", frontIndex: 1),
            TestFixtures.window(id: 4, bundleID: "com.apple.Safari", frontIndex: 2),
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

    @Test func switchSpaceReFocusesIntendedWindowWhenStolenDuringConvergence() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        // win1 (TextEdit) is the MRU window we expect to restore on return to space 1.
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Reproduce the race: while returning to space 1, hiding the space-2
        // window (win3) keeps failing so convergence retries its position
        // mutation, and each such mutation steals key focus to a *sibling* of
        // the target workspace (win2). The early focus on win1 thus gets
        // clobbered after it already succeeded.
        control.failPositionWindowIDs = [3]
        control.stealFocusOnPositionAttempt = 2

        let outcome = try await engine.switchSpace(to: 1, config: config)

        // The engine must notice focus drifted off the window it just focused
        // and re-assert the intended MRU window after convergence settles —
        // folding the user's manual "press the shortcut again" into one switch.
        #expect(outcome.focusedWindowID == 1)
        #expect(control.focusedWindowIDs.last == 1)
    }

    @Test func switchSpaceKeepsUserChosenWindowWhenFocusLeavesTargetWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // During the return to space 1, focus drifts to win3 — a window that is
        // NOT a candidate of the target workspace (models the user deliberately
        // focusing another app while the switch is still settling). Only an OS
        // steal *within* the target workspace should trigger re-focus, so the
        // engine must leave the user's out-of-workspace choice alone.
        control.failPositionWindowIDs = [3]
        control.stealFocusOnPositionAttempt = 3

        _ = try await engine.switchSpace(to: 1, config: config)

        #expect(control.focusedWindowIDs.last == 3)
    }

    @Test func switchSpaceDoesNotReFocusWhenEarlyFocusFailedAndUserLeavesTargetWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        await engine.markActivated(window: control.window(1)!)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Make the early focus pass fail for both space-1 candidates. They
        // would succeed on the post-convergence retry, so this catches the nil
        // branch specifically: if focus has moved outside the target workspace,
        // the engine must not take it back.
        control.failFocusAttemptsRemainingByWindowID = [1: 2, 2: 2]
        control.failPositionWindowIDs = [3]
        control.stealFocusOnPositionAttempt = 3

        let outcome = try await engine.switchSpace(to: 1, config: config)

        #expect(outcome.focusedWindowID == nil)
        #expect(control.focusedWindowIDs.last == 3)
    }

    @Test func switchSpaceRollsBackUnmovableWindowsWithoutLeavingRecoveryPending() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)

        // Simulate special windows that refuse offscreen parking. The switch
        // should keep their persisted state truthful (rolled back to visible)
        // without poisoning pendingVisibilityConvergence forever.
        control.failPositionWindowIDs = [1, 2]

        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.converged)
        let state = await engine.currentState
        #expect(state.pendingVisibilityConvergence == nil)
        #expect(!state.recoveryRequired)
        #expect(state.slots.first { $0.bundleID == "com.apple.TextEdit" }?.visibilityState == .visible)
        #expect(state.slots.first { $0.bundleID == "com.apple.Terminal" }?.visibilityState == .visible)
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
        #expect(textEdit.frame == TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit").frame)
    }

    @Test func switchBackPreservesManualResize() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let resizedFrame = ResolvedFrame(x: 40, y: 50, width: 900, height: 500)
        #expect(control.setWindowFrame(windowID: 1, bundleID: "com.apple.TextEdit", frame: resizedFrame))

        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let textEdit = control.window(1)!
        #expect(textEdit.frame == resizedFrame)
    }

    // バグ1 回帰: 同一アプリ複数ウィンドウでもスペース遷移する
    @Test func multiWindowSameAppStillSwitches() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.Terminal", title: "t1", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", title: "t2", frontIndex: 1),
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
        windows[2] = TestFixtures.window(id: 3, bundleID: "com.apple.Notes", minimized: true, frontIndex: 2)

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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
        ]
        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let outcome = try await engine.switchSpace(to: 2, config: config)

        #expect(outcome.unresolvedSlots == [PendingUnresolvedSlot(slot: 1, spaceID: 2, reason: "windowUnresolved")])
        let state = await engine.currentState
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

    @Test func moveAmbiguousWindowFailsInsteadOfGuessing() async throws {
        // Two terminals, entries without windowID binding for window 2.
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.Terminal", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
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

        // Both entries unbound (no windowID yet) and both match either
        // terminal by rule (index ignored in lookup) → ambiguous → error.
        await #expect(throws: VirtualSpaceEngineError.self) {
            try await engine.moveWindowToWorkspace(window: control.window(1)!, toSpaceID: 2, config: config)
        }
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
        windows.append(TestFixtures.window(id: 9, bundleID: "com.apple.finder", title: "Downloads", frontIndex: 3))

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

    @Test func switchSpaceAdoptsUntrackedWindowsWithSinglePersist() async throws {
        var windows = standardWindows()
        windows.append(TestFixtures.window(id: 9, bundleID: "com.apple.finder", title: "Downloads", frontIndex: 3))

        let (engine, _, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let before = await engine.currentState
        #expect(before.revision == 1)

        _ = try await engine.switchSpace(to: 2, config: config)

        let after = await engine.currentState
        #expect(after.revision == before.revision + 1)
        #expect(after.slots.contains { $0.origin == .adopted && $0.windowID == 9 })
    }

    @Test func focusedUntrackedWindowIsAdoptedIntoCurrentActiveSpace() async throws {
        var windows = standardWindows()
        windows.append(TestFixtures.window(id: 9, bundleID: "com.apple.finder", title: "Downloads", frontIndex: 0))

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

    @Test func helperUIWindowIsNotAdoptedIntoWorkspace() async throws {
        var windows = standardWindows()
        windows.append(
            TestFixtures.window(
                id: 9,
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                title: "",
                frame: ResolvedFrame(x: 20, y: 20, width: 64, height: 64),
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
        _ = control.setWindowMinimized(windowID: 2, bundleID: "com.apple.Terminal", minimized: true)
        candidates = try await engine.switcherCandidates(includeAllSpaces: false, config: config)
        #expect(candidates.compactMap(\.bundleID) == ["com.apple.TextEdit"])
        _ = control.setWindowMinimized(windowID: 2, bundleID: "com.apple.Terminal", minimized: false)

        // A tracked-but-not-on-screen window (e.g. on another native Space)
        // disappears too — unless it is parked offscreen by us.
        control.onScreenWindowIDsOverride = [2, 3] // TextEdit (1) not on screen
        candidates = try await engine.switcherCandidates(includeAllSpaces: false, config: config)
        #expect(candidates.compactMap(\.bundleID) == ["com.apple.Terminal"])
        control.onScreenWindowIDsOverride = nil
    }

    @Test func hiddenOffscreenWindowsRemainInAllSpacesCandidates() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        // Parked space-1 windows are NOT on screen but stay reachable in the
        // all-spaces candidate list (they are ours, not phantoms).
        control.onScreenWindowIDsOverride = [3]
        let candidates = try await engine.switcherCandidates(includeAllSpaces: true, config: config)
        #expect(Set(candidates.compactMap(\.bundleID)) == [
            "com.apple.TextEdit", "com.apple.Terminal", "com.apple.Notes",
        ])
        control.onScreenWindowIDsOverride = nil
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
        windows.append(TestFixtures.window(id: 9, bundleID: "com.apple.finder", title: "Downloads", frontIndex: 3))

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

    @Test func clearPendingResetsRecovery() async throws {
        let windows = [TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit")]
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
