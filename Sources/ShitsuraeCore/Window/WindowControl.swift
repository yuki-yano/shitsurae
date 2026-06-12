import CoreGraphics
import Foundation

/// Side-effecting window operations the engines depend on. The live AX-backed
/// implementation is `LiveWindowControl`; tests inject mocks.
public protocol WindowControl: Sendable {
    func listWindows() -> [WindowSnapshot]
    func listAllWindows() -> [WindowSnapshot]
    /// Cheap on-screen check (IDs only, no AX traffic) for filtering
    /// candidate lists.
    func onScreenWindowIDs() -> Set<UInt32>
    func focusedWindow() -> WindowSnapshot?
    func displays() -> [DisplayInfo]

    @discardableResult
    func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool
    @discardableResult
    func setWindowPosition(windowID: UInt32, bundleID: String, position: CGPoint) -> Bool
    func setWindowMinimized(windowID: UInt32, bundleID: String, minimized: Bool) -> WindowInteractionResult
    func focusWindow(windowID: UInt32, bundleID: String) -> WindowInteractionResult
    @discardableResult
    func activateBundle(bundleID: String) -> Bool
    @discardableResult
    func launchApplication(request: ApplicationLaunchRequest) -> Bool

    func sleep(milliseconds: Int)
}

public extension WindowControl {
    func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000)
    }

    func onScreenWindowIDs() -> Set<UInt32> {
        Set(listWindows().map(\.windowID))
    }
}
