import Foundation

public struct WindowCurrentJSON: Codable {
    public let schemaVersion: Int
    public let bundleID: String
    public let pid: Int
    public let title: String
    public let spaceID: Int?
    public let spacesMode: SpacesMode
    public let displayID: String
    public let role: String
    public let subrole: String?
    public let isMinimized: Bool
    public let frame: ResolvedFrame
    public let slot: Int?
}

public struct SwitcherListJSON: Codable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let includeAllSpaces: Bool
    public let spacesMode: SpacesMode
    public let candidates: [SwitcherCandidate]
}

public struct SwitcherCandidate: Codable, Sendable {
    public let id: String
    public let source: WindowSource
    public let title: String
    public let bundleID: String?
    public let spaceID: Int?
    public let displayID: String?
    public let slot: Int?
    public let quickKey: String?
}
