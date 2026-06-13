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

    public static func matchesIgnoreRule(windowDefinition: WindowDefinition, rules: IgnoreRuleSet?) -> Bool {
        if rules?.apps?.contains(windowDefinition.match.bundleID) == true {
            return true
        }

        guard let windowRules = rules?.windows else {
            return false
        }

        let pseudo = WindowSnapshot(
            windowID: 0,
            bundleID: windowDefinition.match.bundleID,
            pid: 0,
            title: windowDefinition.match.title?.equals
                ?? windowDefinition.match.title?.contains
                ?? windowDefinition.match.title?.regex
                ?? "",
            role: windowDefinition.match.role ?? "AXWindow",
            subrole: windowDefinition.match.subrole,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            displayID: nil,
            isFullscreen: false,
            frontIndex: 0
        )
        return windowRules.contains { matches(window: pseudo, rule: $0) }
    }

    public static func isShortcutDisabled(
        frontmostBundleID: String?,
        shortcutID: String,
        disabledInApps: [String: [String]],
        focusBySlotEnabledInApps: [String: Bool] = [:]
    ) -> Bool {
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
