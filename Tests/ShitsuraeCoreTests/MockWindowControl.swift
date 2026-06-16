import CoreGraphics
import Foundation
@testable import ShitsuraeCore

/// In-memory WindowControl: maintains a mutable window list and applies
/// frame/position/minimize mutations to it, so convergence checks see the
/// effects of earlier calls — like the real system, minus the async races.
final class MockWindowControl: WindowControl, @unchecked Sendable {
    private let lock = NSLock()
    private var windowsByID: [UInt32: WindowSnapshot]
    private let displayList: [DisplayInfo]

    var failFrameWindowIDs: Set<UInt32> = []
    var failPositionWindowIDs: Set<UInt32> = []
    var failUnminimizeWindowIDs: Set<UInt32> = []
    var failFocusWindowIDs: Set<UInt32> = []
    private(set) var focusedWindowIDs: [UInt32] = []
    private(set) var activatedBundles: [String] = []
    private(set) var launchedRequests: [ApplicationLaunchRequest] = []
    private(set) var sleptMilliseconds: [Int] = []

    init(windows: [WindowSnapshot], displays: [DisplayInfo]) {
        self.windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        self.displayList = displays
    }

    func currentWindows() -> [WindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return windowsByID.values.sorted { $0.windowID < $1.windowID }
    }

    func window(_ id: UInt32) -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return windowsByID[id]
    }

    /// Simulates a window closing (app quit etc.).
    func removeWindow(_ id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        windowsByID.removeValue(forKey: id)
    }

    /// When set, restricts what onScreenWindowIDs() reports (simulates
    /// windows on other native Spaces / invisible helper windows).
    var onScreenWindowIDsOverride: Set<UInt32>?

    func listWindows() -> [WindowSnapshot] {
        currentWindows()
    }

    func listAllWindows() -> [WindowSnapshot] {
        currentWindows()
    }

    func onScreenWindowIDs() -> Set<UInt32> {
        lock.lock()
        defer { lock.unlock() }
        return onScreenWindowIDsOverride ?? Set(windowsByID.keys)
    }

    func focusedWindow() -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = focusedWindowIDs.last else { return nil }
        return windowsByID[id]
    }

    func displays() -> [DisplayInfo] {
        displayList
    }

    func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failFrameWindowIDs.contains(windowID), let window = windowsByID[windowID] else {
            return false
        }
        windowsByID[windowID] = window.withFrame(frame)
        return true
    }

    func setWindowPosition(windowID: UInt32, bundleID: String, position: CGPoint) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !failPositionWindowIDs.contains(windowID), let window = windowsByID[windowID] else {
            return false
        }
        windowsByID[windowID] = window.withFrame(
            ResolvedFrame(x: position.x, y: position.y, width: window.frame.width, height: window.frame.height)
        )
        return true
    }

    func setWindowMinimized(windowID: UInt32, bundleID: String, minimized: Bool) -> WindowInteractionResult {
        lock.lock()
        defer { lock.unlock() }
        guard let window = windowsByID[windowID] else {
            return .failed
        }
        if !minimized, failUnminimizeWindowIDs.contains(windowID) {
            return .failed
        }
        windowsByID[windowID] = window.withMinimized(minimized)
        return .success
    }

    func focusWindow(windowID: UInt32, bundleID: String) -> WindowInteractionResult {
        lock.lock()
        defer { lock.unlock() }
        guard !failFocusWindowIDs.contains(windowID), windowsByID[windowID] != nil else {
            return .failed
        }
        focusedWindowIDs.append(windowID)
        return .success
    }

    func activateBundle(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        activatedBundles.append(bundleID)
        return true
    }

    func launchApplication(request: ApplicationLaunchRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        launchedRequests.append(request)
        return true
    }

    func sleep(milliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        sleptMilliseconds.append(milliseconds)
    }
}

extension WindowSnapshot {
    func withFrame(_ newFrame: ResolvedFrame) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: pid,
            title: title,
            role: role,
            subrole: subrole,
            minimized: minimized,
            hidden: hidden,
            frame: newFrame,
            displayID: displayID,
            profileDirectory: profileDirectory,
            isFullscreen: isFullscreen,
            frontIndex: frontIndex
        )
    }

    func withMinimized(_ newValue: Bool) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: pid,
            title: title,
            role: role,
            subrole: subrole,
            minimized: newValue,
            hidden: hidden,
            frame: frame,
            displayID: displayID,
            profileDirectory: profileDirectory,
            isFullscreen: isFullscreen,
            frontIndex: frontIndex
        )
    }
}

enum TestFixtures {
    static let display = DisplayInfo(
        id: "uuid-main",
        width: 2880,
        height: 1800,
        scale: 2,
        isPrimary: true,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )

    static func window(
        id: UInt32,
        bundleID: String,
        title: String = "win",
        frame: ResolvedFrame = ResolvedFrame(x: 10, y: 10, width: 700, height: 400),
        role: String = "AXWindow",
        subrole: String? = nil,
        minimized: Bool = false,
        frontIndex: Int = 0
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: id,
            bundleID: bundleID,
            pid: Int(id) * 10,
            title: title,
            role: role,
            subrole: subrole,
            minimized: minimized,
            hidden: false,
            frame: frame,
            displayID: display.id,
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }

    static func frameDef(_ x: String, _ y: String, _ w: String, _ h: String) -> FrameDefinition {
        FrameDefinition(
            x: .expression(x),
            y: .expression(y),
            width: .expression(w),
            height: .expression(h)
        )
    }

    /// Two-space layout: space1 = TextEdit + Terminal, space2 = Notes.
    static func twoSpaceLayout() -> LayoutDefinition {
        LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 1),
            spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                        slot: 1,
                        launch: false,
                        frame: frameDef("0%", "0%", "50%", "100%")
                    ),
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.Terminal"),
                        slot: 2,
                        launch: false,
                        frame: frameDef("50%", "0%", "50%", "100%")
                    ),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    WindowDefinition(
                        match: WindowMatchRule(bundleID: "com.apple.Notes"),
                        slot: 1,
                        launch: false,
                        frame: frameDef("0%", "0%", "100%", "100%")
                    ),
                ]),
            ]
        )
    }

    static func loadedConfig(layouts: [String: LayoutDefinition]) -> LoadedConfig {
        LoadedConfig(
            config: ShitsuraeConfig(layouts: layouts),
            configFiles: [],
            directoryURL: URL(fileURLWithPath: "/tmp"),
            configGeneration: String(repeating: "a", count: 64)
        )
    }

    static func tempStateStore() -> (RuntimeStateStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-state-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("runtime-state.json")
        return (RuntimeStateStore(stateFileURL: url), url)
    }

    static func nullLogger() -> ShitsuraeLogger {
        ShitsuraeLogger(
            logFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("shitsurae-test-\(UUID().uuidString).log")
        )
    }
}
