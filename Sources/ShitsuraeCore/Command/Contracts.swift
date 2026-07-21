import Foundation

// CLI/IPC JSON contracts. v2 drops every native-space field from v1
// (nativeSpaceID / spacesMode / kind / isNativeFullscreen / source).

public struct WindowCurrentJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let windowID: UInt32
    public let bundleID: String
    public let pid: Int
    public let processStartTime: UInt64
    public let title: String
    public let profile: String?
    public let spaceID: Int?
    public let activeSpaceID: Int?
    public let displayID: String
    public let role: String?
    public let subrole: String?
    public let isModal: Bool?
    public let isMinimized: Bool
    public let frame: ResolvedFrame
    public let slot: Int?

    public init(
        windowID: UInt32,
        bundleID: String,
        pid: Int,
        processStartTime: UInt64,
        title: String,
        profile: String?,
        spaceID: Int?,
        activeSpaceID: Int?,
        displayID: String,
        role: String?,
        subrole: String?,
        isModal: Bool?,
        isMinimized: Bool,
        frame: ResolvedFrame,
        slot: Int?
    ) {
        self.schemaVersion = 4
        self.windowID = windowID
        self.bundleID = bundleID
        self.pid = pid
        self.processStartTime = processStartTime
        self.title = title
        self.profile = profile
        self.spaceID = spaceID
        self.activeSpaceID = activeSpaceID
        self.displayID = displayID
        self.role = role
        self.subrole = subrole
        self.isModal = isModal
        self.isMinimized = isMinimized
        self.frame = frame
        self.slot = slot
    }
}

public struct WindowWorkspaceJSON: Codable, Equatable, Sendable {
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
        self.schemaVersion = 2
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

public struct WindowSetJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let windowID: UInt32
    public let bundleID: String
    public let frame: ResolvedFrame

    public init(windowID: UInt32, bundleID: String, frame: ResolvedFrame) {
        self.schemaVersion = 2
        self.windowID = windowID
        self.bundleID = bundleID
        self.frame = frame
    }
}

public struct FocusJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let windowID: UInt32
    public let bundleID: String
    public let slot: Int?
    public let spaceID: Int?
    public let didSwitchSpace: Bool

    public init(windowID: UInt32, bundleID: String, slot: Int?, spaceID: Int?, didSwitchSpace: Bool) {
        self.schemaVersion = 2
        self.windowID = windowID
        self.bundleID = bundleID
        self.slot = slot
        self.spaceID = spaceID
        self.didSwitchSpace = didSwitchSpace
    }
}

public struct DisplaySummaryJSON: Codable, Equatable, Sendable {
    public let id: String
    public let isPrimary: Bool
    public let scale: Double
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frame: ResolvedFrame
    public let visibleFrame: ResolvedFrame

    public init(display: DisplayInfo) {
        self.id = display.id
        self.isPrimary = display.isPrimary
        self.scale = display.scale
        self.pixelWidth = display.width
        self.pixelHeight = display.height
        self.frame = ResolvedFrame(
            x: display.frame.origin.x,
            y: display.frame.origin.y,
            width: display.frame.width,
            height: display.frame.height
        )
        self.visibleFrame = ResolvedFrame(
            x: display.visibleFrame.origin.x,
            y: display.visibleFrame.origin.y,
            width: display.visibleFrame.width,
            height: display.visibleFrame.height
        )
    }
}

public struct DisplayListJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let displays: [DisplaySummaryJSON]

    public init(displays: [DisplaySummaryJSON]) {
        self.schemaVersion = 2
        self.displays = displays
    }
}

public struct DisplayCurrentJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let display: DisplaySummaryJSON

    public init(display: DisplaySummaryJSON) {
        self.schemaVersion = 2
        self.display = display
    }
}

public struct SpaceSummaryJSON: Codable, Equatable, Sendable {
    public let spaceID: Int
    public let displayID: String?
    public let isActive: Bool
    public let hasFocus: Bool
    public let trackedWindowIDs: [UInt32]

    public init(spaceID: Int, displayID: String?, isActive: Bool, hasFocus: Bool, trackedWindowIDs: [UInt32]) {
        self.spaceID = spaceID
        self.displayID = displayID
        self.isActive = isActive
        self.hasFocus = hasFocus
        self.trackedWindowIDs = trackedWindowIDs
    }
}

public struct SpaceListJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let layoutName: String?
    public let spaces: [SpaceSummaryJSON]

    public init(layoutName: String?, spaces: [SpaceSummaryJSON]) {
        self.schemaVersion = 2
        self.layoutName = layoutName
        self.spaces = spaces
    }
}

public struct SpaceCurrentJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let layoutName: String?
    public let space: SpaceSummaryJSON?
    public let recoveryRequired: Bool

    public init(layoutName: String?, space: SpaceSummaryJSON?, recoveryRequired: Bool) {
        self.schemaVersion = 2
        self.layoutName = layoutName
        self.space = space
        self.recoveryRequired = recoveryRequired
    }
}

public struct SpaceSwitchJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let layoutName: String
    public let spaceID: Int
    public let previousSpaceID: Int?
    public let didChangeSpace: Bool
    public let shownCount: Int
    public let hiddenCount: Int
    public let converged: Bool
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(requestID: String, outcome: SpaceSwitchOutcome) {
        self.schemaVersion = 2
        self.requestID = requestID
        self.layoutName = outcome.layoutName
        self.spaceID = outcome.targetSpaceID
        self.previousSpaceID = outcome.previousSpaceID
        self.didChangeSpace = outcome.didChangeSpace
        self.shownCount = outcome.shownCount
        self.hiddenCount = outcome.hiddenCount
        self.converged = outcome.converged
        self.unresolvedSlots = outcome.unresolvedSlots
    }
}

public struct SpaceRecoveryJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let clearedPending: Bool
    public let previousActiveLayoutName: String?
    public let previousActiveSpaceID: Int?
    public let warning: String

    public init(
        requestID: String,
        clearedPending: Bool,
        previousActiveLayoutName: String?,
        previousActiveSpaceID: Int?,
        warning: String
    ) {
        self.schemaVersion = 2
        self.requestID = requestID
        self.clearedPending = clearedPending
        self.previousActiveLayoutName = previousActiveLayoutName
        self.previousActiveSpaceID = previousActiveSpaceID
        self.warning = warning
    }
}

public struct SwitcherCandidate: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let bundleID: String
    public let pid: Int
    public let processStartTime: UInt64
    public let profile: String?
    public let spaceID: Int?
    public let displayID: String?
    public let slot: Int?
    public let quickKey: String?
    public let windowID: UInt32

    public init(
        id: String,
        title: String,
        bundleID: String,
        pid: Int,
        processStartTime: UInt64,
        profile: String? = nil,
        spaceID: Int?,
        displayID: String?,
        slot: Int?,
        quickKey: String?,
        windowID: UInt32
    ) {
        self.id = id
        self.title = title
        self.bundleID = bundleID
        self.pid = pid
        self.processStartTime = processStartTime
        self.profile = profile
        self.spaceID = spaceID
        self.displayID = displayID
        self.slot = slot
        self.quickKey = quickKey
        self.windowID = windowID
    }

    public var identity: WindowIdentity {
        WindowIdentity(
            pid: pid,
            processStartTime: processStartTime,
            windowID: windowID,
            bundleID: bundleID
        )
    }
}

public struct SwitcherListJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let includeAllSpaces: Bool
    public let candidates: [SwitcherCandidate]

    public init(generatedAt: String, includeAllSpaces: Bool, candidates: [SwitcherCandidate]) {
        self.schemaVersion = 4
        self.generatedAt = generatedAt
        self.includeAllSpaces = includeAllSpaces
        self.candidates = candidates
    }
}

public struct LayoutsListJSON: Codable, Equatable, Sendable {
    public struct LayoutSummary: Codable, Equatable, Sendable {
        public let name: String
        public let spaceIDs: [Int]
        public let windowCount: Int

        public init(name: String, spaceIDs: [Int], windowCount: Int) {
            self.name = name
            self.spaceIDs = spaceIDs
            self.windowCount = windowCount
        }
    }

    public let schemaVersion: Int
    public let layouts: [LayoutSummary]

    public init(layouts: [LayoutSummary]) {
        self.schemaVersion = 2
        self.layouts = layouts
    }
}

public struct DiagnosticsJSON: Codable, Equatable, Sendable {
    public struct Permissions: Codable, Equatable, Sendable {
        public let accessibility: Bool
        public let screenRecording: Bool

        public init(accessibility: Bool, screenRecording: Bool) {
            self.accessibility = accessibility
            self.screenRecording = screenRecording
        }
    }

    public struct StateSummary: Codable, Equatable, Sendable {
        public let activeLayoutName: String?
        public let activeSpaces: [ActiveSpace]
        public let slotCount: Int
        public let hiddenCount: Int
        public let recoveryRequired: Bool
        public let pendingUnresolvedSlots: [PendingUnresolvedSlot]
        public let configGeneration: String
        public let revision: UInt64

        public init(
            activeLayoutName: String?,
            activeSpaces: [ActiveSpace],
            slotCount: Int,
            hiddenCount: Int,
            recoveryRequired: Bool,
            pendingUnresolvedSlots: [PendingUnresolvedSlot],
            configGeneration: String,
            revision: UInt64
        ) {
            self.activeLayoutName = activeLayoutName
            self.activeSpaces = activeSpaces
            self.slotCount = slotCount
            self.hiddenCount = hiddenCount
            self.recoveryRequired = recoveryRequired
            self.pendingUnresolvedSlots = pendingUnresolvedSlots
            self.configGeneration = configGeneration
            self.revision = revision
        }
    }

    public struct PrivateAPIs: Codable, Equatable, Sendable {
        public let operatingSystemVersion: String
        public let targetedWindowFocusSymbolsAvailable: Bool
        public let symbolicHotKeySymbolAvailable: Bool
        public let axWindowIDBridgeSymbolAvailable: Bool
        public let keyWindowEventRecordBytes: Int

        public init(
            operatingSystemVersion: String,
            targetedWindowFocusSymbolsAvailable: Bool,
            symbolicHotKeySymbolAvailable: Bool,
            axWindowIDBridgeSymbolAvailable: Bool,
            keyWindowEventRecordBytes: Int
        ) {
            self.operatingSystemVersion = operatingSystemVersion
            self.targetedWindowFocusSymbolsAvailable = targetedWindowFocusSymbolsAvailable
            self.symbolicHotKeySymbolAvailable = symbolicHotKeySymbolAvailable
            self.axWindowIDBridgeSymbolAvailable = axWindowIDBridgeSymbolAvailable
            self.keyWindowEventRecordBytes = keyWindowEventRecordBytes
        }
    }

    public let schemaVersion: Int
    public let version: String
    public let permissions: Permissions
    public let configFiles: [ConfigFileStatus]
    public let configReload: ConfigReloadStatus?
    public let state: StateSummary
    public let displays: [DisplaySummaryJSON]
    public let privateAPIs: PrivateAPIs

    public init(
        version: String,
        permissions: Permissions,
        configFiles: [ConfigFileStatus],
        configReload: ConfigReloadStatus?,
        state: StateSummary,
        displays: [DisplaySummaryJSON],
        privateAPIs: PrivateAPIs
    ) {
        self.schemaVersion = 3
        self.version = version
        self.permissions = permissions
        self.configFiles = configFiles
        self.configReload = configReload
        self.state = state
        self.displays = displays
        self.privateAPIs = privateAPIs
    }
}

public struct CommonErrorJSON: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let code: Int
    public let message: String
    public let subcode: String?
    public let requestID: String

    public init(
        code: ErrorCode,
        message: String,
        subcode: String? = nil,
        requestID: String = UUID().uuidString.lowercased()
    ) {
        self.schemaVersion = 2
        self.code = code.rawValue
        self.message = message
        self.subcode = subcode
        self.requestID = requestID
    }
}
