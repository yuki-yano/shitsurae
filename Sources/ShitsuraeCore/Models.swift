import Foundation

public struct ShitsuraeConfig: Codable, Equatable {
    public let ignore: IgnoreDefinition?
    public let overlay: OverlayDefinition?
    public let executionPolicy: ExecutionPolicy?
    public let monitors: MonitorsDefinition?
    public let layouts: [String: LayoutDefinition]
    public let shortcuts: ShortcutsDefinition?

    public init(
        ignore: IgnoreDefinition?,
        overlay: OverlayDefinition?,
        executionPolicy: ExecutionPolicy?,
        monitors: MonitorsDefinition?,
        layouts: [String: LayoutDefinition],
        shortcuts: ShortcutsDefinition?
    ) {
        self.ignore = ignore
        self.overlay = overlay
        self.executionPolicy = executionPolicy
        self.monitors = monitors
        self.layouts = layouts
        self.shortcuts = shortcuts
    }
}

public struct ShitsuraeConfigFile: Decodable {
    public let ignore: IgnoreDefinition?
    public let overlay: OverlayDefinition?
    public let executionPolicy: ExecutionPolicy?
    public let monitors: MonitorsDefinition?
    public let layouts: [String: LayoutDefinition]?
    public let shortcuts: ShortcutsDefinition?
}

public struct LayoutDefinition: Codable, Equatable {
    public let initialFocus: InitialFocusDefinition?
    public let spaces: [SpaceDefinition]
}

public struct InitialFocusDefinition: Codable, Equatable {
    public let slot: Int
}

public struct SpaceDefinition: Codable, Equatable {
    public let spaceID: Int
    public let display: DisplayDefinition?
    public let windows: [WindowDefinition]
}

public struct WindowDefinition: Codable, Equatable {
    public let source: WindowSource?
    public let match: WindowMatchRule
    public let slot: Int
    public let launch: Bool?
    public let frame: FrameDefinition
}

public struct ShortcutsDefinition: Codable, Equatable {
    public let focusBySlot: [FocusBySlotShortcut]?
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
        focusBySlot: [FocusBySlotShortcut]?,
        nextWindow: HotkeyDefinition?,
        prevWindow: HotkeyDefinition?,
        cycle: CycleShortcutDefinition? = nil,
        switcher: SwitcherShortcutDefinition?,
        globalActions: [GlobalActionShortcut]?,
        disabledInApps: [String: [String]]?,
        focusBySlotEnabledInApps: [String: Bool]? = nil,
        cycleExcludedApps: [String]? = nil,
        switcherExcludedApps: [String]? = nil
    ) {
        self.focusBySlot = focusBySlot
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

public struct WindowMatchRule: Codable, Equatable {
    public let bundleID: String
    public let title: TitleMatcher?
    public let role: String?
    public let subrole: String?
    public let profile: String?
    public let excludeTitleRegex: String?
    public let index: Int?

    public init(
        bundleID: String,
        title: TitleMatcher?,
        role: String?,
        subrole: String?,
        profile: String? = nil,
        excludeTitleRegex: String?,
        index: Int?
    ) {
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.subrole = subrole
        self.profile = profile
        self.excludeTitleRegex = excludeTitleRegex
        self.index = index
    }
}

public struct IgnoreDefinition: Codable, Equatable {
    public let apply: IgnoreRuleSet?
    public let focus: IgnoreRuleSet?
}

public struct IgnoreRuleSet: Codable, Equatable {
    public let apps: [String]?
    public let windows: [IgnoreWindowRule]?
}

public struct MonitorsDefinition: Codable, Equatable {
    public let primary: MonitorTargetDefinition?
    public let secondary: MonitorTargetDefinition?
}

public struct MonitorTargetDefinition: Codable, Equatable {
    public let id: String?
}

public enum SpacesMode: String, Codable, CaseIterable {
    case perDisplay
    case global
}

public enum ScreenFrameBasis: String, Codable, CaseIterable {
    case visible
    case full
}

public enum SpaceMoveMethod: String, Codable, CaseIterable {
    case drag
    case displayRelay
}

public enum WindowSource: String, Codable, CaseIterable, Sendable {
    case window
}

public struct OverlayDefinition: Codable, Equatable {
    public let showThumbnails: Bool?
}

public struct ExecutionPolicy: Codable, Equatable {
    public let spaceMoveMethod: SpaceMoveMethod?
    public let spaceMoveMethodInApps: [String: SpaceMoveMethod]?

    public init(
        spaceMoveMethod: SpaceMoveMethod? = nil,
        spaceMoveMethodInApps: [String: SpaceMoveMethod]? = nil
    ) {
        self.spaceMoveMethod = spaceMoveMethod
        self.spaceMoveMethodInApps = spaceMoveMethodInApps
    }

    public func spaceMoveMethod(for bundleID: String) -> SpaceMoveMethod {
        if let method = spaceMoveMethodInApps?[bundleID] {
            return method
        }
        return spaceMoveMethod ?? .drag
    }
}

public struct DisplayDefinition: Codable, Equatable {
    public let monitor: MonitorRole?
    public let id: String?
    public let width: Int?
    public let height: Int?
}

public enum MonitorRole: String, Codable, CaseIterable {
    case primary
    case secondary
}

public enum LengthValue: Codable, Equatable {
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

public struct FrameDefinition: Codable, Equatable {
    public let x: LengthValue
    public let y: LengthValue
    public let width: LengthValue
    public let height: LengthValue
}

public struct FocusBySlotShortcut: Codable, Equatable {
    public let key: String
    public let modifiers: [String]
    public let slot: Int
}

public struct HotkeyDefinition: Codable, Equatable {
    public let key: String
    public let modifiers: [String]

    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct CycleShortcutDefinition: Codable, Equatable {
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

public enum CyclePresentationMode: String, Codable, CaseIterable {
    case direct
    case overlay
}

public struct SwitcherShortcutDefinition: Codable, Equatable {
    public let trigger: HotkeyDefinition?
    public let quickKeys: String?
    public let acceptKeys: [String]?
    public let cancelKeys: [String]?
    public let sources: [WindowSource]?

    public init(
        trigger: HotkeyDefinition? = nil,
        quickKeys: String? = nil,
        acceptKeys: [String]? = nil,
        cancelKeys: [String]? = nil,
        sources: [WindowSource]? = nil
    ) {
        self.trigger = trigger
        self.quickKeys = quickKeys
        self.acceptKeys = acceptKeys
        self.cancelKeys = cancelKeys
        self.sources = sources
    }
}

public struct GlobalActionShortcut: Codable, Equatable {
    public let key: String
    public let modifiers: [String]
    public let action: GlobalActionDefinition
}

public struct GlobalActionDefinition: Codable, Equatable {
    public let type: GlobalActionType
    public let x: LengthValue?
    public let y: LengthValue?
    public let width: LengthValue?
    public let height: LengthValue?
    public let preset: SnapPreset?
}

public enum GlobalActionType: String, Codable, CaseIterable {
    case move
    case resize
    case moveResize
    case snap
}

public enum SnapPreset: String, Codable, CaseIterable {
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

public struct TitleMatcher: Codable, Equatable {
    public let equals: String?
    public let contains: String?
    public let regex: String?
}

public struct IgnoreWindowRule: Codable, Equatable {
    public let bundleID: String?
    public let titleRegex: String?
    public let role: String?
    public let subrole: String?
    public let minimized: Bool?
    public let hidden: Bool?
}

public struct ConfigReloadStatus: Codable, Equatable {
    public let status: String
    public let at: String
    public let trigger: String
    public let errorCode: Int?
    public let message: String?
}

public struct ConfigFileStatus: Codable, Equatable {
    public let path: String
    public let loaded: Bool
    public let errorCode: Int?
    public let message: String?
}

public extension ShitsuraeConfig {
    var resolvedSpacesMode: SpacesMode {
        .perDisplay
    }

    var resolvedScreenFrameBasis: ScreenFrameBasis {
        .visible
    }

    var resolvedExecutionPolicy: ExecutionPolicy {
        ExecutionPolicy(
            spaceMoveMethod: executionPolicy?.spaceMoveMethod ?? .drag,
            spaceMoveMethodInApps: executionPolicy?.spaceMoveMethodInApps ?? [:]
        )
    }

    var resolvedShortcuts: ResolvedShortcuts {
        ResolvedShortcuts(from: shortcuts)
    }
}

public struct ResolvedShortcuts: Equatable {
    public let focusBySlot: [Int: HotkeyDefinition]
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
    public let sources: [WindowSource]
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
        sources = switcher?.sources ?? [.window]

        globalActions = shortcuts?.globalActions ?? []
        disabledInApps = shortcuts?.disabledInApps ?? [:]
    }
}
