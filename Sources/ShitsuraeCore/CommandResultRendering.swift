import Foundation

func commonJSONError(
    _ code: ErrorCode,
    _ message: String,
    toStdErr: Bool,
    subcode: String? = nil,
    requestID: String? = nil,
    recoveryContext: RecoveryContextJSON? = nil
) -> CommandResult {
    let payload = CommonErrorJSON(
        code: code,
        message: message,
        subcode: subcode,
        requestID: requestID ?? UUID().uuidString.lowercased(),
        recoveryContext: recoveryContext
    )
    let encoded = encodeJSON(payload) + "\n"
    if toStdErr {
        return CommandResult(exitCode: Int32(code.rawValue), stderr: encoded)
    }
    return CommandResult(exitCode: Int32(code.rawValue), stdout: encoded)
}

func errorAsResult(code: ErrorCode, message: String, json: Bool) -> CommandResult {
    if json {
        let payload = CommonErrorJSON(code: code, message: message)
        return CommandResult(exitCode: Int32(code.rawValue), stdout: encodeJSON(payload) + "\n")
    }

    return CommandResult(exitCode: Int32(code.rawValue), stderr: message + "\n")
}

func spaceSwitchError(
    code: ErrorCode,
    message: String,
    subcode: String,
    requestID: String? = nil,
    recoveryContext: RecoveryContextJSON? = nil,
    json: Bool
) -> CommandResult {
    if json {
        let payload = CommonErrorJSON(
            code: code,
            message: message,
            subcode: subcode,
            requestID: requestID ?? UUID().uuidString.lowercased(),
            recoveryContext: recoveryContext
        )
        return CommandResult(exitCode: Int32(code.rawValue), stdout: encodeJSON(payload) + "\n")
    }
    return CommandResult(exitCode: Int32(code.rawValue), stderr: message + "\n")
}

func runtimeStateLoadErrorResult(
    _ error: RuntimeStateStoreError,
    json: Bool,
    requestID: String? = nil
) -> CommandResult {
    let subcode = error.validationSubcode ?? "runtimeStateCorrupted"
    return spaceSwitchError(
        code: .validationError,
        message: runtimeStateErrorMessage(error),
        subcode: subcode,
        requestID: requestID,
        json: json
    )
}

func runtimeStateErrorMessage(_ error: RuntimeStateStoreError) -> String {
    switch error {
    case .corrupted:
        return "runtime state is corrupted"
    case .readPermissionDenied:
        return "runtime state read permission is denied"
    case .readFailed:
        return "runtime state read failed"
    case .encodingFailed:
        return "runtime state encoding failed"
    case .staleWriteRejected:
        return "runtime state write was rejected because the state is stale"
    case .writePermissionDenied:
        return "runtime state write permission is denied"
    case .writeFailed:
        return "runtime state write failed"
    }
}

func runtimeStateWriteRootCause(_ error: Error) -> String {
    if let stateError = error as? RuntimeStateStoreError {
        return stateError.rootCauseCategory
    }
    return "runtimeStateWriteFailed"
}

func isStaleStateWriteRejected(_ error: Error) -> Bool {
    guard let stateError = error as? RuntimeStateStoreError else {
        return false
    }
    return stateError.validationSubcode == "staleStateWriteRejected"
}

func arrangeFailureResult(
    layoutName: String,
    spacesMode: SpacesMode,
    message: String,
    subcode: String,
    exitCode: Int,
    spaceID: Int?,
    json: Bool
) -> CommandResult {
    let payload = ArrangeExecutionJSON(
        schemaVersion: 2,
        layout: layoutName,
        spacesMode: spacesMode,
        result: "failed",
        subcode: subcode,
        unresolvedSlots: [],
        hardErrors: [
            ErrorItem(
                code: exitCode,
                message: message,
                spaceID: spaceID,
                slot: nil
            ),
        ],
        softErrors: [],
        skipped: [],
        warnings: [],
        exitCode: exitCode
    )
    if json {
        return CommandResult(exitCode: Int32(exitCode), stdout: encodeJSON(payload) + "\n")
    }
    return CommandResult(exitCode: Int32(exitCode), stdout: ArrangeCommandOutputRenderer.execution(payload))
}

func encodeJSON<T: Encodable>(_ value: T) -> String {
    guard let data = try? JSONEncoder.pretty.encode(value),
          let text = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }

    return text
}
