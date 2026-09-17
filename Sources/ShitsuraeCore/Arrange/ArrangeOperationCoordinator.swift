import Foundation

public enum ArrangeOperationKind: String, Codable, Equatable, Sendable {
    case arrange
    case arrangeSet
    case recover
    case switchSpace
    case window
    case focus
    case displayChange
    case shutdown
}

public enum ArrangeOperationPhase: String, Codable, Equatable, Sendable {
    case admitted
    case preflight
    case journaled
    case waitingForWindows
    case releasing
    case ownershipCommitted
    case placing
    case visibility
    case focusing
    case recovering
    case finalizing
}

public enum ArrangeOperationInvalidationReason: String, Codable, Equatable, Sendable {
    case configurationChanged
    case displayConfigurationChanged
    case operationInvalidated
}

public struct ArrangeOperationToken: Equatable, Sendable {
    public let requestID: String
    fileprivate let generation: UInt64
}

public struct ActiveArrangeOperation: Codable, Equatable, Sendable {
    public let requestID: String
    public let operation: ArrangeOperationKind
    public let phase: ArrangeOperationPhase
    public let layout: String?
    public let space: Int?
    public let slot: Int?
    public let waitingReason: String?
    public let startedAt: String
    public let elapsedMS: Int
    public let deadlineExceeded: Bool
    public let inFlight: Bool
    public let invalidationReason: ArrangeOperationInvalidationReason?
}

public struct ArrangeOutcomeSummary: Codable, Equatable, Sendable {
    public let requestID: String
    public let operation: ArrangeOperationKind
    public let result: String
    public let exitCode: Int
    public let finishedAt: String
    public let detail: String?
    public let recoveryRequired: Bool
}

public struct ArrangeStatusJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let active: ActiveArrangeOperation?
    public let lastOutcome: ArrangeOutcomeSummary?
    public let pendingTransition: PendingLayoutTransition?
    public let stateRevision: UInt64
    public let observedAt: String

    public init(
        active: ActiveArrangeOperation?,
        lastOutcome: ArrangeOutcomeSummary?,
        pendingTransition: PendingLayoutTransition?,
        stateRevision: UInt64 = 0,
        observedAt: String = Date.rfc3339UTC()
    ) {
        schemaVersion = 1
        self.active = active
        self.lastOutcome = lastOutcome
        self.pendingTransition = pendingTransition
        self.stateRevision = stateRevision
        self.observedAt = observedAt
    }
}

/// Actor-external admission and status projection. It intentionally owns no
/// WindowControl or RuntimeState; it only serializes mutation leases and
/// mirrors the last successfully persisted transition journal.
public final class ArrangeOperationCoordinator: @unchecked Sendable {
    public static let shared = ArrangeOperationCoordinator()
    public static let dispatchBudgetMS = 60_000

    private struct Active {
        let requestID: String
        let operation: ArrangeOperationKind
        let generation: UInt64
        let startedAt: String
        let startedUptimeNS: UInt64
        let deadlineUptimeNS: UInt64
        var phase: ArrangeOperationPhase
        var layout: String?
        var space: Int?
        var slot: Int?
        var waitingReason: String?
        var inFlight: Bool
        var invalidationReason: ArrangeOperationInvalidationReason?
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active: Active?
    private var lastOutcome: ArrangeOutcomeSummary?
    private var pendingTransitionMirror: PendingLayoutTransition?
    private var mirrorRevision: UInt64 = 0
    private let uptimeNanoseconds: @Sendable () -> UInt64

    public init(uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
        DispatchTime.now().uptimeNanoseconds
    }) {
        self.uptimeNanoseconds = uptimeNanoseconds
    }

    public func tryAdmit(
        requestID: String,
        operation: ArrangeOperationKind,
        permitsRecovery: Bool = false,
        requiresAuthoritativeJournalCheck: Bool = false,
        budgetMS: Int = dispatchBudgetMS
    ) throws -> ArrangeOperationToken {
        lock.lock()
        defer { lock.unlock() }
        if let active {
            if active.requestID == requestID {
                if active.operation != operation {
                    throw ShitsuraeError(
                        .validationError,
                        "requestID is active for a different operation",
                        subcode: "requestIDConflict"
                    )
                }
                throw ShitsuraeError(
                    .operationBusy,
                    "request is already in progress (requestID: \(active.requestID))",
                    subcode: "inProgress"
                )
            }
            throw ShitsuraeError(
                .operationBusy,
                "another operation is active (requestID: \(active.requestID))",
                subcode: "operationBusy"
            )
        }
        if pendingTransitionMirror != nil, !permitsRecovery, !requiresAuthoritativeJournalCheck {
            throw ShitsuraeError(
                .operationBlocked,
                "window recovery is required before starting another operation",
                subcode: "recoveryRequired"
            )
        }
        generation &+= 1
        let now = uptimeNanoseconds()
        let budgetNS = UInt64(max(0, budgetMS)) * 1_000_000
        active = Active(
            requestID: requestID,
            operation: operation,
            generation: generation,
            startedAt: Date.rfc3339UTC(),
            startedUptimeNS: now,
            deadlineUptimeNS: now &+ budgetNS,
            phase: .admitted,
            layout: nil,
            space: nil,
            slot: nil,
            waitingReason: nil,
            inFlight: false,
            invalidationReason: nil
        )
        return ArrangeOperationToken(requestID: requestID, generation: generation)
    }

    public func update(
        token: ArrangeOperationToken,
        phase: ArrangeOperationPhase,
        layout: String? = nil,
        space: Int? = nil,
        slot: Int? = nil,
        waitingReason: String? = nil,
        inFlight: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard var current = active,
              current.requestID == token.requestID,
              current.generation == token.generation
        else { return }
        current.phase = phase
        current.layout = layout
        current.space = space
        current.slot = slot
        current.waitingReason = waitingReason
        current.inFlight = inFlight
        active = current
    }

    public func permitsNewSideEffect(token: ArrangeOperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active,
              active.requestID == token.requestID,
              active.generation == token.generation,
              generation == token.generation
        else { return false }
        return uptimeNanoseconds() < active.deadlineUptimeNS
    }

    public func remainingBudgetMS(token: ArrangeOperationToken) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let active,
              active.requestID == token.requestID,
              active.generation == token.generation,
              generation == token.generation
        else { return 0 }
        let now = uptimeNanoseconds()
        guard now < active.deadlineUptimeNS else { return 0 }
        return Int((active.deadlineUptimeNS - now) / 1_000_000)
    }

    public func invalidateCurrent(reason: ArrangeOperationInvalidationReason = .operationInvalidated) {
        lock.lock()
        if var current = active {
            current.invalidationReason = reason
            active = current
        }
        generation &+= 1
        lock.unlock()
    }

    public func interruptionError(token: ArrangeOperationToken) -> ShitsuraeError? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = active,
              current.requestID == token.requestID,
              current.generation == token.generation
        else {
            return ShitsuraeError(.operationBlocked, "operation token is no longer active", subcode: "operationInvalidated")
        }
        if uptimeNanoseconds() >= current.deadlineUptimeNS {
            return ShitsuraeError(.operationTimedOut, "operation deadline exceeded", subcode: "deadlineExceeded")
        }
        if let reason = current.invalidationReason {
            return ShitsuraeError(.operationBlocked, "operation invalidated: \(reason.rawValue)", subcode: "operationInvalidated")
        }
        if generation != token.generation {
            return ShitsuraeError(.operationBlocked, "operation generation changed", subcode: "operationInvalidated")
        }
        return nil
    }

    func currentInterruptionError() -> ShitsuraeError? {
        lock.lock()
        let token = active.map { ArrangeOperationToken(requestID: $0.requestID, generation: $0.generation) }
        lock.unlock()
        return token.flatMap { interruptionError(token: $0) }
    }

    func currentInteractionBudget() -> WindowInteractionBudget? {
        lock.lock()
        let token = active.map { ArrangeOperationToken(requestID: $0.requestID, generation: $0.generation) }
        lock.unlock()
        guard let token else { return nil }
        return WindowInteractionBudget(
            permitsNewSideEffect: { self.permitsNewSideEffect(token: token) },
            remainingBudgetMS: { self.remainingBudgetMS(token: token) },
            interactionStarted: { self.setInteractionInFlight(token: token, inFlight: true) },
            interactionFinished: { self.setInteractionInFlight(token: token, inFlight: false) }
        )
    }

    private func setInteractionInFlight(token: ArrangeOperationToken, inFlight: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard active?.requestID == token.requestID, active?.generation == token.generation else { return }
        active?.inFlight = inFlight
    }

    public func finish(
        token: ArrangeOperationToken,
        result: String,
        exitCode: Int,
        detail: String? = nil,
        recoveryRequired: Bool? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = active,
              current.requestID == token.requestID,
              current.generation == token.generation
        else { return }
        lastOutcome = ArrangeOutcomeSummary(
            requestID: current.requestID,
            operation: current.operation,
            result: result,
            exitCode: exitCode,
            finishedAt: Date.rfc3339UTC(),
            detail: detail ?? current.invalidationReason.map { "operationInvalidated: \($0.rawValue)" },
            recoveryRequired: recoveryRequired ?? (pendingTransitionMirror != nil)
        )
        active = nil
    }

    public func abandon(token: ArrangeOperationToken) {
        lock.lock()
        defer { lock.unlock() }
        guard active?.requestID == token.requestID,
              active?.generation == token.generation
        else { return }
        active = nil
    }

    public func updateJournalMirror(state: RuntimeState, authoritative: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard authoritative || state.revision >= mirrorRevision else { return }
        mirrorRevision = state.revision
        pendingTransitionMirror = state.pendingLayoutTransition
    }

    public func status() -> ArrangeStatusJSON {
        lock.lock()
        defer { lock.unlock() }
        let now = uptimeNanoseconds()
        let snapshot = active.map { current in
            ActiveArrangeOperation(
                requestID: current.requestID,
                operation: current.operation,
                phase: current.phase,
                layout: current.layout,
                space: current.space,
                slot: current.slot,
                waitingReason: current.waitingReason,
                startedAt: current.startedAt,
                elapsedMS: Int((now >= current.startedUptimeNS ? now - current.startedUptimeNS : 0) / 1_000_000),
                deadlineExceeded: now >= current.deadlineUptimeNS,
                inFlight: current.inFlight,
                invalidationReason: current.invalidationReason
            )
        }
        return ArrangeStatusJSON(
            active: snapshot,
            lastOutcome: lastOutcome,
            pendingTransition: pendingTransitionMirror,
            stateRevision: mirrorRevision
        )
    }
}
