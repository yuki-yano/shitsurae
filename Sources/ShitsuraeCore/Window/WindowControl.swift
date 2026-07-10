import CoreGraphics
import Foundation

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
    ) -> Bool
    @discardableResult
    func setWindowPosition(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        position: CGPoint
    ) -> Bool
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
            focusedIdentity: focusedWindow()?.identity
        )
    }

    func onScreenWindowIdentities() -> Set<WindowIdentity> {
        Set(listWindows().map(\.identity))
    }

    func accessibilityGranted() -> Bool {
        true
    }
}
