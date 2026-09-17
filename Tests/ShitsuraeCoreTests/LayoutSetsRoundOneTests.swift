import Foundation
import Testing
@testable import ShitsuraeCore

final class TestMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 10_000_000_000
    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(milliseconds: Int) { lock.lock(); value += UInt64(milliseconds) * 1_000_000; lock.unlock() }
}

final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func signal() { lock.lock(); value = true; lock.unlock() }
}

@Suite("Layout sets Round 1", .serialized)
struct LayoutSetsRoundOneTests {
    private func layout(_ bundle: String, secondary: Bool = false, title: TitleMatcher? = nil, second: Bool = false) -> LayoutDefinition {
        LayoutDefinition(display: secondary ? DisplayDefinition(id: "uuid-sub") : nil, spaces: [
            SpaceDefinition(spaceID: 1, windows: [WindowDefinition(match: WindowMatchRule(bundleID: bundle, title: title), slot: 1, launch: false,
                frame: TestFixtures.frameDef("0%", "0%", "100%", "100%"))]),
        ] + (second ? [SpaceDefinition(spaceID: 2, windows: [])] : []))
    }
    private func loaded() -> LoadedConfig {
        TestFixtures.loadedConfig(layouts: ["main": layout("Editor", second: true), "side": layout("Calendar", secondary: true)],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main", "side"])])
    }
    private func entry(_ window: WindowSnapshot, name: String, hidden: Bool = false, minimized: Bool = false) -> SlotEntry {
        var e = SlotEntry.makeEntry(layoutName: name, spaceID: 1,
            definition: WindowDefinition(match: WindowMatchRule(bundleID: window.bundleID), slot: 1, launch: false,
                frame: TestFixtures.frameDef("0%", "0%", "100%", "100%"))).bound(to: window)
        e.visibilityState = minimized ? .hiddenMinimized : hidden ? .hiddenOffscreen : .visible
        e.lastVisibleFrame = ResolvedFrame(x: 40, y: 50, width: 600, height: 400)
        e.lastHiddenFrame = hidden || minimized ? window.frame : nil
        return e
    }
    private func engine(_ windows: [WindowSnapshot], state: RuntimeState = RuntimeState(), displays: [DisplayInfo]? = nil,
        clock: TestMonotonicClock? = nil, coordinator suppliedCoordinator: ArrangeOperationCoordinator? = nil,
        checkpoint: @escaping @Sendable (LayoutTransitionCheckpoint) throws -> Void = { _ in }
    ) throws -> (VirtualSpaceEngine, MockWindowControl, RuntimeStateStore, URL) {
        let (store, url) = TestFixtures.tempStateStore()
        try store.saveStrict(state: state)
        let control = MockWindowControl(windows: windows, displays: displays ?? [TestFixtures.display, TestFixtures.secondaryDisplay()])
        let coordinator = suppliedCoordinator ?? ArrangeOperationCoordinator(uptimeNanoseconds: { clock?.now ?? DispatchTime.now().uptimeNanoseconds })
        return (try VirtualSpaceEngine(store: store, control: control, logger: TestFixtures.nullLogger(), retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10, operationCoordinator: coordinator, transitionCheckpoint: checkpoint), control, store, url)
    }
    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    @Test func sameSetKeepsAdoptedAndItsSpaceWithoutReleasingIt() async throws {
        let editor = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let calendar = TestFixtures.window(id: 2, bundleID: "Calendar", isAXBacked: true, displayID: "uuid-sub")
        let extra = TestFixtures.window(id: 3, bundleID: "Extra", isAXBacked: true)
        let (e, _, _, url) = try engine([editor, calendar, extra]); defer { remove(url) }
        _ = try await e.arrangeSet(setName: "home", requestID: "first", config: loaded())
        _ = try await e.moveWindowToWorkspace(window: extra, toSpaceID: 2, config: loaded())
        let old = try #require(await e.currentState.slots.first { $0.boundIdentity == extra.identity })
        #expect(old.origin == .adopted)
        _ = try await e.arrangeSet(setName: "home", requestID: "again", config: loaded())
        let state = await e.currentState
        let kept = try #require(state.slots.first { $0.boundIdentity == extra.identity })
        #expect(kept.id == old.id && kept.spaceID == 2 && kept.origin == .adopted)
        #expect(!state.releasedWindowIdentities.contains(extra.identity))
        let replacement = TestFixtures.loadedConfig(layouts: ["main": layout("Editor", second: true), "side": layout("Calendar", secondary: true),
            "laptop": layout("Editor")], layoutSets: ["home": LayoutSetDefinition(layouts: ["main", "side"]),
            "mobile": LayoutSetDefinition(layouts: ["laptop"])])
        _ = try await e.arrangeSet(setName: "mobile", requestID: "retire", config: replacement)
        let retired = await e.currentState
        #expect(!retired.slots.contains { $0.boundIdentity == extra.identity })
        #expect(retired.releasedWindowIdentities.contains(extra.identity))
        #expect(retired.activeWorkspaces.map(\.layoutName) == ["laptop"])
    }

    @Test func normalQuitWithoutConfigPreservesOnlyPriorReleasedAndSecondaryPosition() async throws {
        let hidden = TestFixtures.window(id: 1, bundleID: "Hidden", frame: ResolvedFrame(x: 4000, y: 50, width: 600, height: 400), isAXBacked: true)
        let visible = TestFixtures.window(id: 2, bundleID: "Visible", frame: ResolvedFrame(x: 1600, y: 50, width: 600, height: 400), isAXBacked: true, displayID: "uuid-sub")
        let prior = TestFixtures.window(id: 3, bundleID: "Prior", isAXBacked: true)
        let state = RuntimeState(releasedWindowIdentities: [prior.identity], activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "gone", spaceID: 1)],
            slots: [entry(hidden, name: "gone", hidden: true), entry(visible, name: "gone")])
        let (e, c, store, url) = try engine([hidden, visible, prior], state: state); defer { remove(url) }
        let result = try await e.shutdownManagedWindows(requestID: "quit")
        #expect(result.result == "success" && result.releasedCount == 0)
        #expect(c.setFrameAttemptWindowIDs == [hidden.windowID])
        #expect(c.window(2)?.frame == visible.frame)
        let restarted = try VirtualSpaceEngine(store: store, control: c, logger: TestFixtures.nullLogger())
        let after = await restarted.currentState
        #expect(after.slots.isEmpty && after.activeWorkspaces.isEmpty)
        #expect(after.releasedWindowIdentities == [prior.identity])
    }

    @Test(arguments: [false, true])
    func normalQuitFailurePreservesRecoverableStateAcrossRestart(inventoryUnavailable: Bool) async throws {
        let hidden = TestFixtures.window(id: 1, bundleID: "Hidden", frame: ResolvedFrame(x: 4000, y: 50, width: 600, height: 400), isAXBacked: true)
        let prior = TestFixtures.window(id: 3, bundleID: "Prior", isAXBacked: true)
        let initial = RuntimeState(releasedWindowIdentities: [prior.identity],
            activeWorkspaces: [ActiveWorkspace(displayID: "old", layoutName: "gone", spaceID: 1)], slots: [entry(hidden, name: "gone", hidden: true)])
        let (e, c, store, url) = try engine([hidden, prior], state: initial); defer { remove(url) }
        if inventoryUnavailable { c.windowInventoryAvailable = false }
        else { c.failFrameWindowIDs = [hidden.windowID] }
        let result = try await e.shutdownManagedWindows(requestID: "quit-failed")
        #expect(result.result == "partial" && result.recoveryRequired && result.exitCode == 51)
        let restarted = try VirtualSpaceEngine(store: store, control: c, logger: TestFixtures.nullLogger())
        let saved = await restarted.currentState
        #expect(saved.slots[0].visibilityState == .hiddenOffscreen && saved.activeWorkspaces.count == 1)
        #expect(saved.releasedWindowIdentities == [prior.identity])
        c.windowInventoryAvailable = true
        c.failFrameWindowIDs = []
        #expect(try await restarted.shutdownManagedWindows(requestID: "quit-retry").result == "success")
    }

    @Test func recoveryDeduplicatesExactBindingsAndPreservesUserMinimized() async throws {
        let hidden = TestFixtures.window(id: 1, bundleID: "Hidden", frame: ResolvedFrame(x: 4000, y: 30, width: 500, height: 400), isAXBacked: true)
        let userMin = TestFixtures.window(id: 2, bundleID: "Min", isAXBacked: true, minimized: true)
        var duplicate = entry(hidden, name: "gone", hidden: true); duplicate.id = "duplicate"
        let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "old", layoutName: "gone", spaceID: 1)],
            slots: [entry(hidden, name: "gone", hidden: true), duplicate, entry(userMin, name: "gone")])
        let (e, c, _, url) = try engine([hidden, userMin], state: initial); defer { remove(url) }
        let result = try await e.recoverLayoutTransition(requestID: "rescue")
        #expect(result.result == "success" && result.releasedCount == 2)
        #expect(c.setFrameAttemptWindowIDs == [1])
        #expect(c.minimizeAttempts.isEmpty && c.window(2)?.minimized == true)
    }

    @Test func recoveryDoesNotFinalizeAcceptedButUnverifiedGeometry() async throws {
        let w = TestFixtures.window(id: 1, bundleID: "Hidden", frame: ResolvedFrame(x: 4000, y: 30, width: 500, height: 400), isAXBacked: true)
        let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "old", layoutName: "gone", spaceID: 1)], slots: [entry(w, name: "gone", hidden: true)])
        let (e, c, _, url) = try engine([w], state: initial); defer { remove(url) }
        c.acceptedButPinnedFrameWindowIDs = [w.windowID: w.frame]
        let result = try await e.recoverLayoutTransition(requestID: "rescue")
        #expect(result.recoveryRequired && result.exitCode == 51)
        #expect(await e.currentState.slots.count == 1)
        #expect(await e.currentState.releasedWindowIdentities.isEmpty)
    }

    @Test func deadlineAfterUnminimizeDoesNotStartFrameOrSave() async throws {
        let clock = TestMonotonicClock()
        let w = TestFixtures.window(id: 1, bundleID: "Hidden", isAXBacked: true, minimized: true)
        let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "old", layoutName: "gone", spaceID: 1)], slots: [entry(w, name: "gone", minimized: true)])
        let (e, c, store, url) = try engine([w], state: initial, clock: clock); defer { remove(url) }
        let revision = try store.loadStrict().revision
        c.onMinimizeAttempt = { clock.advance(milliseconds: 61_000) }
        let result = try await e.recoverLayoutTransition(requestID: "deadline")
        #expect(result.exitCode == 50 && result.recoveryRequired)
        #expect(c.setFrameAttemptWindowIDs.isEmpty)
        #expect(try store.loadStrict().revision == revision)
        #expect(try store.loadStrict().slots[0].visibilityState == .hiddenMinimized)
    }

    @Test func physicalPlacementFailureKeepsJournalButMissingOnlyClosesIt() async throws {
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let config = TestFixtures.loadedConfig(layouts: ["main": layout("Editor")], layoutSets: ["one": LayoutSetDefinition(layouts: ["main"])])
        let (e, c, _, url) = try engine([w]); defer { remove(url) }
        c.failFrameWindowIDs = [1]
        let result = try await e.arrangeSet(setName: "one", requestID: "fail", config: config)
        #expect(result.exitCode == 51 && result.recoveryRequired)
        #expect(await e.currentState.pendingLayoutTransition != nil)
        let (missing, _, _, missingURL) = try engine([]); defer { remove(missingURL) }
        let absent = try await missing.arrangeSet(setName: "one", requestID: "missing", config: config)
        #expect(absent.exitCode == 51 && !absent.recoveryRequired && absent.ownershipCommitted)
        #expect(await missing.currentState.pendingLayoutTransition == nil)
    }

    @Test func singletonReleasedIsExcludedFromAutomaticRuleRebindAndExplicitClaimWorks() async throws {
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let closed = TestFixtures.window(id: 8, bundleID: "Editor", isAXBacked: true)
        let config = TestFixtures.loadedConfig(layouts: ["main": layout("Editor", second: true)])
        let initial = RuntimeState(releasedWindowIdentities: [w.identity], activeWorkspaces: [ActiveWorkspace(displayID: TestFixtures.display.id, layoutName: "main", spaceID: 1,
            appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "main", config: config.config))],
            slots: [SlotEntry.makeEntry(layoutName: "main", spaceID: 1, definition: config.config.layouts["main"]!.spaces[0].windows[0]).bound(to: closed)])
        let (e, c, _, url) = try engine([w], state: initial); defer { remove(url) }
        // AX omission is not proof of CG disappearance: retain A's exact
        // reservation while excluding released B from any rule fallback.
        c.liveWindowHandlesOverride = [closed.handle, w.handle]
        await #expect(throws: VirtualSpaceEngineError.self) { _ = try await e.switchSpace(to: 2, config: config) }
        #expect(await e.currentState.slots[0].boundIdentity == closed.identity)
        c.liveWindowHandlesOverride = [w.handle]
        _ = try await e.switchSpace(to: 2, config: config)
        _ = try await e.switchSpace(to: 1, config: config)
        #expect(try await e.cycleCandidates(config: config).isEmpty)
        #expect(await e.currentState.slots.allSatisfy { $0.boundIdentity != w.identity })
        let claim = try await e.arrange(layoutName: "main", spaceID: 1, config: config)
        #expect(claim.exitCode == 0)
        #expect(await e.currentState.slots.contains { $0.boundIdentity == w.identity })
        #expect(await e.currentState.releasedWindowIdentities.isEmpty)
    }

    @Test func mirrorNilCannotBypassAuthoritativeJournal() async throws {
        let (e, c, _, url) = try engine([]); defer { remove(url) }
        var state = await e.currentState
        state.pendingLayoutTransition = PendingLayoutTransition(requestID: "old", scopeKind: .local, phase: .precommit,
            sourceLayoutNames: [], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil, definitionDigest: "d", topologyDigest: "t")
        await e.replaceStateInMemory(state)
        e.operationCoordinator.updateJournalMirror(state: RuntimeState())
        await #expect(throws: ShitsuraeError.self) { _ = try await e.arrange(layoutName: "main", spaceID: nil, config: loaded()) }
        #expect(e.operationCoordinator.status().pendingTransition?.requestID == "old")
        #expect(c.frameMutationAttemptWindowIDs.isEmpty && c.launchedRequests.isEmpty)
    }

    @Test func staleNonNilMirrorIsRepairedFromAuthoritativeState() async throws {
        let (e, _, _, url) = try engine([]); defer { remove(url) }
        var incorrect = RuntimeState()
        incorrect.revision = 999
        incorrect.pendingLayoutTransition = PendingLayoutTransition(requestID: "not-real", scopeKind: .local, phase: .precommit,
            sourceLayoutNames: [], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil, definitionDigest: "d", topologyDigest: "t")
        e.operationCoordinator.updateJournalMirror(state: incorrect)
        _ = try await e.arrangeStateOnly(layoutName: "main", spaceID: 1, config: loaded())
        #expect(e.operationCoordinator.status().pendingTransition == nil)
        #expect(e.operationCoordinator.status().stateRevision == (await e.currentState).revision)
    }

    @Test func singleReleaseDeadlineKeepsPrecommitJournalAndStartsNoFrame() async throws {
        let clock = TestMonotonicClock()
        let hidden = TestFixtures.window(id: 9, bundleID: "Old", isAXBacked: true, minimized: true)
        let target = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: TestFixtures.display.id, layoutName: "old", spaceID: 1)],
            slots: [entry(hidden, name: "old", minimized: true)])
        let (e, c, store, url) = try engine([hidden, target], state: initial, clock: clock); defer { remove(url) }
        c.onMinimizeAttempt = { clock.advance(milliseconds: 61_000) }
        let result = try await e.arrange(layoutName: "main", spaceID: nil, config: loaded())
        #expect(result.exitCode == 50)
        #expect(c.setFrameAttemptWindowIDs.isEmpty)
        #expect(try store.loadStrict().pendingLayoutTransition?.phase == .precommit)
        #expect(try store.loadStrict().slots[0].visibilityState == .hiddenMinimized)
    }

    @Test func bootstrapAndDryRunRejectRetainedIdenticalMatcherWithoutWindows() async throws {
        let main = layout("Editor"), side = layout("Editor", secondary: true)
        let cfg = TestFixtures.loadedConfig(layouts: ["main": main, "side": side])
        let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)],
            slots: [SlotEntry.makeEntry(layoutName: "side", spaceID: 1, definition: side.spaces[0].windows[0])])
        let (e, c, store, url) = try engine([], state: initial); defer { remove(url) }
        let before = try store.loadStrict()
        for bootstrap in [false, true] {
            do {
                if bootstrap { try await e.bootstrapState(layoutName: "main", activeSpaceID: 1, config: cfg) }
                else { _ = try await e.arrangeDryRun(layoutName: "main", spaceID: nil, config: cfg) }
                Issue.record("retained matcher accepted")
            } catch let error as ShitsuraeError { #expect(error.subcode == "candidateConflict") }
        }
        #expect(try store.loadStrict() == before)
        #expect(c.frameMutationAttemptWindowIDs.isEmpty && c.launchedRequests.isEmpty && c.focusedWindowIDs.isEmpty)
    }

    @Test func deadlineAfterInventoryCannotPruneOrAdoptEvenWithoutPersistence() async throws {
        let clock = TestMonotonicClock()
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let extra = TestFixtures.window(id: 2, bundleID: "Extra", isAXBacked: true)
        let gone = TestFixtures.window(id: 3, bundleID: "Gone", isAXBacked: true)
        let cfg = TestFixtures.loadedConfig(layouts: ["main": layout("Editor")])
        let initial = RuntimeState(releasedWindowIdentities: [gone.identity],
            activeWorkspaces: [ActiveWorkspace(displayID: TestFixtures.display.id, layoutName: "main", spaceID: 1,
                appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "main", config: cfg.config))], slots: [entry(w, name: "main")])
        let (e, c, _, url) = try engine([w, extra], state: initial, clock: clock); defer { remove(url) }
        let before = await e.currentState
        c.onInventoryRead = { clock.advance(milliseconds: 61_000) }
        do { _ = try await e.adoptUntrackedWindows(config: cfg, persistChanges: false); Issue.record("late adoption succeeded") }
        catch let error as ShitsuraeError { #expect(error.code.rawValue == 50) }
        #expect(await e.currentState == before)
        #expect(e.operationCoordinator.status().lastOutcome?.exitCode == 50)
    }

    @Test func directMutationFacadesRejectBusyWithoutActorQueue() async throws {
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let cfg = TestFixtures.loadedConfig(layouts: ["main": layout("Editor")], layoutSets: ["one": LayoutSetDefinition(layouts: ["main"])])
        let (e, c, _, url) = try engine([w]); defer { remove(url) }
        let entered = TestSignal(), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        c.onFrameMutationAttempt = { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        let active = Task { try await e.arrangeSet(setName: "one", requestID: "active", config: cfg) }
        for _ in 0..<200 { if entered.isSet { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(entered.isSet)
        #expect(e.operationCoordinator.status().active?.inFlight == true)
        let calls: [@Sendable () async throws -> Void] = [
            { _ = try await e.arrange(layoutName: "main", spaceID: nil, config: cfg) },
            { _ = try await e.arrangeDryRun(layoutName: "main", spaceID: nil, config: cfg) },
            { _ = try await e.arrangeStateOnly(layoutName: "main", spaceID: nil, config: cfg) },
            { _ = try await e.arrange(layoutNames: ["main"], config: cfg) },
            { _ = try await e.arrangeSet(setName: "one", requestID: "second-set", config: cfg) },
            { _ = try await e.switchSpace(to: 1, config: cfg) },
            { _ = try await e.switchSpace(layoutName: "main", to: 1, config: cfg) },
            { _ = try await e.switchSpace(monitor: "main", to: 1, config: cfg) },
            { _ = try await e.focusSlot(1, config: cfg) },
            { _ = try await e.focusWindow(identity: w.identity, config: cfg) },
            { _ = try await e.focusWindow(selector: WindowTargetSelector(), config: cfg) },
            { _ = try await e.focusPreferredWindowInActiveWorkspace(excludingPID: 123, bundleID: "Other", config: cfg) },
            { _ = try await e.setWindowFrame(selector: WindowTargetSelector(), x: nil, y: nil, width: nil, height: nil, config: cfg) },
            { _ = try await e.adoptUntrackedWindows(config: cfg) },
            { _ = try await e.adoptWindowIntoActiveWorkspace(w, config: cfg) },
            { _ = try await e.cycleCandidates(config: cfg) },
            { _ = try await e.cycleCandidates(displayID: TestFixtures.display.id, config: cfg) },
            { _ = try await e.switcherCandidates(includeAllSpaces: true, config: cfg) },
            { _ = try await e.switcherCandidates(displayID: TestFixtures.display.id, includeAllSpaces: true, config: cfg) },
            { _ = try await e.routeAndSwitchSpace(candidates: [], cursorLocation: .zero, config: cfg) },
            { _ = try await e.snapWindow(selector: WindowTargetSelector(), preset: .leftHalf, config: cfg) },
            { _ = try await e.windowWorkspace(selector: WindowTargetSelector(), toSpaceID: 1, config: cfg) },
            { _ = try await e.moveWindowToWorkspace(window: w, toSpaceID: 1, config: cfg) },
            { try await e.bootstrapState(layoutName: "main", activeSpaceID: 1, config: cfg) },
            { try await e.clearPending() },
            { try await e.clearRuntimeState() },
            { _ = try await e.arrangeSetDryRun(setName: "one", requestID: "dry", config: cfg) },
            { _ = try await e.switchSpaceForFocusEvent(sequence: 999, identity: w.identity, layoutName: "main", to: 1, config: cfg) },
            { try await e.handleDisplayConfigurationChange(config: cfg) },
            { _ = try await e.recoverLayoutTransition(requestID: "rescue") },
            { _ = try await e.shutdownManagedWindows(requestID: "quit") },
        ]
        let started = DispatchTime.now().uptimeNanoseconds
        for call in calls {
            do { try await call(); Issue.record("busy call completed") }
            catch let error as ShitsuraeError { #expect(error.code == .operationBusy) }
        }
        await e.markActivated(window: w)
        #expect(await e.restoreAllForShutdown(config: cfg) == false)
        #expect(await e.processFocusEvent(sequence: 999, windowID: w.windowID, pid: w.pid, processStartTime: w.processStartTime, bundleID: w.bundleID, config: cfg) == nil)
        #expect(DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000)
        #expect(c.frameMutationAttemptWindowIDs.count == 1)
        release.signal()
        _ = try await active.value
    }

    @Test func dirtyScopeIsLocalAndLocalReapplyClearsAggregateRegardlessOfMemberOrder() async throws {
        let editor = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let calendar = TestFixtures.window(id: 2, bundleID: "Calendar", isAXBacked: true, displayID: "uuid-sub")
        let (e, _, _, url) = try engine([editor, calendar]); defer { remove(url) }
        _ = try await e.arrangeSet(setName: "home", requestID: "first", config: loaded())
        let main = LayoutDefinition(spaces: [SpaceDefinition(spaceID: 1, windows: [WindowDefinition(match: WindowMatchRule(bundleID: "Editor"), slot: 1, launch: false,
            frame: TestFixtures.frameDef("0%", "0%", "50%", "100%"))]), SpaceDefinition(spaceID: 2, windows: [])])
        let changed = TestFixtures.loadedConfig(layouts: ["main": main, "side": layout("Calendar", secondary: true)], layoutSets: ["home": LayoutSetDefinition(layouts: ["side", "main"])])
        let before = await e.currentState
        #expect(!before.selectedSetNeedsReapply(config: changed.config))
        #expect(before.needsReapply(layoutName: "main", config: changed.config))
        #expect(!before.needsReapply(layoutName: "side", config: changed.config))
        _ = try await e.switchSpace(layoutName: "side", to: 1, config: changed, reconcile: true)
        _ = try await e.arrange(layoutName: "main", spaceID: nil, config: changed)
        let after = await e.currentState
        #expect(after.selectedLayoutSet?.name == "home")
        #expect(!after.anySelectedSetScopeNeedsReapply(config: changed.config))
        #expect(after.selectedLayoutSet?.definitionDigest == ConfigDigest.layoutSet(name: "home", config: changed.config))
    }

    @Test func manualEffectiveScopeRejectsMatcherAndReportsDormantOwner() async throws {
        let w = TestFixtures.window(id: 1, bundleID: "Editor", title: "Document", isAXBacked: true)
        let broad = layout("Editor")
        let exact = layout("Editor", secondary: true, title: TitleMatcher(equals: "Document"))
        let cfg = TestFixtures.loadedConfig(layouts: ["main": broad, "side": exact])
        var bound = SlotEntry.makeEntry(layoutName: "side", spaceID: 1, definition: exact.spaces[0].windows[0]).bound(to: w)
        bound.displayID = "uuid-sub"
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)], slots: [bound])
        let (e, c, store, url) = try engine([w], state: state, displays: [TestFixtures.display]); defer { remove(url) }
        let revision = try store.loadStrict().revision
        do { _ = try await e.arrange(layoutName: "main", spaceID: nil, config: cfg); Issue.record("owned claim accepted") }
        catch let error as ShitsuraeError {
            #expect(error.subcode == "windowOwnedByOtherLayout")
            #expect(error.message.contains("side") && error.message.contains("dormant=true"))
        }
        #expect(c.frameMutationAttemptWindowIDs.isEmpty && c.launchedRequests.isEmpty)
        #expect(try store.loadStrict().revision == revision)
    }

    @Test func allSixNamedCrashPhasesRecoverFromPersistedState() async throws {
        for point in LayoutTransitionCheckpoint.allCases {
            let source = TestFixtures.window(id: 9, bundleID: "Old", frame: ResolvedFrame(x: 4000, y: 30, width: 500, height: 400), isAXBacked: true)
            let a = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
            let b = TestFixtures.window(id: 2, bundleID: "Second", isAXBacked: true)
            let target = LayoutDefinition(spaces: layout("Editor").spaces + [SpaceDefinition(spaceID: 2, windows: [WindowDefinition(match: WindowMatchRule(bundleID: "Second"), slot: 1, launch: false,
                frame: TestFixtures.frameDef("0%", "0%", "100%", "100%"))])])
            let cfg = TestFixtures.loadedConfig(layouts: ["target": target], layoutSets: ["one": LayoutSetDefinition(layouts: ["target"])])
            let initial = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "old", layoutName: "gone", spaceID: 1)], slots: [entry(source, name: "gone", hidden: true)])
            let (e, c, store, url) = try engine([source, a, b], state: initial, displays: [TestFixtures.display], checkpoint: {
                if $0 == point { throw LayoutTransitionCheckpointFailure(point: point) }
            }); defer { remove(url) }
            do { _ = try await e.arrangeSet(setName: "one", requestID: point.rawValue, config: cfg); Issue.record("checkpoint not reached: \(point)") }
            catch let failure as LayoutTransitionCheckpointFailure { #expect(failure.point == point) }
            let saved = try store.loadStrict()
            #expect(saved.pendingLayoutTransition != nil)
            let ids = saved.slots.compactMap(\.boundIdentity)
            #expect(ids.count == Set(ids).count)
            let restarted = try VirtualSpaceEngine(store: store, control: c, logger: TestFixtures.nullLogger(), retryDelaysMS: [1])
            let result = try await restarted.recoverLayoutTransition(requestID: "recover-\(point.rawValue)")
            #expect(result.result == "success")
            let recovered = await restarted.currentState
            #expect(recovered.slots.isEmpty && recovered.pendingLayoutTransition == nil)
            for window in c.currentWindows() {
                #expect(window.minimized == false)
                #expect(TestFixtures.display.visibleFrame.intersects(window.frame.cgRect))
            }
        }
    }

    @Test func precommitGenerationInvalidationHasOwnReasonAndCanCloseSafeJournal() async throws {
        let coordinator = ArrangeOperationCoordinator()
        let cfg = TestFixtures.loadedConfig(layouts: ["target": layout("Editor")], layoutSets: ["one": LayoutSetDefinition(layouts: ["target"])])
        let (e, c, _, url) = try engine([], coordinator: coordinator, checkpoint: { point in
            if point == .launchWaitFinished { coordinator.invalidateCurrent(reason: .configurationChanged) }
        }); defer { remove(url) }
        let result = try await e.arrangeSet(setName: "one", requestID: "invalidated", config: cfg)
        #expect(result.exitCode == 54 && !result.recoveryRequired)
        #expect(result.warnings.contains { $0.detail.contains("configurationChanged") })
        #expect(await e.currentState.pendingLayoutTransition == nil)
        #expect(c.frameMutationAttemptWindowIDs.isEmpty)
        #expect(coordinator.status().lastOutcome?.detail?.contains("configurationChanged") == true)
    }

    @Test func axReadAndWriteTimeoutsShrinkAndExpiredBudgetDispatchesNothing() {
        let clock = TestMonotonicClock()
        let coordinator = ArrangeOperationCoordinator(uptimeNanoseconds: { clock.now })
        let token = try! coordinator.tryAdmit(requestID: "ax", operation: .arrange, budgetMS: 100)
        let budget = coordinator.currentInteractionBudget()
        #expect(AXReadPolicy.timeoutSeconds(budget: budget) == 0.1)
        #expect(AXWritePolicy.timeoutSeconds(budget: budget) == 0.1)
        clock.advance(milliseconds: 75)
        #expect(AXReadPolicy.timeoutSeconds(budget: budget) == 0.025)
        #expect(AXWritePolicy.timeoutSeconds(budget: budget) == 0.025)
        clock.advance(milliseconds: 25)
        #expect(AXReadPolicy.timeoutSeconds(budget: budget) == nil)
        #expect(AXWritePolicy.timeoutSeconds(budget: budget) == nil)
        coordinator.abandon(token: token)
    }

    @Test func postcommitDeadlineNeverStartsFinalSave() async throws {
        let clock = TestMonotonicClock()
        let cfg = TestFixtures.loadedConfig(layouts: ["target": layout("Editor")], layoutSets: ["one": LayoutSetDefinition(layouts: ["target"])])
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let (e, _, store, url) = try engine([w], clock: clock, checkpoint: { if $0 == .finalSave { clock.advance(milliseconds: 61_000) } }); defer { remove(url) }
        do { _ = try await e.arrangeSet(setName: "one", requestID: "deadline", config: cfg); Issue.record("finalize unexpectedly succeeded") }
        catch let error as ShitsuraeError { #expect(error.code == .operationTimedOut) }
        #expect(try store.loadStrict().pendingLayoutTransition?.phase == .postcommit)
        #expect(e.operationCoordinator.status().lastOutcome?.exitCode == 50)
        #expect(e.operationCoordinator.status().lastOutcome?.recoveryRequired == true)
    }

    @Test func focusOnlyFailureClosesJournalButFocusDeadlineKeepsIt() async throws {
        let clock = TestMonotonicClock()
        let target = LayoutDefinition(initialFocus: InitialFocusDefinition(slot: 1), spaces: layout("Editor").spaces)
        let cfg = TestFixtures.loadedConfig(layouts: ["target": target], layoutSets: ["one": LayoutSetDefinition(layouts: ["target"])])
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let (e, c, _, url) = try engine([w]); defer { remove(url) }
        c.failFocusWindowIDs = [1]
        let focusFailure = try await e.arrangeSet(setName: "one", requestID: "focus-fail", config: cfg)
        #expect(focusFailure.exitCode == 51 && !focusFailure.recoveryRequired)
        #expect(await e.currentState.pendingLayoutTransition == nil)
        let (deadline, d, _, deadlineURL) = try engine([w], clock: clock); defer { remove(deadlineURL) }
        d.onFocusAttempt = { clock.advance(milliseconds: 61_000) }
        let timedOut = try await deadline.arrangeSet(setName: "one", requestID: "focus-deadline", config: cfg)
        #expect(timedOut.exitCode == 50 && timedOut.recoveryRequired)
        #expect(await deadline.currentState.pendingLayoutTransition != nil)
        #expect(d.activatedBundles.isEmpty)
    }

    @Test func singleArrangePhysicalFailureKeepsLocalJournal() async throws {
        let cfg = TestFixtures.loadedConfig(layouts: ["target": layout("Editor")])
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let (e, c, _, url) = try engine([w]); defer { remove(url) }
        c.failFrameWindowIDs = [1]
        let result = try await e.arrange(layoutName: "target", spaceID: 1, config: cfg)
        #expect(result.exitCode != 0)
        #expect(await e.currentState.pendingLayoutTransition?.scopeKind == .local)
    }

    @Test func failedExplicitWorkspaceClaimKeepsReleasedExclusion() async throws {
        let cfg = TestFixtures.loadedConfig(layouts: ["target": layout("Editor", second: true)])
        let w = TestFixtures.window(id: 1, bundleID: "Extra", isAXBacked: true)
        let state = RuntimeState(releasedWindowIdentities: [w.identity], activeWorkspaces: [ActiveWorkspace(displayID: TestFixtures.display.id, layoutName: "target", spaceID: 1,
            appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "target", config: cfg.config))])
        let (e, c, _, url) = try engine([w], state: state); defer { remove(url) }
        c.pinnedFrameWindowIDs = [1: w.frame]
        await #expect(throws: VirtualSpaceEngineError.self) { _ = try await e.windowWorkspace(selector: WindowTargetSelector(), toSpaceID: 2, config: cfg) }
        #expect(await e.currentState.releasedWindowIdentities.contains(w.identity))
    }

    @Test func dirtyScopeDoesNotAdoptOrRebindAutomatically() async throws {
        let cfg = TestFixtures.loadedConfig(layouts: ["target": layout("Editor", second: true)])
        let w = TestFixtures.window(id: 1, bundleID: "Editor", isAXBacked: true)
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: TestFixtures.display.id, layoutName: "target", spaceID: 1, appliedDefinitionDigest: "old")],
            slots: [SlotEntry.makeEntry(layoutName: "target", spaceID: 1, definition: cfg.config.layouts["target"]!.spaces[0].windows[0])])
        let (e, _, _, url) = try engine([w], state: state); defer { remove(url) }
        #expect(try await e.cycleCandidates(config: cfg).isEmpty)
        #expect(try await e.adoptWindowIntoActiveWorkspace(w, config: cfg) == false)
        #expect(await e.currentState.slots.allSatisfy { $0.boundIdentity == nil })
    }
}
