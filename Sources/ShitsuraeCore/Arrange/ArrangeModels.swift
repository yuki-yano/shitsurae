import Foundation

public struct PlanItem: Codable, Equatable, Sendable {
    public let spaceID: Int
    public let slot: Int?
    public let bundleID: String
    public let action: String
    public let frame: ResolvedFrame?
    public let launch: Bool

    public init(spaceID: Int, slot: Int?, bundleID: String, action: String, frame: ResolvedFrame?, launch: Bool) {
        self.spaceID = spaceID
        self.slot = slot
        self.bundleID = bundleID
        self.action = action
        self.frame = frame
        self.launch = launch
    }
}

public struct SkippedItem: Codable, Equatable, Sendable {
    public let spaceID: Int?
    public let slot: Int?
    public let reason: String
    public let detail: String

    public init(spaceID: Int?, slot: Int?, reason: String, detail: String) {
        self.spaceID = spaceID
        self.slot = slot
        self.reason = reason
        self.detail = detail
    }
}

public struct WarningItem: Codable, Equatable, Sendable {
    public let code: String
    public let detail: String

    public init(code: String, detail: String) {
        self.code = code
        self.detail = detail
    }
}

public struct ErrorItem: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let spaceID: Int?
    public let slot: Int?

    public init(code: Int, message: String, spaceID: Int?, slot: Int?) {
        self.code = code
        self.message = message
        self.spaceID = spaceID
        self.slot = slot
    }
}

public struct ArrangeDryRunJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let layout: String
    public let availableSpaceIDs: [Int]
    public let plan: [PlanItem]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]

    public init(
        layout: String,
        availableSpaceIDs: [Int],
        plan: [PlanItem],
        skipped: [SkippedItem],
        warnings: [WarningItem]
    ) {
        self.schemaVersion = 2
        self.layout = layout
        self.availableSpaceIDs = availableSpaceIDs
        self.plan = plan
        self.skipped = skipped
        self.warnings = warnings
    }
}

public struct ArrangeExecutionJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let layout: String
    public let result: String
    public let subcode: String?
    public let unresolvedSlots: [PendingUnresolvedSlot]
    public let hardErrors: [ErrorItem]
    public let softErrors: [ErrorItem]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]
    public let exitCode: Int

    public init(
        layout: String,
        result: String,
        subcode: String?,
        unresolvedSlots: [PendingUnresolvedSlot],
        hardErrors: [ErrorItem],
        softErrors: [ErrorItem],
        skipped: [SkippedItem],
        warnings: [WarningItem],
        exitCode: Int
    ) {
        self.schemaVersion = 2
        self.layout = layout
        self.result = result
        self.subcode = subcode
        self.unresolvedSlots = unresolvedSlots
        self.hardErrors = hardErrors
        self.softErrors = softErrors
        self.skipped = skipped
        self.warnings = warnings
        self.exitCode = exitCode
    }
}
