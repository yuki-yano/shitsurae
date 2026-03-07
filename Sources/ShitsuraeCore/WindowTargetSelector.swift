import Foundation

public struct WindowTargetSelector: Codable, Equatable, Sendable {
    public let windowID: UInt32?
    public let bundleID: String?
    public let title: String?

    public init(windowID: UInt32?, bundleID: String?, title: String?) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
    }

    public var isEmpty: Bool {
        windowID == nil && bundleID == nil && title == nil
    }
}
