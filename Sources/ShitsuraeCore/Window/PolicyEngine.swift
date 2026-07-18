import Foundation

/// Ignore-rule and per-app shortcut policy evaluation. Ported from v1.
public enum PolicyEngine {
    public static func matchesIgnoreRule(window: WindowSnapshot, rules: IgnoreRuleSet?) -> Bool {
        if rules?.apps?.contains(window.bundleID) == true {
            return true
        }

        guard let windowRules = rules?.windows else {
            return false
        }

        return windowRules.contains { matches(window: window, rule: $0) }
    }

    /// App-wide apply rules can be decided from a layout definition. Window
    /// rules require a real snapshot and must never be evaluated against
    /// synthesized title/role/minimized values.
    public static func matchesIgnoreAppRule(
        windowDefinition: WindowDefinition,
        rules: IgnoreRuleSet?
    ) -> Bool {
        rules?.apps?.contains(windowDefinition.match.bundleID) == true
    }

    public static func isShortcutDisabled(
        frontmostBundleID: String?,
        shortcutID: String,
        disabledInApps: [String: [String]],
        focusBySlotEnabledInApps: [String: Bool] = [:],
        frontmostBelongsToActiveWorkspace: Bool = true
    ) -> Bool {
        guard frontmostBelongsToActiveWorkspace else {
            return false
        }

        guard let frontmostBundleID else {
            return false
        }

        if shortcutID.hasPrefix("focusBySlot:"),
           let enabled = focusBySlotEnabledInApps[frontmostBundleID]
        {
            return !enabled
        }

        guard let disabled = disabledInApps[frontmostBundleID] else {
            return false
        }

        if disabled.contains(shortcutID) {
            return true
        }

        if shortcutID.hasPrefix("focusBySlot:"), disabled.contains("focusBySlot") {
            return true
        }

        if shortcutID.hasPrefix("moveCurrentWindowToSpace:"), disabled.contains("moveCurrentWindowToSpace") {
            return true
        }

        if shortcutID.hasPrefix("switchVirtualSpace:"), disabled.contains("switchVirtualSpace") {
            return true
        }

        return false
    }

    private static func matches(window: WindowSnapshot, rule: IgnoreWindowRule) -> Bool {
        if let bundleID = rule.bundleID, window.bundleID != bundleID {
            return false
        }

        if let titleRegex = rule.titleRegex,
           window.title.range(of: titleRegex, options: .regularExpression) == nil
        {
            return false
        }

        if let role = rule.role, window.role != role {
            return false
        }

        if let subrole = rule.subrole, window.subrole != subrole {
            return false
        }

        if let minimized = rule.minimized, window.minimized != minimized {
            return false
        }

        if let hidden = rule.hidden, window.hidden != hidden {
            return false
        }

        return true
    }
}
