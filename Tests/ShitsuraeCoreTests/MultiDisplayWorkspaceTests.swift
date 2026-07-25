import Foundation
import Testing
@testable import ShitsuraeCore

/// Multi-display foundation: per-display active workspaces, non-interference,
/// cross-layout ownership, dormancy and reconnect restore.
@Suite("Multi-display workspaces")
struct MultiDisplayWorkspaceTests {
    private static let calendarBundleID = "com.example.Calendar"

    private func fullFrame() -> FrameDefinition {
        TestFixtures.frameDef("0%", "0%", "100%", "100%")
    }

    private func calendarLayout(
        display: DisplayDefinition = DisplayDefinition(monitor: .secondary),
        match: WindowMatchRule = WindowMatchRule(bundleID: calendarBundleID)
    ) -> LayoutDefinition {
        LayoutDefinition(
            display: display,
            spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(match: match, slot: 1, launch: false, frame: fullFrame()),
                ]),
            ]
        )
    }

    private func twoSpaceCalendarLayout() -> LayoutDefinition {
        LayoutDefinition(
            display: DisplayDefinition(monitor: .secondary),
            spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: Self.calendarBundleID),
                        slot: 1,
                        launch: false,
                        frame: fullFrame()
                    ),
                ]),
                SpaceDefinition(spaceID: 2, windows: []),
            ]
        )
    }

    private var dualConfig: LoadedConfig {
        TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "calendar": calendarLayout(),
        ])
    }

    private func primaryWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
            TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
        ]
    }

    private func calendarWindow(displayID: String = "uuid-sub") -> WindowSnapshot {
        TestFixtures.window(
            id: 5,
            bundleID: Self.calendarBundleID,
            frame: ResolvedFrame(x: 1500, y: 20, width: 600, height: 500),
            isAXBacked: true,
            frontIndex: 3,
            displayID: displayID
        )
    }

    private func makeEngine(
        windows: [WindowSnapshot],
        displays: [DisplayInfo] = [TestFixtures.display, TestFixtures.secondaryDisplay()]
    ) -> (engine: VirtualSpaceEngine, control: MockWindowControl, stateURL: URL) {
        let control = MockWindowControl(windows: windows, displays: displays)
        let (store, url) = TestFixtures.tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        return (engine, control, url)
    }

    // MARK: - Resolver semantics

    @Test func displayResolverFallbackTable() {
        let primary = TestFixtures.display
        let secondary = TestFixtures.secondaryDisplay()
        let config = ShitsuraeConfig(layouts: [:])

        func resolve(_ display: DisplayDefinition?, displays: [DisplayInfo]) -> String? {
            DisplayResolver.hostDisplay(
                layout: LayoutDefinition(display: display, spaces: []),
                config: config,
                displays: displays
            )?.id
        }

        // Undeclared (and empty) declarations fall back to the primary.
        #expect(resolve(nil, displays: [primary, secondary]) == primary.id)
        #expect(resolve(DisplayDefinition(), displays: [primary, secondary]) == primary.id)
        // Declared and resolvable: the declared display.
        #expect(resolve(DisplayDefinition(monitor: .secondary), displays: [primary, secondary]) == secondary.id)
        #expect(resolve(DisplayDefinition(id: secondary.id), displays: [primary, secondary]) == secondary.id)
        #expect(resolve(DisplayDefinition(width: 2560, height: 1440), displays: [primary, secondary]) == secondary.id)
        // Declared but absent: nil, never a silent primary fallback.
        #expect(resolve(DisplayDefinition(monitor: .secondary), displays: [primary]) == nil)
        #expect(resolve(DisplayDefinition(id: secondary.id), displays: [primary]) == nil)
        #expect(resolve(DisplayDefinition(width: 2560, height: 1440), displays: [primary]) == nil)
    }

    // MARK: - Per-display activation

    @Test func bootstrapActivatesIndependentWorkspacesPerDisplay() async throws {
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.layoutName == "work")
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.layoutName == "calendar")
        #expect(state.activeWorkspaces.count == 2)
    }

    @Test func batchArrangeAppliesDistinctDisplayLayoutsInOneRequest() async throws {
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await engine.arrange(
            layoutNames: ["work", "calendar"],
            config: dualConfig
        )

        #expect(result.result == "success")
        #expect(result.layouts.map(\.layout) == ["work", "calendar"])
        #expect(result.exitCode == ErrorCode.success.rawValue)
        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.layoutName == "work")
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.layoutName == "calendar")
        #expect(control.focusedWindow()?.bundleID != Self.calendarBundleID)
    }

    @Test func batchArrangeRejectsSameDisplayLayoutsBeforeMutation() async throws {
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "focus": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: []),
            ]),
        ])
        let (engine, _, url) = makeEngine(windows: primaryWindows())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await #expect(throws: VirtualSpaceEngineError.invalidArrangeBatch(
            "layouts work and focus resolve to the same display uuid-main"
        )) {
            try await engine.arrange(layoutNames: ["work", "focus"], config: config)
        }
        #expect((await engine.currentState).activeWorkspaces.isEmpty)
    }

    @Test func declaredLayoutFailsWithoutItsDisplayInsteadOfFallingBackToPrimary() async throws {
        let (engine, _, url) = makeEngine(
            windows: primaryWindows() + [calendarWindow()],
            displays: [TestFixtures.display] // secondary absent
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        await #expect(throws: VirtualSpaceEngineError.hostDisplayUnavailable) {
            try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        }
        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main") == nil)
    }

    // MARK: - Non-interference

    @Test func primarySwitchNeverTouchesSecondaryWorkspaceWindows() async throws {
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        _ = try await engine.switchSpace(to: 2, config: dualConfig)

        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.spaceID == 2)
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.spaceID == 1)
        // The calendar window keeps its exact frame: no show/hide/park plan
        // may ever target another display's workspace.
        #expect(control.window(calendar.windowID)?.frame == calendar.frame)
        let calendarSlots = state.slots(layoutName: "calendar")
        #expect(calendarSlots.allSatisfy { $0.visibilityState == .visible })
    }

    @Test func secondaryReconcileKeepsPrimaryWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        let textEditFrame = control.window(1)?.frame

        _ = try await engine.switchSpace(layoutName: "calendar", to: 1, config: dualConfig, reconcile: true)

        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.layoutName == "work")
        #expect(state.activeWorkspace(displayID: "uuid-main")?.spaceID == 1)
        #expect(control.window(1)?.frame == textEditFrame)
    }

    @Test func secondarySwitchChangesOnlySecondaryWorkspace() async throws {
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "calendar": twoSpaceCalendarLayout(),
        ])
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: config)
        let primaryFrames = primaryWindows().reduce(into: [UInt32: ResolvedFrame]()) {
            $0[$1.windowID] = control.window($1.windowID)?.frame
        }

        _ = try await engine.switchSpace(
            layoutName: "calendar",
            to: 2,
            config: config
        )

        let state = await engine.currentState
        #expect(state.activeWorkspace(layoutName: "work")?.spaceID == 1)
        #expect(state.activeWorkspace(layoutName: "calendar")?.spaceID == 2)
        for (windowID, frame) in primaryFrames {
            #expect(control.window(windowID)?.frame == frame)
        }
        #expect(
            VisibilityPlanner.isHiddenWindowFrame(
                frame: try #require(control.window(5)?.frame),
                displays: control.displays()
            )
        )
    }

    @Test func layoutScopedQueriesAndSwitchTargetOnlyRequestedWorkspace() async throws {
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        let list = try await engine.spaceList(layoutName: "calendar", config: dualConfig)
        #expect(list.layoutName == "calendar")
        #expect(list.spaces.map(\.spaceID) == [1])
        #expect(list.spaces.first?.isActive == true)

        let current = try await engine.spaceCurrent(layoutName: "calendar", config: dualConfig)
        #expect(current.layoutName == "calendar")
        #expect(current.space?.spaceID == 1)

        _ = try await engine.switchSpace(
            layoutName: "calendar",
            to: 1,
            config: dualConfig,
            reconcile: true
        )
        let state = await engine.currentState
        #expect(state.activeWorkspace(layoutName: "work")?.spaceID == 1)
        #expect(state.activeWorkspace(layoutName: "calendar")?.spaceID == 1)
    }

    @Test func layoutScopedSwitchRejectsConfiguredButInactiveWorkspace() async throws {
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)

        await #expect(throws: VirtualSpaceEngineError.workspaceNotActive("calendar")) {
            try await engine.switchSpace(
                layoutName: "calendar",
                to: 1,
                config: dualConfig
            )
        }
    }

    // MARK: - Adoption scope

    @Test func strayWindowOnSecondaryDisplayStaysUnmanaged() async throws {
        let stray = TestFixtures.window(
            id: 9,
            bundleID: "com.example.Stray",
            isAXBacked: true,
            frontIndex: 4,
            displayID: "uuid-sub"
        )
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [calendarWindow(), stray])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        _ = try await engine.adoptUntrackedWindows(config: dualConfig)
        // Focus-driven adoption path shares the same display scope.
        let tracking = try await engine.trackWindow(
            windowID: stray.windowID,
            pid: stray.pid,
            processStartTime: stray.processStartTime,
            expectedBundleID: stray.bundleID,
            config: dualConfig,
            respectFocusIgnoreRules: true,
            updateMRU: false
        )

        #expect(tracking.didAdopt == false)
        let state = await engine.currentState
        #expect(!state.slots.contains { $0.bundleID == "com.example.Stray" })
    }

    @Test func windowMatchingOtherWorkspaceRuleIsNeverAdoptedAndArrangeReclaimsIt() async throws {
        // The calendar PWA opened on the primary display (e.g. during setup
        // or a disconnect): adoption must skip it, and arrange calendar must
        // still be able to claim it afterwards.
        let strandedCalendar = calendarWindow(displayID: "uuid-main")
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [strandedCalendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        _ = try await engine.adoptUntrackedWindows(config: dualConfig)
        var state = await engine.currentState
        #expect(!state.slots.contains { $0.origin == .adopted && $0.bundleID == Self.calendarBundleID })

        let result = try await engine.arrange(layoutName: "calendar", spaceID: nil, config: dualConfig)
        #expect(result.result == "success")
        state = await engine.currentState
        let calendarSlot = state.slots(layoutName: "calendar").first
        #expect(calendarSlot?.windowID == strandedCalendar.windowID)
    }

    @Test func arrangeReclaimsWindowAdoptedByAnotherWorkspace() async throws {
        // Even when a rule-matching window slipped into another workspace as
        // an adopted entry (pre-foundation state or an edge race), the layout
        // rule claim wins and the stale adopted entry is removed.
        let strandedCalendar = calendarWindow(displayID: "uuid-main")
        let (engine, _, url) = makeEngine(windows: primaryWindows() + [strandedCalendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        var seeded = await engine.currentState
        seeded.slots.append(SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 0,
            origin: .adopted,
            definitionFingerprint: "adopted\u{0}\(Self.calendarBundleID)\u{0}5",
            bundleID: Self.calendarBundleID,
            pid: strandedCalendar.pid,
            processStartTime: strandedCalendar.processStartTime,
            windowID: strandedCalendar.windowID,
            lastKnownTitle: strandedCalendar.title,
            displayID: "uuid-main",
            lastVisibleFrame: strandedCalendar.frame,
            visibilityState: .visible
        ))
        try await engine.replaceState(seeded)

        let result = try await engine.arrange(layoutName: "calendar", spaceID: nil, config: dualConfig)
        #expect(result.result == "success")

        let state = await engine.currentState
        #expect(state.slots(layoutName: "calendar").first?.windowID == strandedCalendar.windowID)
        #expect(!state.slots.contains {
            $0.layoutName == "work" && $0.origin == .adopted && $0.bundleID == Self.calendarBundleID
        })
    }

    // MARK: - Display affinity

    @Test func unboundWindowOnHostedDisplayIsNotClaimedByOtherWorkspace() async throws {
        // Partial matcher overlap: work also matches the calendar bundleID
        // (with a title discriminator). The unbound calendar window sits on a
        // display hosted by the calendar workspace, so the primary switch
        // must not pull it over.
        let overlapWork = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: Self.calendarBundleID, title: TitleMatcher(contains: "win")),
                    slot: 1,
                    launch: false,
                    frame: fullFrame()
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    launch: false,
                    frame: fullFrame()
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: [
            "work": overlapWork,
            "calendar": calendarLayout(),
        ])
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(
            windows: [TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true)] + [calendar]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: config)

        _ = try await engine.switchSpace(to: 1, config: config, reconcile: true)

        let state = await engine.currentState
        #expect(state.slots(layoutName: "work").allSatisfy { $0.windowID != calendar.windowID })
        #expect(control.window(calendar.windowID)?.frame == calendar.frame)
    }

    @Test func unboundWindowOnUnhostedDisplayRemainsClaimable() async throws {
        // A window on a display no workspace hosts (third display) keeps the
        // v2.0 pull-back behavior: the next switch claims and re-places it.
        let wanderer = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: 3000, y: 10, width: 700, height: 400),
            isAXBacked: true,
            displayID: "uuid-third"
        )
        let (engine, _, url) = makeEngine(
            windows: [wanderer] + [
                TestFixtures.window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
                TestFixtures.window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
                calendarWindow(),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        _ = try await engine.switchSpace(to: 1, config: dualConfig, reconcile: true)

        let state = await engine.currentState
        let textEditSlot = state.slots(layoutName: "work").first { $0.bundleID == "com.apple.TextEdit" }
        #expect(textEditSlot?.windowID == wanderer.windowID)
    }

    @Test func sameDisplayArrangeTakeoverInheritsBoundWindows() async throws {
        // Replacing the primary layout with another primary-hosted layout is
        // a takeover: the old layout's bound windows must stay claimable
        // while the other display's workspace stays excluded.
        let focusLayout = LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    launch: false,
                    frame: fullFrame()
                ),
            ]),
        ])
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "focus": focusLayout,
            "calendar": calendarLayout(),
        ])
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: config)
        // Bind TextEdit to the work layout before the takeover.
        _ = try await engine.switchSpace(layoutName: "work", to: 1, config: config, reconcile: true)
        let boundState = await engine.currentState
        try #require(boundState.slots(layoutName: "work").contains { $0.windowID == 1 })

        let result = try await engine.arrange(layoutName: "focus", spaceID: nil, config: config)
        #expect(result.result == "success")

        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.layoutName == "focus")
        #expect(state.slots(layoutName: "focus").first?.windowID == 1)
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.layoutName == "calendar")
        #expect(control.window(calendar.windowID)?.frame == calendar.frame)
    }

    @Test func arrangeReclaimsParkedAdoptedWindowIntoVisiblePosition() async throws {
        // The reclaim also works when the foreign adopted entry parked the
        // window offscreen: after arrange the window is visible at its
        // declared position and the recovery metadata is gone with the entry.
        let strandedCalendar = calendarWindow(displayID: "uuid-main")
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [strandedCalendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        let parkedFrame = ResolvedFrame(x: 1439, y: 874, width: 600, height: 500)
        _ = control.setWindowFrame(
            windowID: strandedCalendar.windowID,
            pid: strandedCalendar.pid,
            processStartTime: strandedCalendar.processStartTime,
            bundleID: strandedCalendar.bundleID,
            frame: parkedFrame
        )
        var seeded = await engine.currentState
        seeded.slots.append(SlotEntry(
            layoutName: "work",
            spaceID: 2,
            slot: 0,
            origin: .adopted,
            definitionFingerprint: "adopted\u{0}\(Self.calendarBundleID)\u{0}5",
            bundleID: Self.calendarBundleID,
            pid: strandedCalendar.pid,
            processStartTime: strandedCalendar.processStartTime,
            windowID: strandedCalendar.windowID,
            lastKnownTitle: strandedCalendar.title,
            displayID: "uuid-main",
            lastVisibleFrame: strandedCalendar.frame,
            lastHiddenFrame: parkedFrame,
            visibilityState: .hiddenOffscreen
        ))
        try await engine.replaceState(seeded)

        let result = try await engine.arrange(layoutName: "calendar", spaceID: nil, config: dualConfig)
        #expect(result.result == "success")

        let state = await engine.currentState
        let calendarSlot = state.slots(layoutName: "calendar").first
        #expect(calendarSlot?.windowID == strandedCalendar.windowID)
        #expect(calendarSlot?.visibilityState == .visible)
        #expect(!state.slots.contains {
            $0.layoutName == "work" && $0.origin == .adopted && $0.bundleID == Self.calendarBundleID
        })
        let frame = try #require(control.window(strandedCalendar.windowID)?.frame)
        #expect(frame != parkedFrame)
        // Placed by the calendar layout's 100% frame on its host display.
        #expect(frame.x >= TestFixtures.secondaryDisplay().visibleFrame.minX)
    }

    // MARK: - Follow focus ownership

    @Test func focusOnScopeExcludedStrayKeepsPerAppShortcutPolicy() async throws {
        // A stray window on the calendar-hosted display is excluded from the
        // primary workspace's scope, but it is physically in front of the
        // user: the outcome must report "present, unmanaged" (spaceID nil) —
        // not nil — so per-app shortcut disabling stays effective.
        let stray = TestFixtures.window(
            id: 9,
            bundleID: "com.example.Stray",
            isAXBacked: true,
            frontIndex: 4,
            displayID: "uuid-sub"
        )
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow(), stray])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        control.setFocusedWindowID(stray.windowID)
        let outcome = await engine.processFocusEvent(
            sequence: 1,
            windowID: stray.windowID,
            pid: stray.pid,
            processStartTime: stray.processStartTime,
            bundleID: stray.bundleID,
            config: dualConfig
        )

        let unwrapped = try #require(outcome)
        #expect(unwrapped.spaceID == nil)
        #expect(unwrapped.didAdopt == false)
        #expect(FollowFocusPolicy.frontmostBelongsToActiveWorkspace(
            targetSpaceID: unwrapped.spaceID,
            activeSpaceID: unwrapped.activeSpaceID
        ))
        let state = await engine.currentState
        #expect(!state.slots.contains { $0.bundleID == "com.example.Stray" })
    }

    @Test func focusEventOnOtherWorkspaceWindowReportsOwnerWorkspace() async throws {
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        // Bind the calendar window to its slot so ownership resolves exactly.
        _ = try await engine.switchSpace(layoutName: "calendar", to: 1, config: dualConfig, reconcile: true)

        control.setFocusedWindowID(calendar.windowID)
        let outcome = await engine.processFocusEvent(
            sequence: 1,
            windowID: calendar.windowID,
            pid: calendar.pid,
            processStartTime: calendar.processStartTime,
            bundleID: calendar.bundleID,
            config: dualConfig
        )

        #expect(outcome?.layoutName == "calendar")
        #expect(outcome?.spaceID == 1)
        #expect(outcome?.activeSpaceID == 1)
        #expect(outcome?.didAdopt == false)
        // The primary workspace is untouched by the focus event.
        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-main")?.spaceID == 1)
    }

    @Test func followFocusSwitchIsNoOpForDormantOwner() async throws {
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        control.setDisplays([TestFixtures.display]) // secondary disconnected

        control.setFocusedWindowID(calendar.windowID)
        await engine.invalidateFocusEvents(upTo: 0)
        _ = await engine.processFocusEvent(
            sequence: 1,
            windowID: calendar.windowID,
            pid: calendar.pid,
            processStartTime: calendar.processStartTime,
            bundleID: calendar.bundleID,
            config: dualConfig
        )
        let outcome = try await engine.switchSpaceForFocusEvent(
            sequence: 1,
            identity: calendar.identity,
            layoutName: "calendar",
            to: 1,
            config: dualConfig
        )
        #expect(outcome == nil)
    }

    // MARK: - Reference reporting

    @Test func spaceListReportsEveryWorkspaceIncludingDormantOnes() async throws {
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        control.setDisplays([TestFixtures.display]) // calendar goes dormant

        let list = await engine.spaceList(config: dualConfig)
        #expect(list.layoutName == "work")
        let byLayout = Dictionary(uniqueKeysWithValues: list.workspaces.map { ($0.layoutName, $0) })
        #expect(byLayout["work"]?.dormant == false)
        #expect(byLayout["calendar"]?.dormant == true)
        #expect(byLayout["calendar"]?.displayID == "uuid-sub")
    }

    // MARK: - Disconnect / reconnect

    @Test func primarySwitchDuringDisconnectKeepsDormantWorkspace() async throws {
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        control.setDisplays([TestFixtures.display])
        _ = try await engine.switchSpace(to: 2, config: dualConfig)

        // v2.0 pruned disconnected displays' records here, which silently
        // broke reconnect restore. The dormant record must survive switches.
        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.layoutName == "calendar")
    }

    @Test func reconnectRestoresDormantWorkspaceViaReResolutionEvenWithNewUUID() async throws {
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendarWindow()])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)

        control.setDisplays([TestFixtures.display])
        await engine.handleDisplayConfigurationChange(config: dualConfig)
        var state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-sub")?.layoutName == "calendar")

        // Reconnect with a CHANGED display UUID: UUID equality can never
        // restore this; declaration re-resolution must.
        control.setDisplays([TestFixtures.display, TestFixtures.secondaryDisplay(id: "uuid-sub-2")])
        await engine.handleDisplayConfigurationChange(config: dualConfig)

        state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-sub") == nil)
        #expect(state.activeWorkspace(displayID: "uuid-sub-2")?.layoutName == "calendar")
        #expect(state.activeWorkspace(displayID: "uuid-sub-2")?.spaceID == 1)
        #expect(state.activeWorkspace(displayID: "uuid-main")?.layoutName == "work")
    }

    @Test func reconnectRestorePriorityIsDeterministic() async throws {
        // Two dormant workspaces re-resolve to the same reconnected display:
        // the id declaration beats the monitor role, deterministically.
        let subA = TestFixtures.secondaryDisplay(id: "uuid-subA")
        let subB = TestFixtures.secondaryDisplay(id: "uuid-subB")
        let config = TestFixtures.loadedConfig(layouts: [
            "work": TestFixtures.twoSpaceLayout(),
            "calRole": calendarLayout(display: DisplayDefinition(monitor: .secondary)),
            "calPinned": LayoutDefinition(
                display: DisplayDefinition(id: "uuid-subB"),
                spaces: [
                    SpaceDefinition(spaceID: 1, windows: [
                        WindowDefinition(
                            match: WindowMatchRule(bundleID: "com.example.Pinned"),
                            slot: 1,
                            launch: false,
                            frame: fullFrame()
                        ),
                    ]),
                ]
            ),
        ])
        let pinnedWindow = TestFixtures.window(
            id: 7,
            bundleID: "com.example.Pinned",
            isAXBacked: true,
            frontIndex: 5,
            displayID: "uuid-subB"
        )
        let (engine, control, url) = makeEngine(
            windows: primaryWindows() + [calendarWindow(displayID: "uuid-subA"), pinnedWindow],
            displays: [TestFixtures.display, subA, subB]
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        try await engine.bootstrapState(layoutName: "calRole", activeSpaceID: 1, config: config)
        try await engine.bootstrapState(layoutName: "calPinned", activeSpaceID: 1, config: config)

        control.setDisplays([TestFixtures.display])
        await engine.handleDisplayConfigurationChange(config: config)

        // Only subB reconnects; both dormant declarations resolve to it.
        control.setDisplays([TestFixtures.display, subB])
        await engine.handleDisplayConfigurationChange(config: config)

        let state = await engine.currentState
        #expect(state.activeWorkspace(displayID: "uuid-subB")?.layoutName == "calPinned")
        // The role-declared workspace stays dormant on its old record.
        #expect(state.activeWorkspace(layoutName: "calRole")?.displayID == "uuid-subA")
    }

    // MARK: - Shutdown restore

    @Test func shutdownRestoresAllWorkspacesAndClampsDormantOntoPrimary() async throws {
        let calendar = calendarWindow()
        let (engine, control, url) = makeEngine(windows: primaryWindows() + [calendar])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: dualConfig)
        try await engine.bootstrapState(layoutName: "calendar", activeSpaceID: 1, config: dualConfig)
        _ = try await engine.switchSpace(layoutName: "calendar", to: 1, config: dualConfig, reconcile: true)

        // Park the calendar window offscreen (as a hidden multi-space
        // secondary layout would), then disconnect its display.
        var seeded = await engine.currentState
        seeded.slots = seeded.slots.map { entry in
            guard entry.layoutName == "calendar" else { return entry }
            var updated = entry
            updated.visibilityState = .hiddenOffscreen
            updated.lastVisibleFrame = ResolvedFrame(x: 1500, y: 20, width: 600, height: 500)
            updated.lastHiddenFrame = ResolvedFrame(x: 2800, y: 719, width: 600, height: 500)
            return updated
        }
        try await engine.replaceState(seeded)
        control.setDisplays([TestFixtures.display])

        let restored = await engine.restoreAllForShutdown(config: dualConfig)
        #expect(restored)

        let frame = try #require(control.window(calendar.windowID)?.frame)
        let visible = TestFixtures.display.visibleFrame
        #expect(frame.x >= visible.minX)
        #expect(frame.y >= visible.minY)
        #expect(frame.x + frame.width <= visible.maxX + 0.5)
        #expect(frame.y + frame.height <= visible.maxY + 0.5)
    }
}
