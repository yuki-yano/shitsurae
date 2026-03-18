import Foundation

public struct WindowCurrentJSON: Codable {
    public let schemaVersion: Int
    public let windowID: UInt32
    public let bundleID: String
    public let pid: Int
    public let title: String
    public let profile: String?
    public let spaceID: Int?
    public let activeSpaceID: Int?
    public let nativeSpaceID: Int?
    public let spacesMode: SpacesMode
    public let displayID: String
    public let role: String
    public let subrole: String?
    public let isMinimized: Bool
    public let frame: ResolvedFrame
    public let slot: Int?

    public init(
        schemaVersion: Int,
        windowID: UInt32,
        bundleID: String,
        pid: Int,
        title: String,
        profile: String? = nil,
        spaceID: Int?,
        activeSpaceID: Int?,
        nativeSpaceID: Int?,
        spacesMode: SpacesMode,
        displayID: String,
        role: String,
        subrole: String?,
        isMinimized: Bool,
        frame: ResolvedFrame,
        slot: Int?
    ) {
        self.schemaVersion = schemaVersion
        self.windowID = windowID
        self.bundleID = bundleID
        self.pid = pid
        self.title = title
        self.profile = profile
        self.spaceID = spaceID
        self.activeSpaceID = activeSpaceID
        self.nativeSpaceID = nativeSpaceID
        self.spacesMode = spacesMode
        self.displayID = displayID
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.frame = frame
        self.slot = slot
    }
}

public struct WindowWorkspaceJSON: Codable {
    public let schemaVersion: Int
    public let requestID: String
    public let windowID: UInt32
    public let bundleID: String
    public let slot: Int
    public let previousSpaceID: Int?
    public let spaceID: Int
    public let didChangeSpace: Bool
    public let didCreateTrackingEntry: Bool
    public let visibilityAction: String

    public init(
        schemaVersion: Int = 1,
        requestID: String,
        windowID: UInt32,
        bundleID: String,
        slot: Int,
        previousSpaceID: Int?,
        spaceID: Int,
        didChangeSpace: Bool,
        didCreateTrackingEntry: Bool,
        visibilityAction: String
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.windowID = windowID
        self.bundleID = bundleID
        self.slot = slot
        self.previousSpaceID = previousSpaceID
        self.spaceID = spaceID
        self.didChangeSpace = didChangeSpace
        self.didCreateTrackingEntry = didCreateTrackingEntry
        self.visibilityAction = visibilityAction
    }
}

public struct DisplaySummaryJSON: Codable, Equatable {
    public let id: String
    public let isPrimary: Bool
    public let scale: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frame: ResolvedFrame
    public let visibleFrame: ResolvedFrame

    public init(
        id: String,
        isPrimary: Bool,
        scale: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        frame: ResolvedFrame,
        visibleFrame: ResolvedFrame
    ) {
        self.id = id
        self.isPrimary = isPrimary
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct DisplayListJSON: Codable {
    public let schemaVersion: Int
    public let displays: [DisplaySummaryJSON]

    public init(schemaVersion: Int, displays: [DisplaySummaryJSON]) {
        self.schemaVersion = schemaVersion
        self.displays = displays
    }
}

public struct DisplayCurrentJSON: Codable {
    public let schemaVersion: Int
    public let display: DisplaySummaryJSON

    public init(schemaVersion: Int, display: DisplaySummaryJSON) {
        self.schemaVersion = schemaVersion
        self.display = display
    }
}

public struct SpaceSummaryJSON: Codable, Equatable {
    public let spaceID: Int
    public let kind: SpaceInterpretationMode
    public let displayID: String?
    public let isVisible: Bool
    public let isNativeFullscreen: Bool
    public let hasFocus: Bool
    public let trackedWindowIDs: [UInt32]

    public init(
        spaceID: Int,
        kind: SpaceInterpretationMode,
        displayID: String?,
        isVisible: Bool,
        isNativeFullscreen: Bool,
        hasFocus: Bool,
        trackedWindowIDs: [UInt32]
    ) {
        self.spaceID = spaceID
        self.kind = kind
        self.displayID = displayID
        self.isVisible = isVisible
        self.isNativeFullscreen = isNativeFullscreen
        self.hasFocus = hasFocus
        self.trackedWindowIDs = trackedWindowIDs
    }
}

public struct SpaceListJSON: Codable {
    public let schemaVersion: Int
    public let spaces: [SpaceSummaryJSON]

    public init(schemaVersion: Int, spaces: [SpaceSummaryJSON]) {
        self.schemaVersion = schemaVersion
        self.spaces = spaces
    }
}

public struct SpaceCurrentJSON: Codable {
    public let schemaVersion: Int
    public let space: SpaceSummaryJSON

    public init(schemaVersion: Int, space: SpaceSummaryJSON) {
        self.schemaVersion = schemaVersion
        self.space = space
    }
}

public struct SpaceSwitchJSON: Codable {
    public let requestID: String
    public let layoutName: String
    public let space: SpaceSummaryJSON
    public let previousSpaceID: Int?
    public let didChangeSpace: Bool
    public let action: String

    public init(
        requestID: String,
        layoutName: String,
        space: SpaceSummaryJSON,
        previousSpaceID: Int?,
        didChangeSpace: Bool,
        action: String
    ) {
        self.requestID = requestID
        self.layoutName = layoutName
        self.space = space
        self.previousSpaceID = previousSpaceID
        self.didChangeSpace = didChangeSpace
        self.action = action
    }
}

public struct SpaceRecoveryJSON: Codable {
    public let requestID: String
    public let clearedPending: Bool
    public let previousActiveLayoutName: String?
    public let previousActiveSpaceID: Int?
    public let warning: String
    public let nextActionKind: String
    public let discoveryCommand: String
    public let reconcileCommandTemplate: String

    public init(
        requestID: String,
        clearedPending: Bool,
        previousActiveLayoutName: String?,
        previousActiveSpaceID: Int?,
        warning: String,
        nextActionKind: String,
        discoveryCommand: String,
        reconcileCommandTemplate: String
    ) {
        self.requestID = requestID
        self.clearedPending = clearedPending
        self.previousActiveLayoutName = previousActiveLayoutName
        self.previousActiveSpaceID = previousActiveSpaceID
        self.warning = warning
        self.nextActionKind = nextActionKind
        self.discoveryCommand = discoveryCommand
        self.reconcileCommandTemplate = reconcileCommandTemplate
    }
}

public struct SwitcherListJSON: Codable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let includeAllSpaces: Bool
    public let spacesMode: SpacesMode
    public let candidates: [SwitcherCandidate]
}

public struct SwitcherCandidateQuery {
    public let includeAllSpaces: Bool
    public let spacesMode: SpacesMode
    public let quickKeys: String
    public let candidates: [SwitcherCandidate]

    public init(
        includeAllSpaces: Bool,
        spacesMode: SpacesMode,
        quickKeys: String,
        candidates: [SwitcherCandidate]
    ) {
        self.includeAllSpaces = includeAllSpaces
        self.spacesMode = spacesMode
        self.quickKeys = quickKeys
        self.candidates = candidates
    }
}

public enum SwitcherCandidateQueryResolution {
    case success(SwitcherCandidateQuery)
    case failure(CommandResult)
}

public enum SwitcherCandidatesResolution {
    case success([SwitcherCandidate])
    case failure(CommandResult)
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
