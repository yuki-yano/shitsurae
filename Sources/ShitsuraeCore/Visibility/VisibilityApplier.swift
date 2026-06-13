import CoreGraphics
import Foundation

/// Result of applying one VisibilityPlan, before/after convergence.
public struct AppliedVisibilityChange: Equatable, Sendable {
    public let window: WindowSnapshot
    public let originalEntry: SlotEntry
    /// Entry to persist right now (desired on apply success, original on failure).
    public var effectiveEntry: SlotEntry
    public let desiredEntry: SlotEntry
    public let restoredFromMinimized: Bool
}

public struct ConvergenceOutcome: Equatable, Sendable {
    public let changes: [AppliedVisibilityChange]
    public let hasPending: Bool
    public let retryCount: Int
    public let verifyCount: Int
}

/// Applies visibility plans through WindowControl and verifies convergence.
///
/// macOS applies AX frame changes asynchronously and sometimes silently
/// adjusts them; the verify-retry loop is the defense against that race —
/// keep it even if it looks redundant.
public enum VisibilityApplier {
    public static let defaultRetryDelaysMS = [40, 80, 160]

    public static func apply(
        plans: [VisibilityPlan],
        control: WindowControl,
        logger: ShitsuraeLogger
    ) -> [AppliedVisibilityChange] {
        plans.map { plan in
            let succeeded = apply(plan: plan, control: control, logger: logger)
            return AppliedVisibilityChange(
                window: plan.window,
                originalEntry: plan.originalEntry,
                effectiveEntry: succeeded ? plan.desiredEntry : plan.originalEntry,
                desiredEntry: plan.desiredEntry,
                restoredFromMinimized: plan.restoreFromMinimized
            )
        }
    }

    static func apply(
        plan: VisibilityPlan,
        control: WindowControl,
        logger: ShitsuraeLogger
    ) -> Bool {
        // v2: unminimize before showing — without this a minimized window can
        // never come back through a space switch (v1 bug).
        if plan.restoreFromMinimized,
           !control.setWindowMinimized(
               windowID: plan.window.windowID,
               bundleID: plan.window.bundleID,
               minimized: false
           ).isSuccess
        {
            logger.log(
                level: "warn",
                event: "visibility.apply.unminimizeFailed",
                fields: [
                    "windowID": Int(plan.window.windowID),
                    "bundleID": plan.window.bundleID,
                    "action": plan.action,
                ]
            )
        }

        switch plan.mutation {
        case .none:
            return true

        case let .frame(frame):
            let tolerance = 2.0
            if !plan.restoreFromMinimized,
               abs(plan.window.frame.x - frame.x) <= tolerance,
               abs(plan.window.frame.y - frame.y) <= tolerance,
               abs(plan.window.frame.width - frame.width) <= tolerance,
               abs(plan.window.frame.height - frame.height) <= tolerance
            {
                return true
            }
            guard control.setWindowFrame(windowID: plan.window.windowID, bundleID: plan.window.bundleID, frame: frame) else {
                logger.error(
                    event: "visibility.apply.setFrameFailed",
                    fields: [
                        "windowID": Int(plan.window.windowID),
                        "bundleID": plan.window.bundleID,
                        "action": plan.action,
                    ]
                )
                return false
            }
            return true

        case let .position(position):
            let tolerance: CGFloat = 2.0
            if abs(plan.window.frame.x - position.x) <= tolerance,
               abs(plan.window.frame.y - position.y) <= tolerance
            {
                return true
            }
            guard control.setWindowPosition(windowID: plan.window.windowID, bundleID: plan.window.bundleID, position: position) else {
                logger.error(
                    event: "visibility.apply.setPositionFailed",
                    fields: [
                        "windowID": Int(plan.window.windowID),
                        "bundleID": plan.window.bundleID,
                        "action": plan.action,
                    ]
                )
                return false
            }
            return true
        }
    }

    /// Verify-retry until every change matches its desired state or the retry
    /// budget is exhausted. Non-converged changes roll back their effective
    /// entry to the original so persisted state never lies about reality.
    public static func converge(
        changes: [AppliedVisibilityChange],
        control: WindowControl,
        logger: ShitsuraeLogger,
        retryDelaysMS: [Int] = defaultRetryDelaysMS
    ) -> ConvergenceOutcome {
        guard !changes.isEmpty else {
            return ConvergenceOutcome(changes: [], hasPending: false, retryCount: 0, verifyCount: 0)
        }

        var latestWindows = control.listAllWindows()
        var verifyCount = 1
        var retryCount = 0
        var pending = changes.filter { !matchesDesiredState(change: $0, windows: latestWindows) }

        for delayMS in retryDelaysMS where !pending.isEmpty {
            retryCount += 1
            retry(changes: pending, control: control, logger: logger)
            control.sleep(milliseconds: delayMS)
            latestWindows = control.listAllWindows()
            verifyCount += 1
            pending = changes.filter { !matchesDesiredState(change: $0, windows: latestWindows) }
        }

        let unresolvedWindowIDs = Set(pending.map(\.window.windowID))
        let resolved = changes.map { change in
            var copy = change
            copy.effectiveEntry = unresolvedWindowIDs.contains(change.window.windowID)
                ? change.originalEntry
                : change.desiredEntry
            return copy
        }

        return ConvergenceOutcome(
            changes: resolved,
            hasPending: !pending.isEmpty,
            retryCount: retryCount,
            verifyCount: verifyCount
        )
    }

    static func matchesDesiredState(
        change: AppliedVisibilityChange,
        windows: [WindowSnapshot]
    ) -> Bool {
        guard let actual = windows.first(where: { $0.windowID == change.window.windowID }) else {
            return false
        }

        switch change.desiredEntry.visibilityState {
        case .visible:
            guard !actual.minimized else {
                return false
            }
            if let expectedFrame = change.desiredEntry.lastVisibleFrame {
                return frameMatches(actual.frame, expectedFrame)
            }
            return true
        case .hiddenOffscreen:
            if actual.minimized || actual.isFullscreen {
                return true
            }
            guard let expectedFrame = change.desiredEntry.lastHiddenFrame else {
                return false
            }
            return positionMatches(actual.frame, expectedFrame)
        }
    }

    private static func retry(
        changes: [AppliedVisibilityChange],
        control: WindowControl,
        logger: ShitsuraeLogger
    ) {
        for change in changes {
            switch change.desiredEntry.visibilityState {
            case .visible:
                guard let frame = change.desiredEntry.lastVisibleFrame else {
                    continue
                }
                if change.restoredFromMinimized {
                    _ = control.setWindowMinimized(
                        windowID: change.window.windowID,
                        bundleID: change.window.bundleID,
                        minimized: false
                    )
                }
                if !control.setWindowFrame(windowID: change.window.windowID, bundleID: change.window.bundleID, frame: frame) {
                    logger.log(
                        level: "warn",
                        event: "visibility.retry.failed",
                        fields: [
                            "windowID": Int(change.window.windowID),
                            "bundleID": change.window.bundleID,
                            "action": "show",
                        ]
                    )
                }
            case .hiddenOffscreen:
                guard let frame = change.desiredEntry.lastHiddenFrame else {
                    continue
                }
                if !control.setWindowPosition(
                    windowID: change.window.windowID,
                    bundleID: change.window.bundleID,
                    position: CGPoint(x: frame.x, y: frame.y)
                ) {
                    logger.log(
                        level: "warn",
                        event: "visibility.retry.failed",
                        fields: [
                            "windowID": Int(change.window.windowID),
                            "bundleID": change.window.bundleID,
                            "action": "hide",
                        ]
                    )
                }
            }
        }
    }

    static func frameMatches(
        _ actual: ResolvedFrame,
        _ expected: ResolvedFrame,
        tolerance: Double = 4
    ) -> Bool {
        abs(actual.x - expected.x) <= tolerance
            && abs(actual.y - expected.y) <= tolerance
            && abs(actual.width - expected.width) <= tolerance
            && abs(actual.height - expected.height) <= tolerance
    }

    static func positionMatches(
        _ actual: ResolvedFrame,
        _ expected: ResolvedFrame,
        tolerance: Double = 4
    ) -> Bool {
        abs(actual.x - expected.x) <= tolerance
            && abs(actual.y - expected.y) <= tolerance
    }

}
