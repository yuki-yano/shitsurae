import Foundation

public enum VisibilityState: String, Codable, Equatable, Sendable {
    case visible
    case hiddenOffscreen
}

public enum SlotOrigin: String, Codable, Equatable, Sendable {
    /// Defined by a layout window definition.
    case layout
    /// Adopted at runtime (untracked window pulled into the active workspace).
    case adopted
}

/// One tracked window binding. Persisted in RuntimeState.
///
/// v2 removed from v1: nativeSpaceID (no native spaces), source (always a
/// window), layoutOriginSpaceID/Slot (replaced by `layoutSpaceID`), and all
/// "legacy" decoder fallbacks.
public struct SlotEntry: Codable, Equatable, Sendable {
    /// Stable identity, assigned once at creation. All write-side updates go
    /// through id lookup — never through fuzzy matching.
    public var id: String
    public var layoutName: String
    /// The virtual workspace this window currently belongs to.
    public var spaceID: Int
    public var slot: Int
    public var origin: SlotOrigin
    /// Normalized matcher key; identifies the layout definition the entry was
    /// created from so arranges can preserve runtime fields.
    public var definitionFingerprint: String
    /// The spaceID the layout definition places this window on (nil for
    /// adopted entries). The layout frame applies only while
    /// `spaceID == layoutSpaceID`.
    public var layoutSpaceID: Int?

    // Matcher (mirrors WindowMatchRule)
    public var bundleID: String
    public var titleMatchKind: TitleMatchKind
    public var titleMatchValue: String?
    public var excludeTitleRegex: String?
    public var role: String?
    public var subrole: String?
    public var matchIndex: Int?
    public var profile: String?

    // Runtime
    public var pid: Int?
    public var windowID: UInt32?
    public var lastKnownTitle: String?
    public var displayID: String?
    public var lastVisibleFrame: ResolvedFrame?
    public var lastHiddenFrame: ResolvedFrame?
    public var visibilityState: VisibilityState
    public var lastActivatedAt: String?

    public enum TitleMatchKind: String, Codable, Equatable, Sendable {
        case none
        case equals
        case contains
        case regex
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        layoutName: String,
        spaceID: Int,
        slot: Int,
        origin: SlotOrigin,
        definitionFingerprint: String,
        layoutSpaceID: Int? = nil,
        bundleID: String,
        titleMatchKind: TitleMatchKind = .none,
        titleMatchValue: String? = nil,
        excludeTitleRegex: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        matchIndex: Int? = nil,
        profile: String? = nil,
        pid: Int? = nil,
        windowID: UInt32? = nil,
        lastKnownTitle: String? = nil,
        displayID: String? = nil,
        lastVisibleFrame: ResolvedFrame? = nil,
        lastHiddenFrame: ResolvedFrame? = nil,
        visibilityState: VisibilityState = .visible,
        lastActivatedAt: String? = nil
    ) {
        self.id = id
        self.layoutName = layoutName
        self.spaceID = spaceID
        self.slot = slot
        self.origin = origin
        self.definitionFingerprint = definitionFingerprint
        self.layoutSpaceID = layoutSpaceID
        self.bundleID = bundleID
        self.titleMatchKind = titleMatchKind
        self.titleMatchValue = titleMatchValue
        self.excludeTitleRegex = excludeTitleRegex
        self.role = role
        self.subrole = subrole
        self.matchIndex = matchIndex
        self.profile = profile
        self.pid = pid
        self.windowID = windowID
        self.lastKnownTitle = lastKnownTitle
        self.displayID = displayID
        self.lastVisibleFrame = lastVisibleFrame
        self.lastHiddenFrame = lastHiddenFrame
        self.visibilityState = visibilityState
        self.lastActivatedAt = lastActivatedAt
    }

    public var title: String {
        lastKnownTitle ?? titleMatchValue ?? bundleID
    }

    public var matchRule: WindowMatchRule {
        let titleMatcher: TitleMatcher?
        switch titleMatchKind {
        case .none:
            titleMatcher = nil
        case .equals:
            titleMatcher = TitleMatcher(equals: titleMatchValue)
        case .contains:
            titleMatcher = TitleMatcher(contains: titleMatchValue)
        case .regex:
            titleMatcher = TitleMatcher(regex: titleMatchValue)
        }
        return WindowMatchRule(
            bundleID: bundleID,
            title: titleMatcher,
            role: role,
            subrole: subrole,
            profile: profile,
            excludeTitleRegex: excludeTitleRegex,
            index: matchIndex
        )
    }

    public var registryEntry: WindowRegistry.Entry {
        WindowRegistry.Entry(id: id, rule: matchRule, windowID: windowID)
    }

    /// Refreshes the runtime binding fields from a live window. Matcher and
    /// placement fields are untouched.
    public func bound(to window: WindowSnapshot) -> SlotEntry {
        var copy = self
        copy.windowID = window.windowID
        copy.pid = window.pid
        copy.lastKnownTitle = window.title
        copy.displayID = window.displayID ?? displayID
        return copy
    }

    public static func makeEntry(
        layoutName: String,
        spaceID: Int,
        definition: WindowDefinition
    ) -> SlotEntry {
        let kind: TitleMatchKind
        let value: String?
        if let equals = definition.match.title?.equals {
            kind = .equals
            value = equals
        } else if let contains = definition.match.title?.contains {
            kind = .contains
            value = contains
        } else if let regex = definition.match.title?.regex {
            kind = .regex
            value = regex
        } else {
            kind = .none
            value = nil
        }

        return SlotEntry(
            layoutName: layoutName,
            spaceID: spaceID,
            slot: definition.slot,
            origin: .layout,
            definitionFingerprint: fingerprint(layoutName: layoutName, spaceID: spaceID, definition: definition),
            layoutSpaceID: spaceID,
            bundleID: definition.match.bundleID,
            titleMatchKind: kind,
            titleMatchValue: value,
            excludeTitleRegex: definition.match.excludeTitleRegex,
            role: definition.match.role,
            subrole: definition.match.subrole,
            matchIndex: definition.match.index,
            profile: definition.match.profile
        )
    }

    public static func fingerprint(layoutName: String, spaceID: Int, definition: WindowDefinition) -> String {
        let title = definition.match.title
        let titleKey: String
        if let equals = title?.equals {
            titleKey = "equals:\(equals)"
        } else if let contains = title?.contains {
            titleKey = "contains:\(contains)"
        } else if let regex = title?.regex {
            titleKey = "regex:\(regex)"
        } else {
            titleKey = "none"
        }
        return [
            "layout:\(layoutName)",
            "space:\(spaceID)",
            "slot:\(definition.slot)",
            "bundleID:\(definition.match.bundleID)",
            "title:\(titleKey)",
            "profile:\(definition.match.profile ?? "<nil>")",
            "role:\(definition.match.role ?? "<nil>")",
            "subrole:\(definition.match.subrole ?? "<nil>")",
            "index:\(definition.match.index.map(String.init) ?? "<nil>")",
            "exclude:\(definition.match.excludeTitleRegex ?? "<nil>")",
        ].joined(separator: "\u{0}")
    }
}

public struct PendingUnresolvedSlot: Codable, Equatable, Sendable {
    public let slot: Int
    public let spaceID: Int
    public let reason: String

    public init(slot: Int, spaceID: Int, reason: String) {
        self.slot = slot
        self.spaceID = spaceID
        self.reason = reason
    }
}

/// The single pending structure in v2 (PendingSwitchTransaction was removed).
/// Non-nil means the last visibility application did not fully converge; the
/// engine retries reconciliation and diagnostics report recoveryRequired.
public struct PendingVisibilityConvergence: Codable, Equatable, Sendable {
    public let requestID: String
    public let startedAt: String
    public let layoutName: String
    public let targetSpaceID: Int
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(
        requestID: String,
        startedAt: String,
        layoutName: String,
        targetSpaceID: Int,
        unresolvedSlots: [PendingUnresolvedSlot] = []
    ) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.layoutName = layoutName
        self.targetSpaceID = targetSpaceID
        self.unresolvedSlots = unresolvedSlots
    }
}

/// Active workspace per display. v2.0 keeps exactly one element (the host
/// display); the schema is a map so per-display workspaces can ship without a
/// schema migration.
public struct ActiveSpace: Codable, Equatable, Sendable {
    public var displayID: String
    public var spaceID: Int

    public init(displayID: String, spaceID: Int) {
        self.displayID = displayID
        self.spaceID = spaceID
    }
}

public struct RuntimeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var updatedAt: String
    public var revision: UInt64
    public var configGeneration: String
    public var liveArrangeRecoveryRequired: Bool
    public var activeLayoutName: String?
    public var activeSpaces: [ActiveSpace]
    public var pendingVisibilityConvergence: PendingVisibilityConvergence?
    public var slots: [SlotEntry]

    public init(
        schemaVersion: Int = RuntimeState.currentSchemaVersion,
        updatedAt: String = Date.rfc3339UTC(),
        revision: UInt64 = 0,
        configGeneration: String = "",
        liveArrangeRecoveryRequired: Bool = false,
        activeLayoutName: String? = nil,
        activeSpaces: [ActiveSpace] = [],
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil,
        slots: [SlotEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.revision = revision
        self.configGeneration = configGeneration
        self.liveArrangeRecoveryRequired = liveArrangeRecoveryRequired
        self.activeLayoutName = activeLayoutName
        self.activeSpaces = activeSpaces
        self.pendingVisibilityConvergence = pendingVisibilityConvergence
        self.slots = slots
    }

    /// v2.0 single-host-display accessor.
    public var primaryActiveSpaceID: Int? {
        activeSpaces.first?.spaceID
    }

    public func activeSpaceID(displayID: String) -> Int? {
        activeSpaces.first(where: { $0.displayID == displayID })?.spaceID
    }

    public mutating func setActiveSpace(displayID: String, spaceID: Int) {
        if let index = activeSpaces.firstIndex(where: { $0.displayID == displayID }) {
            activeSpaces[index].spaceID = spaceID
        } else {
            activeSpaces.append(ActiveSpace(displayID: displayID, spaceID: spaceID))
        }
    }

    public func slots(layoutName: String) -> [SlotEntry] {
        slots.filter { $0.layoutName == layoutName }
    }

    public var recoveryRequired: Bool {
        pendingVisibilityConvergence != nil || liveArrangeRecoveryRequired
    }
}
