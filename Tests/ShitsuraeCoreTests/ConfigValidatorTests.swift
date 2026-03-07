import XCTest
@testable import ShitsuraeCore

final class ConfigValidatorTests: XCTestCase {
    func testLayoutsMustNotBeEmpty() {
        let config = ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: [:],
            shortcuts: nil
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "at least one layout is required")
    }

    func testLayoutNamePatternValidation() {
        let layout = baseConfig().layouts["work"]!
        let config = ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: ["work layout": layout],
            shortcuts: nil
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "layout name is invalid")
    }

    func testInitialFocusOutOfRange() {
        let window = defaultWindowDefinition()
        let layout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 10),
            spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])]
        )
        let config = ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: nil,
            monitors: nil,
            layouts: ["work": layout],
            shortcuts: nil
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "initialFocus.slot must be 1..9")
    }

    func testSlotConflictInSameSpace() {
        let first = defaultWindowDefinition()
        let second = WindowDefinition(
            source: .window,
            match: WindowMatchRule(
                bundleID: "com.example.other",
                title: nil,
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            ),
            slot: 1,
            launch: true,
            frame: defaultFrameDefinition()
        )
        let config = baseConfig(
            spaces: [
                SpaceDefinition(spaceID: 1, display: nil, windows: [first, second]),
            ]
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.contains(where: { $0.code == ErrorCode.slotConflict.rawValue }))
        assertHasError(errors, contains: "slot conflict")
    }

    func testWindowSlotOutOfRange() {
        let window = WindowDefinition(
            source: .window,
            match: WindowMatchRule(
                bundleID: "com.example.app",
                title: nil,
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            ),
            slot: 0,
            launch: true,
            frame: defaultFrameDefinition()
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "slot must be 1..9")
    }

    func testMatchIndexMustBePositive() {
        let window = defaultWindowDefinition(
            windowMatch: WindowMatchRule(
                bundleID: "com.example.app",
                title: nil,
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: 0
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "match.index must be >= 1")
    }

    func testTitleRegexCompileError() {
        let window = defaultWindowDefinition(
            windowMatch: WindowMatchRule(
                bundleID: "com.example.app",
                title: TitleMatcher(equals: nil, contains: nil, regex: "["),
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "match.title.regex is invalid")
    }

    func testExcludeTitleRegexCompileError() {
        let window = defaultWindowDefinition(
            windowMatch: WindowMatchRule(
                bundleID: "com.example.app",
                title: nil,
                role: nil,
                subrole: nil,
                profile: nil,
                excludeTitleRegex: "[",
                index: nil
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "match.excludeTitleRegex is invalid")
    }

    func testMatchProfileRequiresChromiumBrowser() {
        let window = defaultWindowDefinition(
            windowMatch: WindowMatchRule(
                bundleID: "com.example.app",
                title: nil,
                role: nil,
                subrole: nil,
                profile: "Default",
                excludeTitleRegex: nil,
                index: nil
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "match.profile is only supported for Chromium-based browsers")
    }

    func testMatchProfileAllowedForChromiumBrowser() {
        let window = defaultWindowDefinition(
            windowMatch: WindowMatchRule(
                bundleID: "com.google.Chrome",
                title: nil,
                role: nil,
                subrole: nil,
                profile: "Default",
                excludeTitleRegex: nil,
                index: nil
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertFalse(errors.contains(where: { $0.message.contains("match.profile") }))
    }

    func testFrameLengthParseError() {
        let window = WindowDefinition(
            source: .window,
            match: WindowMatchRule(
                bundleID: "com.example.app",
                title: nil,
                role: nil,
                subrole: nil,
                profile: nil,
                excludeTitleRegex: nil,
                index: nil
            ),
            slot: 1,
            launch: true,
            frame: FrameDefinition(
                x: .expression("invalid"),
                y: .expression("0%"),
                width: .expression("100%"),
                height: .expression("100%")
            )
        )
        let config = baseConfig(spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: [window])])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "frame has invalid length expression")
    }

    func testExecutionPolicyBoundaryValidation() {
        let config = baseConfig(executionPolicy: ExecutionPolicy())
        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.isEmpty)
    }

    func testExecutionPolicySpaceMoveMethodDefaultsAndAppOverrideResolve() {
        let config = baseConfig(
            executionPolicy: ExecutionPolicy(
                spaceMoveMethod: .displayRelay,
                spaceMoveMethodInApps: ["org.alacritty": .drag]
            )
        )

        XCTAssertEqual(config.resolvedExecutionPolicy.spaceMoveMethod(for: "com.example.app"), .displayRelay)
        XCTAssertEqual(config.resolvedExecutionPolicy.spaceMoveMethod(for: "org.alacritty"), .drag)
    }

    func testMatchTitleMutualExclusion() {
        let config = baseConfig(
            windowMatch: WindowMatchRule(
                bundleID: "com.example.app",
                title: TitleMatcher(equals: "A", contains: "B", regex: nil),
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.contains(where: { $0.code == ErrorCode.validationError.rawValue }))
        XCTAssertTrue(errors.contains(where: { $0.message.contains("mutually exclusive") }))
    }

    func testIgnoreWindowEmptyObjectRejected() {
        let config = baseConfig(
            ignore: IgnoreDefinition(
                apply: IgnoreRuleSet(apps: nil, windows: [IgnoreWindowRule(bundleID: nil, titleRegex: nil, role: nil, subrole: nil, minimized: nil, hidden: nil)]),
                focus: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.contains(where: { $0.message.contains("at least one condition") }))
    }

    func testQuickKeysDuplicateRejected() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: SwitcherShortcutDefinition(
                    trigger: nil,
                    quickKeys: "aabc",
                    acceptKeys: nil,
                    cancelKeys: nil,
                    sources: nil
                ),
                globalActions: nil,
                disabledInApps: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.contains(where: { $0.message.contains("quickKeys") }))
    }

    func testQuickKeysCharacterValidation() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: SwitcherShortcutDefinition(
                    trigger: nil,
                    quickKeys: "abC!",
                    acceptKeys: nil,
                    cancelKeys: nil,
                    sources: nil
                ),
                globalActions: nil,
                disabledInApps: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "switcher.quickKeys")
    }

    func testFocusBySlotPartialOverrideInheritsDefaults() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: [
                    FocusBySlotShortcut(key: "x", modifiers: ["cmd"], slot: 2),
                ],
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: nil,
                globalActions: nil,
                disabledInApps: nil
            )
        )

        let resolved = config.resolvedShortcuts
        XCTAssertEqual(resolved.focusBySlot[2], HotkeyDefinition(key: "x", modifiers: ["cmd"]))
        XCTAssertEqual(resolved.focusBySlot[1], HotkeyDefinition(key: "1", modifiers: ["cmd"]))
        XCTAssertEqual(resolved.focusBySlot[9], HotkeyDefinition(key: "9", modifiers: ["cmd"]))
        XCTAssertEqual(resolved.nextWindow, HotkeyDefinition(key: "j", modifiers: ["cmd", "ctrl"]))
        XCTAssertEqual(resolved.prevWindow, HotkeyDefinition(key: "k", modifiers: ["cmd", "ctrl"]))
        XCTAssertEqual(resolved.cycleMode, .direct)
        XCTAssertEqual(resolved.cycleQuickKeys, "123456789")
        XCTAssertEqual(resolved.cycleAcceptKeys, ["enter"])
        XCTAssertEqual(resolved.cycleCancelKeys, ["esc"])
        XCTAssertTrue(resolved.focusBySlotEnabledInApps.isEmpty)
        XCTAssertTrue(resolved.cycleExcludedApps.isEmpty)
        XCTAssertTrue(resolved.switcherExcludedApps.isEmpty)
    }

    func testFocusBySlotAppSwitchAndExcludedAppsResolve() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: nil,
                globalActions: nil,
                disabledInApps: nil,
                focusBySlotEnabledInApps: [
                    "com.apple.Terminal": false,
                    "com.apple.TextEdit": true,
                ],
                cycleExcludedApps: [
                    "com.hnc.Discord",
                ],
                switcherExcludedApps: [
                    "com.tinyspeck.slackmacgap",
                ]
            )
        )

        let resolved = config.resolvedShortcuts
        XCTAssertEqual(resolved.focusBySlotEnabledInApps["com.apple.Terminal"], false)
        XCTAssertEqual(resolved.focusBySlotEnabledInApps["com.apple.TextEdit"], true)
        XCTAssertEqual(resolved.cycleExcludedApps, Set(["com.hnc.Discord"]))
        XCTAssertEqual(resolved.switcherExcludedApps, Set(["com.tinyspeck.slackmacgap"]))
    }

    func testShortcutAndModifierValidation() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: [
                    FocusBySlotShortcut(key: "invalid-key", modifiers: [], slot: 1),
                    FocusBySlotShortcut(key: "f21", modifiers: ["cmd", "cmd"], slot: 2),
                    FocusBySlotShortcut(key: "3", modifiers: ["hyper"], slot: 3),
                ],
                nextWindow: HotkeyDefinition(key: "left", modifiers: ["cmd", "shift"]),
                prevWindow: HotkeyDefinition(key: "home", modifiers: ["ctrl"]),
                cycle: CycleShortcutDefinition(
                    mode: .overlay,
                    quickKeys: "123",
                    acceptKeys: ["enter", "bad-key"],
                    cancelKeys: ["esc", "bad-key"]
                ),
                switcher: SwitcherShortcutDefinition(
                    trigger: HotkeyDefinition(key: "pagedown", modifiers: ["cmd"]),
                    quickKeys: nil,
                    acceptKeys: ["enter", "bad-key"],
                    cancelKeys: ["esc", "bad-key"],
                    sources: nil
                ),
                globalActions: nil,
                disabledInApps: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "focusBySlot:1 has invalid key")
        assertHasError(errors, contains: "focusBySlot:1 must have at least one modifier")
        assertHasError(errors, contains: "focusBySlot:2 has invalid key")
        assertHasError(errors, contains: "focusBySlot:2 has duplicate modifiers")
        assertHasError(errors, contains: "focusBySlot:3 has invalid modifier")
        assertHasError(errors, contains: "cycle.acceptKeys contains invalid key")
        assertHasError(errors, contains: "cycle.cancelKeys contains invalid key")
        assertHasError(errors, contains: "acceptKeys contains invalid key")
        assertHasError(errors, contains: "cancelKeys contains invalid key")
    }

    func testCycleQuickKeysConflictsWithNavigationAcceptAndCancelKeys() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: nil,
                nextWindow: HotkeyDefinition(key: "j", modifiers: ["cmd", "ctrl"]),
                prevWindow: HotkeyDefinition(key: "k", modifiers: ["cmd", "ctrl"]),
                cycle: CycleShortcutDefinition(
                    mode: .overlay,
                    quickKeys: "1jk",
                    acceptKeys: ["enter", "1"],
                    cancelKeys: ["esc"]
                ),
                switcher: nil,
                globalActions: nil,
                disabledInApps: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "cycle.quickKeys must not contain nextWindow/prevWindow keys")
        assertHasError(errors, contains: "cycle.quickKeys must not overlap cycle.acceptKeys/cancelKeys")
    }

    func testGlobalActionValidationAndDisabledInAppsID() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: nil,
                globalActions: [
                    GlobalActionShortcut(
                        key: "1",
                        modifiers: ["cmd"],
                        action: GlobalActionDefinition(
                            type: .move,
                            x: .expression("10%"),
                            y: nil,
                            width: nil,
                            height: nil,
                            preset: nil
                        )
                    ),
                    GlobalActionShortcut(
                        key: "2",
                        modifiers: ["cmd"],
                        action: GlobalActionDefinition(
                            type: .resize,
                            x: nil,
                            y: nil,
                            width: .expression("50%"),
                            height: nil,
                            preset: nil
                        )
                    ),
                    GlobalActionShortcut(
                        key: "3",
                        modifiers: ["cmd"],
                        action: GlobalActionDefinition(
                            type: .moveResize,
                            x: .expression("0%"),
                            y: .expression("0%"),
                            width: nil,
                            height: .expression("50%"),
                            preset: nil
                        )
                    ),
                    GlobalActionShortcut(
                        key: "4",
                        modifiers: ["cmd"],
                        action: GlobalActionDefinition(
                            type: .snap,
                            x: .expression("0%"),
                            y: nil,
                            width: nil,
                            height: nil,
                            preset: nil
                        )
                    ),
                ],
                disabledInApps: [
                    "com.apple.Terminal": ["globalAction:5", "focusBySlot:10", "invalid"],
                ]
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "type=move requires x/y only")
        assertHasError(errors, contains: "type=resize requires width/height only")
        assertHasError(errors, contains: "type=moveResize requires x/y/width/height")
        assertHasError(errors, contains: "type=snap requires preset only")
        assertHasError(errors, contains: "disabledInApps shortcutID is invalid")
    }

    func testIgnoreTitleRegexValidation() {
        let config = baseConfig(
            ignore: IgnoreDefinition(
                apply: IgnoreRuleSet(
                    apps: nil,
                    windows: [IgnoreWindowRule(bundleID: "com.apple.Terminal", titleRegex: "[", role: nil, subrole: nil, minimized: nil, hidden: nil)]
                ),
                focus: nil
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        assertHasError(errors, contains: "ignore window titleRegex is invalid")
    }

    func testValidConfigAllowsSpecialKeysAndFnModifier() {
        let config = baseConfig(
            shortcuts: ShortcutsDefinition(
                focusBySlot: [FocusBySlotShortcut(key: "f20", modifiers: ["fn", "cmd"], slot: 1)],
                nextWindow: HotkeyDefinition(key: "left", modifiers: ["cmd"]),
                prevWindow: HotkeyDefinition(key: "right", modifiers: ["cmd"]),
                cycle: CycleShortcutDefinition(
                    mode: .overlay,
                    quickKeys: "123456789",
                    acceptKeys: ["enter", "space"],
                    cancelKeys: ["esc"]
                ),
                switcher: SwitcherShortcutDefinition(
                    trigger: HotkeyDefinition(key: "tab", modifiers: ["cmd"]),
                    quickKeys: "asdf",
                    acceptKeys: ["enter", "space"],
                    cancelKeys: ["esc"],
                    sources: [.window]
                ),
                globalActions: [
                    GlobalActionShortcut(
                        key: "m",
                        modifiers: ["cmd", "shift"],
                        action: GlobalActionDefinition(
                            type: .moveResize,
                            x: .expression("0%"),
                            y: .expression("0%"),
                            width: .expression("100%"),
                            height: .expression("100%"),
                            preset: nil
                        )
                    ),
                ],
                disabledInApps: ["com.apple.Terminal": ["switcher", "focusBySlot:1", "globalAction:1"]]
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/tmp/config.yml")
        XCTAssertTrue(errors.isEmpty)
    }

    private func baseConfig(
        windowMatch: WindowMatchRule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: nil,
            index: nil
        ),
        ignore: IgnoreDefinition? = nil,
        shortcuts: ShortcutsDefinition? = nil,
        executionPolicy: ExecutionPolicy? = nil,
        spaces: [SpaceDefinition]? = nil
    ) -> ShitsuraeConfig {
        let window = defaultWindowDefinition(windowMatch: windowMatch)
        let layout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 1),
            spaces: spaces ?? [SpaceDefinition(spaceID: 1, display: nil, windows: [window])]
        )

        return ShitsuraeConfig(
            ignore: ignore,
            overlay: nil,
            executionPolicy: executionPolicy,
            monitors: nil,
            layouts: ["work": layout],
            shortcuts: shortcuts
        )
    }

    private func defaultWindowDefinition(
        windowMatch: WindowMatchRule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: nil,
            index: nil
        )
    ) -> WindowDefinition {
        WindowDefinition(
            source: .window,
            match: windowMatch,
            slot: 1,
            launch: true,
            frame: defaultFrameDefinition()
        )
    }

    private func defaultFrameDefinition() -> FrameDefinition {
        FrameDefinition(
            x: .expression("0%"),
            y: .expression("0%"),
            width: .expression("100%"),
            height: .expression("100%")
        )
    }

    private func assertHasError(_ errors: [ValidateErrorItem], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(errors.contains(where: { $0.message.contains(needle) }), "missing error containing: \(needle)", file: file, line: line)
    }
}
