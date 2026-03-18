import Foundation
import XCTest
@testable import ShitsuraeCore

final class StateStoreTests: XCTestCase {
    func testLoadLegacyStatePromotesDefaults() throws {
        let url = temporaryStateURL()
        let json = """
        {
          "updatedAt": "2026-03-10T00:00:00Z",
          "slots": [
            {
              "slot": 1,
              "source": "window",
              "bundleID": "com.example.app",
              "title": "Legacy",
              "profile": "Default",
              "spaceID": 3,
              "displayID": "display-1",
              "windowID": 99
            }
          ]
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)

        let state = RuntimeStateStore(stateFileURL: url).load()
        XCTAssertEqual(state.stateMode, .native)
        XCTAssertEqual(state.configGeneration, "legacy")
        XCTAssertEqual(state.revision, 0)
        XCTAssertEqual(state.activeLayoutName, nil)
        XCTAssertEqual(state.activeVirtualSpaceID, nil)
        XCTAssertEqual(state.slots.first?.layoutName, "__legacy__")
        XCTAssertEqual(state.slots.first?.definitionFingerprint, "legacy")
        XCTAssertEqual(state.slots.first?.lastKnownTitle, "Legacy")
        XCTAssertEqual(state.slots.first?.nativeSpaceID, 3)
    }

    func testSaveAndLoadExtendedStateRoundTrips() {
        let url = temporaryStateURL()
        let store = RuntimeStateStore(stateFileURL: url)
        store.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.example.app",
                    definitionFingerprint: "fingerprint",
                    pid: 123,
                    titleMatchKind: .equals,
                    titleMatchValue: "Main",
                    excludeTitleRegex: "Debug",
                    role: "AXWindow",
                    subrole: "AXStandardWindow",
                    matchIndex: 1,
                    lastKnownTitle: "Main",
                    profile: "Default",
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-1",
                    windowID: 88
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: UUID().uuidString.lowercased(),
                startedAt: "2026-03-10T00:00:00Z",
                activeLayoutName: "work",
                attemptedTargetSpaceID: 2,
                previousActiveSpaceID: 1,
                configGeneration: "generation-1",
                status: .inFlight,
            )
        )

        let state = store.load()
        XCTAssertEqual(state.stateMode, .virtual)
        XCTAssertEqual(state.configGeneration, "generation-1")
        XCTAssertEqual(state.activeLayoutName, "work")
        XCTAssertEqual(state.activeVirtualSpaceID, 2)
        XCTAssertEqual(state.revision, 5)
        XCTAssertEqual(state.pendingSwitchTransaction?.attemptedTargetSpaceID, 2)
        XCTAssertEqual(state.slots.first?.layoutName, "work")
        XCTAssertEqual(state.slots.first?.nativeSpaceID, 7)
        XCTAssertEqual(state.slots.first?.title, "Main")
    }

    func testLoadStrictMovesCorruptedStateAside() throws {
        let url = temporaryStateURL()
        try "{ not-json".write(to: url, atomically: true, encoding: .utf8)

        do {
            _ = try RuntimeStateStore(stateFileURL: url).loadStrict()
            XCTFail("expected corrupted state error")
        } catch let error as RuntimeStateStoreError {
            guard case let .corrupted(fileURL, backupURL) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileURL, url)
            XCTAssertNotNil(backupURL)
            if let backupURL {
                XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testSaveStrictThrowsWhenStateFileURLIsDirectory() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-state-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let store = RuntimeStateStore(stateFileURL: directoryURL)

        XCTAssertThrowsError(try store.saveStrict(slots: [])) { error in
            guard case let RuntimeStateStoreError.writeFailed(fileURL, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileURL, directoryURL)
        }
    }

    func testLoadStrictThrowsReadPermissionDeniedWithoutCreatingBackup() throws {
        let url = temporaryStateURL()
        try "{\"updatedAt\":\"2026-03-12T00:00:00Z\",\"slots\":[]}".write(to: url, atomically: true, encoding: .utf8)
        let beforeBackups = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("runtime-state.corrupt-") }.count
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        XCTAssertThrowsError(try RuntimeStateStore(stateFileURL: url).loadStrict()) { error in
            guard case let RuntimeStateStoreError.readPermissionDenied(fileURL) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileURL, url)
        }
        let afterBackups = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("runtime-state.corrupt-") }.count
        XCTAssertEqual(afterBackups, beforeBackups)
    }

    func testSaveStrictRejectsStaleRevisionAndGeneration() throws {
        let url = temporaryStateURL()
        try RuntimeStateStore(stateFileURL: url).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-2",
            revision: 9
        )
        let store = RuntimeStateStore(stateFileURL: url)

        XCTAssertThrowsError(
            try store.saveStrict(
                slots: [],
                stateMode: .virtual,
                configGeneration: "generation-3",
                revision: 10,
                expecting: RuntimeStateWriteExpectation(
                    revision: 8,
                    configGeneration: "generation-1"
                )
            )
        ) { error in
            guard case let RuntimeStateStoreError.staleWriteRejected(
                expectedRevision,
                actualRevision,
                expectedConfigGeneration,
                actualConfigGeneration
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expectedRevision, 8)
            XCTAssertEqual(actualRevision, 9)
            XCTAssertEqual(expectedConfigGeneration, "generation-1")
            XCTAssertEqual(actualConfigGeneration, "generation-2")
        }
    }

    func testSaveStrictRejectsSameGenerationStaleRevision() throws {
        let url = temporaryStateURL()
        try RuntimeStateStore(stateFileURL: url).saveStrict(
            slots: [],
            stateMode: .virtual,
            configGeneration: "generation-2",
            revision: 9
        )
        let store = RuntimeStateStore(stateFileURL: url)

        XCTAssertThrowsError(
            try store.saveStrict(
                slots: [],
                stateMode: .virtual,
                configGeneration: "generation-2",
                revision: 10,
                expecting: RuntimeStateWriteExpectation(
                    revision: 8,
                    configGeneration: "generation-2"
                )
            )
        ) { error in
            guard case let RuntimeStateStoreError.staleWriteRejected(
                expectedRevision,
                actualRevision,
                expectedConfigGeneration,
                actualConfigGeneration
            ) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(expectedRevision, 8)
            XCTAssertEqual(actualRevision, 9)
            XCTAssertEqual(expectedConfigGeneration, "generation-2")
            XCTAssertEqual(actualConfigGeneration, "generation-2")
        }
    }

    func testSaveStrictRejectsLegacySlotMetadataInCurrentGeneration() throws {
        let url = temporaryStateURL()
        let store = RuntimeStateStore(stateFileURL: url)

        XCTAssertThrowsError(
            try store.saveStrict(
                slots: [
                    SlotEntry(
                        slot: 1,
                        source: .window,
                        bundleID: "com.example.app",
                        title: "Legacy",
                        profile: "Default",
                        spaceID: 3,
                        displayID: "display-1",
                        windowID: 99
                    ),
                ],
                stateMode: .virtual,
                configGeneration: "generation-1",
                activeLayoutName: "work",
                activeVirtualSpaceID: 3,
                revision: 1
            )
        ) { error in
            guard case let RuntimeStateStoreError.writeFailed(fileURL, reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(fileURL, url)
            XCTAssertTrue(reason.contains("legacy slot metadata cannot be saved"))
        }
    }

    func testSaveStrictDeduplicatesRuntimeManagedEntriesByFingerprint() throws {
        let url = temporaryStateURL()
        let store = RuntimeStateStore(stateFileURL: url)

        try store.saveStrict(
            slots: [
                SlotEntry(
                    layoutName: "default",
                    slot: 101,
                    source: .window,
                    bundleID: "com.apple.finder",
                    definitionFingerprint: "runtimeVirtualWorkspace\u{0}default\u{0}com.apple.finder\u{0}ダウンロード\u{0}AXWindow\u{0}\u{0}",
                    pid: 500,
                    titleMatchKind: .equals,
                    titleMatchValue: "ダウンロード",
                    role: "AXWindow",
                    lastKnownTitle: "ダウンロード",
                    spaceID: 1,
                    nativeSpaceID: 1,
                    displayID: "display-1",
                    windowID: 105590,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 1000, height: 700),
                    visibilityState: .hiddenOffscreen,
                    lastActivatedAt: "2026-03-18T03:03:37.233Z"
                ),
                SlotEntry(
                    layoutName: "default",
                    slot: 104,
                    source: .window,
                    bundleID: "com.apple.finder",
                    definitionFingerprint: "runtimeVirtualWorkspace\u{0}default\u{0}com.apple.finder\u{0}ダウンロード\u{0}AXWindow\u{0}\u{0}",
                    pid: 501,
                    titleMatchKind: .equals,
                    titleMatchValue: "ダウンロード",
                    role: "AXWindow",
                    lastKnownTitle: "ダウンロード",
                    spaceID: 1,
                    nativeSpaceID: 1,
                    displayID: "display-1",
                    windowID: 105730,
                    lastVisibleFrame: ResolvedFrame(x: 20, y: 30, width: 1280, height: 900),
                    visibilityState: .visible,
                    lastActivatedAt: "2026-03-18T03:25:04.496Z"
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "default",
            activeVirtualSpaceID: 1,
            revision: 7
        )

        let state = try store.loadStrict()
        XCTAssertEqual(state.slots.count, 1)
        XCTAssertEqual(state.slots.first?.slot, 101)
        XCTAssertEqual(state.slots.first?.windowID, 105730)
        XCTAssertEqual(state.slots.first?.visibilityState, .visible)
        XCTAssertEqual(state.slots.first?.lastActivatedAt, "2026-03-18T03:25:04.496Z")
        XCTAssertEqual(state.slots.first?.lastVisibleFrame, ResolvedFrame(x: 20, y: 30, width: 1280, height: 900))
    }

    func testSaveStrictKeepsDistinctLayoutManagedEntries() throws {
        let url = temporaryStateURL()
        let store = RuntimeStateStore(stateFileURL: url)

        try store.saveStrict(
            slots: [
                SlotEntry(
                    layoutName: "default",
                    slot: 1,
                    source: .window,
                    bundleID: "org.alacritty",
                    definitionFingerprint: "slot-1",
                    titleMatchKind: .equals,
                    titleMatchValue: "Alacritty",
                    role: "AXWindow",
                    lastKnownTitle: "Alacritty",
                    spaceID: 1,
                    nativeSpaceID: 1,
                    displayID: "display-1",
                    windowID: 10
                ),
                SlotEntry(
                    layoutName: "default",
                    slot: 2,
                    source: .window,
                    bundleID: "org.alacritty",
                    definitionFingerprint: "slot-1",
                    titleMatchKind: .equals,
                    titleMatchValue: "Alacritty",
                    role: "AXWindow",
                    lastKnownTitle: "Alacritty",
                    spaceID: 2,
                    nativeSpaceID: 1,
                    displayID: "display-1",
                    windowID: 11
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "default",
            activeVirtualSpaceID: 1,
            revision: 1
        )

        let state = try store.loadStrict()
        XCTAssertEqual(state.slots.count, 2)
        XCTAssertEqual(state.slots.map(\.slot), [1, 2])
    }

    private func temporaryStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-state-\(UUID().uuidString).json")
    }
}
