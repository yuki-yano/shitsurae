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
    func applyingBudget(_ budget: WindowInteractionBudget?) -> any WindowControl
    func listWindows() -> [WindowSnapshot]
    func listAllWindows() -> [WindowSnapshot]
    /// Full CG inventory with authoritative failure information.
    func windowInventory() -> WindowInventory
    /// Authoritative inventory limited to the requested concrete windows.
    /// Implementations must retain handle-reuse and unknown-liveness evidence
    /// for those identities without enumerating unrelated applications.
    func windowInventory(identities: Set<WindowIdentity>) -> WindowInventory
    /// Full inventory plus the exact currently focused window identity.
    func focusedWindowObservation() -> WindowObservation
    /// Exact focused identity from the frontmost process without a full
    /// window inventory. Used only when callers need to verify focus after
    /// they already hold the authoritative inventory for their mutation.
    func focusedWindowIdentity() -> WindowIdentity?
    /// Cheap frontmost layer-0 identity derived from CG z-order. This is not
    /// an AX focus observation; callers may use it only to detect that the
    /// user moved to another window while a mutation was in flight.
    func frontmostWindowIdentity() -> WindowIdentity?
    /// Cheap on-screen check (identity-preserving, no AX traffic) for filtering
    /// candidate lists.
    func onScreenWindowIdentities() -> Set<WindowIdentity>
    /// Whether AX-based window mutations can succeed at all.
    func accessibilityGranted() -> Bool
    /// Delay once after a batch of asynchronous AX geometry writes before the
    /// first physical-state verification. Test controls apply synchronously.
    func visibilityVerificationSettlingDelayMS() -> Int
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
    func applyingBudget(_ budget: WindowInteractionBudget?) -> any WindowControl {
        guard let budget else { return self }
        return BudgetedWindowControl(base: self, budget: budget)
    }
    func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000)
    }

    func windowInventory() -> WindowInventory {
        .available(listAllWindows())
    }

    func windowInventory(identities: Set<WindowIdentity>) -> WindowInventory {
        windowInventory()
    }

    func focusedWindowObservation() -> WindowObservation {
        WindowObservation(
            inventory: windowInventory(),
            focusedIdentity: focusedWindow()?.identity,
            mainIdentity: focusedWindow()?.identity
        )
    }

    func focusedWindowIdentity() -> WindowIdentity? {
        focusedWindow()?.identity
    }

    func frontmostWindowIdentity() -> WindowIdentity? {
        focusedWindowIdentity()
    }

    func onScreenWindowIdentities() -> Set<WindowIdentity> {
        Set(listWindows().map(\.identity))
    }

    func accessibilityGranted() -> Bool {
        true
    }

    func visibilityVerificationSettlingDelayMS() -> Int {
        0
    }
}
