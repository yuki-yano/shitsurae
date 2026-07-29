import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("RuntimeStateStore")
struct StateStoreTests {
    @Test func canonicalizationPreservesWorkspaceRegistrationOrder() {
        let state = RuntimeState(activeWorkspaces: [
            ActiveWorkspace(displayID: "z-primary", layoutName: "work", spaceID: 1),
            ActiveWorkspace(displayID: "a-secondary", layoutName: "calendar", spaceID: 2),
        ])

        let canonical = state.canonicalized()
        #expect(canonical.activeWorkspaces.map(\.displayID) == ["z-primary", "a-secondary"])
    }

    @Test func upsertEnforcesDisplayAndLayoutUniqueness() {
        var state = RuntimeState()
        state.upsertActiveWorkspace(displayID: "uuid-a", layoutName: "work", spaceID: 1)
        state.upsertActiveWorkspace(displayID: "uuid-b", layoutName: "calendar", spaceID: 1)

        // Same display, different layout: replacement.
        state.upsertActiveWorkspace(displayID: "uuid-a", layoutName: "focus", spaceID: 2)
        #expect(state.activeWorkspace(displayID: "uuid-a")?.layoutName == "focus")
        #expect(state.activeWorkspaces.count == 2)

        // Same layout, different display: the old record leaves.
        state.upsertActiveWorkspace(displayID: "uuid-c", layoutName: "calendar", spaceID: 3)
        #expect(state.activeWorkspace(displayID: "uuid-b") == nil)
        #expect(state.activeWorkspace(layoutName: "calendar")?.displayID == "uuid-c")
        #expect(state.activeWorkspaces.count == 2)
    }

    @Test func upsertMigratesPendingToNewDisplayID() {
        var state = RuntimeState()
        state.upsertActiveWorkspace(displayID: "uuid-old", layoutName: "calendar", spaceID: 1)
        state.setPendingVisibilityConvergence(
            displayID: "uuid-old",
            PendingVisibilityConvergence(
                requestID: "r1",
                startedAt: "2026-01-01T00:00:00Z",
                displayID: "uuid-old",
                layoutName: "calendar",
                targetSpaceID: 1
            )
        )

        // Reconnect changed the display UUID: the pending entry follows so it
        // can still be cleared (no permanent recoveryRequired residue).
        state.upsertActiveWorkspace(displayID: "uuid-new", layoutName: "calendar", spaceID: 1)
        #expect(state.pendingVisibilityConvergence(displayID: "uuid-old") == nil)
        #expect(state.pendingVisibilityConvergence(displayID: "uuid-new")?.requestID == "r1")
        #expect(state.recoveryRequired)
    }

    @Test func pendingIsIsolatedPerDisplay() {
        var state = RuntimeState()
        state.setPendingVisibilityConvergence(
            displayID: "uuid-a",
            PendingVisibilityConvergence(
                requestID: "ra",
                startedAt: "2026-01-01T00:00:00Z",
                displayID: "uuid-a",
                layoutName: "work",
                targetSpaceID: 2
            )
        )
        state.setPendingVisibilityConvergence(
            displayID: "uuid-b",
            PendingVisibilityConvergence(
                requestID: "rb",
                startedAt: "2026-01-01T00:00:00Z",
                displayID: "uuid-b",
                layoutName: "calendar",
                targetSpaceID: 1
            )
        )

        // Clearing one display never touches the other's recovery metadata.
        state.setPendingVisibilityConvergence(displayID: "uuid-b", nil)
        #expect(state.pendingVisibilityConvergence(displayID: "uuid-a")?.requestID == "ra")
        #expect(state.pendingVisibilityConvergence(displayID: "uuid-b") == nil)
        #expect(state.recoveryRequired)
    }

    private func makeEntry(spaceID: Int, slot: Int, bundleID: String = "com.example.App") -> SlotEntry {
        SlotEntry(
            layoutName: "work",
            spaceID: spaceID,
            slot: slot,
            origin: .layout,
            definitionFingerprint: "fp-\(spaceID)-\(slot)",
            layoutSpaceID: spaceID,
            bundleID: bundleID
        )
    }

    @Test func roundTripsState() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.upsertActiveWorkspace(displayID: "uuid-main", layoutName: "work", spaceID: 2)
        var minimizedEntry = makeEntry(spaceID: 2, slot: 1)
        minimizedEntry.visibilityState = .hiddenMinimized
        state.slots = [makeEntry(spaceID: 1, slot: 1), minimizedEntry]

        try store.saveStrict(state: state)
        let loaded = try store.loadStrict()

        #expect(loaded.schemaVersion == 6)
        #expect(loaded.activeLayoutName == "work")
        #expect(loaded.activeSpaceID(displayID: "uuid-main") == 2)
        #expect(loaded.primaryActiveSpaceID == 2)
        #expect(loaded.slots.count == 2)
        #expect(loaded.slots.first { $0.spaceID == 2 }?.visibilityState == .hiddenMinimized)
    }

    @Test func missingFileYieldsFreshState() throws {
        let (store, _) = TestFixtures.tempStateStore()
        let state = try store.loadStrict()
        #expect(state.slots.isEmpty)
        #expect(state.activeLayoutName == nil)
    }

    @Test func rejectsUnsupportedStateWithoutMovingOriginal() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let v4JSON = """
        {
          "schemaVersion": 4,
          "updatedAt": "2026-01-01T00:00:00Z",
          "revision": 7,
          "configGeneration": "legacy",
          "liveArrangeRecoveryRequired": false,
          "activeLayoutName": "old",
          "activeSpaces": [{"displayID": "uuid-main", "spaceID": 3}],
          "slots": []
        }
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try v4JSON.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: RuntimeStateStoreError.unsupportedSchema(
            fileURL: url,
            actualVersion: 4,
            expectedVersion: RuntimeState.currentSchemaVersion
        )) {
            try store.loadStrict()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func backsUpCorruptedFile() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{\"schemaVersion\": 6, \"broken".write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: RuntimeStateStoreError.self) {
            try store.loadStrict()
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.contains("corrupt") })
    }

    @Test func rejectsStaleWrite() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.revision = 5
        try store.saveStrict(state: state)

        let staleExpectation = RuntimeStateWriteExpectation(revision: 3, configGeneration: "gen")
        var next = state
        next.revision = 6

        #expect(throws: RuntimeStateStoreError.self) {
            try store.saveStrict(state: next, expecting: staleExpectation)
        }
    }

    @Test func acceptsMatchingExpectation() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.revision = 5
        try store.saveStrict(state: state)

        var next = state
        next.revision = 6
        try store.saveStrict(
            state: next,
            expecting: RuntimeStateWriteExpectation(revision: 5, configGeneration: "gen")
        )

        let loaded = try store.loadStrict()
        #expect(loaded.revision == 6)
    }

    @Test func sortsSlotsOnSave() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.slots = [
            makeEntry(spaceID: 2, slot: 2),
            makeEntry(spaceID: 1, slot: 2),
            makeEntry(spaceID: 1, slot: 1),
        ]
        try store.saveStrict(state: state)

        let loaded = try store.loadStrict()
        #expect(loaded.slots.map { "\($0.spaceID)-\($0.slot)" } == ["1-1", "1-2", "2-2"])
    }

    @Test func movesUnreadableStateFileAsideOnExplicitConsent() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"schemaVersion": 4}"#.write(to: url, atomically: true, encoding: .utf8)

        let backupURL = try #require(store.moveStateFileAside(label: "unsupported"))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backupURL.lastPathComponent.hasPrefix("runtime-state.unsupported-"))
        // The next load starts fresh instead of failing closed again.
        #expect(try store.loadStrict().activeWorkspaces.isEmpty)

        // Nothing to move → nil, and no phantom backup appears.
        #expect(store.moveStateFileAside(label: "unsupported") == nil)
    }

    @Test func multiDisplayActiveWorkspacesRoundTrip() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.upsertActiveWorkspace(displayID: "uuid-a", layoutName: "work", spaceID: 1)
        state.upsertActiveWorkspace(displayID: "uuid-b", layoutName: "calendar", spaceID: 3)
        try store.saveStrict(state: state)

        let loaded = try store.loadStrict()
        #expect(loaded.activeWorkspace(displayID: "uuid-a")?.spaceID == 1)
        #expect(loaded.activeWorkspace(displayID: "uuid-a")?.layoutName == "work")
        #expect(loaded.activeWorkspace(displayID: "uuid-b")?.spaceID == 3)
        #expect(loaded.activeWorkspace(displayID: "uuid-b")?.layoutName == "calendar")
    }
}
