import Foundation

public struct WindowCurrentJSON: Codable {
    public let schemaVersion: Int
    public let bundleID: String
    public let pid: Int
    public let title: String
    public let profile: String?
    public let spaceID: Int?
    public let spacesMode: SpacesMode
    public let displayID: String
    public let role: String
    public let subrole: String?
    public let isMinimized: Bool
    public let frame: ResolvedFrame
    public let slot: Int?

    public init(
        schemaVersion: Int,
        bundleID: String,
        pid: Int,
        title: String,
        profile: String? = nil,
        spaceID: Int?,
        spacesMode: SpacesMode,
        displayID: String,
        role: String,
        subrole: String?,
        isMinimized: Bool,
        frame: ResolvedFrame,
        slot: Int?
    ) {
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.pid = pid
        self.title = title
        self.profile = profile
        self.spaceID = spaceID
        self.spacesMode = spacesMode
        self.displayID = displayID
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.frame = frame
        self.slot = slot
    }
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
    public let profile: String?
    public let spaceID: Int?
    public let displayID: String?
    public let slot: Int?
    public let quickKey: String?

    public init(
        id: String,
        source: WindowSource,
        title: String,
        bundleID: String?,
        profile: String? = nil,
        spaceID: Int?,
        displayID: String?,
        slot: Int?,
        quickKey: String?
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.bundleID = bundleID
        self.profile = profile
        self.spaceID = spaceID
        self.displayID = displayID
        self.slot = slot
        self.quickKey = quickKey
    }
}
