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
        ShitsuraeConfig(layouts: layouts)
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

    @Test func rejectsMixedImplicitAndExplicitDisplays() {
        let config = makeConfig(layouts: [
            "work": LayoutDefinition(spaces: [
                SpaceDefinition(
                    spaceID: 1,
                    display: DisplayDefinition(monitor: .primary),
                    windows: [makeWindow(bundleID: "a.b.c", slot: 1)]
                ),
                SpaceDefinition(spaceID: 2, windows: [makeWindow(bundleID: "d.e.f", slot: 1)]),
            ]),
        ])

        let errors = ConfigValidator.validate(config: config, sourcePath: "/test")
        #expect(errors.contains { $0.message.contains("cannot mix implicit and explicit displays") })
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
}
