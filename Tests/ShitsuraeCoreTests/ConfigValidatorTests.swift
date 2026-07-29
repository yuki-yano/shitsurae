import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("ConfigValidator")
struct ConfigValidatorTests {
    private func makeWindow(
        bundleID: String,
        slot: Int,
        title: TitleMatcher? = nil,
        profile: String? = nil,
        index: Int? = nil
    ) -> WindowDefinition {
        WindowDefinition(
            match: WindowMatchRule(bundleID: bundleID, title: title, profile: profile, index: index),
            slot: slot,
            launch: false,
            frame: FrameDefinition(
                x: .expression("0%"),
                y: .expression("0%"),
                width: .expression("50%"),
                height: .expression("100%")
            )
        )
    }

    private func makeConfig(layouts: [String: LayoutDefinition]) -> ShitsuraeConfig {
        ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "main": MonitorTargetDefinition(primary: true),
                "calendar": MonitorTargetDefinition(id: "uuid-sub"),
            ]),
            layouts: layouts
        )
    }

    @Test func acceptsValidLayout() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.TextEdit", slot: 1),
                    makeWindow(bundleID: "com.apple.Terminal", slot: 2),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    makeWindow(bundleID: "com.apple.Notes", slot: 1),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.isEmpty)
    }

    @Test func rejectsAmbiguousSameBundleIDWithoutDiscriminator() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1, index: 2),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("add match.title / match.profile / match.index") })
    }

    @Test func acceptsSameBundleIDWithDiscriminators() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1, index: 1),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1, index: 2),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.isEmpty)
    }

    @Test func rejectsIdenticalMatchers() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1, index: 1),
                ]),
                SpaceDefinition(spaceID: 2, windows: [
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1, index: 1),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("window matchers must be unique") })
    }

    @Test func rejectsSlotConflictInSpace() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.TextEdit", slot: 1),
                    makeWindow(bundleID: "com.apple.Terminal", slot: 1),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.code == ErrorCode.slotConflict.rawValue })
    }

    @Test func rejectsDuplicateSpaceIDs() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "d.e.f", slot: 1)]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("spaceID must be unique") })
    }

    @Test func rejectsProfileForNonChromiumApp() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.apple.TextEdit", slot: 1, profile: "Default"),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("Chromium") })
    }

    @Test func acceptsProfileForChrome() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [
                    makeWindow(bundleID: "com.google.Chrome", slot: 1, profile: "Default"),
                ]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.isEmpty)
    }

    @Test func rejectsMonitorAndIDTogetherInLayoutDisplay() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(
                display: DisplayDefinition(monitor: "main", id: "uuid-x"),
                spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]
            ),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("mutually exclusive") })
    }

    @Test func rejectsEmptyLayoutDisplayDeclaration() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(
                display: DisplayDefinition(),
                spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]
            ),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("display must declare monitor, id, or a resolution") })
    }

    @Test func rejectsIdenticalMatcherAcrossSimultaneouslyActiveLayouts() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
            ]),
            "calendar": LayoutDefinition(
                display: DisplayDefinition(monitor: "calendar"),
                spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]
            ),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("identical window matcher") })
    }

    @Test func allowsIdenticalMatcherBetweenSameHostLayouts() {
        // Layouts sharing one host replace each other on arrange and are
        // never active simultaneously — sharing a matcher is the standard
        // v2.0 multi-layout workflow and must stay legal. An undeclared
        // display and monitor: primary are the same host while
        // monitors.primary.id is unset.
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
            ]),
            "focus": LayoutDefinition(
                display: DisplayDefinition(monitor: "main"),
                spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]
            ),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(!errors.contains { $0.message.contains("identical window matcher") })
    }

    @Test func pinnedPrimaryRoleBreaksImplicitEquivalence() {
        // monitors.primary.id pins the primary role to an arbitrary display,
        // so a monitor: primary layout and an undeclared layout can be active
        // simultaneously and must be validated as a normal pair.
        let config = ShitsuraeConfig(
            monitors: MonitorsDefinition(["main": MonitorTargetDefinition(id: "uuid-x")]),
            layouts: [
                "work": LayoutDefinition(spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]),
                "focus": LayoutDefinition(
                    display: DisplayDefinition(monitor: "main"),
                    spaces: [
                        SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                    ]
                ),
            ]
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("identical window matcher") })
    }

    @Test func rejectsInvalidShortcutKey() {
        let config = ShitsuraeConfig(
            layouts: [
                "work": LayoutDefinition(spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]),
            ],
            shortcuts: ShortcutsDefinition(
                nextWindow: HotkeyDefinition(key: "invalid-key", modifiers: ["cmd"])
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("nextWindow has invalid key") })
    }

    @Test func rejectsModifierlessHotkey() {
        let config = ShitsuraeConfig(
            layouts: [
                "work": LayoutDefinition(spaces: [
                    SpaceDefinition(spaceID: 1, windows: [makeWindow(bundleID: "a.b.c", slot: 1)]),
                ]),
            ],
            shortcuts: ShortcutsDefinition(
                nextWindow: HotkeyDefinition(key: "j", modifiers: [])
            )
        )

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("must have at least one modifier") })
    }

    @Test func rejectsEmptyLayouts() {
        let config = makeConfig(layouts: [:])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("at least one layout is required") })
    }

    @Test func rejectsUndefinedMonitorAlias() {
        let config = makeConfig(layouts: [
            "research": LayoutDefinition(
                display: DisplayDefinition(monitor: "missing"),
                spaces: [SpaceDefinition(spaceID: 1, windows: [])]
            ),
        ])
        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("undefined monitor alias missing") })
    }

    @Test func rejectsMonitorWithoutExactlyOneSelector() {
        let config = ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "research": MonitorTargetDefinition(id: "uuid-research", primary: true),
            ]),
            layouts: [
                "work": LayoutDefinition(spaces: [SpaceDefinition(spaceID: 1, windows: [])]),
            ]
        )
        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("exactly one selector") })
    }

    @Test func rejectsDuplicateSpaceShortcutChordOnSameMonitor() {
        let config = ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "research": MonitorTargetDefinition(id: "uuid-research"),
            ]),
            layouts: [
                "research": LayoutDefinition(
                    display: DisplayDefinition(monitor: "research"),
                    spaces: [
                        SpaceDefinition(spaceID: 1, windows: []),
                        SpaceDefinition(spaceID: 2, windows: []),
                    ]
                ),
            ],
            shortcuts: ShortcutsDefinition(switchVirtualSpace: [
                SwitchVirtualSpaceShortcut(
                    key: "x",
                    modifiers: ["ctrl"],
                    spaceID: 1,
                    monitor: "research"
                ),
                SwitchVirtualSpaceShortcut(
                    key: "x",
                    modifiers: ["ctrl"],
                    spaceID: 2,
                    monitor: "research"
                ),
            ])
        )
        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("same monitor and key chord") })
    }

    @Test func rejectsPrimaryAliasChordThatDuplicatesDefaultShortcut() {
        let config = ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "main": MonitorTargetDefinition(primary: true),
            ]),
            layouts: [
                "work": LayoutDefinition(spaces: [
                    SpaceDefinition(spaceID: 1, windows: []),
                    SpaceDefinition(spaceID: 2, windows: []),
                ]),
            ],
            shortcuts: ShortcutsDefinition(switchVirtualSpace: [
                SwitchVirtualSpaceShortcut(
                    key: "2",
                    modifiers: ["ctrl"],
                    spaceID: 1,
                    monitor: "main"
                ),
            ])
        )
        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("same monitor and key chord") })
    }
}
