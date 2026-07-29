import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("Space shortcut routing")
struct SpaceShortcutRouterTests {
    private let main = TestFixtures.display
    private let research = TestFixtures.secondaryDisplay(id: "uuid-research")

    private var config: ShitsuraeConfig {
        ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "main": MonitorTargetDefinition(primary: true),
                "research": MonitorTargetDefinition(id: research.id),
            ]),
            layouts: [
                "work": LayoutDefinition(spaces: [
                    SpaceDefinition(spaceID: 1, windows: []),
                    SpaceDefinition(spaceID: 2, windows: []),
                ]),
                "research": LayoutDefinition(
                    display: DisplayDefinition(monitor: "research"),
                    spaces: [
                        SpaceDefinition(spaceID: 1, windows: []),
                        SpaceDefinition(spaceID: 2, windows: []),
                    ]
                ),
            ]
        )
    }

    private var workspaces: [ActiveWorkspace] {
        [
            ActiveWorkspace(displayID: main.id, layoutName: "work", spaceID: 1),
            ActiveWorkspace(displayID: research.id, layoutName: "research", spaceID: 1),
        ]
    }

    private func candidate(
        monitor: String?,
        spaceID: Int = 2,
        focus: SpaceSwitchFocusPolicy = .preserve
    ) -> ResolvedSpaceSwitchShortcut {
        ResolvedSpaceSwitchShortcut(
            hotkey: HotkeyDefinition(key: "2", modifiers: ["ctrl"]),
            spaceID: spaceID,
            monitor: monitor,
            focus: focus
        )
    }

    @Test func duplicateChordUsesCursorDisplay() {
        let candidates = [candidate(monitor: nil), candidate(monitor: "research")]

        let mainResult = SpaceShortcutRouter.route(
            candidates: candidates,
            cursorLocation: CGPoint(x: 20, y: 20),
            config: config,
            displays: [main, research],
            activeWorkspaces: workspaces
        )
        let researchResult = SpaceShortcutRouter.route(
            candidates: candidates,
            cursorLocation: CGPoint(x: research.frame.minX, y: 20),
            config: config,
            displays: [main, research],
            activeWorkspaces: workspaces
        )

        guard case let .execute(mainTarget) = mainResult,
              case let .execute(researchTarget) = researchResult
        else {
            Issue.record("expected routed targets")
            return
        }
        #expect(mainTarget.displayID == main.id)
        #expect(researchTarget.displayID == research.id)
    }

    @Test func oneExecutableCandidateIgnoresCursorLocation() {
        let result = SpaceShortcutRouter.route(
            candidates: [candidate(monitor: nil), candidate(monitor: "research")],
            cursorLocation: CGPoint(x: 99_999, y: 99_999),
            config: config,
            displays: [main],
            activeWorkspaces: workspaces
        )

        guard case let .execute(target) = result else {
            Issue.record("expected primary target")
            return
        }
        #expect(target.displayID == main.id)
    }

    @Test func duplicateChordWithoutCandidateOnCursorDisplayFailsClosed() {
        let calendar = DisplayInfo(
            id: "uuid-calendar",
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1080)
        )
        let result = SpaceShortcutRouter.route(
            candidates: [candidate(monitor: nil), candidate(monitor: "research")],
            cursorLocation: CGPoint(x: 20, y: 920),
            config: config,
            displays: [main, research, calendar],
            activeWorkspaces: workspaces
        )

        guard case let .failure(message) = result else {
            Issue.record("expected routing failure")
            return
        }
        #expect(message.contains("cursor display"))
    }

    @Test func candidatesWithoutActiveWorkspaceOrTargetSpaceAreNotExecutable() {
        let result = SpaceShortcutRouter.route(
            candidates: [candidate(monitor: "research", spaceID: 9)],
            cursorLocation: research.frame.origin,
            config: config,
            displays: [main, research],
            activeWorkspaces: workspaces
        )
        #expect(result == .failure("no executable workspace switch target"))
    }

    @Test func duplicateChordWithCursorOutsideEveryDisplayFailsClosed() {
        let result = SpaceShortcutRouter.route(
            candidates: [candidate(monitor: nil), candidate(monitor: "research")],
            cursorLocation: CGPoint(x: -500, y: -500),
            config: config,
            displays: [main, research],
            activeWorkspaces: workspaces
        )

        #expect(
            result == .failure(
                "cursor is not on a connected display with a matching shortcut"
            )
        )
    }

    @Test func identicalTargetsResolvedThroughDifferentAliasesAreDeduplicated() {
        let duplicateAliasConfig = ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "research": MonitorTargetDefinition(id: research.id),
                "research-dock": MonitorTargetDefinition(id: research.id),
            ]),
            layouts: config.layouts
        )
        let result = SpaceShortcutRouter.route(
            candidates: [
                candidate(monitor: "research"),
                candidate(monitor: "research-dock"),
            ],
            cursorLocation: .zero,
            config: duplicateAliasConfig,
            displays: [main, research],
            activeWorkspaces: workspaces
        )

        guard case let .execute(target) = result else {
            Issue.record("expected deduplicated target")
            return
        }
        #expect(target.displayID == research.id)
        #expect(target.spaceID == 2)
    }

    @Test func differentPoliciesOnSameResolvedDisplayRemainAmbiguous() {
        let duplicateAliasConfig = ShitsuraeConfig(
            monitors: MonitorsDefinition([
                "research": MonitorTargetDefinition(id: research.id),
                "research-dock": MonitorTargetDefinition(id: research.id),
            ]),
            layouts: config.layouts
        )
        let result = SpaceShortcutRouter.route(
            candidates: [
                candidate(monitor: "research", focus: .target),
                candidate(monitor: "research-dock", focus: .preserve),
            ],
            cursorLocation: research.frame.origin,
            config: duplicateAliasConfig,
            displays: [main, research],
            activeWorkspaces: workspaces
        )

        #expect(
            result == .failure(
                "multiple matching shortcut targets resolve to the cursor display"
            )
        )
    }
}
