import Foundation

public extension Date {
    static func rfc3339UTC() -> String {
        makeRFC3339UTCFormatter().string(from: Date())
    }
}

func makeRFC3339UTCFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}

public extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
}

public struct WindowTargetSelector: Codable, Equatable, Sendable {
    public let windowID: UInt32?
    public let pid: Int?
    public let processStartTime: UInt64?
    public let bundleID: String?
    public let title: String?

    public init(
        windowID: UInt32? = nil,
        pid: Int? = nil,
        processStartTime: UInt64? = nil,
        bundleID: String? = nil,
        title: String? = nil
    ) {
        self.windowID = windowID
        self.pid = pid
        self.processStartTime = processStartTime
        self.bundleID = bundleID
        self.title = title
    }

    public var isEmpty: Bool {
        windowID == nil && pid == nil && processStartTime == nil && bundleID == nil && title == nil
    }
}

public struct ApplicationLaunchRequest: Equatable, Sendable {
    public let bundleID: String
    public let profileDirectory: String?

    public init(bundleID: String, profileDirectory: String? = nil) {
        self.bundleID = bundleID
        self.profileDirectory = profileDirectory
    }
}
