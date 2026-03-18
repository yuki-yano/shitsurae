import Foundation

public enum ErrorCode: Int, Codable, CaseIterable, Sendable {
    case success = 0
    case invalidYAMLSyntax = 10
    case validationError = 11
    case configMergeConflict = 12
    case slotConflict = 13
    case missingPermission = 20
    case spacesModeMismatch = 21
    case backendUnavailable = 30
    case xpcCommunicationError = 31
    case spaceMoveFailed = 32
    case targetWindowNotFound = 40
    case appLaunchFailed = 41
    case externalCommandFailed = 42
    case operationTimedOut = 50
    case partialSuccess = 51
    case virtualSpaceSwitchFailed = 52
    case virtualSpaceSwitchRollbackFailed = 53
}

public struct RecoveryContextJSON: Codable {
    public let activeLayoutName: String?
    public let activeVirtualSpaceID: Int?
    public let attemptedTargetSpaceID: Int?
    public let previousActiveSpaceID: Int?
    public let lockOwnerPID: Int?
    public let lockOwnerProcessKind: String?
    public let lockOwnerStartedAt: String?
    public let lockWaitTimeoutMS: Int?
    public let recoveryForceClearEligible: Bool?
    public let manualRecoveryRequired: Bool?
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(
        activeLayoutName: String?,
        activeVirtualSpaceID: Int?,
        attemptedTargetSpaceID: Int?,
        previousActiveSpaceID: Int?,
        lockOwnerPID: Int? = nil,
        lockOwnerProcessKind: String? = nil,
        lockOwnerStartedAt: String? = nil,
        lockWaitTimeoutMS: Int? = nil,
        recoveryForceClearEligible: Bool? = nil,
        manualRecoveryRequired: Bool? = nil,
        unresolvedSlots: [PendingUnresolvedSlot] = []
    ) {
        self.activeLayoutName = activeLayoutName
        self.activeVirtualSpaceID = activeVirtualSpaceID
        self.attemptedTargetSpaceID = attemptedTargetSpaceID
        self.previousActiveSpaceID = previousActiveSpaceID
        self.lockOwnerPID = lockOwnerPID
        self.lockOwnerProcessKind = lockOwnerProcessKind
        self.lockOwnerStartedAt = lockOwnerStartedAt
        self.lockWaitTimeoutMS = lockWaitTimeoutMS
        self.recoveryForceClearEligible = recoveryForceClearEligible
        self.manualRecoveryRequired = manualRecoveryRequired
        self.unresolvedSlots = unresolvedSlots
    }
}

public struct CommonErrorJSON: Codable {
    public let schemaVersion: Int
    public let code: Int
    public let message: String
    public let subcode: String?
    public let requestID: String
    public let recoveryContext: RecoveryContextJSON?

    public init(
        code: ErrorCode,
        message: String,
        subcode: String? = nil,
        requestID: String = UUID().uuidString.lowercased(),
        recoveryContext: RecoveryContextJSON? = nil
    ) {
        self.schemaVersion = 2
        self.code = code.rawValue
        self.message = message
        self.subcode = subcode
        self.requestID = requestID
        self.recoveryContext = recoveryContext
    }
}

public struct ShitsuraeError: Error, Sendable {
    public let code: ErrorCode
    public let message: String
    public let subcode: String?

    public init(_ code: ErrorCode, _ message: String, subcode: String? = nil) {
        self.code = code
        self.message = message
        self.subcode = subcode
    }
}
