import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Arrange")
struct ArrangeTests {
    private var config: LoadedConfig {
        TestFixtures.loadedConfig(layouts: ["work": TestFixtures.twoSpaceLayout()])
    }

    private func makeEngine(
        windows: [WindowSnapshot]
    ) -> (engine: VirtualSpaceEngine, control: MockWindowControl, stateURL: URL) {
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display])
        let (store, url) = TestFixtures.tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 50
        )
        return (engine, control, url)
    }

    private func standardWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
        ]
    }

    @Test func dryRunListsPlanAndAvailableSpaces() async throws {
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let dryRun = try await engine.arrangeDryRun(layoutName: "work", spaceID: nil, config: config)

        #expect(dryRun.availableSpaceIDs == [1, 2])
        #expect(dryRun.plan.contains { $0.action == "setFrame" && $0.bundleID == "com.apple.TextEdit" })
        #expect(dryRun.plan.contains { $0.action == "focusInitial" })
        #expect(dryRun.skipped.isEmpty)
        // No windows were touched.
        #expect(dryRun.plan.allSatisfy { $0.action != "moveSpace" })
    }

    @Test func dryRunReportsMissingWindows() async throws {
        let (engine, _, url) = makeEngine(windows: [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let dryRun = try await engine.arrangeDryRun(layoutName: "work", spaceID: nil, config: config)
        #expect(dryRun.skipped.contains { $0.reason == "noWindowMatched" })
    }

    @Test func stateOnlyBootstrapsWithoutTouchingWindows() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await engine.arrangeStateOnly(layoutName: "work", spaceID: 1, config: config)

        #expect(result.result == "success")
        #expect(result.warnings.contains { $0.code == "arrange.stateOnly" })

        let state = await engine.currentState
        #expect(state.activeLayoutName == "work")
        #expect(state.primaryActiveSpaceID == 1)
        #expect(state.slots.count == 3)

        // No window mutations happened.
        let original = standardWindows()
        for window in original {
            #expect(control.window(window.windowID)?.frame == window.frame)
        }
    }

    @Test func arrangePlacesWindowsAndHidesInactiveSpace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        #expect(result.result == "success")
        #expect(result.exitCode == 0)

        // space1 windows placed by layout: TextEdit left half, Terminal right half.
        let textEdit = control.window(1)!
        let terminal = control.window(2)!
        #expect(abs(textEdit.frame.width - 720) <= 2)
        #expect(abs(terminal.frame.width - 720) <= 2)
        #expect(terminal.frame.x > textEdit.frame.x)

        // space2 window (Notes) hidden because active space is 1.
        let notes = control.window(3)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: notes.frame, displays: [TestFixtures.display]))

        let state = await engine.currentState
        #expect(state.activeLayoutName == "work")
        let notesEntry = state.slots.first { $0.bundleID == "com.apple.Notes" }
        #expect(notesEntry?.visibilityState == .hiddenOffscreen)
        #expect(notesEntry?.windowID == 3)
    }

    @Test func arrangeReportsPartialWhenWindowMissing() async throws {
        // Notes is not running and launch:false in the fixture layout.
        let (engine, _, url) = makeEngine(windows: [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        #expect(result.result == "partial")
        #expect(result.exitCode == ErrorCode.partialSuccess.rawValue)
        #expect(result.softErrors.contains { $0.code == ErrorCode.targetWindowNotFound.rawValue })
    }

    @Test func arrangeSelectedSpaceOnlyTouchesThatSpace() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 2, config: config)
        let result = try await engine.arrange(layoutName: "work", spaceID: 2, config: config)

        #expect(result.result == "success")

        // Notes (space 2 = active) is placed full-size and visible.
        let notes = control.window(3)!
        #expect(abs(notes.frame.width - 1440) <= 2)
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: notes.frame, displays: [TestFixtures.display]))

        let state = await engine.currentState
        #expect(state.primaryActiveSpaceID == 2)
        // space1 entries kept (preserved fingerprints) and hidden after reconcile.
        let space1Entries = state.slots.filter { $0.spaceID == 1 }
        #expect(space1Entries.count == 2)
    }

    @Test func arrangeRestoresHiddenWindowsBeforePlacing() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        // Hide space2 by switching to space1 context, then arrange all.
        _ = try await engine.switchSpace(to: 2, config: config)
        _ = try await engine.switchSpace(to: 1, config: config)

        let notesBefore = control.window(3)!
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: notesBefore.frame, displays: [TestFixtures.display]))

        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)
        #expect(result.result == "success")

        // After arrange, notes is hidden again (active space 1), but it was
        // restored mid-arrange and its tracked lastVisibleFrame is the layout
        // frame, not the parking position.
        let state = await engine.currentState
        let notesEntry = state.slots.first { $0.bundleID == "com.apple.Notes" }
        #expect(notesEntry != nil)
        if let frame = notesEntry?.lastVisibleFrame {
            #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: frame, displays: [TestFixtures.display]))
        }
    }

    @Test func stateOnlyRejectsRemovingRecoveryMetadataForHiddenWindow() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let hiddenTextEdit = try #require(control.window(1))
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: hiddenTextEdit.frame,
            displays: [TestFixtures.display]
        ))
        let oldLayout = try #require(config.config.layouts["work"])
        let newLayout = LayoutDefinition(
            initialFocus: oldLayout.initialFocus,
            spaces: oldLayout.spaces.map { space in
                SpaceDefinition(
                    spaceID: space.spaceID,
                    windows: space.windows.filter { $0.match.bundleID != "com.apple.TextEdit" }
                )
            }
        )
        let newConfig = TestFixtures.loadedConfig(layouts: ["work": newLayout])
        let before = await engine.currentState

        await #expect(throws: VirtualSpaceEngineError.self) {
            try await engine.arrangeStateOnly(layoutName: "work", spaceID: 2, config: newConfig)
        }
        #expect(await engine.currentState == before)
    }

    @Test func liveArrangeRestoresHiddenWindowBeforeRemovingItsSlot() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let oldLayout = try #require(config.config.layouts["work"])
        let newLayout = LayoutDefinition(
            initialFocus: oldLayout.initialFocus,
            spaces: oldLayout.spaces.map { space in
                SpaceDefinition(
                    spaceID: space.spaceID,
                    windows: space.windows.filter { $0.match.bundleID != "com.apple.TextEdit" }
                )
            }
        )
        let newConfig = TestFixtures.loadedConfig(layouts: ["work": newLayout])

        let result = try await engine.arrange(layoutName: "work", spaceID: 2, config: newConfig)

        #expect(result.result == "success")
        let restoredTextEdit = try #require(control.window(1))
        #expect(!VisibilityPlanner.isHiddenWindowFrame(
            frame: restoredTextEdit.frame,
            displays: [TestFixtures.display]
        ))
        let textEditEntries = (await engine.currentState).slots.filter {
            $0.bundleID == "com.apple.TextEdit"
        }
        #expect(textEditEntries.allSatisfy { $0.origin == .adopted })
        #expect(textEditEntries.allSatisfy { $0.visibilityState == .visible })
    }

    @Test func liveArrangeRestoresPreviousLayoutWhenLayoutWasRenamed() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        #expect(VisibilityPlanner.isHiddenWindowFrame(
            frame: try #require(control.window(1)).frame,
            displays: [TestFixtures.display]
        ))

        let renamedLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let renamedConfig = TestFixtures.loadedConfig(layouts: ["renamed": renamedLayout])

        let result = try await engine.arrange(
            layoutName: "renamed",
            spaceID: 1,
            config: renamedConfig
        )

        #expect(result.result == "success")
        #expect(!VisibilityPlanner.isHiddenWindowFrame(
            frame: try #require(control.window(1)).frame,
            displays: [TestFixtures.display]
        ))
        #expect((await engine.currentState).activeLayoutName == "renamed")
    }

    @Test func arrangeAbortsWhenHiddenExactBindingIsAXInvisible() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let hiddenTextEdit = control.window(1)!
        control.removeWindow(hiddenTextEdit.windowID)
        control.addWindow(TestFixtures.window(
            id: hiddenTextEdit.windowID,
            bundleID: hiddenTextEdit.bundleID,
            pid: hiddenTextEdit.pid,
            frame: hiddenTextEdit.frame,
            isAXBacked: false,
            frontIndex: 1
        ))
        let sibling = TestFixtures.window(
            id: 10,
            bundleID: hiddenTextEdit.bundleID,
            pid: 1000,
            isAXBacked: true,
            frontIndex: 0
        )
        control.addWindow(sibling)
        let before = await engine.currentState

        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        #expect(result.result == "failed")
        #expect(result.subcode == "restoreIncomplete")
        #expect(await engine.currentState == before)
        #expect(!control.frameMutationAttemptWindowIDs.contains(sibling.windowID))
    }

    @Test func arrangeAbortsWithoutChangingStateWhenInventoryIsUnavailable() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)
        let before = await engine.currentState
        control.windowInventoryAvailable = false

        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        #expect(result.result == "failed")
        #expect(result.subcode == "restoreIncomplete")
        #expect(await engine.currentState == before)
    }

    @Test func arrangeSelectedSpaceDoesNotRestoreHiddenWindowOutsideScope() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let hiddenTextEdit = control.window(1)!
        control.removeWindow(hiddenTextEdit.windowID)
        control.addWindow(TestFixtures.window(
            id: hiddenTextEdit.windowID,
            bundleID: hiddenTextEdit.bundleID,
            pid: hiddenTextEdit.pid,
            processStartTime: hiddenTextEdit.processStartTime,
            frame: hiddenTextEdit.frame,
            isAXBacked: false,
            frontIndex: hiddenTextEdit.frontIndex
        ))
        let attemptsBeforeArrange = control.frameMutationAttemptWindowIDs.count

        let result = try await engine.arrange(layoutName: "work", spaceID: 2, config: config)

        #expect(result.result == "partial")
        #expect(result.exitCode == ErrorCode.partialSuccess.rawValue)
        #expect(!result.unresolvedSlots.isEmpty)
        #expect(result.subcode != "restoreIncomplete")
        #expect(!control.frameMutationAttemptWindowIDs
            .dropFirst(attemptsBeforeArrange)
            .contains(hiddenTextEdit.windowID))
    }

    @Test func arrangeSelectedSpaceNeverStealsWindowOwnedByAnotherLayoutEntry() async throws {
        let chromeRule = WindowMatchRule(bundleID: "com.google.Chrome")
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: chromeRule,
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: chromeRule,
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["work": layout])
        let chrome = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            isAXBacked: true
        )
        let (engine, _, url) = makeEngine(windows: [chrome])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        var boundState = await engine.currentState
        boundState.slots = boundState.slots.map { entry in
            entry.layoutSpaceID == 1 ? entry.bound(to: chrome) : entry
        }
        try await engine.replaceState(boundState)

        _ = try await engine.arrange(layoutName: "work", spaceID: 2, config: config)

        let state = await engine.currentState
        #expect(state.slots.filter { $0.boundIdentity == chrome.identity }.count == 1)
        #expect(state.slots.first { $0.layoutSpaceID == 1 }?.boundIdentity == chrome.identity)
        #expect(state.slots.first { $0.layoutSpaceID == 2 }?.boundIdentity == nil)
    }

    @Test func arrangeRestoreNeverMutatesWindowOwnedByOutOfScopeLayoutEntry() async throws {
        let layout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.google.Chrome"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(
                        bundleID: "com.google.Chrome",
                        title: TitleMatcher(equals: "Owned")
                    ),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["work": layout])
        let owned = TestFixtures.window(
            id: 20,
            bundleID: "com.google.Chrome",
            title: "Owned",
            isAXBacked: true
        )
        let vanished = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            pid: 2000,
            title: "Vanished",
            isAXBacked: true
        )
        let (engine, control, url) = makeEngine(windows: [owned])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 2, config: config)
        var state = await engine.currentState
        state.slots = state.slots.map { entry in
            var updated = entry.layoutSpaceID == 1
                ? entry.bound(to: vanished)
                : entry.bound(to: owned)
            if entry.layoutSpaceID == 1 {
                updated.visibilityState = .hiddenOffscreen
                updated.lastVisibleFrame = vanished.frame
            }
            return updated
        }
        try await engine.replaceState(state)

        let result = try await engine.arrange(layoutName: "work", spaceID: 1, config: config)

        #expect(result.result == "partial")
        // The final reconcile may intentionally park space 2, but the
        // pre-arrange restore must never issue a show/frame write to B's
        // exactly-owned window on behalf of stale entry A.
        #expect(!control.setFrameAttemptWindowIDs.contains(owned.windowID))
        let finalState = await engine.currentState
        #expect(finalState.slots.first { $0.layoutSpaceID == 2 }?.boundIdentity == owned.identity)
        #expect(finalState.slots.first { $0.layoutSpaceID == 1 }?.boundIdentity != owned.identity)
    }

    @Test func arrangePreferredBindingRequiresExactDefinitionFingerprint() async throws {
        let oldLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(
                        bundleID: "com.google.Chrome",
                        title: TitleMatcher(equals: "Old")
                    ),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let newLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(
                        bundleID: "com.google.Chrome",
                        title: TitleMatcher(equals: "New")
                    ),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let oldConfig = TestFixtures.loadedConfig(layouts: ["work": oldLayout])
        let newConfig = TestFixtures.loadedConfig(layouts: ["work": newLayout])
        let oldWindow = TestFixtures.window(
            id: 9,
            bundleID: "com.google.Chrome",
            title: "Old",
            frame: ResolvedFrame(x: 20, y: 20, width: 600, height: 400),
            isAXBacked: true
        )
        let newWindow = TestFixtures.window(
            id: 10,
            bundleID: "com.google.Chrome",
            title: "New",
            frame: ResolvedFrame(x: 30, y: 30, width: 600, height: 400),
            isAXBacked: true,
            frontIndex: 1
        )
        let (engine, control, url) = makeEngine(windows: [oldWindow, newWindow])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: oldConfig)
        var boundState = await engine.currentState
        boundState.slots[0] = boundState.slots[0].bound(to: oldWindow)
        try await engine.replaceState(boundState)

        _ = try await engine.arrange(layoutName: "work", spaceID: 1, config: newConfig)

        let state = await engine.currentState
        #expect(state.slots.first { $0.origin == .layout }?.boundIdentity == newWindow.identity)
        #expect(control.window(oldWindow.windowID)?.frame == oldWindow.frame)
    }

    @Test func arrangeTransfersClaimedAdoptedWindowToSingleLayoutEntry() async throws {
        let baseLayout = LayoutDefinition(spaces: [SpaceDefinition(spaceID: 1, windows: [])])
        let newLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.finder"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let baseConfig = TestFixtures.loadedConfig(layouts: ["work": baseLayout])
        let newConfig = TestFixtures.loadedConfig(layouts: ["work": newLayout])
        let finder = TestFixtures.window(
            id: 9,
            bundleID: "com.apple.finder",
            isAXBacked: true
        )
        let (engine, _, url) = makeEngine(windows: [finder])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: baseConfig)
        #expect(try await engine.adoptWindowIntoActiveWorkspace(finder, config: baseConfig))

        _ = try await engine.arrange(layoutName: "work", spaceID: 1, config: newConfig)

        let state = await engine.currentState
        let owners = state.slots.filter { $0.boundIdentity == finder.identity }
        #expect(owners.count == 1)
        #expect(owners.first?.origin == .layout)
    }

    @Test func arrangePreservesRuntimeBindingAcrossRuns() async throws {
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        let firstState = await engine.currentState
        let firstIDs = Set(firstState.slots.map(\.id))

        _ = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)
        let secondState = await engine.currentState
        let secondIDs = Set(secondState.slots.map(\.id))

        // Entry identity is stable across arranges (same fingerprints).
        #expect(firstIDs == secondIDs)
    }

    @Test func arrangePreferredBindingRejectsReusedIDFromAnotherProcess() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        control.removeWindow(1)
        let replacement = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.finder",
            pid: 999,
            frame: ResolvedFrame(x: 90, y: 90, width: 400, height: 300),
            isAXBacked: true,
            frontIndex: 0
        )
        let actualTextEdit = TestFixtures.window(
            id: 10,
            bundleID: "com.apple.TextEdit",
            pid: 1000,
            isAXBacked: true,
            frontIndex: 1
        )
        control.addWindow(replacement)
        control.addWindow(actualTextEdit)

        _ = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)
        #expect(control.window(replacement.windowID)?.frame == replacement.frame)
        let state = await engine.currentState
        #expect(state.slots.first { $0.bundleID == "com.apple.TextEdit" }?.boundIdentity
            == actualTextEdit.identity)
    }

    @Test func arrangeKeepsExactBindingWhenPreferredWindowIsFullscreen() async throws {
        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        let textEdit = control.window(1)!
        let fullscreen = TestFixtures.window(
            id: textEdit.windowID,
            bundleID: textEdit.bundleID,
            pid: textEdit.pid,
            processStartTime: textEdit.processStartTime,
            frame: ResolvedFrame(x: 0, y: 0, width: 1440, height: 900),
            isAXBacked: true,
            isFullscreen: true,
            frontIndex: textEdit.frontIndex
        )
        control.removeWindow(textEdit.windowID)
        control.addWindow(fullscreen)

        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: config)

        #expect(!result.softErrors.contains {
            $0.code == ErrorCode.targetWindowNotFound.rawValue && $0.slot == 1 && $0.spaceID == 1
        })
        let state = await engine.currentState
        #expect(state.slots.first { $0.bundleID == textEdit.bundleID }?.boundIdentity == textEdit.identity)
    }

    @Test func arrangeFallsBackWhenPreviousLayoutActiveSpaceIsInvalid() async throws {
        let otherLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 3, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 4, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "other": otherLayout,
        ])
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let result = try await engine.arrange(layoutName: "other", spaceID: nil, config: config)

        #expect(result.result == "success")
        let state = await engine.currentState
        #expect(state.activeLayoutName == "other")
        #expect(state.primaryActiveSpaceID == 3)
    }

    @Test func stateOnlyFallsBackWhenPreviousLayoutActiveSpaceIsInvalid() async throws {
        let otherLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 3, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "other": otherLayout,
        ])
        let (engine, _, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        let result = try await engine.arrangeStateOnly(layoutName: "other", spaceID: nil, config: config)

        #expect(result.result == "success")
        let state = await engine.currentState
        #expect(state.activeLayoutName == "other")
        #expect(state.primaryActiveSpaceID == 3)
    }

    // Codex指摘回帰: index:1 / index:2 が arrange で両方解決される
    @Test func arrangeResolvesMultipleIndexEntriesOfSameApp() async throws {
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
                    launch: false,
                    frame: TestFixtures.frameDef("0%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Terminal", index: 2),
                    slot: 2,
                    launch: false,
                    frame: TestFixtures.frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: ["term": layout])

        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "term", activeSpaceID: 1, config: config)
        let result = try await engine.arrange(layoutName: "term", spaceID: nil, config: config)

        #expect(result.result == "success")
        #expect(result.softErrors.isEmpty)

        // Both terminals placed side by side, bound to distinct windows.
        let state = await engine.currentState
        let boundIDs = Set(state.slots.compactMap(\.windowID))
        #expect(boundIDs == [1, 2])
        let first = control.window(1)!
        let second = control.window(2)!
        #expect(first.frame.x != second.frame.x)
    }

    @Test func ignoredAppIsSkipped() async throws {
        let layout = TestFixtures.twoSpaceLayout()
        let configWithIgnore = LoadedConfig(
            config: ShitsuraeConfig(
                ignore: IgnoreDefinition(
                    apply: IgnoreRuleSet(apps: ["com.apple.Terminal"])
                ),
                layouts: ["work": layout]
            ),
            configFiles: [],
            directoryURL: URL(fileURLWithPath: "/tmp"),
            configGeneration: String(repeating: "b", count: 64)
        )

        let (engine, control, url) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: configWithIgnore)
        let result = try await engine.arrange(layoutName: "work", spaceID: nil, config: configWithIgnore)

        #expect(result.skipped.contains { $0.reason == "ignoreApply" })
        // Terminal window untouched at its original frame.
        let terminal = control.window(2)!
        #expect(terminal.frame == ResolvedFrame(x: 10, y: 10, width: 700, height: 400))
    }

    @Test func ignoredWindowRuleUsesLiveWindowAttributes() async throws {
        let layout = TestFixtures.twoSpaceLayout()
        let configWithIgnore = LoadedConfig(
            config: ShitsuraeConfig(
                ignore: IgnoreDefinition(
                    apply: IgnoreRuleSet(windows: [
                        IgnoreWindowRule(bundleID: "com.apple.TextEdit", titleRegex: "^Skip Me$")
                    ])
                ),
                layouts: ["work": layout]
            ),
            configFiles: [],
            directoryURL: URL(fileURLWithPath: "/tmp"),
            configGeneration: String(repeating: "c", count: 64)
        )
        var windows = standardWindows()
        windows[0] = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            title: "Skip Me",
            isAXBacked: true,
            frontIndex: 0
        )
        let (engine, control, url) = makeEngine(windows: windows)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await engine.bootstrapState(
            layoutName: "work",
            activeSpaceID: 1,
            config: configWithIgnore
        )
        let originalFrame = try #require(control.window(1)).frame

        let result = try await engine.arrange(
            layoutName: "work",
            spaceID: nil,
            config: configWithIgnore
        )

        #expect(result.skipped.contains {
            $0.reason == "ignoreApply" && $0.slot == 1 && $0.spaceID == 1
        })
        #expect(control.window(1)?.frame == originalFrame)
        #expect(!(await engine.currentState).slots.contains { $0.boundIdentity == windows[0].identity })
    }
}
