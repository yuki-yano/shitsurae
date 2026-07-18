import Foundation
import ShitsuraeCore

struct CLIWindowSelector: Equatable {
    let windowID: UInt32?
    let pid: Int?
    let processStartTime: UInt64?
    let bundleID: String?
    let title: String?

    func apply(to request: inout CommandRequest) {
        request.windowID = windowID
        request.pid = pid
        request.processStartTime = processStartTime
        request.bundleID = bundleID
        request.title = title
    }
}

enum CLIRequestBuilder {
    static func arrange(
        layout: String,
        dryRun: Bool,
        stateOnly: Bool,
        spaceID: Int?
    ) -> CommandRequest {
        var request = CommandRequest(command: "arrange")
        request.layout = layout
        request.dryRun = dryRun ? true : nil
        request.stateOnly = stateOnly ? true : nil
        request.spaceID = spaceID
        return request
    }

    static func spaceSwitch(spaceID: Int, reconcile: Bool) -> CommandRequest {
        var request = CommandRequest(command: "spaceSwitch")
        request.spaceID = spaceID
        request.reconcile = reconcile ? true : nil
        return request
    }

    static func spaceRecover() -> CommandRequest {
        var request = CommandRequest(command: "spaceRecover")
        request.forceClearPending = true
        return request
    }

    static func window(
        command: String,
        selector: CLIWindowSelector,
        spaceID: Int? = nil,
        x: String? = nil,
        y: String? = nil,
        width: String? = nil,
        height: String? = nil
    ) -> CommandRequest {
        var request = CommandRequest(command: command)
        request.spaceID = spaceID
        request.x = x
        request.y = y
        request.width = width
        request.height = height
        selector.apply(to: &request)
        return request
    }

    static func focus(slot: Int?, selector: CLIWindowSelector) -> CommandRequest {
        var request = CommandRequest(command: "focus")
        request.slot = slot
        selector.apply(to: &request)
        return request
    }

    static func switcherList(includeAllSpaces: Bool) -> CommandRequest {
        var request = CommandRequest(command: "switcherList")
        request.includeAllSpaces = includeAllSpaces
        return request
    }
}

struct CLIFormattedOutput: Equatable {
    let standardOutput: Data
    let standardError: Data
}

enum CLIOutputFormatter {
    static func error(code: ErrorCode, message: String, json: Bool) -> CLIFormattedOutput {
        if json {
            let payload = CommonErrorJSON(code: code, message: message)
            guard let encoded = try? JSONEncoder.pretty.encode(payload) else {
                preconditionFailure("CommonErrorJSON must always be encodable")
            }
            let data = encoded + Data("\n".utf8)
            return CLIFormattedOutput(standardOutput: data, standardError: Data())
        }
        return CLIFormattedOutput(
            standardOutput: Data(),
            standardError: Data("error: \(message)\n".utf8)
        )
    }
}
