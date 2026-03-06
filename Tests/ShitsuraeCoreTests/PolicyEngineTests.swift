import XCTest
@testable import ShitsuraeCore

final class PolicyEngineTests: XCTestCase {
    func testIgnoreRuleMatchesByBundleAndTitleRegex() {
        let rules = IgnoreRuleSet(
            apps: ["com.apple.finder"],
            windows: [
                IgnoreWindowRule(bundleID: "com.example.app", titleRegex: "^Draft", role: nil, subrole: nil, minimized: nil, hidden: nil),
            ]
        )

        let finder = sampleWindow(bundleID: "com.apple.finder", title: "Finder")
        XCTAssertTrue(PolicyEngine.matchesIgnoreRule(window: finder, rules: rules))

        let draft = sampleWindow(bundleID: "com.example.app", title: "Draft-1")
        XCTAssertTrue(PolicyEngine.matchesIgnoreRule(window: draft, rules: rules))

        let editor = sampleWindow(bundleID: "com.example.app", title: "Editor")
        XCTAssertFalse(PolicyEngine.matchesIgnoreRule(window: editor, rules: rules))
    }

    func testShortcutDisabledByFocusBySlotWildcard() {
        let disabled = ["com.example.editor": ["focusBySlot"]]
        XCTAssertTrue(
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: "com.example.editor",
                shortcutID: "focusBySlot:3",
                disabledInApps: disabled
            )
        )
    }

    func testShortcutDisabledByExactID() {
        let disabled = ["com.example.editor": ["switcher"]]
        XCTAssertTrue(
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: "com.example.editor",
                shortcutID: "switcher",
                disabledInApps: disabled
            )
        )
        XCTAssertFalse(
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: "com.example.editor",
                shortcutID: "nextWindow",
                disabledInApps: disabled
            )
        )
    }

    func testFocusBySlotDisabledByAppSwitchWhenExplicitlyFalse() {
        XCTAssertTrue(
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: "com.example.editor",
                shortcutID: "focusBySlot:1",
                disabledInApps: [:],
                focusBySlotEnabledInApps: ["com.example.editor": false]
            )
        )
    }

    func testFocusBySlotEnabledByAppSwitchWhenExplicitlyTrue() {
        XCTAssertFalse(
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: "com.example.editor",
                shortcutID: "focusBySlot:1",
                disabledInApps: ["com.example.editor": ["focusBySlot"]],
                focusBySlotEnabledInApps: ["com.example.editor": true]
            )
        )
    }

    private func sampleWindow(bundleID: String, title: String) -> WindowSnapshot {
        WindowSnapshot(
            windowID: 1,
            bundleID: bundleID,
            pid: 100,
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: 1,
            displayID: "display-1",
            isFullscreen: false,
            frontIndex: 0
        )
    }
}
