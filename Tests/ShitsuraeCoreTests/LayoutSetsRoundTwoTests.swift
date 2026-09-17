import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Layout sets Round 2", .serialized)
struct LayoutSetsRoundTwoTests {
    private func layout(_ rule: WindowMatchRule? = nil, secondary: Bool = false, spaces: [Int] = [1]) -> LayoutDefinition {
        LayoutDefinition(display: secondary ? DisplayDefinition(id: "uuid-sub") : nil,
            spaces: spaces.map { id in SpaceDefinition(spaceID: id, windows: id == 1 ? rule.map {
                [WindowDefinition(match: $0, slot: 1, launch: false, frame: TestFixtures.frameDef("0%", "0%", "100%", "100%"))]
            } ?? [] : []) })
    }
    private func engine(_ windows: [WindowSnapshot], state: RuntimeState, displays: [DisplayInfo]? = nil
    ) throws -> (VirtualSpaceEngine, MockWindowControl, RuntimeStateStore, URL) {
        let (store, url) = TestFixtures.tempStateStore()
        try store.saveStrict(state: state)
        let control = MockWindowControl(windows: windows, displays: displays ?? [TestFixtures.display, TestFixtures.secondaryDisplay()])
        return (try VirtualSpaceEngine(store: store, control: control, logger: TestFixtures.nullLogger(), retryDelaysMS: [1],
            arrangeWaitTimeoutMS: 10, operationCoordinator: ArrangeOperationCoordinator()), control, store, url)
    }
    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    private func entry(_ window: WindowSnapshot, name: String, adopted: Bool = false, space: Int = 1, hidden: Bool = false,
        rule: WindowMatchRule? = nil
    ) -> SlotEntry {
        var entry = SlotEntry.makeEntry(layoutName: name, spaceID: space,
            definition: WindowDefinition(match: rule ?? WindowMatchRule(bundleID: window.bundleID), slot: 1, launch: false)).bound(to: window)
        entry.origin = adopted ? .adopted : .layout
        if adopted { entry.layoutSpaceID = nil }
        entry.visibilityState = hidden ? .hiddenOffscreen : .visible
        entry.lastVisibleFrame = ResolvedFrame(x: 50, y: 50, width: 500, height: 400)
        entry.lastHiddenFrame = hidden ? window.frame : nil
        return entry
    }

    @Test(arguments: [false, true], [LayoutTransitionScopeKind.local, .layoutSet])
    func quitWithJournalRestoresOtherScopeWithoutConfigAndKeepsOnlyPriorReleased(failing: Bool, scopeKind: LayoutTransitionScopeKind) async throws {
        let main = TestFixtures.window(id: 1, bundleID: "Main", frame: ResolvedFrame(x: 4000, y: 20, width: 500, height: 400), isAXBacked: true)
        let side = TestFixtures.window(id: 2, bundleID: "Side", frame: ResolvedFrame(x: 4600, y: 20, width: 500, height: 400), isAXBacked: true)
        let released = TestFixtures.window(id: 3, bundleID: "Released", isAXBacked: true)
        let journal = PendingLayoutTransition(requestID: "local", scopeKind: scopeKind, phase: .precommit,
            sourceLayoutNames: scopeKind == .local ? [] : ["main", "side"], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil,
            definitionDigest: "old", topologyDigest: "old")
        let state = RuntimeState(releasedWindowIdentities: [released.identity], pendingLayoutTransition: journal,
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 1),
                ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)],
            slots: [entry(main, name: "main", hidden: true), entry(side, name: "side", hidden: true)])
        let (e, c, store, url) = try engine([main, side, released], state: state); defer { remove(url) }
        if failing { c.failFrameWindowIDs = [side.windowID] }
        let result = try await e.shutdownManagedWindows(requestID: "quit")
        #expect(result.releasedCount == 0)
        #expect(Set(c.setFrameAttemptWindowIDs) == [main.windowID, side.windowID])
        let restarted = try VirtualSpaceEngine(store: store, control: c, logger: TestFixtures.nullLogger(), operationCoordinator: ArrangeOperationCoordinator())
        let saved = await restarted.currentState
        #expect(saved.releasedWindowIdentities == [released.identity])
        if failing {
            #expect(result.exitCode == 51 && result.recoveryRequired)
            #expect(saved.pendingLayoutTransition == journal && saved.activeWorkspaces.count == 2)
            #expect(saved.slots.first { $0.layoutName == "side" }?.visibilityState == .hiddenOffscreen)
            c.failFrameWindowIDs = []
            #expect(try await restarted.shutdownManagedWindows(requestID: "retry").exitCode == 0)
        } else { #expect(result.exitCode == 0) }
        let final = try store.loadStrict()
        #expect(final.slots.isEmpty && final.activeWorkspaces.isEmpty && final.pendingLayoutTransition == nil)
        #expect(final.releasedWindowIdentities == [released.identity])
    }

    @Test(arguments: [1, 2])
    func manualIndexRanksFreeWindowsAfterProtectedIdentityRemoval(index: Int) async throws {
        let a = TestFixtures.window(id: 1, bundleID: "Editor", title: "A", isAXBacked: true, displayID: "uuid-sub")
        let b = TestFixtures.window(id: 2, bundleID: "Editor", title: "B", isAXBacked: true)
        let c = TestFixtures.window(id: 3, bundleID: "Editor", title: "C", isAXBacked: true)
        let sideRule = WindowMatchRule(bundleID: "Editor", title: TitleMatcher(equals: "A"))
        let config = TestFixtures.loadedConfig(layouts: ["main": layout(WindowMatchRule(bundleID: "Editor", index: index)),
            "side": layout(sideRule, secondary: true)])
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)],
            slots: [entry(a, name: "side", rule: sideRule)])
        let (e, control, store, url) = try engine([a, b, c], state: state); defer { remove(url) }
        let revision = try store.loadStrict().revision
        _ = try await e.arrangeDryRun(layoutName: "main", spaceID: nil, config: config)
        #expect(try store.loadStrict().revision == revision && control.frameMutationAttemptWindowIDs.isEmpty)
        let result = try await e.arrange(layoutName: "main", spaceID: nil, config: config)
        #expect(result.exitCode == 0)
        let after = await e.currentState
        #expect(after.slots.first { $0.layoutName == "main" && $0.origin == .layout }?.boundIdentity == (index == 1 ? b.identity : c.identity))
        #expect(after.slots.first { $0.layoutName == "side" }?.boundIdentity == a.identity)
        #expect(!control.frameMutationAttemptWindowIDs.contains(a.windowID))
    }

    @Test func manualOnlyProtectedCandidateReportsDormantOwnerBeforeAnyMutation() async throws {
        let a = TestFixtures.window(id: 1, bundleID: "Editor", title: "A", isAXBacked: true)
        let rule = WindowMatchRule(bundleID: "Editor", title: TitleMatcher(equals: "A"))
        let config = TestFixtures.loadedConfig(layouts: ["main": layout(WindowMatchRule(bundleID: "Editor", index: 1)), "side": layout(rule, secondary: true)])
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)], slots: [entry(a, name: "side", rule: rule)])
        let (e, c, store, url) = try engine([a], state: state, displays: [TestFixtures.display]); defer { remove(url) }
        let revision = try store.loadStrict().revision
        do { _ = try await e.arrange(layoutName: "main", spaceID: nil, config: config); Issue.record("expected owner rejection") }
        catch let error as ShitsuraeError {
            #expect(error.subcode == "windowOwnedByOtherLayout")
            #expect(error.message.contains("side display=uuid-sub dormant=true"))
        }
        #expect(try store.loadStrict().revision == revision)
        #expect(c.launchedRequests.isEmpty && c.frameMutationAttemptWindowIDs.isEmpty && c.focusedWindowIDs.isEmpty)
    }

    @Test func manualSelectionSharesIgnoreGeometryAndExactReservationWithExecutor() async throws {
        let a = TestFixtures.window(id: 1, bundleID: "Editor", title: "A", isAXBacked: true)
        let ignored = TestFixtures.window(id: 2, bundleID: "Editor", title: "Ignored", isAXBacked: true)
        let blocked = TestFixtures.window(id: 3, bundleID: "Editor", title: "Blocked", geometryBlocked: true, isAXBacked: true)
        let free = TestFixtures.window(id: 4, bundleID: "Editor", title: "Free", isAXBacked: true)
        let rule = WindowMatchRule(bundleID: "Editor", title: TitleMatcher(equals: "A"))
        let config = TestFixtures.loadedConfig(layouts: ["main": layout(WindowMatchRule(bundleID: "Editor", index: 1)), "side": layout(rule, secondary: true)],
            ignore: IgnoreDefinition(apply: IgnoreRuleSet(windows: [IgnoreWindowRule(bundleID: "Editor", titleRegex: "^Ignored$")])))
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 1)], slots: [entry(a, name: "side", rule: rule)])
        let (e, c, _, url) = try engine([a, ignored, blocked, free], state: state); defer { remove(url) }
        _ = try await e.arrange(layoutName: "main", spaceID: nil, config: config)
        #expect(await e.currentState.slots.first { $0.layoutName == "main" && $0.origin == .layout }?.boundIdentity == free.identity)
        #expect(!c.frameMutationAttemptWindowIDs.contains(a.windowID) && !c.frameMutationAttemptWindowIDs.contains(ignored.windowID) && !c.frameMutationAttemptWindowIDs.contains(blocked.windowID))
        let unknown = TestFixtures.window(id: 5, bundleID: "Editor", isAXBacked: false)
        var reserved = state
        reserved.activeWorkspaces.append(ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 1))
        reserved.slots.append(entry(unknown, name: "main", rule: WindowMatchRule(bundleID: "Editor", index: 1)))
        let observation = WindowObservation(inventory: .available([a, unknown, free]), focusedIdentity: nil, mainIdentity: nil)
        _ = try LayoutRuntimeValidator.validate(layoutName: "main", layout: config.config.layouts["main"]!, host: TestFixtures.display,
            config: config.config, state: reserved, displays: [TestFixtures.display], observation: observation)
        let records = ArrangeWindowSelection.registryEntries(layoutName: "main", layout: config.config.layouts["main"]!, config: config.config, state: reserved, excluding: [])
        let resolution = WindowRegistry.resolve(entries: records.map(\.entry), manageableWindows: [free], fullInventory: observation.inventory)
        #expect(resolution.unresolvedReasons[records[0].entry.id] == .reservedExactIdentity)
    }

    @Test(arguments: [false, true])
    func deletedSpaceAdoptedMovesToReapplyTargetForSetAndSingle(single: Bool) async throws {
        let window = TestFixtures.window(id: 1, bundleID: "Extra", frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), isAXBacked: true)
        let config = TestFixtures.loadedConfig(layouts: ["main": layout()], layoutSets: ["home": LayoutSetDefinition(layouts: ["main"])])
        let adopted = entry(window, name: "main", adopted: true, space: 2, hidden: true)
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main"], definitionDigest: "old"),
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 2)], slots: [adopted])
        let (e, c, _, url) = try engine([window], state: state); defer { remove(url) }
        if single { #expect(try await e.arrange(layoutName: "main", spaceID: nil, config: config).exitCode == 0) }
        else { #expect(try await e.arrangeSet(setName: "home", requestID: "reapply", config: config).exitCode == 0) }
        let after = await e.currentState
        let kept = try #require(after.slots.first { $0.id == adopted.id })
        #expect(kept.spaceID == 1 && kept.boundIdentity == window.identity && kept.visibilityState == .visible)
        #expect((c.window(window.windowID)?.frame.x ?? 4000) < 1440)
        #expect(after.pendingLayoutTransition == nil && after.releasedWindowIdentities.isEmpty)
    }

    @Test(arguments: [false, true])
    func reapplyPreservesValidAdoptedSpaceAndUserMinimization(single: Bool) async throws {
        let valid = TestFixtures.window(id: 1, bundleID: "Valid", frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), isAXBacked: true)
        let userMin = TestFixtures.window(id: 2, bundleID: "UserMin", isAXBacked: true, minimized: true)
        let config = TestFixtures.loadedConfig(layouts: ["main": layout(spaces: [1, 2])], layoutSets: ["home": LayoutSetDefinition(layouts: ["main"])])
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main"], definitionDigest: "old"),
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 1)],
            slots: [entry(valid, name: "main", adopted: true, space: 2, hidden: true), entry(userMin, name: "main", adopted: true, space: 3)])
        let (e, c, _, url) = try engine([valid, userMin], state: state); defer { remove(url) }
        if single { #expect(try await e.arrange(layoutName: "main", spaceID: nil, config: config).exitCode == 0) }
        else { #expect(try await e.arrangeSet(setName: "home", requestID: "reapply", config: config).exitCode == 0) }
        let after = await e.currentState
        #expect(after.slots.first { $0.boundIdentity == valid.identity }?.spaceID == 2)
        #expect(after.slots.first { $0.boundIdentity == userMin.identity }?.spaceID == 1)
        #expect(c.window(userMin.windowID)?.minimized == true && c.minimizeAttempts.isEmpty)
        #expect(after.pendingLayoutTransition == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func deletedSpaceUnknownAdoptedKeepsExactRecoveryMetadataAndJournal(single: Bool, rawHandleOnly: Bool) async throws {
        let unknown = TestFixtures.window(id: 1, bundleID: "Unknown", frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), isAXBacked: false)
        let adopted = entry(unknown, name: "main", adopted: true, space: 2, hidden: true)
        let config = TestFixtures.loadedConfig(layouts: ["main": layout()], layoutSets: ["home": LayoutSetDefinition(layouts: ["main"])])
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main"], definitionDigest: "old"),
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 2)], slots: [adopted])
        let (e, c, store, url) = try engine([unknown], state: state); defer { remove(url) }
        if rawHandleOnly {
            c.liveWindowHandlesOverride = [unknown.handle]
            c.removeWindow(unknown.windowID)
        }
        if single {
            do { _ = try await e.arrange(layoutName: "main", spaceID: nil, config: config) }
            catch let error as VirtualSpaceEngineError {
                #expect(error == .stateError("window inventory temporarily lacks manageable bindings"))
            }
        }
        else { _ = try await e.arrangeSet(setName: "home", requestID: "reapply", config: config) }
        let kept = try #require(try store.loadStrict().slots.first { $0.id == adopted.id })
        #expect(kept.boundIdentity == adopted.boundIdentity && kept.lastVisibleFrame == adopted.lastVisibleFrame && kept.lastHiddenFrame == adopted.lastHiddenFrame)
        let saved = try store.loadStrict()
        #expect(kept.visibilityState.isManagedHidden && saved.pendingLayoutTransition != nil)
        #expect(c.frameMutationAttemptWindowIDs.isEmpty)
    }

    @Test func deletedSpaceAdoptedUsesEachMembersNonMinimumReapplyTarget() async throws {
        let mainWindow = TestFixtures.window(id: 1, bundleID: "MainExtra", frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), isAXBacked: true)
        let sideWindow = TestFixtures.window(id: 2, bundleID: "SideExtra", frame: ResolvedFrame(x: 4600, y: 50, width: 500, height: 400), isAXBacked: true, displayID: "uuid-sub")
        let config = TestFixtures.loadedConfig(layouts: ["main": layout(spaces: [1, 2]), "side": layout(secondary: true, spaces: [1, 4])],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main", "side"])])
        let main = entry(mainWindow, name: "main", adopted: true, space: 3, hidden: true)
        var side = entry(sideWindow, name: "side", adopted: true, space: 3, hidden: true)
        side.lastVisibleFrame = ResolvedFrame(x: 1600, y: 50, width: 500, height: 400)
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main", "side"], definitionDigest: "old"),
            activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 2), ActiveWorkspace(displayID: "uuid-sub", layoutName: "side", spaceID: 4)],
            slots: [main, side])
        let (e, _, _, url) = try engine([mainWindow, sideWindow], state: state); defer { remove(url) }
        #expect(try await e.arrangeSet(setName: "home", requestID: "reapply", config: config).exitCode == 0)
        let after = await e.currentState
        #expect(after.slots.first { $0.id == main.id }?.spaceID == 2)
        #expect(after.slots.first { $0.id == side.id }?.spaceID == 4)
        #expect(after.slots.allSatisfy { !$0.visibilityState.isManagedHidden })
        #expect(after.pendingLayoutTransition == nil)
    }

    @Test func manualDirtyAggregationIncludesChangedAndRemovedDefinitions() {
        let original = ShitsuraeConfig(layouts: ["main": layout(WindowMatchRule(bundleID: "Editor"))])
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "uuid-main", layoutName: "main", spaceID: 1,
            appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "main", config: original))])
        #expect(!state.anyActiveScopeNeedsReapply(config: original))
        let changed = ShitsuraeConfig(layouts: ["main": layout(WindowMatchRule(bundleID: "Other"))])
        #expect(state.anyActiveScopeNeedsReapply(config: changed))
        #expect(state.anyActiveScopeNeedsReapply(config: ShitsuraeConfig(layouts: [:])))
    }
}
