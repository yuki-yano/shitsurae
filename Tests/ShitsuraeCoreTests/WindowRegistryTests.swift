import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowRegistry")
struct WindowRegistryTests {
    private func resolve(
        entries: [WindowRegistry.Entry],
        windows: [WindowSnapshot]
    ) -> WindowRegistry.Resolution {
        WindowRegistry.resolve(
            entries: entries,
            manageableWindows: windows,
            fullInventory: .available(windows)
        )
    }

    private func assignedEntry(
        for window: WindowSnapshot,
        entries: [WindowRegistry.Entry],
        windows: [WindowSnapshot]
    ) -> WindowRegistry.Entry? {
        WindowRegistry.assignedEntry(
            for: window,
            entries: entries,
            manageableWindows: windows,
            fullInventory: .available(windows)
        )
    }

    private func makeWindow(
        id: UInt32,
        bundleID: String,
        pid: Int? = nil,
        processStartTime: UInt64? = nil,
        title: String = "",
        profile: String? = nil,
        frontIndex: Int = 0,
        area: Double = 10000
    ) -> WindowSnapshot {
        let resolvedPID = pid ?? Int(id) * 10
        return WindowSnapshot(
            windowID: id,
            bundleID: bundleID,
            pid: resolvedPID,
            processStartTime: processStartTime ?? UInt64(resolvedPID) * 1_000_000,
            title: title,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            modal: false,
            geometryBlocked: false,
            isAXBacked: true,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: area / 100, height: 100),
            displayID: "display-1",
            profileDirectory: profile,
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }

    private func entry(
        _ id: String,
        bundleID: String,
        pid: Int? = nil,
        windowID: UInt32? = nil,
        title: TitleMatcher? = nil,
        profile: String? = nil,
        index: Int? = nil,
        bindingPolicy: WindowRegistry.BindingPolicy = .exactThenRule
    ) -> WindowRegistry.Entry {
        let resolvedPID = pid ?? windowID.map { Int($0) * 10 }
        return WindowRegistry.Entry(
            id: id,
            rule: WindowMatchRule(bundleID: bundleID, title: title, profile: profile, index: index),
            pid: resolvedPID,
            processStartTime: resolvedPID.map { UInt64($0) * 1_000_000 },
            windowID: windowID,
            bindingPolicy: bindingPolicy
        )
    }

    // バグ1-a 回帰: 同一bundleIDの複数エントリが同一ウィンドウに解決されない
    @Test func twoEntriesNeverShareOneWindow() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.apple.Terminal", frontIndex: 0),
            makeWindow(id: 2, bundleID: "com.apple.Terminal", frontIndex: 1),
        ]
        let entries = [
            entry("space1-slot1", bundleID: "com.apple.Terminal", index: 1),
            entry("space2-slot1", bundleID: "com.apple.Terminal", index: 2),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.unresolved.isEmpty)
        let assigned = Set(resolution.assignments.values.map(\.windowID))
        #expect(assigned == [1, 2])
    }

    @Test func windowIDMatchWinsOverRules() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.apple.Terminal", title: "small", area: 100),
            makeWindow(id: 2, bundleID: "com.apple.Terminal", title: "big", area: 100_000),
        ]
        let entries = [
            // The rule alone would prefer the bigger window, but windowID
            // pins entry A to window 1.
            entry("a", bundleID: "com.apple.Terminal", windowID: 1),
            entry("b", bundleID: "com.apple.Terminal", index: 1),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["a"]?.windowID == 1)
        #expect(resolution.assignments["b"]?.windowID == 2)
    }

    // バグ2-c 回帰: index エントリ同士は同一の固定プールを見る
    @Test func indexEntriesShareStableOrdering() {
        let windows = [
            makeWindow(id: 10, bundleID: "app", title: "w1", frontIndex: 0),
            makeWindow(id: 20, bundleID: "app", title: "w2", frontIndex: 1),
            makeWindow(id: 30, bundleID: "app", title: "w3", frontIndex: 2),
        ]
        // Entry order reversed relative to index — must not shift results.
        let entries = [
            entry("third", bundleID: "app", index: 3),
            entry("first", bundleID: "app", index: 1),
            entry("second", bundleID: "app", index: 2),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["first"]?.windowID == 10)
        #expect(resolution.assignments["second"]?.windowID == 20)
        #expect(resolution.assignments["third"]?.windowID == 30)
    }

    @Test func indexOutOfBoundsIsUnresolvedAndDoesNotStealWindow() {
        let windows = [
            makeWindow(id: 10, bundleID: "app", title: "only", frontIndex: 0),
        ]
        let entries = [
            entry("first", bundleID: "app", index: 1),
            entry("second", bundleID: "app", index: 2),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["first"]?.windowID == 10)
        #expect(resolution.unresolved == ["second"])
        #expect(resolution.unassignedWindows.isEmpty)
    }

    @Test func titleDiscriminatorsResolveIndependently() {
        let windows = [
            makeWindow(id: 1, bundleID: "app", title: "Editor — notes"),
            makeWindow(id: 2, bundleID: "app", title: "Terminal — build"),
        ]
        let entries = [
            entry("notes", bundleID: "app", title: TitleMatcher(contains: "notes")),
            entry("build", bundleID: "app", title: TitleMatcher(contains: "build")),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["notes"]?.windowID == 1)
        #expect(resolution.assignments["build"]?.windowID == 2)
    }

    @Test func profileDiscriminatorMatches() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.google.Chrome", profile: "Default"),
            makeWindow(id: 2, bundleID: "com.google.Chrome", profile: "Profile 1"),
        ]
        let entries = [
            entry("work", bundleID: "com.google.Chrome", profile: "Profile 1"),
            entry("home", bundleID: "com.google.Chrome", profile: "Default"),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["work"]?.windowID == 2)
        #expect(resolution.assignments["home"]?.windowID == 1)
    }

    @Test func unresolvedProfileWindowDoesNotMatchButIsRetained() {
        // Profile still pending (nil) — entry must not match, window stays
        // unassigned rather than being grabbed by the wrong entry.
        let windows = [
            makeWindow(id: 1, bundleID: "com.google.Chrome", profile: nil),
        ]
        let entries = [
            entry("work", bundleID: "com.google.Chrome", profile: "Default"),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.unresolved == ["work"])
        #expect(resolution.unassignedWindows.map(\.windowID) == [1])
    }

    @Test func staleWindowIDFallsBackToRule() {
        let windows = [
            makeWindow(id: 99, bundleID: "com.apple.Notes"),
        ]
        let entries = [
            entry("notes", bundleID: "com.apple.Notes", windowID: 12345), // stale
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["notes"]?.windowID == 99)
    }

    @Test func exactOnlyDoesNotRebindStaleEntryToSameBundle() {
        let replacement = makeWindow(id: 99, bundleID: "com.google.Chrome", pid: 200)
        let adopted = entry(
            "adopted",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 42,
            bindingPolicy: .exactOnly
        )

        let resolution = resolve(entries: [adopted], windows: [replacement])

        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolved == ["adopted"])
        #expect(resolution.unassignedWindows == [replacement])
    }

    @Test func slotOriginSelectsBindingPolicyAndForwardsPID() {
        let layout = SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "layout",
            bundleID: "app",
            pid: 100,
            windowID: 42
        )
        let adopted = SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 0,
            origin: .adopted,
            definitionFingerprint: "adopted",
            bundleID: "app",
            pid: 200,
            windowID: 43
        )

        #expect(layout.registryEntry.bindingPolicy == .exactThenRule)
        #expect(layout.registryEntry.pid == 100)
        #expect(adopted.registryEntry.bindingPolicy == .exactOnly)
        #expect(adopted.registryEntry.pid == 200)
    }

    @Test func exactOnlyRequiresPIDWindowIDAndBundleIDToMatch() {
        let reusedID = makeWindow(id: 42, bundleID: "com.google.Chrome", pid: 200)
        let wrongBundle = makeWindow(id: 42, bundleID: "com.google.Chrome.helper", pid: 100)
        let adopted = entry(
            "adopted",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 42,
            bindingPolicy: .exactOnly
        )

        let reusedIDResolution = resolve(entries: [adopted], windows: [reusedID])
        let wrongBundleResolution = resolve(entries: [adopted], windows: [wrongBundle])

        #expect(reusedIDResolution.assignments.isEmpty)
        #expect(reusedIDResolution.unresolved == ["adopted"])
        #expect(wrongBundleResolution.assignments.isEmpty)
        #expect(wrongBundleResolution.unresolved == ["adopted"])
        #expect(assignedEntry(for: reusedID, entries: [adopted], windows: [reusedID]) == nil)
        #expect(assignedEntry(for: wrongBundle, entries: [adopted], windows: [wrongBundle]) == nil)
    }

    @Test func exactOnlyRejectsReusedPIDAndWindowIDFromAnotherProcessGeneration() {
        let replacement = makeWindow(
            id: 1,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 100_000_001
        )
        let bound = entry(
            "adopted",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1,
            bindingPolicy: .exactOnly
        )

        let resolution = resolve(entries: [bound], windows: [replacement])

        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unassignedWindows.map(\.identity) == [replacement.identity])
    }

    @Test func sameWindowIDFromDifferentProcessesRemainDistinctCandidates() {
        let windows = [
            makeWindow(id: 42, bundleID: "app", pid: 100, frontIndex: 0),
            makeWindow(id: 42, bundleID: "app", pid: 200, frontIndex: 1),
        ]
        let entries = [
            entry("first", bundleID: "app", index: 1),
            entry("second", bundleID: "app", index: 2),
        ]

        let resolution = resolve(entries: entries, windows: windows)

        #expect(resolution.unresolved.isEmpty)
        #expect(Set(resolution.assignments.values.map(\.pid)) == [100, 200])
        #expect(resolution.unassignedWindows.isEmpty)
    }

    @Test func singleEntryPicksDeterministicBestAmongClones() {
        let windows = [
            makeWindow(id: 5, bundleID: "app", title: "", frontIndex: 1, area: 100),
            makeWindow(id: 6, bundleID: "app", title: "named", frontIndex: 2, area: 100),
        ]
        let entries = [entry("only", bundleID: "app")]

        let resolution = resolve(entries: entries, windows: windows)
        // Non-empty title wins the stable ordering.
        #expect(resolution.assignments["only"]?.windowID == 6)
        #expect(resolution.unassignedWindows.map(\.windowID) == [5])
    }

    // Codex指摘回帰: 完全割当が存在するなら貪欲で詰まらず全件解決する(増加道)
    @Test func augmentingPathFindsCompleteAssignment() {
        // w1 matches both rules; w2 matches only "y". A greedy pass that
        // hands w1 to the "y" entry first would starve the "x" entry.
        let windows = [
            makeWindow(id: 1, bundleID: "app", title: "x y", frontIndex: 0),
            makeWindow(id: 2, bundleID: "app", title: "y", frontIndex: 1),
        ]
        let entries = [
            entry("wants-y", bundleID: "app", title: TitleMatcher(contains: "y")),
            entry("wants-x", bundleID: "app", title: TitleMatcher(contains: "x")),
        ]

        let resolution = resolve(entries: entries, windows: windows)
        #expect(resolution.unresolved.isEmpty)
        #expect(resolution.assignments["wants-x"]?.windowID == 1)
        #expect(resolution.assignments["wants-y"]?.windowID == 2)
    }

    // バグ1-c 回帰(改): クローンruleでも書き込み先は resolve と同一entryに
    // 確定する。旧lookupの「曖昧ならnil」はfocus経路でのadopt重複を招くため、
    // global assignmentとの一致で誤entry汚染を防ぐ方式に置き換えた。
    @Test func assignedEntryAgreesWithResolveForCloneRules() {
        let window = makeWindow(id: 1, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app"),
            entry("b", bundleID: "app"),
        ]

        let resolution = resolve(entries: entries, windows: [window])
        let assigned = assignedEntry(for: window, entries: entries, windows: [window])

        #expect(resolution.assignments.count == 1)
        #expect(assigned?.id == resolution.assignments.keys.first)
    }

    @Test func assignedEntryPrefersExactIdentityMatch() {
        let window = makeWindow(id: 7, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app"),
            entry("b", bundleID: "app", windowID: 7),
        ]

        #expect(
            assignedEntry(for: window, entries: entries, windows: [window])?.id == "b"
        )
    }

    @Test func exactBindingSurvivesVolatileTitleChange() {
        // A bound window keeps its concrete identity even when its title
        // stops matching the entry's title discriminator (Chrome retitles on
        // every tab switch); only the immutable bundle identity is re-checked.
        let retitled = makeWindow(id: 7, bundleID: "app", title: "new title")
        let bound = entry(
            "slot",
            bundleID: "app",
            windowID: 7,
            title: TitleMatcher(equals: "old title")
        )

        let resolution = resolve(entries: [bound], windows: [retitled])

        #expect(resolution.assignments["slot"]?.windowID == 7)
        #expect(resolution.unresolved.isEmpty)
        #expect(
            assignedEntry(for: retitled, entries: [bound], windows: [retitled])?.id == "slot"
        )
    }

    @Test func assignedEntryRejectsMatchingWindowIDOwnedByDifferentPID() {
        let window = makeWindow(id: 7, bundleID: "app", pid: 700)
        let entries = [
            entry("stale", bundleID: "app", pid: 701, windowID: 7, bindingPolicy: .exactOnly),
        ]

        #expect(assignedEntry(for: window, entries: entries, windows: [window]) == nil)
    }

    @Test func assignedEntryUniqueRuleMatch() {
        let window = makeWindow(id: 7, bundleID: "app", title: "notes")
        let entries = [
            entry("a", bundleID: "app", title: TitleMatcher(contains: "notes")),
            entry("b", bundleID: "other"),
        ]

        #expect(assignedEntry(for: window, entries: entries, windows: [window])?.id == "a")
    }

    @Test func assignedEntryExcludesEntriesBoundToOtherLiveWindows() {
        let boundElsewhere = makeWindow(id: 99, bundleID: "app")
        let window = makeWindow(id: 7, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app", windowID: 99), // exact-bound to window 99
            entry("b", bundleID: "app"),
        ]

        // "a" claims its own window in the global assignment; 7 goes to "b".
        #expect(
            assignedEntry(
                for: window,
                entries: entries,
                windows: [boundElsewhere, window]
            )?.id == "b"
        )
    }

    @Test func exactLayoutBindingIsReservedWhileCGIdentityLives() {
        let exact = makeWindow(id: 1, bundleID: "com.google.Chrome", pid: 100)
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 100)
        let bound = entry(
            "layout",
            bundleID: "com.google.Chrome",
            pid: exact.pid,
            windowID: exact.windowID
        )

        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: [sibling],
            fullInventory: .available([exact, sibling])
        )

        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolvedReasons[bound.id] == .reservedExactIdentity)
        #expect(resolution.unassignedWindows.isEmpty)
        #expect(resolution.deferredWindows.map(\.identity) == [sibling.identity])
    }

    @Test func layoutRuleFallsBackOnlyAfterAuthoritativeCGDisappearance() {
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 100)
        let bound = entry(
            "layout",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1
        )

        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: [sibling],
            fullInventory: .available([sibling])
        )
        #expect(resolution.assignments[bound.id]?.identity == sibling.identity)
        #expect(resolution.deferredWindows.isEmpty)
    }

    @Test func unavailableInventoryNeverReleasesExactBinding() {
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 100)
        let bound = entry(
            "layout",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1
        )

        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: [sibling],
            fullInventory: .unavailable
        )
        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolvedReasons[bound.id] == .reservedExactIdentity)
        #expect(resolution.deferredWindows.map(\.identity) == [sibling.identity])
    }

    @Test func rawCGLivenessReservesBindingWhenSnapshotAssemblyDropsWindow() {
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 100)
        let bound = entry(
            "layout",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1
        )
        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: [sibling],
            fullInventory: .available(
                [sibling],
                liveWindowHandles: [
                    WindowHandle(pid: 100, processStartTime: nil, windowID: 1),
                    sibling.handle,
                ]
            )
        )

        #expect(resolution.assignments.isEmpty)
        #expect(resolution.unresolvedReasons[bound.id] == .reservedExactIdentity)
        #expect(resolution.deferredWindows.map(\.identity) == [sibling.identity])
    }

    @Test func resolvedDifferentBundleProvesRawHandleWasReused() {
        let replacement = makeWindow(id: 1, bundleID: "com.example.Replacement", pid: 100)
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 200)
        let bound = entry(
            "layout",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1
        )
        let inventory = WindowInventory.available([replacement, sibling])
        let oldIdentity = WindowIdentity(
            pid: 100,
            processStartTime: 100_000_000,
            windowID: 1,
            bundleID: "com.google.Chrome"
        )

        #expect(!inventory.mayContain(oldIdentity))
        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: [replacement, sibling],
            fullInventory: inventory
        )
        #expect(resolution.assignments[bound.id]?.identity == sibling.identity)
    }

    @Test func resolvedDifferentProcessGenerationProvesRawHandleWasReused() {
        let replacement = makeWindow(
            id: 1,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 100_000_001
        )
        let oldIdentity = WindowIdentity(
            pid: 100,
            processStartTime: 100_000_000,
            windowID: 1,
            bundleID: "com.google.Chrome"
        )

        #expect(!WindowInventory.available([replacement]).mayContain(oldIdentity))
    }

    @Test func reservedIndexRuleDefersOnlyRequiredCandidatePrefix() {
        let candidates = [
            makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 200, frontIndex: 0),
            makeWindow(id: 3, bundleID: "com.google.Chrome", pid: 300, frontIndex: 1),
            makeWindow(id: 4, bundleID: "com.google.Chrome", pid: 400, frontIndex: 2),
        ]
        let bound = entry(
            "layout-index-2",
            bundleID: "com.google.Chrome",
            pid: 100,
            windowID: 1,
            index: 2
        )
        let resolution = WindowRegistry.resolve(
            entries: [bound],
            manageableWindows: candidates,
            fullInventory: .available(
                candidates,
                liveWindowHandles: Set(candidates.map(\.handle) + [
                    WindowHandle(pid: 100, processStartTime: 100_000_000, windowID: 1),
                ])
            )
        )

        #expect(resolution.deferredWindows.map(\.identity) == candidates.prefix(2).map(\.identity))
        #expect(resolution.unassignedWindows.map(\.identity) == [candidates[2].identity])
    }

    @Test func reservedCloneRulesJointlyDeferDistinctFallbackWindows() {
        let candidates = [
            makeWindow(id: 3, bundleID: "com.google.Chrome", pid: 300, frontIndex: 0),
            makeWindow(id: 4, bundleID: "com.google.Chrome", pid: 400, frontIndex: 1),
            makeWindow(id: 5, bundleID: "com.google.Chrome", pid: 500, frontIndex: 2),
        ]
        let entries = [
            entry("clone-a", bundleID: "com.google.Chrome", pid: 100, windowID: 1),
            entry("clone-b", bundleID: "com.google.Chrome", pid: 200, windowID: 2),
        ]
        let liveHandles = Set(candidates.map(\.handle) + [
            WindowHandle(pid: 100, processStartTime: 100_000_000, windowID: 1),
            WindowHandle(pid: 200, processStartTime: 200_000_000, windowID: 2),
        ])
        let reserved = WindowRegistry.resolve(
            entries: entries,
            manageableWindows: candidates,
            fullInventory: .available(candidates, liveWindowHandles: liveHandles)
        )

        #expect(Set(reserved.deferredWindows.map(\.identity)).count == 2)
        #expect(reserved.unassignedWindows.count == 1)

        let adopted = reserved.unassignedWindows.map { window in
            WindowRegistry.Entry(
                id: "adopted-\(window.windowID)",
                rule: WindowMatchRule(bundleID: window.bundleID),
                pid: window.pid,
                processStartTime: window.processStartTime,
                windowID: window.windowID,
                bindingPolicy: .exactOnly
            )
        }
        let rebound = WindowRegistry.resolve(
            entries: entries + adopted,
            manageableWindows: candidates,
            fullInventory: .available(candidates)
        )

        #expect(rebound.assignments[entries[0].id] != nil)
        #expect(rebound.assignments[entries[1].id] != nil)
        #expect(Set(rebound.assignments.values.map(\.identity)).count == 3)
    }

    @Test func exactOnlyReservationDoesNotDeferSiblingAdoption() {
        let exact = makeWindow(id: 1, bundleID: "com.google.Chrome", pid: 100)
        let sibling = makeWindow(id: 2, bundleID: "com.google.Chrome", pid: 100)
        let adopted = entry(
            "adopted",
            bundleID: "com.google.Chrome",
            pid: exact.pid,
            windowID: exact.windowID,
            bindingPolicy: .exactOnly
        )

        let resolution = WindowRegistry.resolve(
            entries: [adopted],
            manageableWindows: [sibling],
            fullInventory: .available([exact, sibling])
        )
        #expect(resolution.deferredWindows.isEmpty)
        #expect(resolution.unassignedWindows.map(\.identity) == [sibling.identity])
    }
}
