import Foundation

public struct ValidateErrorItem: Codable, Equatable, Sendable {
    public let code: Int
    public let path: String
    public let line: Int?
    public let column: Int?
    public let message: String

    public init(code: ErrorCode, path: String, line: Int? = nil, column: Int? = nil, message: String) {
        self.code = code.rawValue
        self.path = path
        self.line = line
        self.column = column
        self.message = message
    }
}

public struct ValidateJSON: Codable {
    public let schemaVersion: Int
    public let valid: Bool
    public let errors: [ValidateErrorItem]
}

public enum ConfigValidator {
    private static let layoutNamePattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]+$")

    private static let modifiers: Set<String> = ["cmd", "shift", "ctrl", "alt", "fn"]
    private static let specialKeys: Set<String> = [
        "tab", "enter", "esc", "space", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"
    ]
    private static let overlayCommandLiteralKeys: Set<String> = ["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"]

    public static func validate(config: ShitsuraeConfig, sourcePath: String) -> [ValidateErrorItem] {
        var errors: [ValidateErrorItem] = []

        if config.layouts.isEmpty {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "at least one layout is required"
                )
            )
        }

        for (layoutName, layout) in config.layouts {
            if !matches(layoutNamePattern, text: layoutName) {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "layout name is invalid: \(layoutName)"
                    )
                )
            }

            if let initialFocus = layout.initialFocus, !(1 ... 9).contains(initialFocus.slot) {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "initialFocus.slot must be 1..9 in layout \(layoutName)"
                    )
                )
            }

            let spaceIDs = layout.spaces.map(\.spaceID)
            if spaceIDs.count != Set(spaceIDs).count {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "spaceID must be unique in layout \(layoutName)"
                    )
                )
            }

            if config.resolvedSpaceInterpretationMode == .virtual {
                validateVirtualLayoutDisplayConsistency(
                    layoutName: layoutName,
                    layout: layout,
                    sourcePath: sourcePath,
                    errors: &errors
                )
                validateVirtualLayoutWindowUniqueness(
                    layoutName: layoutName,
                    layout: layout,
                    sourcePath: sourcePath,
                    errors: &errors
                )
            }

            for space in layout.spaces {
                let slots = space.windows.map(\.slot)
                if slots.count != Set(slots).count {
                    errors.append(
                        ValidateErrorItem(
                            code: .slotConflict,
                            path: sourcePath,
                            message: "slot conflict in layout \(layoutName) spaceID=\(space.spaceID)"
                        )
                    )
                }

                for window in space.windows {
                    if !(1 ... 9).contains(window.slot) {
                        errors.append(
                            ValidateErrorItem(
                                code: .validationError,
                                path: sourcePath,
                                message: "slot must be 1..9 in layout \(layoutName) spaceID=\(space.spaceID)"
                            )
                        )
                    }

                    if let index = window.match.index, index <= 0 {
                        errors.append(
                            ValidateErrorItem(
                                code: .validationError,
                                path: sourcePath,
                                message: "match.index must be >= 1"
                            )
                        )
                    }

                    if let title = window.match.title {
                        let setCount = [title.equals, title.contains, title.regex].compactMap { $0 }.count
                        if setCount > 1 {
                            errors.append(
                                ValidateErrorItem(
                                    code: .validationError,
                                    path: sourcePath,
                                    message: "match.title equals/contains/regex are mutually exclusive"
                                )
                            )
                        }

                        if let regex = title.regex, !isRegexCompilable(regex) {
                            errors.append(
                                ValidateErrorItem(
                                    code: .validationError,
                                    path: sourcePath,
                                    message: "match.title.regex is invalid: \(regex)"
                                )
                            )
                        }
                    }

                    if let excludeRegex = window.match.excludeTitleRegex, !isRegexCompilable(excludeRegex) {
                        errors.append(
                            ValidateErrorItem(
                                code: .validationError,
                                path: sourcePath,
                                message: "match.excludeTitleRegex is invalid: \(excludeRegex)"
                            )
                        )
                    }

                    if window.match.profile != nil,
                       !ChromiumProfileSupport.supports(bundleID: window.match.bundleID)
                    {
                        errors.append(
                            ValidateErrorItem(
                                code: .validationError,
                                path: sourcePath,
                                message: "match.profile is only supported for Chromium-based browsers"
                            )
                        )
                    }

                    do {
                        _ = try LengthParser.parse(window.frame.x)
                        _ = try LengthParser.parse(window.frame.y)
                        _ = try LengthParser.parse(window.frame.width)
                        _ = try LengthParser.parse(window.frame.height)
                    } catch {
                        errors.append(
                            ValidateErrorItem(
                                code: .validationError,
                                path: sourcePath,
                                message: "frame has invalid length expression"
                            )
                        )
                    }

                }
            }
        }

        if let executionPolicy = config.executionPolicy {
            _ = executionPolicy
        }

        validateIgnore(config.ignore, sourcePath: sourcePath, errors: &errors)
        validateShortcuts(config.resolvedShortcuts, sourcePath: sourcePath, errors: &errors)

        return errors.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.line != $1.line {
                switch ($0.line, $1.line) {
                case let (.some(left), .some(right)): return left < right
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            if $0.column != $1.column {
                switch ($0.column, $1.column) {
                case let (.some(left), .some(right)): return left < right
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            return $0.code < $1.code
        }
    }

    private static func validateIgnore(
        _ ignore: IgnoreDefinition?,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        for ruleset in [ignore?.apply, ignore?.focus] {
            guard let windows = ruleset?.windows else { continue }
            for rule in windows {
                let conditionCount = [
                    rule.bundleID,
                    rule.titleRegex,
                    rule.role,
                    rule.subrole,
                    rule.minimized == nil ? nil : "has",
                    rule.hidden == nil ? nil : "has",
                ].compactMap { $0 }.count

                if conditionCount == 0 {
                    errors.append(
                        ValidateErrorItem(
                            code: .validationError,
                            path: sourcePath,
                            message: "ignore windows rule must contain at least one condition"
                        )
                    )
                }

                if let regex = rule.titleRegex, !isRegexCompilable(regex) {
                    errors.append(
                        ValidateErrorItem(
                            code: .validationError,
                            path: sourcePath,
                            message: "ignore window titleRegex is invalid: \(regex)"
                        )
                    )
                }
            }
        }
    }

    private static func validateVirtualLayoutDisplayConsistency(
        layoutName: String,
        layout: LayoutDefinition,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        let descriptors = layout.spaces.map { space in
            (spaceID: space.spaceID, value: normalizedVirtualDisplayKey(for: space.display))
        }

        if descriptors.contains(where: { descriptor in
            if case .invalid = descriptor.value { return true }
            return false
        }) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "virtual mode requires each layout to target one host display in layout \(layoutName)"
                )
            )
            return
        }

        let normalizedKeys = Set(descriptors.compactMap { descriptor -> String? in
            if case let .value(key) = descriptor.value {
                return key
            }
            return nil
        })
        let hasNilDisplay = descriptors.contains { descriptor in
            if case .none = descriptor.value { return true }
            return false
        }
        let hasExplicitDisplay = descriptors.contains { descriptor in
            if case .value = descriptor.value { return true }
            return false
        }

        if hasNilDisplay && hasExplicitDisplay {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "virtual mode cannot mix implicit and explicit displays in layout \(layoutName)"
                )
            )
        } else if normalizedKeys.count > 1 {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "virtual mode requires spaces to share one display target in layout \(layoutName)"
                )
            )
        }
    }

    private static func validateVirtualLayoutWindowUniqueness(
        layoutName: String,
        layout: LayoutDefinition,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        var seen: [String: (spaceID: Int, slot: Int)] = [:]

        for space in layout.spaces {
            for window in space.windows {
                let key = normalizedVirtualWindowKey(window)
                if let existing = seen[key] {
                    errors.append(
                        ValidateErrorItem(
                            code: .validationError,
                            path: sourcePath,
                            message: "virtual mode requires unique window matchers in layout \(layoutName): spaceID=\(existing.spaceID) slot=\(existing.slot) conflicts with spaceID=\(space.spaceID) slot=\(window.slot)"
                        )
                    )
                } else {
                    seen[key] = (space.spaceID, window.slot)
                }
            }
        }
    }

    private static func validateShortcuts(
        _ shortcuts: ResolvedShortcuts,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        for slot in 1 ... 9 {
            if let shortcut = shortcuts.focusBySlot[slot] {
                validateHotkey(shortcut, sourcePath: sourcePath, messagePrefix: "focusBySlot:\(slot)", requireModifier: true, errors: &errors)
            }
            if let shortcut = shortcuts.moveCurrentWindowToSpace[slot] {
                validateHotkey(shortcut, sourcePath: sourcePath, messagePrefix: "moveCurrentWindowToSpace:\(slot)", requireModifier: true, errors: &errors)
            }
            if let shortcut = shortcuts.switchVirtualSpace[slot] {
                validateHotkey(shortcut, sourcePath: sourcePath, messagePrefix: "switchVirtualSpace:\(slot)", requireModifier: true, errors: &errors)
            }
        }

        validateHotkey(shortcuts.nextWindow, sourcePath: sourcePath, messagePrefix: "nextWindow", requireModifier: true, errors: &errors)
        validateHotkey(shortcuts.prevWindow, sourcePath: sourcePath, messagePrefix: "prevWindow", requireModifier: true, errors: &errors)
        validateHotkey(shortcuts.switcherTrigger, sourcePath: sourcePath, messagePrefix: "switcher.trigger", requireModifier: true, errors: &errors)

        for (index, action) in shortcuts.globalActions.enumerated() {
            validateHotkey(action.asHotkey, sourcePath: sourcePath, messagePrefix: "globalActions:\(index + 1)", requireModifier: true, errors: &errors)
            validateGlobalAction(action.action, sourcePath: sourcePath, errors: &errors)
        }

        if !isQuickKeysValid(shortcuts.cycleQuickKeys) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "cycle.quickKeys must be [a-z0-9] with no duplicate characters"
                )
            )
        }

        for key in shortcuts.cycleAcceptKeys where !isOverlayCommandKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "cycle.acceptKeys contains invalid key: \(key)"
                )
            )
        }

        for key in shortcuts.cycleCancelKeys where !isOverlayCommandKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "cycle.cancelKeys contains invalid key: \(key)"
                )
            )
        }

        let cycleQuickKeySet = Set(shortcuts.cycleQuickKeys.lowercased().map(String.init))
        let navigationKeys = Set([shortcuts.nextWindow.key.lowercased(), shortcuts.prevWindow.key.lowercased()])
        if !cycleQuickKeySet.isDisjoint(with: navigationKeys) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "cycle.quickKeys must not contain nextWindow/prevWindow keys"
                )
            )
        }

        let cycleCommandKeySet = Set(
            shortcuts.cycleAcceptKeys
                .map { $0.lowercased() }
                .filter { $0.count == 1 }
            + shortcuts.cycleCancelKeys
                .map { $0.lowercased() }
                .filter { $0.count == 1 }
        )
        if !cycleQuickKeySet.isDisjoint(with: cycleCommandKeySet) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "cycle.quickKeys must not overlap cycle.acceptKeys/cancelKeys"
                )
            )
        }

        if !isQuickKeysValid(shortcuts.quickKeys) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "switcher.quickKeys must be [a-z0-9] with no duplicate characters"
                )
            )
        }

        for key in shortcuts.acceptKeys where !isOverlayCommandKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "switcher.acceptKeys contains invalid key: \(key)"
                )
            )
        }

        for key in shortcuts.cancelKeys where !isOverlayCommandKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "switcher.cancelKeys contains invalid key: \(key)"
                )
            )
        }

        let maxGlobalActionIndex = shortcuts.globalActions.count
        for (_, shortcutIDs) in shortcuts.disabledInApps {
            for shortcutID in shortcutIDs where !isShortcutIDValid(shortcutID, maxGlobalActionIndex: maxGlobalActionIndex) {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "disabledInApps shortcutID is invalid: \(shortcutID)"
                    )
                )
            }
        }
    }

    private static func validateHotkey(
        _ hotkey: HotkeyDefinition,
        sourcePath: String,
        messagePrefix: String,
        requireModifier: Bool,
        errors: inout [ValidateErrorItem]
    ) {
        let key = hotkey.key.lowercased()
        if !isKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "\(messagePrefix) has invalid key: \(hotkey.key)"
                )
            )
        }

        if requireModifier, hotkey.modifiers.isEmpty {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "\(messagePrefix) must have at least one modifier"
                )
            )
        }

        let normalized = hotkey.modifiers.map { $0.lowercased() }
        if Set(normalized).count != normalized.count {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "\(messagePrefix) has duplicate modifiers"
                )
            )
        }

        for modifier in normalized where !modifiers.contains(modifier) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "\(messagePrefix) has invalid modifier: \(modifier)"
                )
            )
        }
    }

    private static func validateGlobalAction(
        _ action: GlobalActionDefinition,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        switch action.type {
        case .move:
            if action.x == nil || action.y == nil || action.width != nil || action.height != nil || action.preset != nil {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "globalActions action type=move requires x/y only"
                    )
                )
            }
        case .resize:
            if action.width == nil || action.height == nil || action.x != nil || action.y != nil || action.preset != nil {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "globalActions action type=resize requires width/height only"
                    )
                )
            }
        case .moveResize:
            if action.x == nil || action.y == nil || action.width == nil || action.height == nil || action.preset != nil {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "globalActions action type=moveResize requires x/y/width/height"
                    )
                )
            }
        case .snap:
            if action.preset == nil || action.x != nil || action.y != nil || action.width != nil || action.height != nil {
                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        message: "globalActions action type=snap requires preset only"
                    )
                )
            }
        }
    }

    private static func isQuickKeysValid(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }

        let lower = keys.lowercased()
        guard lower.range(of: "^[a-z0-9]+$", options: .regularExpression) != nil else {
            return false
        }
        return Set(lower).count == lower.count
    }

    private static func isShortcutIDValid(_ shortcutID: String, maxGlobalActionIndex: Int) -> Bool {
        if shortcutID == "focusBySlot"
            || shortcutID == "moveCurrentWindowToSpace"
            || shortcutID == "switchVirtualSpace"
            || shortcutID == "nextWindow"
            || shortcutID == "prevWindow"
            || shortcutID == "switcher"
        {
            return true
        }

        if shortcutID.hasPrefix("focusBySlot:"),
           let slot = Int(shortcutID.replacingOccurrences(of: "focusBySlot:", with: "")),
           (1 ... 9).contains(slot)
        {
            return true
        }

        if shortcutID.hasPrefix("moveCurrentWindowToSpace:"),
           let slot = Int(shortcutID.replacingOccurrences(of: "moveCurrentWindowToSpace:", with: "")),
           (1 ... 9).contains(slot)
        {
            return true
        }

        if shortcutID.hasPrefix("switchVirtualSpace:"),
           let slot = Int(shortcutID.replacingOccurrences(of: "switchVirtualSpace:", with: "")),
           (1 ... 9).contains(slot)
        {
            return true
        }

        if shortcutID.hasPrefix("globalAction:"),
           let index = Int(shortcutID.replacingOccurrences(of: "globalAction:", with: "")),
           index >= 1,
           index <= maxGlobalActionIndex
        {
            return true
        }

        return false
    }

    private static func isKeyValid(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower.range(of: "^[a-z0-9]$", options: .regularExpression) != nil {
            return true
        }

        if specialKeys.contains(lower) {
            return true
        }

        if lower.range(of: "^f([1-9]|1[0-9]|20)$", options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func isOverlayCommandKeyValid(_ key: String) -> Bool {
        let lower = key.lowercased()
        return isKeyValid(lower) || overlayCommandLiteralKeys.contains(lower)
    }

    private static func matches(_ regex: NSRegularExpression, text: String) -> Bool {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func isRegexCompilable(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    private enum VirtualDisplayKey {
        case none
        case value(String)
        case invalid
    }

    private static func normalizedVirtualDisplayKey(for display: DisplayDefinition?) -> VirtualDisplayKey {
        guard let display else {
            return .none
        }

        if display.monitor != nil && display.id != nil {
            return .invalid
        }
        if display.monitor == nil && display.id == nil && (display.width != nil || display.height != nil) {
            return .invalid
        }
        if let monitor = display.monitor {
            return .value("monitor:\(monitor.rawValue)")
        }
        if let id = display.id {
            return .value("id:\(id)")
        }
        return .none
    }

    private static func normalizedVirtualWindowKey(_ window: WindowDefinition) -> String {
        let titleKind: String
        let titleValue: String
        if let equals = window.match.title?.equals {
            titleKind = "equals"
            titleValue = equals
        } else if let contains = window.match.title?.contains {
            titleKind = "contains"
            titleValue = contains
        } else if let regex = window.match.title?.regex {
            titleKind = "regex"
            titleValue = regex
        } else {
            titleKind = "none"
            titleValue = "<nil>"
        }

        func segment(_ name: String, _ value: String?) -> String {
            "\(name)=\(value ?? "<nil>")"
        }

        return [
            segment("source", (window.source ?? .window).rawValue),
            segment("bundleID", window.match.bundleID),
            segment("profile", window.match.profile),
            segment("titleMatchKind", titleKind),
            segment("titleMatchValue", titleValue),
            segment("excludeTitleRegex", window.match.excludeTitleRegex),
            segment("role", window.match.role),
            segment("subrole", window.match.subrole),
            segment("index", window.match.index.map(String.init)),
        ].joined(separator: "\u{0}")
    }
}

private extension GlobalActionShortcut {
    var asHotkey: HotkeyDefinition {
        HotkeyDefinition(key: key, modifiers: modifiers)
    }
}
