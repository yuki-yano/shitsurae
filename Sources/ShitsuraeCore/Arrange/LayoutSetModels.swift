import Foundation

/// Deterministic fault-injection boundaries; no history is persisted.
public enum LayoutTransitionCheckpoint: String, CaseIterable, Sendable {
    case journalPersisted
    case launchWaitFinished
    case releaseProgressPersisted
    case ownershipCommitted
    case hideWALPersisted
    case finalSave
}

struct LayoutTransitionCheckpointFailure: Error {
    let point: LayoutTransitionCheckpoint
}

public enum LayoutSetPlanError: Error, Equatable, Sendable {
    case setNotFound(String)
    case memberLayoutNotFound(String)
    case hostDisplayUnavailable(String)
    case displayCollision(displayID: String, layouts: [String])
    case candidateConflict(layouts: [String], identity: WindowIdentity)
    case initialFocusExcluded(layout: String, bundleID: String)
}

public struct LayoutSetMemberPlan: Equatable, Sendable {
    public let layoutName: String
    public let resolvedDisplayID: String
    public let targetSpaceID: Int
    public let arrangePlan: ArrangePlan

    public init(layoutName: String, resolvedDisplayID: String, targetSpaceID: Int, arrangePlan: ArrangePlan) {
        self.layoutName = layoutName
        self.resolvedDisplayID = resolvedDisplayID
        self.targetSpaceID = targetSpaceID
        self.arrangePlan = arrangePlan
    }
}

public struct LayoutSetPlan: Equatable, Sendable {
    public let setName: String
    public let memberNames: [String]
    public let definitionDigest: String
    public let topologyDigest: String
    public let members: [LayoutSetMemberPlan]
    public let sourceLayoutNames: [String]
    public let retiringLayoutNames: [String]
    public let releasedEntryIDs: [String]
    public let transferredIdentities: Set<WindowIdentity>
    public let warnings: [WarningItem]

    public init(
        setName: String,
        memberNames: [String],
        definitionDigest: String,
        topologyDigest: String,
        members: [LayoutSetMemberPlan],
        sourceLayoutNames: [String],
        retiringLayoutNames: [String],
        releasedEntryIDs: [String],
        transferredIdentities: Set<WindowIdentity>,
        warnings: [WarningItem]
    ) {
        self.setName = setName
        self.memberNames = memberNames
        self.definitionDigest = definitionDigest
        self.topologyDigest = topologyDigest
        self.members = members
        self.sourceLayoutNames = sourceLayoutNames
        self.retiringLayoutNames = retiringLayoutNames
        self.releasedEntryIDs = releasedEntryIDs
        self.transferredIdentities = transferredIdentities
        self.warnings = warnings
    }
}

public struct LayoutSetDryRunJSON: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public let layout: String
        public let resolvedDisplayID: String
        public let targetSpace: Int
        public let plan: [PlanItem]
        public let skipped: [SkippedItem]
    }

    public let schemaVersion: Int
    public let requestID: String
    public let setName: String
    public let result: String
    public let members: [Member]
    public let retiringLayouts: [String]
    public let releasedCount: Int
    public let transferredCount: Int
    public let warnings: [WarningItem]
    public let exitCode: Int

    public init(requestID: String, plan: LayoutSetPlan) {
        schemaVersion = 1
        self.requestID = requestID
        setName = plan.setName
        result = "dryRun"
        members = plan.members.map {
            Member(
                layout: $0.layoutName,
                resolvedDisplayID: $0.resolvedDisplayID,
                targetSpace: $0.targetSpaceID,
                plan: $0.arrangePlan.planItems,
                skipped: $0.arrangePlan.skipped
            )
        }
        retiringLayouts = plan.retiringLayoutNames
        releasedCount = plan.releasedEntryIDs.count
        transferredCount = plan.transferredIdentities.count
        warnings = plan.warnings
        exitCode = ErrorCode.success.rawValue
    }
}

public struct LayoutSetMemberResult: Codable, Equatable, Sendable {
    public let layout: String
    public let resolvedDisplayID: String?
    public let targetSpace: Int?
    public let result: String
    public let reason: String?

    public init(
        layout: String,
        resolvedDisplayID: String?,
        targetSpace: Int?,
        result: String,
        reason: String? = nil
    ) {
        self.layout = layout
        self.resolvedDisplayID = resolvedDisplayID
        self.targetSpace = targetSpace
        self.result = result
        self.reason = reason
    }
}

public struct LayoutSetExecutionJSON: Codable, Equatable, Sendable {
    public var outcomeDetail: String {
        (unresolved.map(\.reason) + warnings.map(\.detail) + memberResults.compactMap(\.reason)).joined(separator: "; ")
    }
    public let schemaVersion: Int
    public let requestID: String
    public let setName: String
    public let result: String
    public let phase: String
    public let ownershipCommitted: Bool
    public let selectedSet: String?
    public let memberResults: [LayoutSetMemberResult]
    public let releasedCount: Int
    public let transferredCount: Int
    public let unresolved: [PendingUnresolvedSlot]
    public let warnings: [WarningItem]
    public let focusOutcome: String
    public let recoveryRequired: Bool
    public let elapsedMS: Int
    public let exitCode: Int

    public init(
        requestID: String,
        setName: String,
        result: String,
        phase: String,
        ownershipCommitted: Bool,
        selectedSet: String?,
        memberResults: [LayoutSetMemberResult],
        releasedCount: Int,
        transferredCount: Int,
        unresolved: [PendingUnresolvedSlot],
        warnings: [WarningItem],
        focusOutcome: String,
        recoveryRequired: Bool,
        elapsedMS: Int,
        exitCode: Int
    ) {
        schemaVersion = 1
        self.requestID = requestID
        self.setName = setName
        self.result = result
        self.phase = phase
        self.ownershipCommitted = ownershipCommitted
        self.selectedSet = selectedSet
        self.memberResults = memberResults
        self.releasedCount = releasedCount
        self.transferredCount = transferredCount
        self.unresolved = unresolved
        self.warnings = warnings
        self.focusOutcome = focusOutcome
        self.recoveryRequired = recoveryRequired
        self.elapsedMS = elapsedMS
        self.exitCode = exitCode
    }
}

public struct LayoutSetsListJSON: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public let name: String
        public let layouts: [String]
        public let selected: Bool
        public let needsReapply: Bool
    }

    public let schemaVersion: Int
    public let selectedSet: String?
    public let sets: [Item]

    public init(selectedSet: String?, sets: [Item]) {
        schemaVersion = 1
        self.selectedSet = selectedSet
        self.sets = sets
    }
}
