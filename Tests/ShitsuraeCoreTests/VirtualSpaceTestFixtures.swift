import Foundation
@testable import ShitsuraeCore

/// Branch-free setup shared by the virtual-space engine suites. Fault
/// injection and assertions stay in each test body.
extension TestFixtures {
    static func makeVirtualSpaceEngine(
        windows: [WindowSnapshot],
        displays: [DisplayInfo] = [TestFixtures.display]
    ) -> (engine: VirtualSpaceEngine, control: MockWindowControl, stateURL: URL) {
        let control = MockWindowControl(windows: windows, displays: displays)
        let (store, url) = tempStateStore()
        let engine = try! VirtualSpaceEngine(
            store: store,
            control: control,
            logger: nullLogger(),
            retryDelaysMS: [1]
        )
        return (engine, control, url)
    }

    /// TextEdit (1) / Terminal (2) / Notes (3), matching `twoSpaceLayout()`.
    static func twoSpaceLayoutWindows() -> [WindowSnapshot] {
        [
            window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            window(id: 2, bundleID: "com.apple.Terminal", isAXBacked: true, frontIndex: 1),
            window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 2),
        ]
    }

    /// TextEdit (1) / Notes (3) / Safari (4), matching `textEditThenNotesSafariLayout()`.
    static func textEditThenNotesSafariWindows() -> [WindowSnapshot] {
        [
            window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true, frontIndex: 0),
            window(id: 3, bundleID: "com.apple.Notes", isAXBacked: true, frontIndex: 1),
            window(id: 4, bundleID: "com.apple.Safari", isAXBacked: true, frontIndex: 2),
        ]
    }

    /// space1 = TextEdit full screen, space2 = Notes (left) + Safari (right).
    static func textEditThenNotesSafariLayout() -> LayoutDefinition {
        LayoutDefinition(spaces: [
            SpaceDefinition(spaceID: 1, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.TextEdit"),
                    slot: 1,
                    frame: frameDef("0%", "0%", "100%", "100%")
                ),
            ]),
            SpaceDefinition(spaceID: 2, windows: [
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Notes"),
                    slot: 1,
                    frame: frameDef("0%", "0%", "50%", "100%")
                ),
                WindowDefinition(
                    match: WindowMatchRule(bundleID: "com.apple.Safari"),
                    slot: 2,
                    frame: frameDef("50%", "0%", "50%", "100%")
                ),
            ]),
        ])
    }

    /// Switches 1 → 2 → 1 on a `twoSpaceLayout()` engine whose active space is 2.
    /// Every switch plans the space-1 window, so when the caller has pinned that
    /// window (it refuses both parking and minimize) each switch stays
    /// unconverged and the third one reaches the engine's quarantine threshold
    /// of three consecutive failures. The outcomes are returned so callers can
    /// assert that the threshold was actually reached.
    static func switchThroughQuarantineThreshold(
        engine: VirtualSpaceEngine,
        config: LoadedConfig
    ) async throws -> [SpaceSwitchOutcome] {
        let first = try await engine.switchSpace(to: 1, config: config)
        let second = try await engine.switchSpace(to: 2, config: config)
        let third = try await engine.switchSpace(to: 1, config: config)
        return [first, second, third]
    }
}
