import Foundation

// MARK: - Merged config (post-merge, non-optional layouts)

public struct ShitsuraeConfig: Codable, Equatable, Sendable {
    public let app: AppDefinition?
    public let ignore: IgnoreDefinition?
    public let overlay: OverlayDefinition?
    public let monitors: MonitorsDefinition?
    public let layouts: [String: LayoutDefinition]
    public let shortcuts: ShortcutsDefinition?
    public let mode: ModeDefinition?

    public init(
        app: AppDefinition? = nil,
        ignore: IgnoreDefinition? = nil,
        overlay: OverlayDefinition? = nil,
        monitors: MonitorsDefinition? = nil,
        layouts: [String: LayoutDefinition],
        shortcuts: ShortcutsDefinition? = nil,
        mode: ModeDefinition? = nil
    ) {
        self.app = app
        self.ignore = ignore
        self.overlay = overlay
        self.monitors = monitors
        self.layouts = layouts
        self.shortcuts = shortcuts
        self.mode = mode
    }
}

// MARK: - Per-file config (pre-merge, everything optional)

public struct ShitsuraeConfigFile: Decodable {
    public let app: AppDefinition?
    public let ignore: IgnoreDefinition?
    public let overlay: OverlayDefinition?
    public let monitors: MonitorsDefinition?
    public let layouts: [String: LayoutDefinition]?
    public let shortcuts: ShortcutsDefinition?
    public let mode: ModeDefinition?

    private enum CodingKeys: String, CodingKey {
        case app
        case ignore
        case overlay
        case monitors
        case layouts
        case shortcuts
        case mode
        case executionPolicy
    }

    private enum ModeProbeKeys: String, CodingKey {
        case space
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Report every removed v1 key at once so migration is a single edit.
        var removedKeyMessages: [String] = []
        if container.contains(.mode),
           let modeContainer = try? container.nestedContainer(keyedBy: ModeProbeKeys.self, forKey: .mode),
           modeContainer.contains(.space)
        {
            removedKeyMessages.append("mode.space was removed in v2 (always virtual)")
        }
        if container.contains(.executionPolicy) {
            removedKeyMessages.append("executionPolicy was removed in v2 (Mission Control support was dropped)")
        }
        if !removedKeyMessages.isEmpty {
            throw ShitsuraeError(
                .validationError,
                removedKeyMessages.joined(separator: "; ") + "; delete these keys from the config",
                subcode: "removedConfigKey"
            )
        }

        app = try container.decodeIfPresent(AppDefinition.self, forKey: .app)
        ignore = try container.decodeIfPresent(IgnoreDefinition.self, forKey: .ignore)
        overlay = try container.decodeIfPresent(OverlayDefinition.self, forKey: .overlay)
        monitors = try container.decodeIfPresent(MonitorsDefinition.self, forKey: .monitors)
        layouts = try container.decodeIfPresent([String: LayoutDefinition].self, forKey: .layouts)
        shortcuts = try container.decodeIfPresent(ShortcutsDefinition.self, forKey: .shortcuts)
        mode = try container.decodeIfPresent(ModeDefinition.self, forKey: .mode)
    }
}

// MARK: - Sections

public struct AppDefinition: Codable, Equatable, Sendable {
    public let launchAtLogin: Bool?

    public init(launchAtLogin: Bool? = nil) {
        self.launchAtLogin = launchAtLogin
    }
}

/// v2: only followFocus remains. `mode.space` was removed together with native
/// (Mission Control) mode; specifying it is a hard validation error.
public struct ModeDefinition: Codable, Equatable, Sendable {
    public let followFocus: Bool?

    public init(followFocus: Bool? = nil) {
        self.followFocus = followFocus
    }

    private enum CodingKeys: String, CodingKey {
        case followFocus
        case space
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.space) {
            throw ShitsuraeError(
                .validationError,
                "mode.space was removed in v2 (always virtual); delete the mode.space key",
                subcode: "removedConfigKey"
            )
        }
        followFocus = try container.decodeIfPresent(Bool.self, forKey: .followFocus)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(followFocus, forKey: .followFocus)
    }
}

public struct LayoutDefinition: Codable, Equatable, Sendable {
    public let initialFocus: InitialFocusDefinition?
    public let spaces: [SpaceDefinition]

    public init(initialFocus: InitialFocusDefinition? = nil, spaces: [SpaceDefinition]) {
        self.initialFocus = initialFocus
        self.spaces = spaces
    }
}

public struct InitialFocusDefinition: Codable, Equatable, Sendable {
    public let slot: Int

    public init(slot: Int) {
        self.slot = slot
    }
}

public struct SpaceDefinition: Codable, Equatable, Sendable {
    public let spaceID: Int
    public let display: DisplayDefinition?
    public let windows: [WindowDefinition]

    public init(spaceID: Int, display: DisplayDefinition? = nil, windows: [WindowDefinition]) {
        self.spaceID = spaceID
        self.display = display
        self.windows = windows
    }
}

public struct WindowDefinition: Codable, Equatable, Sendable {
    public let match: WindowMatchRule
    public let slot: Int
    public let launch: Bool?
    public let frame: FrameDefinition

    public init(match: WindowMatchRule, slot: Int, launch: Bool? = nil, frame: FrameDefinition) {
        self.match = match
        self.slot = slot
        self.launch = launch
        self.frame = frame
    }
}

public struct WindowMatchRule: Codable, Equatable, Sendable {
    public let bundleID: String
    public let title: TitleMatcher?
    public let role: String?
    public let subrole: String?
    public let profile: String?
    public let excludeTitleRegex: String?
    public let index: Int?

    public init(
        bundleID: String,
        title: TitleMatcher? = nil,
        role: String? = nil,
        subrole: String? = nil,
        profile: String? = nil,
        excludeTitleRegex: String? = nil,
        index: Int? = nil
    ) {
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.subrole = subrole
        self.profile = profile
        self.excludeTitleRegex = excludeTitleRegex
        self.index = index
    }

    /// True when this rule can distinguish between multiple windows of the
    /// same application. Used by validation to reject ambiguous layouts.
    public var hasDiscriminator: Bool {
        title != nil || profile != nil || index != nil
    }
}

public struct TitleMatcher: Codable, Equatable, Sendable {
    public let equals: String?
    public let contains: String?
    public let regex: String?

    public init(equals: String? = nil, contains: String? = nil, regex: String? = nil) {
        self.equals = equals
        self.contains = contains
        self.regex = regex
    }
}

public struct IgnoreDefinition: Codable, Equatable, Sendable {
    public let apply: IgnoreRuleSet?
    public let focus: IgnoreRuleSet?

    public init(apply: IgnoreRuleSet? = nil, focus: IgnoreRuleSet? = nil) {
        self.apply = apply
        self.focus = focus
    }
}

public struct IgnoreRuleSet: Codable, Equatable, Sendable {
    public let apps: [String]?
    public let windows: [IgnoreWindowRule]?

    public init(apps: [String]? = nil, windows: [IgnoreWindowRule]? = nil) {
        self.apps = apps
        self.windows = windows
    }
}

public struct IgnoreWindowRule: Codable, Equatable, Sendable {
    public let bundleID: String?
    public let titleRegex: String?
    public let role: String?
    public let subrole: String?
    public let minimized: Bool?
    public let hidden: Bool?

    public init(
        bundleID: String? = nil,
        titleRegex: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        minimized: Bool? = nil,
        hidden: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.titleRegex = titleRegex
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
        self.hidden = hidden
    }
}

public struct MonitorsDefinition: Codable, Equatable, Sendable {
    public let primary: MonitorTargetDefinition?
    public let secondary: MonitorTargetDefinition?

    public init(primary: MonitorTargetDefinition? = nil, secondary: MonitorTargetDefinition? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}

public struct MonitorTargetDefinition: Codable, Equatable, Sendable {
    public let id: String?

    public init(id: String? = nil) {
        self.id = id
    }
}

public struct OverlayDefinition: Codable, Equatable, Sendable {
    public let showThumbnails: Bool?

    public init(showThumbnails: Bool? = nil) {
        self.showThumbnails = showThumbnails
    }
}

public struct DisplayDefinition: Codable, Equatable, Sendable {
    public let monitor: MonitorRole?
    public let id: String?
    public let width: Int?
    public let height: Int?

    public init(monitor: MonitorRole? = nil, id: String? = nil, width: Int? = nil, height: Int? = nil) {
        self.monitor = monitor
        self.id = id
        self.width = width
        self.height = height
    }
}

public enum MonitorRole: String, Codable, CaseIterable, Sendable {
    case primary
    case secondary
}

// MARK: - Frame / length

public enum LengthValue: Codable, Equatable, Sendable {
    case pt(Double)
    case expression(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .pt(number)
            return
        }
        let text = try container.decode(String.self)
        self = .expression(text)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .pt(value):
            try container.encode(value)
        case let .expression(value):
            try container.encode(value)
        }
    }
}

public struct FrameDefinition: Codable, Equatable, Sendable {
    public let x: LengthValue
    public let y: LengthValue
    public let width: LengthValue
    public let height: LengthValue

    public init(x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Shortcuts

public struct ShortcutsDefinition: Codable, Equatable, Sendable {
    public let focusBySlot: [FocusBySlotShortcut]?
    public let moveCurrentWindowToSpace: [FocusBySlotShortcut]?
    public let switchVirtualSpace: [FocusBySlotShortcut]?
    public let nextWindow: HotkeyDefinition?
    public let prevWindow: HotkeyDefinition?
    public let cycle: CycleShortcutDefinition?
    public let switcher: SwitcherShortcutDefinition?
    public let globalActions: [GlobalActionShortcut]?
    public let disabledInApps: [String: [String]]?
    public let focusBySlotEnabledInApps: [String: Bool]?
    public let cycleExcludedApps: [String]?
    public let switcherExcludedApps: [String]?

    public init(
        focusBySlot: [FocusBySlotShortcut]? = nil,
        moveCurrentWindowToSpace: [FocusBySlotShortcut]? = nil,
        switchVirtualSpace: [FocusBySlotShortcut]? = nil,
        nextWindow: HotkeyDefinition? = nil,
        prevWindow: HotkeyDefinition? = nil,
        cycle: CycleShortcutDefinition? = nil,
        switcher: SwitcherShortcutDefinition? = nil,
        globalActions: [GlobalActionShortcut]? = nil,
        disabledInApps: [String: [String]]? = nil,
        focusBySlotEnabledInApps: [String: Bool]? = nil,
        cycleExcludedApps: [String]? = nil,
        switcherExcludedApps: [String]? = nil
    ) {
        self.focusBySlot = focusBySlot
        self.moveCurrentWindowToSpace = moveCurrentWindowToSpace
        self.switchVirtualSpace = switchVirtualSpace
        self.nextWindow = nextWindow
        self.prevWindow = prevWindow
        self.cycle = cycle
        self.switcher = switcher
        self.globalActions = globalActions
        self.disabledInApps = disabledInApps
        self.focusBySlotEnabledInApps = focusBySlotEnabledInApps
        self.cycleExcludedApps = cycleExcludedApps
        self.switcherExcludedApps = switcherExcludedApps
    }
}

public struct FocusBySlotShortcut: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: [String]
    public let slot: Int

    public init(key: String, modifiers: [String], slot: Int) {
        self.key = key
        self.modifiers = modifiers
        self.slot = slot
    }
}

public struct HotkeyDefinition: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct CycleShortcutDefinition: Codable, Equatable, Sendable {
    public let mode: CyclePresentationMode?
    public let quickKeys: String?
    public let acceptKeys: [String]?
    public let cancelKeys: [String]?

    public init(
        mode: CyclePresentationMode? = nil,
        quickKeys: String? = nil,
        acceptKeys: [String]? = nil,
        cancelKeys: [String]? = nil
    ) {
        self.mode = mode
        self.quickKeys = quickKeys
        self.acceptKeys = acceptKeys
        self.cancelKeys = cancelKeys
    }
}

public enum CyclePresentationMode: String, Codable, CaseIterable, Sendable {
    case direct
    case overlay
}

public struct SwitcherShortcutDefinition: Codable, Equatable, Sendable {
    public let trigger: HotkeyDefinition?
    public let quickKeys: String?
    public let acceptKeys: [String]?
    public let cancelKeys: [String]?

    public init(
        trigger: HotkeyDefinition? = nil,
        quickKeys: String? = nil,
        acceptKeys: [String]? = nil,
        cancelKeys: [String]? = nil
    ) {
        self.trigger = trigger
        self.quickKeys = quickKeys
        self.acceptKeys = acceptKeys
        self.cancelKeys = cancelKeys
    }
}

public struct GlobalActionShortcut: Codable, Equatable, Sendable {
    public let key: String
    public let modifiers: [String]
    public let action: GlobalActionDefinition

    public init(key: String, modifiers: [String], action: GlobalActionDefinition) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }
}

public struct GlobalActionDefinition: Codable, Equatable, Sendable {
    public let type: GlobalActionType
    public let x: LengthValue?
    public let y: LengthValue?
    public let width: LengthValue?
    public let height: LengthValue?
    public let preset: SnapPreset?

    public init(
        type: GlobalActionType,
        x: LengthValue? = nil,
        y: LengthValue? = nil,
        width: LengthValue? = nil,
        height: LengthValue? = nil,
        preset: SnapPreset? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.preset = preset
    }
}

public enum GlobalActionType: String, Codable, CaseIterable, Sendable {
    case move
    case resize
    case moveResize
    case snap
}

public enum SnapPreset: String, Codable, CaseIterable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case leftThird
    case centerThird
    case rightThird
    case maximize
    case center
}

// MARK: - Load status

public struct ConfigReloadStatus: Codable, Equatable, Sendable {
    public let status: String
    public let at: String
    public let trigger: String
    public let errorCode: Int?
    public let message: String?

    public init(status: String, at: String, trigger: String, errorCode: Int? = nil, message: String? = nil) {
        self.status = status
        self.at = at
        self.trigger = trigger
        self.errorCode = errorCode
        self.message = message
    }
}

public struct ConfigFileStatus: Codable, Equatable, Sendable {
    public let path: String
    public let loaded: Bool
    public let errorCode: Int?
    public let message: String?

    public init(path: String, loaded: Bool, errorCode: Int? = nil, message: String? = nil) {
        self.path = path
        self.loaded = loaded
        self.errorCode = errorCode
        self.message = message
    }
}

public struct LoadedConfig: Sendable {
    public let config: ShitsuraeConfig
    public let configFiles: [ConfigFileStatus]
    public let directoryURL: URL
    public let configGeneration: String

    public init(
        config: ShitsuraeConfig,
        configFiles: [ConfigFileStatus],
        directoryURL: URL,
        configGeneration: String
    ) {
        self.config = config
        self.configFiles = configFiles
        self.directoryURL = directoryURL
        self.configGeneration = configGeneration
    }
}

// MARK: - Resolved accessors

public extension ShitsuraeConfig {
    var resolvedFollowFocus: Bool {
        mode?.followFocus ?? true
    }

    var resolvedShortcuts: ResolvedShortcuts {
        ResolvedShortcuts(from: shortcuts)
    }
}

public struct ResolvedShortcuts: Equatable, Sendable {
    public let focusBySlot: [Int: HotkeyDefinition]
    public let moveCurrentWindowToSpace: [Int: HotkeyDefinition]
    public let switchVirtualSpace: [Int: HotkeyDefinition]
    public let focusBySlotEnabledInApps: [String: Bool]
    public let cycleExcludedApps: Set<String>
    public let switcherExcludedApps: Set<String>
    public let nextWindow: HotkeyDefinition
    public let prevWindow: HotkeyDefinition
    public let cycleMode: CyclePresentationMode
    public let cycleQuickKeys: String
    public let cycleAcceptKeys: [String]
    public let cycleCancelKeys: [String]
    public let switcherTrigger: HotkeyDefinition
    public let quickKeys: String
    public let acceptKeys: [String]
    public let cancelKeys: [String]
    public let globalActions: [GlobalActionShortcut]
    public let disabledInApps: [String: [String]]

    public init(from shortcuts: ShortcutsDefinition?) {
        var slots: [Int: HotkeyDefinition] = [:]
        for slot in 1 ... 9 {
            slots[slot] = HotkeyDefinition(key: String(slot), modifiers: ["cmd"])
        }
        if let overrides = shortcuts?.focusBySlot {
            for item in overrides where (1 ... 9).contains(item.slot) {
                slots[item.slot] = HotkeyDefinition(key: item.key, modifiers: item.modifiers)
            }
        }
        focusBySlot = slots

        var moveToSpaceShortcuts: [Int: HotkeyDefinition] = [:]
        for slot in 1 ... 9 {
            moveToSpaceShortcuts[slot] = HotkeyDefinition(key: String(slot), modifiers: ["alt"])
        }
        if let overrides = shortcuts?.moveCurrentWindowToSpace {
            for item in overrides where (1 ... 9).contains(item.slot) {
                moveToSpaceShortcuts[item.slot] = HotkeyDefinition(key: item.key, modifiers: item.modifiers)
            }
        }
        moveCurrentWindowToSpace = moveToSpaceShortcuts

        var switchVirtualSpaceShortcuts: [Int: HotkeyDefinition] = [:]
        for slot in 1 ... 9 {
            switchVirtualSpaceShortcuts[slot] = HotkeyDefinition(key: String(slot), modifiers: ["ctrl"])
        }
        if let overrides = shortcuts?.switchVirtualSpace {
            for item in overrides where (1 ... 9).contains(item.slot) {
                switchVirtualSpaceShortcuts[item.slot] = HotkeyDefinition(key: item.key, modifiers: item.modifiers)
            }
        }
        switchVirtualSpace = switchVirtualSpaceShortcuts

        focusBySlotEnabledInApps = shortcuts?.focusBySlotEnabledInApps ?? [:]
        cycleExcludedApps = Set(shortcuts?.cycleExcludedApps ?? [])
        switcherExcludedApps = Set(shortcuts?.switcherExcludedApps ?? [])

        nextWindow = shortcuts?.nextWindow ?? HotkeyDefinition(key: "j", modifiers: ["cmd", "ctrl"])
        prevWindow = shortcuts?.prevWindow ?? HotkeyDefinition(key: "k", modifiers: ["cmd", "ctrl"])

        let cycle = shortcuts?.cycle
        cycleMode = cycle?.mode ?? .direct
        cycleQuickKeys = cycle?.quickKeys ?? "123456789"
        cycleAcceptKeys = cycle?.acceptKeys ?? ["enter"]
        cycleCancelKeys = cycle?.cancelKeys ?? ["esc"]

        let switcher = shortcuts?.switcher
        switcherTrigger = switcher?.trigger ?? HotkeyDefinition(key: "tab", modifiers: ["cmd"])
        quickKeys = switcher?.quickKeys ?? "1234567890qwertyuiopasdfghjklzxcvbnm"
        acceptKeys = switcher?.acceptKeys ?? ["enter"]
        cancelKeys = switcher?.cancelKeys ?? ["esc"]

        globalActions = shortcuts?.globalActions ?? []
        disabledInApps = shortcuts?.disabledInApps ?? [:]
    }
}
