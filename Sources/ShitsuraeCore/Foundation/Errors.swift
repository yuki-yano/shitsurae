import Foundation

/// v2 error codes. Mission Control / native-space related codes from v1
/// (spacesModeMismatch, spaceMoveFailed) are intentionally absent.
public enum ErrorCode: Int, Codable, CaseIterable, Sendable {
    case success = 0
    case invalidYAMLSyntax = 10
    case validationError = 11
    case configMergeConflict = 12
    case slotConflict = 13
    case missingPermission = 20
    case backendUnavailable = 30
    case ipcCommunicationError = 31
    case targetWindowNotFound = 40
    case appLaunchFailed = 41
    case externalCommandFailed = 42
    case operationTimedOut = 50
    case partialSuccess = 51
    case spaceSwitchFailed = 52
}

public struct ShitsuraeError: Error, Sendable, Equatable {
    public let code: ErrorCode
    public let message: String
    public let subcode: String?

    public init(_ code: ErrorCode, _ message: String, subcode: String? = nil) {
        self.code = code
        self.message = message
        self.subcode = subcode
    }
}

extension ShitsuraeError: CustomStringConvertible {
    public var description: String {
        if let subcode {
            return "\(message) [\(code)/\(subcode)]"
        }
        return "\(message) [\(code)]"
    }
}
