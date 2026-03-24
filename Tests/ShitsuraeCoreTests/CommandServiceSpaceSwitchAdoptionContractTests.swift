import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceSpaceSwitchAdoptionContractTests: CommandServiceContractTestCase {
    // MARK: - Untracked Window Adoption

    func testSpaceSwitchAdoptsUntrackedWindowsIntoCurrentWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var positionCalls: [(UInt32, CGPoint)] = []
        var onScreenWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
            // Untracked window — should be adopted into workspace 1
            Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 2),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { onScreenWindows },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                guard let index = onScreenWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = onScreenWindows[index]
                onScreenWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: ResolvedFrame(
                        x: position.x,
                        y: position.y,
                        width: existing.frame.width,
                        height: existing.frame.height
                    ),
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { onScreenWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)

        let finderEntry = persisted.slots.first(where: { $0.windowID == 900 })
        XCTAssertNotNil(finderEntry)
        XCTAssertEqual(finderEntry?.spaceID, 1)
        XCTAssertEqual(finderEntry?.bundleID, "com.apple.Finder")
        XCTAssertGreaterThanOrEqual(finderEntry?.slot ?? 0, CommandService.untrackedSlotOffset)
        XCTAssertTrue(positionCalls.contains(where: { $0.0 == 900 }))
        XCTAssertEqual(finderEntry?.visibilityState, .hiddenOffscreen)
    }

    func testSpaceSwitchDoesNotAdoptMinimizedOrTinyWindows() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 2
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 901, bundleID: "com.apple.Preview", title: "Image", spaceID: 7, frontIndex: 1, minimized: true),
                    WindowSnapshot(
                        windowID: 902, bundleID: "com.apple.SystemUIServer", pid: 100,
                        title: "", role: "AXMenuBarItem", subrole: nil,
                        minimized: false, hidden: false,
                        frame: ResolvedFrame(x: 0, y: 0, width: 30, height: 22),
                        spaceID: 7, displayID: "display-a", isFullscreen: false, frontIndex: 2
                    ),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 901 }))
        XCTAssertNil(persisted.slots.first(where: { $0.windowID == 902 }))
    }

    func testSpaceSwitchAdoptedWindowShowsWhenSwitchingBackToItsWorkspace() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    lastHiddenFrame: ResolvedFrame(x: 5000, y: 0, width: 800, height: 977),
                    visibilityState: .hiddenOffscreen
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 800, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Finder",
                    definitionFingerprint: "runtime-finder",
                    lastKnownTitle: "Desktop",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 900,
                    lastVisibleFrame: ResolvedFrame(x: 200, y: 100, width: 600, height: 400),
                    lastHiddenFrame: ResolvedFrame(x: 5000, y: 100, width: 600, height: 400),
                    visibilityState: .hiddenOffscreen
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 2,
            revision: 5
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var liveWindows = [
            Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
            Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
            Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 2),
        ]
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                guard let index = liveWindows.firstIndex(where: { $0.windowID == windowID }) else {
                    return false
                }
                let existing = liveWindows[index]
                liveWindows[index] = WindowSnapshot(
                    windowID: existing.windowID,
                    bundleID: existing.bundleID,
                    pid: existing.pid,
                    title: existing.title,
                    role: existing.role,
                    subrole: existing.subrole,
                    minimized: existing.minimized,
                    hidden: existing.hidden,
                    frame: frame,
                    spaceID: existing.spaceID,
                    displayID: existing.displayID,
                    profileDirectory: existing.profileDirectory,
                    isFullscreen: existing.isFullscreen,
                    frontIndex: existing.frontIndex
                )
                return true
            },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: { liveWindows }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 1, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 1)
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 800 }))
        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 900 }))
        XCTAssertEqual(persisted.slots.first(where: { $0.windowID == 900 })?.visibilityState, .visible)
    }

    func testUntrackedWindowSlotIsNotMatchedByFocusBySlot() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Finder",
                    definitionFingerprint: "runtime-finder",
                    lastKnownTitle: "Desktop",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 900
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1
        )

        var focusedTargets: [(UInt32, String)] = []
        var activatedBundleIDs: [String] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 1),
                ]
            },
            focusedWindow: { nil },
            activateBundle: { bundleID in
                activatedBundleIDs.append(bundleID)
                return true
            },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            focusWindow: { windowID, bundleID in
                focusedTargets.append((windowID, bundleID))
                return .success
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result1 = service.focus(slot: 1)
        XCTAssertEqual(result1.exitCode, 0)
        XCTAssertEqual(focusedTargets.map(\.0), [800])

        focusedTargets.removeAll()
        activatedBundleIDs.removeAll()
        _ = service.focus(slot: 2)
        XCTAssertTrue(focusedTargets.isEmpty || focusedTargets.map(\.0) != [900])
    }

    // MARK: - Deduplication: same window resolved by both target and other

    func testSpaceSwitchDeduplicatesTargetAndOtherResolvingToSameWindow() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: nil,
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: nil,
                    displayID: nil,
                    windowID: nil,
                    lastVisibleFrame: nil,
                    visibilityState: nil
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 100,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "runtime-notes",
                    lastKnownTitle: "Notes",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 801,
                    lastVisibleFrame: ResolvedFrame(x: 400, y: 0, width: 400, height: 977),
                    visibilityState: .visible
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        var frameCalls: [(UInt32, ResolvedFrame)] = []
        var positionCalls: [(UInt32, CGPoint)] = []
        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                ]
            },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            setWindowFrame: { windowID, _, frame in
                frameCalls.append((windowID, frame))
                return true
            },
            setWindowPosition: { windowID, _, position in
                positionCalls.append((windowID, position))
                return true
            },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 801, bundleID: "com.apple.Notes", title: "Notes", spaceID: 7, frontIndex: 1),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        XCTAssertTrue(frameCalls.contains(where: { $0.0 == 801 }), "Notes should be shown as target")
        XCTAssertFalse(positionCalls.contains(where: { $0.0 == 801 }), "Notes should NOT be hidden — dedup should prevent it")

        let persisted = stateStore.load()
        XCTAssertEqual(persisted.activeVirtualSpaceID, 2)
    }

    // MARK: - Adoption adopts new windows even when unresolved config entries exist

    func testAdoptionAdoptsNewWindowEvenWhenUnresolvedConfigEntryExists() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let stateStore = RuntimeStateStore(stateFileURL: workspace.stateFileURL)
        stateStore.save(
            slots: [
                SlotEntry(
                    layoutName: "work",
                    slot: 1,
                    source: .window,
                    bundleID: "com.apple.TextEdit",
                    definitionFingerprint: "slot-1",
                    lastKnownTitle: "Editor",
                    profile: nil,
                    spaceID: 1,
                    nativeSpaceID: 7,
                    displayID: "display-a",
                    windowID: 800,
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 977),
                    visibilityState: .visible
                ),
                SlotEntry(
                    layoutName: "work",
                    slot: 2,
                    source: .window,
                    bundleID: "com.apple.Notes",
                    definitionFingerprint: "slot-2",
                    lastKnownTitle: nil,
                    profile: nil,
                    spaceID: 2,
                    nativeSpaceID: nil,
                    displayID: nil,
                    windowID: nil,
                    lastVisibleFrame: nil,
                    visibilityState: nil
                ),
            ],
            stateMode: .virtual,
            configGeneration: "generation-1",
            activeLayoutName: "work",
            activeVirtualSpaceID: 1,
            revision: 3
        )

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 1),
                ]
            },
            focusedWindow: {
                Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0)
            },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: {
                [
                    DisplayInfo(
                        id: "display-a",
                        width: 3200,
                        height: 2000,
                        scale: 2.0,
                        isPrimary: true,
                        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                        visibleFrame: CGRect(x: 0, y: 23, width: 1600, height: 977)
                    ),
                ]
            },
            runProcess: { _, _ in (0, "") },
            focusWindow: { _, _ in .success },
            setWindowFrame: { _, _, _ in true },
            setWindowPosition: { _, _, _ in true },
            spaces: {
                [SpaceInfo(spaceID: 7, displayID: "display-a", isVisible: true, isNativeFullscreen: false)]
            },
            listWindowsOnAllSpaces: {
                [
                    Self.window(windowID: 800, bundleID: "com.apple.TextEdit", title: "Editor", spaceID: 7, frontIndex: 0),
                    Self.window(windowID: 900, bundleID: "com.apple.Finder", title: "Desktop", spaceID: 7, frontIndex: 1),
                ]
            }
        )
        let service = workspace.makeService(stateStore: stateStore, runtimeHooks: runtimeHooks)

        let result = service.spaceSwitch(spaceID: 2, json: true, reconcile: false)
        XCTAssertEqual(result.exitCode, 0)

        let persisted = stateStore.load()
        let finderEntry = persisted.slots.first(where: { $0.windowID == 900 })
        XCTAssertNotNil(finderEntry, "Finder should be adopted")
        XCTAssertEqual(finderEntry?.spaceID, 1)
        XCTAssertEqual(finderEntry?.bundleID, "com.apple.Finder")
    }
}
