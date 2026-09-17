import CoreGraphics
import Foundation

public struct LayoutRecoveryJSON: Codable, Equatable, Sendable {
    public var outcomeDetail: String? {
        remainingCount > 0 ? "\(remainingCount) windows still need recovery" : nil
    }

    public let schemaVersion: Int
    public let requestID: String
    public let result: String
    public let recoveredCount: Int
    public let releasedCount: Int
    public let remainingCount: Int
    public let recoveryRequired: Bool
    public let exitCode: Int

    public init(
        requestID: String,
        result: String,
        recoveredCount: Int,
        releasedCount: Int,
        remainingCount: Int,
        recoveryRequired: Bool,
        exitCode: Int
    ) {
        schemaVersion = 1
        self.requestID = requestID
        self.result = result
        self.recoveredCount = recoveredCount
        self.releasedCount = releasedCount
        self.remainingCount = remainingCount
        self.recoveryRequired = recoveryRequired
        self.exitCode = exitCode
    }
}

public extension VirtualSpaceEngine {
    package func restoreEntriesForTransition(
        _ entries: [SlotEntry],
        token: ArrangeOperationToken
    ) throws -> (restored: Set<WindowIdentity>, unresolvedEntryIDs: [String], live: Set<WindowIdentity>) {
        let displays = control.displays()
        guard let primary = DisplayResolver.primaryDisplay(displays) else {
            return ([], entries.map(\.id), [])
        }
        var restored = Set<WindowIdentity>()
        var live = Set<WindowIdentity>()
        var unresolved: [String] = []
        unresolved.append(contentsOf: entries.filter { $0.boundIdentity == nil && $0.visibilityState.isManagedHidden }.map(\.id))
        let uniqueEntries = Dictionary(grouping: entries.filter { $0.boundIdentity != nil }, by: { $0.boundIdentity! })
            .values.compactMap { duplicates in
                duplicates.sorted {
                    if $0.visibilityState.isManagedHidden != $1.visibilityState.isManagedHidden {
                        return $0.visibilityState.isManagedHidden
                    }
                    return $0.id < $1.id
                }.first
            }.sorted { $0.id < $1.id }
        for entry in uniqueEntries {
            guard let identity = entry.boundIdentity else { continue }
            if !operationCoordinator.permitsNewSideEffect(token: token) {
                unresolved.append(entry.id)
                continue
            }
            let inventory = control.windowInventory(identities: [identity])
            guard inventory.isAuthoritative else {
                unresolved.append(entry.id)
                continue
            }
            guard let window = inventory.windows.first(where: { $0.identity == identity }) else {
                if inventory.mayContain(identity) { unresolved.append(entry.id) }
                continue
            }
            live.insert(identity)
            let shouldMove = entry.visibilityState.isManagedHidden
                || (!window.minimized && !displays.contains { $0.visibleFrame.intersects(window.frame.cgRect) })
            if !shouldMove {
                restored.insert(identity)
                continue
            }
            guard window.isAXBacked, !window.geometryBlocked else {
                unresolved.append(entry.id)
                continue
            }
            if !operationCoordinator.permitsNewSideEffect(token: token) {
                unresolved.append(entry.id)
                continue
            }
            var success = true
            if entry.visibilityState.isManagedHidden && window.minimized {
                do {
                    operationCoordinator.update(
                        token: token,
                        phase: .recovering,
                        layout: entry.layoutName,
                        space: entry.spaceID,
                        slot: entry.slot,
                        inFlight: true
                    )
                }
                success = control.setWindowMinimized(
                    windowID: identity.windowID,
                    pid: identity.pid,
                    processStartTime: identity.processStartTime,
                    bundleID: identity.bundleID,
                    minimized: false
                ).isSuccess
                do {
                    operationCoordinator.update(
                        token: token,
                        phase: .recovering,
                        layout: entry.layoutName,
                        space: entry.spaceID,
                        slot: entry.slot
                    )
                }
            }
            let preferred = entry.lastVisibleFrame ?? window.frame
            let target = Self.clampRecoveryFrame(preferred, into: primary.visibleFrame)
            if success {
                if !operationCoordinator.permitsNewSideEffect(token: token) {
                    unresolved.append(entry.id)
                    continue
                }
                do {
                    operationCoordinator.update(
                        token: token,
                        phase: .recovering,
                        layout: entry.layoutName,
                        space: entry.spaceID,
                        slot: entry.slot,
                        inFlight: true
                    )
                }
                success = control.setWindowFrame(
                    windowID: identity.windowID,
                    pid: identity.pid,
                    processStartTime: identity.processStartTime,
                    bundleID: identity.bundleID,
                    frame: target
                ).isApplied
                do {
                    operationCoordinator.update(
                        token: token,
                        phase: .recovering,
                        layout: entry.layoutName,
                        space: entry.spaceID,
                        slot: entry.slot
                    )
                }
            }
            guard success else {
                unresolved.append(entry.id)
                continue
            }
            if !operationCoordinator.permitsNewSideEffect(token: token) {
                unresolved.append(entry.id)
                continue
            }
            let verification = control.windowInventory(identities: [identity])
            guard verification.isAuthoritative,
                  let actual = verification.windows.first(where: { $0.identity == identity }),
                  actual.isAXBacked,
                  WindowEnumerator.roughlySame(frame: actual.frame, expectedFrame: target),
                  !entry.visibilityState.isManagedHidden || !actual.minimized
            else {
                unresolved.append(entry.id)
                continue
            }
            if !operationCoordinator.permitsNewSideEffect(token: token) {
                unresolved.append(entry.id)
                continue
            }
            var progress = currentState
            progress.slots = progress.slots.map { candidate in
                guard candidate.boundIdentity == identity else { return candidate }
                var visible = candidate
                visible.visibilityState = .visible
                visible.lastHiddenFrame = nil
                visible.lastVisibleFrame = target
                return visible
            }
            try replaceState(progress)
            try reachTransitionCheckpoint(.releaseProgressPersisted)
            restored.insert(identity)
        }
        return (restored, unresolved, live)
    }

    /// Restores exact persisted identities without consulting config. Progress
    /// is persisted per entry, so interruption can safely resume.
    package func recoverLayoutTransition(
        requestID: String,
        token: ArrangeOperationToken
    ) throws -> LayoutRecoveryJSON {
        try validateMutationAdmission(token: token, permitsRecovery: true)
        guard DisplayResolver.primaryDisplay(control.displays()) != nil else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        let scopeNames: Set<String>
        if let transition = currentState.pendingLayoutTransition {
            scopeNames = Set(transition.sourceLayoutNames + transition.targetLayoutNames)
        } else {
            scopeNames = Set(
                currentState.activeWorkspaces.map(\.layoutName)
                    + currentState.slots.filter(\.visibilityState.isManagedHidden).map(\.layoutName)
            )
        }
        guard !scopeNames.isEmpty else {
            return LayoutRecoveryJSON(
                requestID: requestID,
                result: "success",
                recoveredCount: 0,
                releasedCount: 0,
                remainingCount: 0,
                recoveryRequired: false,
                exitCode: ErrorCode.success.rawValue
            )
        }

        let candidates = currentState.slots.filter { scopeNames.contains($0.layoutName) }
        let progress = try restoreEntriesForTransition(candidates, token: token)
        let recovered = progress.restored.count
        let released = progress.live
        let unresolvedIDs = Set(progress.unresolvedEntryIDs)

        if !unresolvedIDs.isEmpty {
            let interruption = operationCoordinator.interruptionError(token: token)
            return LayoutRecoveryJSON(
                requestID: requestID,
                result: interruption == nil ? "partial" : "failed",
                recoveredCount: recovered,
                releasedCount: released.count,
                remainingCount: unresolvedIDs.count,
                recoveryRequired: true,
                exitCode: interruption?.code.rawValue
                    ?? ErrorCode.partialSuccess.rawValue
            )
        }

        if let interruption = operationCoordinator.interruptionError(token: token) {
            return LayoutRecoveryJSON(
                requestID: requestID,
                result: "failed",
                recoveredCount: recovered,
                releasedCount: released.count,
                remainingCount: candidates.count,
                recoveryRequired: true,
                exitCode: interruption.code.rawValue
            )
        }

        var final = currentState
        final.releasedWindowIdentities.formUnion(released)
        final.slots.removeAll { scopeNames.contains($0.layoutName) }
        final.activeWorkspaces.removeAll { scopeNames.contains($0.layoutName) }
        final.pendingVisibilityConvergences.removeAll { scopeNames.contains($0.layoutName) }
        final.selectedLayoutSet = nil
        final.pendingLayoutTransition = nil
        final.liveArrangeRecoveryRequired = false
        try replaceState(final)

        return LayoutRecoveryJSON(
            requestID: requestID,
            result: "success",
            recoveredCount: recovered,
            releasedCount: released.count,
            remainingCount: 0,
            recoveryRequired: false,
            exitCode: ErrorCode.success.rawValue
        )
    }

    /// A normal Quit ends management, but does not make every managed window
    /// an explicit released-window exclusion. This uses only saved exact
    /// identities/frames and live displays, so config removal cannot strand
    /// hidden windows. Unlike explicit journal recovery, Quit always ends
    /// every saved scope, including scopes outside a local transition.
    package func shutdownManagedWindows(
        requestID: String,
        token: ArrangeOperationToken
    ) throws -> LayoutRecoveryJSON {
        try validateMutationAdmission(token: token, permitsRecovery: true)
        let candidates = currentState.slots
        let progress = try restoreEntriesForTransition(candidates, token: token)
        if !progress.unresolvedEntryIDs.isEmpty || !operationCoordinator.permitsNewSideEffect(token: token) {
            let interruption = operationCoordinator.interruptionError(token: token)
            return LayoutRecoveryJSON(
                requestID: requestID,
                result: interruption == nil ? "partial" : "failed",
                recoveredCount: progress.restored.count,
                releasedCount: 0,
                remainingCount: progress.unresolvedEntryIDs.count,
                recoveryRequired: true,
                exitCode: interruption?.code.rawValue
                    ?? ErrorCode.partialSuccess.rawValue
            )
        }
        var final = RuntimeState(
            configGeneration: currentState.configGeneration,
            releasedWindowIdentities: currentState.releasedWindowIdentities
        )
        final.revision = currentState.revision
        try replaceState(final)
        return LayoutRecoveryJSON(
            requestID: requestID,
            result: "success",
            recoveredCount: progress.restored.count,
            releasedCount: 0,
            remainingCount: 0,
            recoveryRequired: false,
            exitCode: ErrorCode.success.rawValue
        )
    }

    private static func clampRecoveryFrame(_ frame: ResolvedFrame, into visible: CGRect) -> ResolvedFrame {
        let width = min(max(frame.width, 1), visible.width)
        let height = min(max(frame.height, 1), visible.height)
        let x = min(max(frame.x, visible.minX), visible.maxX - width)
        let y = min(max(frame.y, visible.minY), visible.maxY - height)
        return ResolvedFrame(x: x, y: y, width: width, height: height)
    }
}
