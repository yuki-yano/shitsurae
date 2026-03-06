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

    private static func validateShortcuts(
        _ shortcuts: ResolvedShortcuts,
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        for slot in 1 ... 9 {
            if let shortcut = shortcuts.focusBySlot[slot] {
                validateHotkey(shortcut, sourcePath: sourcePath, messagePrefix: "focusBySlot:\(slot)", requireModifier: true, errors: &errors)
            }
        }

        validateHotkey(shortcuts.nextWindow, sourcePath: sourcePath, messagePrefix: "nextWindow", requireModifier: true, errors: &errors)
        validateHotkey(shortcuts.prevWindow, sourcePath: sourcePath, messagePrefix: "prevWindow", requireModifier: true, errors: &errors)
        validateHotkey(shortcuts.switcherTrigger, sourcePath: sourcePath, messagePrefix: "switcher.trigger", requireModifier: true, errors: &errors)

        for (index, action) in shortcuts.globalActions.enumerated() {
            validateHotkey(action.asHotkey, sourcePath: sourcePath, messagePrefix: "globalActions:\(index + 1)", requireModifier: true, errors: &errors)
            validateGlobalAction(action.action, sourcePath: sourcePath, errors: &errors)
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

        for key in shortcuts.acceptKeys where !isKeyValid(key) {
            errors.append(
                ValidateErrorItem(
                    code: .validationError,
                    path: sourcePath,
                    message: "switcher.acceptKeys contains invalid key: \(key)"
                )
            )
        }

        for key in shortcuts.cancelKeys where !isKeyValid(key) {
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
        if shortcutID == "focusBySlot" || shortcutID == "nextWindow" || shortcutID == "prevWindow" || shortcutID == "switcher" {
            return true
        }

        if shortcutID.hasPrefix("focusBySlot:"),
           let slot = Int(shortcutID.replacingOccurrences(of: "focusBySlot:", with: "")),
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

    private static func matches(_ regex: NSRegularExpression, text: String) -> Bool {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func isRegexCompilable(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}

private extension GlobalActionShortcut {
    var asHotkey: HotkeyDefinition {
        HotkeyDefinition(key: key, modifiers: modifiers)
    }
}
