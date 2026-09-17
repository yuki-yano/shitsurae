import CoreGraphics
import Foundation
@testable import ShitsuraeCore

/// In-memory WindowControl: maintains a mutable window list and applies
/// frame/position/minimize mutations to it, so convergence checks see the
/// effects of earlier calls — like the real system, minus the async races.
final class MockWindowControl: WindowControl, @unchecked Sendable {
    private let lock = NSLock()
    private var windowsByID: [UInt32: WindowSnapshot]
    private var displayList: [DisplayInfo]

    var accessibilityAvailable = true
    var failFrameWindowIDs: Set<UInt32> = []
    var failPositionWindowIDs: Set<UInt32> = []
    /// Rejects frame requests larger than a window-specific limit. This models
    /// macOS constraining a window after its display resolution shrinks.
    var maximumAcceptedFrameSizeByWindowID: [UInt32: CGSize] = [:]
    /// Safe transient failures that occur before a geometry setter runs.
    var notAttemptedFrameAttemptsRemainingByWindowID: [UInt32: Int] = [:]
    var notAttemptedPositionAttemptsRemainingByWindowID: [UInt32: Int] = [:]
    /// Models an app (e.g. Chrome's remote-debug popup) that refuses geometry
    /// writes and keeps the window pinned at its own frame: every set attempt
    /// forces the window back to this frame and reports failure, so the window
    /// can never match the desired *or* the rolled-back state — it stays
    /// unconverged forever.
    var pinnedFrameWindowIDs: [UInt32: ResolvedFrame] = [:]
    /// Models an accepted asynchronous write that has not physically landed
    /// yet. Convergence may retry it, which is useful for focus-settling races.
    var acceptedButPinnedFrameWindowIDs: [UInt32: ResolvedFrame] = [:]
    var failMinimizeWindowIDs: Set<UInt32> = []
    var failUnminimizeWindowIDs: Set<UInt32> = []
    var failFocusWindowIDs: Set<UInt32> = []
    var failFocusAttemptsRemainingByWindowID: [UInt32: Int] = [:]
    /// When set, every setWindowPosition *attempt* (whether or not the write
    /// succeeds) re-points key focus to this window — models the real macOS
    /// race where windows settling during convergence change key focus before
    /// the engine performs its final focus decision.
    var stealFocusOnPositionAttempt: UInt32?
    /// Simulates a user selecting a different window while arrange geometry
    /// is in progress. The identity is changed under the same lock as the
    /// frame write so the test has no scheduling race.
    var userFocusOnFrameMutationAttempt: UInt32?
    private(set) var focusedWindowIDs: [UInt32] = []
    private var currentFocusedWindowIdentity: WindowIdentity?
    private var currentFrontmostWindowIdentity: WindowIdentity?
    private var mainWindowIdentity: WindowIdentity?
    private(set) var activatedBundles: [String] = []
    /// Every setWindowFrame/setWindowPosition attempt, successful or not —
    /// lets tests assert that unmanageable windows are never even targeted.
    private(set) var frameMutationAttemptWindowIDs: [UInt32] = []
    private(set) var setFrameAttemptWindowIDs: [UInt32] = []
    private(set) var setPositionAttemptWindowIDs: [UInt32] = []
    private(set) var minimizeAttempts: [(windowID: UInt32, minimized: Bool)] = []
    private(set) var launchedRequests: [ApplicationLaunchRequest] = []
    private(set) var sleptMilliseconds: [Int] = []
    var onFrameMutationAttempt: (() -> Void)?
    var onMinimizeAttempt: (() -> Void)?
    var onFocusAttempt: (() -> Void)?

    init(windows: [WindowSnapshot], displays: [DisplayInfo]) {
        self.windowsByID = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0) })
        self.displayList = displays
    }

    func accessibilityGranted() -> Bool {
        accessibilityAvailable
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

    func setFocusedWindowID(_ id: UInt32?) {
        lock.lock()
        defer { lock.unlock() }
        if let id {
            focusedWindowIDs.append(id)
            currentFocusedWindowIdentity = windowsByID[id]?.identity
            currentFrontmostWindowIdentity = currentFocusedWindowIdentity
            mainWindowIdentity = currentFocusedWindowIdentity
        } else {
            focusedWindowIDs.removeAll()
            currentFocusedWindowIdentity = nil
            currentFrontmostWindowIdentity = nil
            mainWindowIdentity = nil
        }
    }

    func setFrontmostWindowID(_ id: UInt32?) {
        lock.lock()
        defer { lock.unlock() }
        currentFrontmostWindowIdentity = id.flatMap { windowsByID[$0]?.identity }
    }

    func setMainWindowID(_ id: UInt32?) {
        lock.lock()
        defer { lock.unlock() }
        mainWindowIdentity = id.flatMap { windowsByID[$0]?.identity }
    }

    /// Simulates a window closing (app quit etc.).
    func removeWindow(_ id: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        windowsByID.removeValue(forKey: id)
    }

    /// Simulates a window appearing (app launch / new window).
    func addWindow(_ window: WindowSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        windowsByID[window.windowID] = window
    }

    /// When set, restricts what onScreenWindowIdentities() reports (simulates
    /// windows on other native Spaces / invisible helper windows).
    var onScreenWindowIdentitiesOverride: Set<WindowIdentity>?
    var windowInventoryAvailable = true
    var liveWindowHandlesOverride: Set<WindowHandle>?
    private(set) var listAllWindowsCallCount = 0
    private(set) var targetedWindowInventoryCallCount = 0
    private(set) var targetedWindowInventoryIdentitySets: [Set<WindowIdentity>] = []

    /// When non-empty, each listAllWindows() call consumes the next snapshot
    /// (replacing the whole window state) — lets tests change the enumeration
    /// result between successive engine passes to model AX dropouts and
    /// windows closing mid-flow. The state set by the last consumed snapshot
    /// persists once the queue is exhausted.
    var windowListSequence: [[WindowSnapshot]] = []
    var onInventoryRead: (() -> Void)?

    func listWindows() -> [WindowSnapshot] {
        currentWindows()
    }

    func listAllWindows() -> [WindowSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        listAllWindowsCallCount += 1
        if !windowListSequence.isEmpty {
            let next = windowListSequence.removeFirst()
            windowsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.windowID, $0) })
        }
        return windowsByID.values.sorted { $0.windowID < $1.windowID }
    }

    func windowInventory() -> WindowInventory {
        onInventoryRead?()
        guard windowInventoryAvailable else { return .unavailable }
        let windows = listAllWindows()
        return .available(windows, liveWindowHandles: liveWindowHandlesOverride)
    }

    func windowInventory(identities: Set<WindowIdentity>) -> WindowInventory {
        lock.lock()
        defer { lock.unlock() }
        targetedWindowInventoryCallCount += 1
        targetedWindowInventoryIdentitySets.append(identities)
        if !windowListSequence.isEmpty {
            let next = windowListSequence.removeFirst()
            windowsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.windowID, $0) })
        }
        guard windowInventoryAvailable else { return .unavailable }
        let targetWindowIDs = Set(identities.map(\.windowID))
        let windows = windowsByID.values
            .filter { targetWindowIDs.contains($0.windowID) }
            .sorted { $0.windowID < $1.windowID }
        let handles = liveWindowHandlesOverride.map { handles in
            Set(handles.filter { targetWindowIDs.contains($0.windowID) })
        }
        return .available(windows, liveWindowHandles: handles)
    }

    func focusedWindowObservation() -> WindowObservation {
        lock.lock()
        defer { lock.unlock() }
        listAllWindowsCallCount += 1
        if !windowListSequence.isEmpty {
            let next = windowListSequence.removeFirst()
            windowsByID = Dictionary(uniqueKeysWithValues: next.map { ($0.windowID, $0) })
        }
        let inventory: WindowInventory = windowInventoryAvailable
            ? .available(
                windowsByID.values.sorted { $0.windowID < $1.windowID },
                liveWindowHandles: liveWindowHandlesOverride
            )
            : .unavailable
        let focusedIdentity = currentFocusedWindowIdentity.flatMap { identity in
            windowsByID[identity.windowID]?.identity == identity ? identity : nil
        }
        let mainIdentity = mainWindowIdentity.flatMap { identity in
            windowsByID[identity.windowID]?.identity == identity ? identity : nil
        }
        return WindowObservation(
            inventory: inventory,
            focusedIdentity: focusedIdentity,
            mainIdentity: mainIdentity
        )
    }

    func onScreenWindowIdentities() -> Set<WindowIdentity> {
        lock.lock()
        defer { lock.unlock() }
        let windows = windowsByID.values.filter { window in
            if let identities = onScreenWindowIdentitiesOverride {
                return identities.contains(window.identity)
            }
            return true
        }
        return Set(windows.map(\.identity))
    }

    func focusedWindow() -> WindowSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = currentFocusedWindowIdentity,
              let window = windowsByID[identity.windowID],
              window.identity == identity
        else {
            return nil
        }
        return window
    }

    func focusedWindowIdentity() -> WindowIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = currentFocusedWindowIdentity,
              windowsByID[identity.windowID]?.identity == identity
        else {
            return nil
        }
        return identity
    }

    func frontmostWindowIdentity() -> WindowIdentity? {
        lock.lock()
        defer { lock.unlock() }
        guard let identity = currentFrontmostWindowIdentity,
              windowsByID[identity.windowID]?.identity == identity
        else {
            return nil
        }
        return identity
    }

    func displays() -> [DisplayInfo] {
        lock.lock()
        defer { lock.unlock() }
        return displayList
    }

    /// Simulates display connect/disconnect (and reconnects that change the
    /// display UUID) for multi-display workspace tests.
    func setDisplays(_ displays: [DisplayInfo]) {
        lock.lock()
        defer { lock.unlock() }
        displayList = displays
    }

    func setWindowFrame(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        frame: ResolvedFrame
    ) -> WindowGeometryMutationResult {
        lock.lock()
        defer { lock.unlock() }
        frameMutationAttemptWindowIDs.append(windowID)
        setFrameAttemptWindowIDs.append(windowID)
        onFrameMutationAttempt?()
        if let focusedID = userFocusOnFrameMutationAttempt {
            currentFocusedWindowIdentity = windowsByID[focusedID]?.identity
            currentFrontmostWindowIdentity = currentFocusedWindowIdentity
            mainWindowIdentity = currentFocusedWindowIdentity
        }
        guard let window = windowsByID[windowID],
              window.pid == pid,
              window.processStartTime == processStartTime,
              window.bundleID == bundleID
        else {
            return .notAttempted
        }
        if let remaining = notAttemptedFrameAttemptsRemainingByWindowID[windowID], remaining > 0 {
            notAttemptedFrameAttemptsRemainingByWindowID[windowID] = remaining - 1
            return .notAttempted
        }
        if let pinned = acceptedButPinnedFrameWindowIDs[windowID] {
            windowsByID[windowID] = window.withFrame(pinned)
            return .applied
        }
        if let pinned = pinnedFrameWindowIDs[windowID] {
            windowsByID[windowID] = window.withFrame(pinned)
            return .rejected
        }
        if let maximumSize = maximumAcceptedFrameSizeByWindowID[windowID],
           (frame.width > maximumSize.width || frame.height > maximumSize.height)
        {
            return .rejected
        }
        guard !failFrameWindowIDs.contains(windowID) else {
            return .rejected
        }
        windowsByID[windowID] = window.withFrame(frame)
        return .applied
    }

    func setWindowPosition(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        position: CGPoint
    ) -> WindowGeometryMutationResult {
        lock.lock()
        defer { lock.unlock() }
        frameMutationAttemptWindowIDs.append(windowID)
        setPositionAttemptWindowIDs.append(windowID)
        onFrameMutationAttempt?()
        guard let window = windowsByID[windowID],
              window.pid == pid,
              window.processStartTime == processStartTime,
              window.bundleID == bundleID
        else {
            return .notAttempted
        }
        if let remaining = notAttemptedPositionAttemptsRemainingByWindowID[windowID], remaining > 0 {
            notAttemptedPositionAttemptsRemainingByWindowID[windowID] = remaining - 1
            return .notAttempted
        }
        if let thief = stealFocusOnPositionAttempt {
            focusedWindowIDs.append(thief)
            currentFocusedWindowIdentity = windowsByID[thief]?.identity
            currentFrontmostWindowIdentity = currentFocusedWindowIdentity
        }
        if let pinned = acceptedButPinnedFrameWindowIDs[windowID] {
            windowsByID[windowID] = window.withFrame(pinned)
            return .applied
        }
        if let pinned = pinnedFrameWindowIDs[windowID] {
            windowsByID[windowID] = window.withFrame(pinned)
            return .rejected
        }
        guard !failPositionWindowIDs.contains(windowID) else {
            return .rejected
        }
        windowsByID[windowID] = window.withFrame(
            ResolvedFrame(x: position.x, y: position.y, width: window.frame.width, height: window.frame.height)
        )
        return .applied
    }

    func setWindowMinimized(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        minimized: Bool
    ) -> WindowInteractionResult {
        onMinimizeAttempt?()
        lock.lock()
        defer { lock.unlock() }
        minimizeAttempts.append((windowID: windowID, minimized: minimized))
        guard let window = windowsByID[windowID],
              window.pid == pid,
              window.processStartTime == processStartTime,
              window.bundleID == bundleID
        else {
            return .failed
        }
        if minimized, failMinimizeWindowIDs.contains(windowID) {
            return .failed
        }
        if !minimized, failUnminimizeWindowIDs.contains(windowID) {
            return .failed
        }
        windowsByID[windowID] = window.withMinimized(minimized)
        return .success
    }

    func focusWindow(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String
    ) -> WindowInteractionResult {
        onFocusAttempt?()
        lock.lock()
        defer { lock.unlock() }
        guard let window = windowsByID[windowID],
              window.pid == pid,
              window.processStartTime == processStartTime,
              window.bundleID == bundleID
        else {
            return .failed
        }
        if let remaining = failFocusAttemptsRemainingByWindowID[windowID], remaining > 0 {
            failFocusAttemptsRemainingByWindowID[windowID] = remaining - 1
            return .failed
        }
        guard !failFocusWindowIDs.contains(windowID) else {
            return .failed
        }
        focusedWindowIDs.append(windowID)
        currentFocusedWindowIdentity = window.identity
        currentFrontmostWindowIdentity = window.identity
        return .success
    }

    func activateApplication(pid: Int, processStartTime: UInt64, bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard windowsByID.values.contains(where: {
            $0.pid == pid
                && $0.processStartTime == processStartTime
                && $0.bundleID == bundleID
        }) else {
            return false
        }
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
    func withAXBacked(_ newValue: Bool) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: pid,
            processStartTime: processStartTime,
            title: title,
            role: role,
            subrole: subrole,
            modal: modal,
            geometryBlocked: geometryBlocked,
            isAXBacked: newValue,
            minimized: minimized,
            hidden: hidden,
            frame: frame,
            displayID: displayID,
            profileDirectory: profileDirectory,
            isFullscreen: isFullscreen,
            frontIndex: frontIndex
        )
    }

    func withFrame(_ newFrame: ResolvedFrame) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: pid,
            processStartTime: processStartTime,
            title: title,
            role: role,
            subrole: subrole,
            modal: modal,
            geometryBlocked: geometryBlocked,
            isAXBacked: isAXBacked,
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
            processStartTime: processStartTime,
            title: title,
            role: role,
            subrole: subrole,
            modal: modal,
            geometryBlocked: geometryBlocked,
            isAXBacked: isAXBacked,
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

    static func secondaryDisplay(id: String = "uuid-sub") -> DisplayInfo {
        DisplayInfo(
            id: id,
            width: 2560,
            height: 1440,
            scale: 2,
            isPrimary: false,
            frame: CGRect(x: 1440, y: 0, width: 1280, height: 720),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1280, height: 720)
        )
    }

    static func window(
        id: UInt32,
        bundleID: String,
        pid: Int? = nil,
        processStartTime: UInt64? = nil,
        title: String = "win",
        frame: ResolvedFrame = ResolvedFrame(x: 10, y: 10, width: 700, height: 400),
        role: String? = "AXWindow",
        subrole: String? = "AXStandardWindow",
        modal: Bool? = false,
        isApplicationMainWindow: Bool = false,
        geometryBlocked: Bool = false,
        isAXBacked: Bool,
        minimized: Bool = false,
        isFullscreen: Bool = false,
        frontIndex: Int = 0,
        displayID: String? = nil
    ) -> WindowSnapshot {
        let resolvedPID = pid ?? Int(id) * 10
        return WindowSnapshot(
            windowID: id,
            bundleID: bundleID,
            pid: resolvedPID,
            processStartTime: processStartTime ?? UInt64(resolvedPID) * 1_000_000,
            title: title,
            role: role,
            subrole: subrole,
            modal: modal,
            isApplicationMainWindow: isApplicationMainWindow,
            geometryBlocked: geometryBlocked,
            isAXBacked: isAXBacked,
            minimized: minimized,
            hidden: false,
            frame: frame,
            displayID: displayID ?? display.id,
            isFullscreen: isFullscreen,
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

    static func loadedConfig(
        layouts: [String: LayoutDefinition],
        layoutSets: [String: LayoutSetDefinition] = [:],
        ignore: IgnoreDefinition? = nil,
        monitors: MonitorsDefinition = MonitorsDefinition([
            "main": MonitorTargetDefinition(primary: true),
            "calendar": MonitorTargetDefinition(width: 2560, height: 1440),
        ])
    ) -> LoadedConfig {
        LoadedConfig(
            config: ShitsuraeConfig(
                ignore: ignore,
                monitors: monitors,
                layouts: layouts,
                layoutSets: layoutSets
            ),
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
