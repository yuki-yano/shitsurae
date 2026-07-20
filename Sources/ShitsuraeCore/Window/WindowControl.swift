import CoreGraphics
import Foundation

public enum WindowGeometryMutationResult: Equatable, Sendable {
    case applied
    /// No geometry setter ran, so retrying after a short delay is safe.
    case notAttempted
    /// A setter ran but the requested geometry was rejected or could not be
    /// verified. Do not retry: some apps mutate a window while returning an
    /// AX error.
    case rejected

    public var isApplied: Bool {
        self == .applied
    }

    public var canRetry: Bool {
        self != .rejected
    }
}

/// Side-effecting window operations the engines depend on. The live AX-backed
/// implementation is `LiveWindowControl`; tests inject mocks.
public protocol WindowControl: Sendable {
    func listWindows() -> [WindowSnapshot]
    func listAllWindows() -> [WindowSnapshot]
    /// Full CG inventory with authoritative failure information.
    func windowInventory() -> WindowInventory
    /// Full inventory plus the exact currently focused window identity.
    func focusedWindowObservation() -> WindowObservation
    /// Cheap on-screen check (identity-preserving, no AX traffic) for filtering
    /// candidate lists.
    func onScreenWindowIdentities() -> Set<WindowIdentity>
    /// Whether AX-based window mutations can succeed at all.
    func accessibilityGranted() -> Bool
    func focusedWindow() -> WindowSnapshot?
    func displays() -> [DisplayInfo]

    @discardableResult
    func setWindowFrame(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        frame: ResolvedFrame
    ) -> WindowGeometryMutationResult
    @discardableResult
    func setWindowPosition(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        position: CGPoint
    ) -> WindowGeometryMutationResult
    func setWindowMinimized(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        minimized: Bool
    ) -> WindowInteractionResult
    func focusWindow(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String
    ) -> WindowInteractionResult
    @discardableResult
    func activateApplication(pid: Int, processStartTime: UInt64, bundleID: String) -> Bool
    @discardableResult
    func launchApplication(request: ApplicationLaunchRequest) -> Bool

    func sleep(milliseconds: Int)
}

public extension WindowControl {
    func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000)
    }

    func windowInventory() -> WindowInventory {
        .available(listAllWindows())
    }

    func focusedWindowObservation() -> WindowObservation {
        WindowObservation(
            inventory: windowInventory(),
            focusedIdentity: focusedWindow()?.identity,
            mainIdentity: focusedWindow()?.identity
        )
    }

    func onScreenWindowIdentities() -> Set<WindowIdentity> {
        Set(listWindows().map(\.identity))
    }

    func accessibilityGranted() -> Bool {
        true
    }
}
