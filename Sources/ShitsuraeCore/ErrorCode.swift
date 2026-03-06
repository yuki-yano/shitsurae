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
}

public struct CommonErrorJSON: Codable {
    public let schemaVersion: Int
    public let code: Int
    public let message: String
    public let subcode: String?

    public init(code: ErrorCode, message: String, subcode: String? = nil) {
        self.schemaVersion = 1
        self.code = code.rawValue
        self.message = message
        self.subcode = subcode
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
