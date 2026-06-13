import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowRegistry")
struct WindowRegistryTests {
    private func makeWindow(
        id: UInt32,
        bundleID: String,
        title: String = "",
        profile: String? = nil,
        frontIndex: Int = 0,
        area: Double = 10000
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: id,
            bundleID: bundleID,
            pid: Int(id) * 10,
            title: title,
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
        windowID: UInt32? = nil,
        title: TitleMatcher? = nil,
        profile: String? = nil,
        index: Int? = nil
    ) -> WindowRegistry.Entry {
        WindowRegistry.Entry(
            id: id,
            rule: WindowMatchRule(bundleID: bundleID, title: title, profile: profile, index: index),
            windowID: windowID
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
        #expect(resolution.assignments["notes"]?.windowID == 99)
    }

    @Test func singleEntryPicksDeterministicBestAmongClones() {
        let windows = [
            makeWindow(id: 5, bundleID: "app", title: "", frontIndex: 1, area: 100),
            makeWindow(id: 6, bundleID: "app", title: "named", frontIndex: 2, area: 100),
        ]
        let entries = [entry("only", bundleID: "app")]

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
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

        let resolution = WindowRegistry.resolve(entries: entries, windows: windows)
        #expect(resolution.unresolved.isEmpty)
        #expect(resolution.assignments["wants-x"]?.windowID == 1)
        #expect(resolution.assignments["wants-y"]?.windowID == 2)
    }

    // バグ1-c 回帰: lookup は曖昧なら nil(誤エントリへの書き込み禁止)
    @Test func lookupIsNilWhenAmbiguous() {
        let window = makeWindow(id: 1, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app"),
            entry("b", bundleID: "app"),
        ]

        #expect(WindowRegistry.lookup(window: window, entries: entries) == nil)
    }

    @Test func lookupPrefersWindowIDMatch() {
        let window = makeWindow(id: 7, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app"),
            entry("b", bundleID: "app", windowID: 7),
        ]

        #expect(WindowRegistry.lookup(window: window, entries: entries)?.id == "b")
    }

    @Test func lookupUniqueRuleMatch() {
        let window = makeWindow(id: 7, bundleID: "app", title: "notes")
        let entries = [
            entry("a", bundleID: "app", title: TitleMatcher(contains: "notes")),
            entry("b", bundleID: "other"),
        ]

        #expect(WindowRegistry.lookup(window: window, entries: entries)?.id == "a")
    }

    @Test func lookupExcludesEntriesBoundToOtherWindows() {
        let window = makeWindow(id: 7, bundleID: "app")
        let entries = [
            entry("a", bundleID: "app", windowID: 99), // bound elsewhere
            entry("b", bundleID: "app"),
        ]

        // Only "b" is unbound and matching → unique.
        #expect(WindowRegistry.lookup(window: window, entries: entries)?.id == "b")
    }
}
