import CoreGraphics
import Foundation

/// The current mutation lease's remaining dispatch budget. The closures keep
/// shrinking while an OS call is in flight; returning from that call cannot
/// grant a fresh timeout to its next read/write.
public struct WindowInteractionBudget: Sendable {
    let permitsNewSideEffect: @Sendable () -> Bool
    let remainingBudgetMS: @Sendable () -> Int
    let interactionStarted: @Sendable () -> Void
    let interactionFinished: @Sendable () -> Void

    public init(
        permitsNewSideEffect: @escaping @Sendable () -> Bool,
        remainingBudgetMS: @escaping @Sendable () -> Int,
        interactionStarted: @escaping @Sendable () -> Void = {},
        interactionFinished: @escaping @Sendable () -> Void = {}
    ) {
        self.permitsNewSideEffect = permitsNewSideEffect
        self.remainingBudgetMS = remainingBudgetMS
        self.interactionStarted = interactionStarted
        self.interactionFinished = interactionFinished
    }

    var permitsCall: Bool { permitsNewSideEffect() && remainingBudgetMS() > 0 }
    func perform<Result>(_ operation: () -> Result) -> Result {
        interactionStarted()
        defer { interactionFinished() }
        return operation()
    }
}

/// Test/non-AX controls still obey dispatch boundaries. LiveWindowControl
/// supplies its own budgeted copy so the same budget also reaches AX IPC.
struct BudgetedWindowControl: WindowControl {
    let base: any WindowControl
    let budget: WindowInteractionBudget

    func listWindows() -> [WindowSnapshot] { budget.permitsCall ? budget.perform { base.listWindows() } : [] }
    func listAllWindows() -> [WindowSnapshot] { budget.permitsCall ? budget.perform { base.listAllWindows() } : [] }
    func windowInventory() -> WindowInventory { budget.permitsCall ? budget.perform { base.windowInventory() } : .unavailable }
    func windowInventory(identities: Set<WindowIdentity>) -> WindowInventory {
        budget.permitsCall ? budget.perform { base.windowInventory(identities: identities) } : .unavailable
    }
    func focusedWindowObservation() -> WindowObservation {
        budget.permitsCall ? budget.perform { base.focusedWindowObservation() } : WindowObservation(inventory: .unavailable, focusedIdentity: nil, mainIdentity: nil)
    }
    func focusedWindowIdentity() -> WindowIdentity? { budget.permitsCall ? budget.perform { base.focusedWindowIdentity() } : nil }
    func frontmostWindowIdentity() -> WindowIdentity? { base.frontmostWindowIdentity() }
    func onScreenWindowIdentities() -> Set<WindowIdentity> { base.onScreenWindowIdentities() }
    func accessibilityGranted() -> Bool { base.accessibilityGranted() }
    func visibilityVerificationSettlingDelayMS() -> Int { min(base.visibilityVerificationSettlingDelayMS(), budget.remainingBudgetMS()) }
    func focusedWindow() -> WindowSnapshot? { budget.permitsCall ? budget.perform { base.focusedWindow() } : nil }
    func displays() -> [DisplayInfo] { base.displays() }
    func setWindowFrame(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, frame: ResolvedFrame) -> WindowGeometryMutationResult {
        guard budget.permitsCall else { return .notAttempted }
        return budget.perform { base.setWindowFrame(windowID: windowID, pid: pid, processStartTime: processStartTime, bundleID: bundleID, frame: frame) }
    }
    func setWindowPosition(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, position: CGPoint) -> WindowGeometryMutationResult {
        guard budget.permitsCall else { return .notAttempted }
        return budget.perform { base.setWindowPosition(windowID: windowID, pid: pid, processStartTime: processStartTime, bundleID: bundleID, position: position) }
    }
    func setWindowMinimized(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, minimized: Bool) -> WindowInteractionResult {
        guard budget.permitsCall else { return .failed }
        return budget.perform { base.setWindowMinimized(windowID: windowID, pid: pid, processStartTime: processStartTime, bundleID: bundleID, minimized: minimized) }
    }
    func focusWindow(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String) -> WindowInteractionResult {
        guard budget.permitsCall else { return .failed }
        return budget.perform { base.focusWindow(windowID: windowID, pid: pid, processStartTime: processStartTime, bundleID: bundleID) }
    }
    func activateApplication(pid: Int, processStartTime: UInt64, bundleID: String) -> Bool {
        budget.permitsCall && budget.perform { base.activateApplication(pid: pid, processStartTime: processStartTime, bundleID: bundleID) }
    }
    func launchApplication(request: ApplicationLaunchRequest) -> Bool {
        budget.permitsCall && budget.perform { base.launchApplication(request: request) }
    }
    func sleep(milliseconds: Int) {
        guard budget.permitsCall else { return }
        base.sleep(milliseconds: min(milliseconds, budget.remainingBudgetMS()))
    }
}
