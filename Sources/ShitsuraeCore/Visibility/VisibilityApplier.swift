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
    /// Latest geometry attempt. Safe pre-write failures remain retryable;
    /// rejected AX writes do not because some Chrome surfaces move even while
    /// returning an error.
    public var geometryMutationResult: WindowGeometryMutationResult

    public init(
        window: WindowSnapshot,
        originalEntry: SlotEntry,
        effectiveEntry: SlotEntry,
        desiredEntry: SlotEntry,
        restoredFromMinimized: Bool,
        geometryMutationResult: WindowGeometryMutationResult = .applied
    ) {
        self.window = window
        self.originalEntry = originalEntry
        self.effectiveEntry = effectiveEntry
        self.desiredEntry = desiredEntry
        self.restoredFromMinimized = restoredFromMinimized
        self.geometryMutationResult = geometryMutationResult
    }
}

public struct ConvergenceOutcome: Equatable, Sendable {
    public let changes: [AppliedVisibilityChange]
    public let hasPending: Bool
    public let retryCount: Int
    public let verifyCount: Int
    /// Identities whose final state could not be verified authoritatively.
    /// They remain pending because absence from a failed/partial inventory is
    /// unknown.
    public let unverifiedWindowIdentities: [WindowIdentity]
    /// Identities that did not reach the requested visibility, even when an
    /// authoritative snapshot proves they safely remained at the original
    /// state.
    public let desiredUnresolvedWindowIdentities: [WindowIdentity]
    /// Exact window identities that never reached their effective state within
    /// the retry budget.
    public let unconvergedWindowIdentities: [WindowIdentity]

    public init(
        changes: [AppliedVisibilityChange],
        hasPending: Bool,
        retryCount: Int,
        verifyCount: Int,
        unverifiedWindowIdentities: [WindowIdentity] = [],
        desiredUnresolvedWindowIdentities: [WindowIdentity] = [],
        unconvergedWindowIdentities: [WindowIdentity] = []
    ) {
        self.changes = changes
        self.hasPending = hasPending
        self.retryCount = retryCount
        self.verifyCount = verifyCount
        self.unverifiedWindowIdentities = unverifiedWindowIdentities
        self.desiredUnresolvedWindowIdentities = desiredUnresolvedWindowIdentities
        self.unconvergedWindowIdentities = unconvergedWindowIdentities
    }
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
            let result = apply(plan: plan, control: control, logger: logger)
            return AppliedVisibilityChange(
                window: plan.window,
                originalEntry: plan.originalEntry,
                effectiveEntry: result.isApplied ? plan.desiredEntry : plan.originalEntry,
                desiredEntry: plan.desiredEntry,
                restoredFromMinimized: plan.restoreFromMinimized,
                geometryMutationResult: result
            )
        }
    }

    static func apply(
        plan: VisibilityPlan,
        control: WindowControl,
        logger: ShitsuraeLogger
    ) -> WindowGeometryMutationResult {
        // v2: unminimize before showing — without this a minimized window can
        // never come back through a space switch (v1 bug).
        if plan.restoreFromMinimized,
           !control.setWindowMinimized(
               windowID: plan.window.windowID,
               pid: plan.window.pid,
               processStartTime: plan.window.processStartTime,
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
            return .applied

        case let .frame(frame):
            let tolerance = 2.0
            if !plan.restoreFromMinimized,
               abs(plan.window.frame.x - frame.x) <= tolerance,
               abs(plan.window.frame.y - frame.y) <= tolerance,
               abs(plan.window.frame.width - frame.width) <= tolerance,
               abs(plan.window.frame.height - frame.height) <= tolerance
            {
                return .applied
            }
            let result = control.setWindowFrame(
                windowID: plan.window.windowID,
                pid: plan.window.pid,
                processStartTime: plan.window.processStartTime,
                bundleID: plan.window.bundleID,
                frame: frame
            )
            if !result.isApplied {
                logger.error(
                    event: "visibility.apply.setFrameFailed",
                    fields: [
                        "windowID": Int(plan.window.windowID),
                        "bundleID": plan.window.bundleID,
                        "action": plan.action,
                        "result": String(describing: result),
                    ]
                )
            }
            return result

        case let .position(position):
            let tolerance: CGFloat = 2.0
            if abs(plan.window.frame.x - position.x) <= tolerance,
               abs(plan.window.frame.y - position.y) <= tolerance
            {
                return .applied
            }
            let result = control.setWindowPosition(
                windowID: plan.window.windowID,
                pid: plan.window.pid,
                processStartTime: plan.window.processStartTime,
                bundleID: plan.window.bundleID,
                position: position
            )
            if !result.isApplied {
                logger.error(
                    event: "visibility.apply.setPositionFailed",
                    fields: [
                        "windowID": Int(plan.window.windowID),
                        "bundleID": plan.window.bundleID,
                        "action": plan.action,
                        "result": String(describing: result),
                    ]
                )
            }
            return result
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

        var workingChanges = changes
        var latestInventory = control.windowInventory()
        var verifyCount = 1
        var retryCount = 0
        var verification = desiredStateVerification(changes: workingChanges, inventory: latestInventory)

        for delayMS in retryDelaysMS where verification.values.contains(where: { $0 != .desired }) {
            let retryableIndices = workingChanges.indices.filter {
                workingChanges[$0].geometryMutationResult.canRetry
                    && verification[workingChanges[$0].window.identity] == .notDesired
            }
            let hasUnknown = verification.values.contains(.unknown)
            if retryableIndices.isEmpty && !hasUnknown {
                break
            }
            if !retryableIndices.isEmpty {
                retryCount += 1
                retry(
                    changes: &workingChanges,
                    indices: retryableIndices,
                    control: control,
                    logger: logger
                )
            }
            control.sleep(milliseconds: delayMS)
            latestInventory = control.windowInventory()
            verifyCount += 1
            verification = desiredStateVerification(changes: workingChanges, inventory: latestInventory)
        }

        let desiredUnresolvedWindowIdentities = Set(verification.compactMap { identity, result in
            result == .notDesired ? identity : nil
        })
        let unverifiedWindowIdentities = Set(verification.compactMap { identity, result in
            result == .unknown ? identity : nil
        })
        let resolved = workingChanges.map { change in
            var copy = change
            if desiredUnresolvedWindowIdentities.contains(change.window.identity) {
                copy.effectiveEntry = change.originalEntry
            } else if !unverifiedWindowIdentities.contains(change.window.identity) {
                copy.effectiveEntry = change.desiredEntry
            }
            // Unknown means the inventory could not prove the physical state.
            // Preserve apply()'s best-known effective entry; manufacturing a
            // rollback here corrupts a successful mutation's write-ahead state.
            return copy
        }
        let effectivePending = resolved.filter {
            !unverifiedWindowIdentities.contains($0.window.identity)
                && !matchesEffectiveState(change: $0, windows: latestInventory.windows)
        }

        // [diagnostic] convergence-failure investigation — remove after root
        // cause confirmed. One summary line per switch (not per window) so the
        // permanently-unconverged windows don't flood the log. Each entry is
        // "bundleID#windowID:desired:expected:actual:flags" (flags: m=minimized,
        // f=fullscreen), letting us tell "can't be moved" (size-constrained /
        // special windows) from a real placement bug.
        if !effectivePending.isEmpty {
            let entries = effectivePending.map { change -> String in
                let identity = change.window.identity
                let actual = latestInventory.windows.first(where: { $0.identity == identity })
                let desired = String(describing: change.desiredEntry.visibilityState)
                let expected: String
                switch change.desiredEntry.visibilityState {
                case .visible:
                    expected = change.desiredEntry.lastVisibleFrame
                        .map { "\(Int($0.x)),\(Int($0.y)),\(Int($0.width)),\(Int($0.height))" } ?? "?"
                case .hiddenOffscreen:
                    expected = change.desiredEntry.lastHiddenFrame
                        .map { "\(Int($0.x)),\(Int($0.y))" } ?? "?"
                }
                let actualFrame = actual
                    .map { "\(Int($0.frame.x)),\(Int($0.frame.y)),\(Int($0.frame.width)),\(Int($0.frame.height))" } ?? "gone"
                let flags = "\(actual?.minimized == true ? "m" : "")\(actual?.isFullscreen == true ? "f" : "")"
                return "\(change.window.bundleID)#\(change.window.windowID):\(desired):\(expected):\(actualFrame):\(flags)"
            }
            logger.log(
                level: "warn",
                event: "visibility.converge.unresolved",
                fields: [
                    "count": effectivePending.count,
                    "windows": entries.joined(separator: ";"),
                ]
            )
        }

        if !unverifiedWindowIdentities.isEmpty {
            logger.log(
                level: "warn",
                event: "visibility.converge.unverified",
                fields: [
                    "count": unverifiedWindowIdentities.count,
                    "windows": unverifiedWindowIdentities
                        .sorted { lhs, rhs in
                            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
                            return lhs.windowID < rhs.windowID
                        }
                        .map { "\($0.bundleID)#\($0.pid):\($0.windowID)" }
                        .joined(separator: ";"),
                ]
            )
        }

        return ConvergenceOutcome(
            changes: resolved,
            hasPending: !desiredUnresolvedWindowIdentities.isEmpty || !unverifiedWindowIdentities.isEmpty,
            retryCount: retryCount,
            verifyCount: verifyCount,
            unverifiedWindowIdentities: Array(unverifiedWindowIdentities),
            desiredUnresolvedWindowIdentities: Array(desiredUnresolvedWindowIdentities),
            unconvergedWindowIdentities: effectivePending.map(\.window.identity)
        )
    }

    private enum DesiredStateVerification: Equatable {
        case desired
        case notDesired
        case unknown
    }

    private static func desiredStateVerification(
        changes: [AppliedVisibilityChange],
        inventory: WindowInventory
    ) -> [WindowIdentity: DesiredStateVerification] {
        Dictionary(uniqueKeysWithValues: changes.map { change in
            let identity = change.window.identity
            guard inventory.isAuthoritative else {
                return (identity, .unknown)
            }
            guard inventory.windows.contains(where: { $0.identity == identity }) else {
                // A raw CG handle that could still be this identity is not an
                // authoritative disappearance (snapshot assembly can fail).
                return (identity, inventory.mayContain(identity) ? .unknown : .notDesired)
            }
            return (
                identity,
                matchesDesiredState(change: change, windows: inventory.windows)
                    ? .desired
                    : .notDesired
            )
        })
    }

    static func matchesDesiredState(
        change: AppliedVisibilityChange,
        windows: [WindowSnapshot]
    ) -> Bool {
        let identity = change.window.identity
        guard let actual = windows.first(where: { $0.identity == identity }) else {
            return false
        }

        return matchesVisibilityState(entry: change.desiredEntry, actual: actual)
    }

    static func matchesEffectiveState(
        change: AppliedVisibilityChange,
        windows: [WindowSnapshot]
    ) -> Bool {
        let identity = change.window.identity
        guard let actual = windows.first(where: { $0.identity == identity }) else {
            return false
        }

        return matchesVisibilityState(
            entry: change.effectiveEntry,
            actual: actual,
            fallbackVisibleFrame: change.window.frame
        )
    }

    private static func matchesVisibilityState(
        entry: SlotEntry,
        actual: WindowSnapshot,
        fallbackVisibleFrame: ResolvedFrame? = nil
    ) -> Bool {
        switch entry.visibilityState {
        case .visible:
            guard !actual.minimized else {
                return false
            }
            if let expectedFrame = entry.lastVisibleFrame ?? fallbackVisibleFrame {
                return frameMatches(actual.frame, expectedFrame)
            }
            return true
        case .hiddenOffscreen:
            if actual.minimized {
                return true
            }
            guard let expectedFrame = entry.lastHiddenFrame else {
                return false
            }
            return positionMatches(actual.frame, expectedFrame)
        }
    }

    private static func retry(
        changes: inout [AppliedVisibilityChange],
        indices: [Int],
        control: WindowControl,
        logger: ShitsuraeLogger
    ) {
        for index in indices {
            let change = changes[index]
            let result: WindowGeometryMutationResult
            switch change.desiredEntry.visibilityState {
            case .visible:
                guard let frame = change.desiredEntry.lastVisibleFrame else {
                    continue
                }
                if change.restoredFromMinimized {
                    _ = control.setWindowMinimized(
                        windowID: change.window.windowID,
                        pid: change.window.pid,
                        processStartTime: change.window.processStartTime,
                        bundleID: change.window.bundleID,
                        minimized: false
                    )
                }
                result = control.setWindowFrame(
                    windowID: change.window.windowID,
                    pid: change.window.pid,
                    processStartTime: change.window.processStartTime,
                    bundleID: change.window.bundleID,
                    frame: frame
                )
            case .hiddenOffscreen:
                guard let frame = change.desiredEntry.lastHiddenFrame else {
                    continue
                }
                result = control.setWindowPosition(
                    windowID: change.window.windowID,
                    pid: change.window.pid,
                    processStartTime: change.window.processStartTime,
                    bundleID: change.window.bundleID,
                    position: CGPoint(x: frame.x, y: frame.y)
                )
            }

            changes[index].geometryMutationResult = result
            if result.isApplied {
                changes[index].effectiveEntry = change.desiredEntry
            } else if result == .rejected {
                changes[index].effectiveEntry = change.originalEntry
            }

            if !result.isApplied {
                logger.log(
                    level: "warn",
                    event: "visibility.retry.failed",
                    fields: [
                        "windowID": Int(change.window.windowID),
                        "bundleID": change.window.bundleID,
                        "action": change.desiredEntry.visibilityState == .visible ? "show" : "hide",
                        "result": String(describing: result),
                    ]
                )
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
