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
        let engine = VirtualSpaceEngine(
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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", frontIndex: 2),
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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit"),
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
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit"),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
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

    // Codex指摘回帰: index:1 / index:2 が arrange で両方解決される
    @Test func arrangeResolvesMultipleIndexEntriesOfSameApp() async throws {
        let windows = [
            TestFixtures.window(id: 1, bundleID: "com.apple.Terminal", title: "t1", frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", title: "t2", frontIndex: 1),
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
}
