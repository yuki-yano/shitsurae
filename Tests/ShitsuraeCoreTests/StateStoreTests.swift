import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("RuntimeStateStore")
struct StateStoreTests {
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
        state.activeLayoutName = "work"
        state.setActiveSpace(displayID: "uuid-main", spaceID: 2)
        state.slots = [makeEntry(spaceID: 1, slot: 1), makeEntry(spaceID: 2, slot: 1)]

        try store.saveStrict(state: state)
        let loaded = try store.loadStrict()

        #expect(loaded.schemaVersion == 2)
        #expect(loaded.activeLayoutName == "work")
        #expect(loaded.activeSpaceID(displayID: "uuid-main") == 2)
        #expect(loaded.primaryActiveSpaceID == 2)
        #expect(loaded.slots.count == 2)
    }

    @Test func missingFileYieldsFreshState() throws {
        let (store, _) = TestFixtures.tempStateStore()
        let state = try store.loadStrict()
        #expect(state.slots.isEmpty)
        #expect(state.activeLayoutName == nil)
    }

    // v1状態ファイルの破棄(確定仕様)
    @Test func discardsV1StateFile() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let v1JSON = """
        {
          "updatedAt": "2026-01-01T00:00:00Z",
          "revision": 7,
          "stateMode": "virtual",
          "configGeneration": "legacy",
          "activeLayoutName": "old",
          "activeVirtualSpaceID": 3,
          "slots": []
        }
        """
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try v1JSON.write(to: url, atomically: true, encoding: .utf8)

        let state = try store.loadStrict()
        #expect(state.activeLayoutName == nil)
        #expect(state.revision == 0)

        // Old file moved aside as a backup.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(siblings.contains { $0.contains("discarded") })
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func backsUpCorruptedFile() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{\"schemaVersion\": 2, \"broken".write(to: url, atomically: true, encoding: .utf8)

        // Probe fails to decode → treated as non-v2 → discarded, fresh state.
        let state = try store.loadStrict()
        #expect(state.slots.isEmpty)
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

    @Test func multiDisplayActiveSpacesRoundTrip() throws {
        let (store, url) = TestFixtures.tempStateStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var state = RuntimeState(configGeneration: "gen")
        state.setActiveSpace(displayID: "uuid-a", spaceID: 1)
        state.setActiveSpace(displayID: "uuid-b", spaceID: 3)
        try store.saveStrict(state: state)

        let loaded = try store.loadStrict()
        #expect(loaded.activeSpaceID(displayID: "uuid-a") == 1)
        #expect(loaded.activeSpaceID(displayID: "uuid-b") == 3)
    }
}
