import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Workspace state snapshot")
struct WorkspaceStateSnapshotTests {
    private var config: LoadedConfig {
        TestFixtures.loadedConfig(layouts: ["work": TestFixtures.twoSpaceLayout()])
    }

    private func makeEngine(
        windows: [WindowSnapshot]
    ) -> (engine: VirtualSpaceEngine, control: MockWindowControl, stateURL: URL) {
        let control = MockWindowControl(windows: windows, displays: [TestFixtures.display])
        let (store, stateURL) = TestFixtures.tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )
        return (engine, control, stateURL)
    }

    private func standardWindows() -> [WindowSnapshot] {
        [
            TestFixtures.window(
                id: 1,
                bundleID: "com.apple.TextEdit",
                title: "Document",
                isAXBacked: true,
                frontIndex: 0
            ),
            TestFixtures.window(
                id: 2,
                bundleID: "com.apple.Terminal",
                title: "Shell",
                isAXBacked: true,
                frontIndex: 1
            ),
            TestFixtures.window(
                id: 3,
                bundleID: "com.apple.Notes",
                title: "Notes",
                isAXBacked: true,
                frontIndex: 2
            ),
        ]
    }

    @Test func joinsTrackedStateWithOneCoherentLiveObservation() async throws {
        let (engine, control, stateURL) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.setFocusedWindowID(1)
        let inventoryCallsBeforeSnapshot = control.listAllWindowsCallCount

        let snapshot = await engine.workspaceStateSnapshot(config: config)

        #expect(control.listAllWindowsCallCount == inventoryCallsBeforeSnapshot + 1)
        #expect(snapshot.layoutName == "work")
        #expect(snapshot.inventoryAvailability == .available)
        #expect(snapshot.trackedWindowCount == 3)
        #expect(snapshot.boundWindowCount == 3)
        #expect(snapshot.displays == [TestFixtures.display])
        #expect(snapshot.unmanagedWindows.isEmpty)
        #expect(snapshot.workspaces.map(\.spaceID) == [1, 2])
        #expect(snapshot.workspaces.first(where: { $0.spaceID == 1 })?.isActive == true)
        #expect(snapshot.workspaces.first(where: { $0.spaceID == 2 })?.isActive == false)

        let focused = try #require(
            snapshot.workspaces
                .flatMap(\.windows)
                .first(where: { $0.liveWindow?.identity.windowID == 1 })
        )
        #expect(focused.liveWindow?.title == "Document")
        #expect(focused.liveWindow?.isFocused == true)
        #expect(focused.bindingState == .bound)
        #expect(focused.trackedVisibility == .visible)
        #expect(focused.previewFrame == focused.liveWindow?.frame)
        #expect(focused.previewFrameSource == .liveFrame)
        #expect(!focused.hasVisibilityMismatch)
    }

    @Test func reportsPhysicalOffscreenStateAfterWorkspaceSwitch() async throws {
        let (engine, _, stateURL) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        _ = try await engine.switchSpace(to: 2, config: config)

        let snapshot = await engine.workspaceStateSnapshot(config: config)

        #expect(snapshot.hiddenWindowCount == 2)
        #expect(snapshot.workspaces.first(where: { $0.spaceID == 2 })?.isActive == true)
        let inactiveWindows = try #require(
            snapshot.workspaces.first(where: { $0.spaceID == 1 })?.windows
        )
        #expect(inactiveWindows.allSatisfy { $0.trackedVisibility == .hiddenOffscreen })
        #expect(inactiveWindows.allSatisfy {
            $0.liveWindow?.actualVisibility == .hiddenOffscreen
        })
        #expect(inactiveWindows.allSatisfy { $0.previewFrameSource == .lastVisibleFrame })
        #expect(inactiveWindows.allSatisfy { window in
            window.previewFrame.map {
                !VisibilityPlanner.isHiddenWindowFrame(
                    frame: $0,
                    displays: snapshot.displays
                )
            } == true
        })
        #expect(inactiveWindows.allSatisfy { !$0.hasVisibilityMismatch })
    }

    @Test func distinguishesMissingBindingsFromUnmanagedLiveWindows() async throws {
        let (engine, control, stateURL) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.removeWindow(3)
        control.addWindow(TestFixtures.window(
            id: 9,
            bundleID: "com.apple.Safari",
            title: "Unmanaged",
            isAXBacked: true,
            frontIndex: 0
        ))

        let snapshot = await engine.workspaceStateSnapshot(config: config)

        let notes = try #require(
            snapshot.workspaces
                .flatMap(\.windows)
                .first(where: { $0.bundleID == "com.apple.Notes" })
        )
        #expect(notes.bindingState == .noCandidate)
        #expect(notes.liveWindow == nil)
        #expect(snapshot.unmanagedWindows.count == 1)
        #expect(snapshot.unmanagedWindows[0].liveWindow.identity.windowID == 9)
        #expect(snapshot.unmanagedWindows[0].reason == .unassigned)
    }

    @Test func failsClosedWhenLiveInventoryIsUnavailable() async throws {
        let (engine, control, stateURL) = makeEngine(windows: standardWindows())
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }
        try await engine.bootstrapState(layoutName: "work", activeSpaceID: 1, config: config)
        control.windowInventoryAvailable = false

        let snapshot = await engine.workspaceStateSnapshot(config: config)

        #expect(snapshot.inventoryAvailability == .unavailable)
        #expect(snapshot.boundWindowCount == 0)
        #expect(snapshot.unmanagedWindows.isEmpty)
        #expect(snapshot.workspaces.flatMap(\.windows).allSatisfy {
            $0.bindingState == .inventoryUnavailable && $0.liveWindow == nil
        })
    }
}
