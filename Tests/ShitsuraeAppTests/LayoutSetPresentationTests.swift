import CoreGraphics
import ShitsuraeCore
import Testing
@testable import Shitsurae

@Suite("Layout set presentation")
struct LayoutSetPresentationTests {
    private let primary = DisplayInfo(
        id: "primary",
        width: 2880,
        height: 1800,
        scale: 2,
        isPrimary: true,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
    )
    private let secondary = DisplayInfo(
        id: "secondary",
        width: 2560,
        height: 1440,
        scale: 2,
        isPrimary: false,
        frame: CGRect(x: 1440, y: 0, width: 1280, height: 720),
        visibleFrame: CGRect(x: 1440, y: 0, width: 1280, height: 720)
    )

    private func layout(display: DisplayDefinition? = nil, spaces: [Int] = [1]) -> LayoutDefinition {
        LayoutDefinition(
            display: display,
            spaces: spaces.map { SpaceDefinition(spaceID: $0, windows: []) }
        )
    }

    @Test func oneMemberSetIsApplicableAndSelectionIsOnlyPresentationState() throws {
        let config = ShitsuraeConfig(
            layouts: ["macbook-pro": layout(spaces: [1, 2])],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["macbook-pro"])]
        )

        let item = try #require(LayoutSetPresentation.makeAll(
            config: config,
            state: RuntimeState(),
            displays: [primary]
        ).first)

        #expect(item.name == "mobile")
        #expect(item.members.count == 1)
        #expect(item.members[0].targetSpaceID == 1)
        #expect(item.canApply)
        #expect(!item.isSelected)
    }

    @Test func selectedSetReapplyPreservesValidCurrentSpaceAndShowsDirtyDigest() throws {
        let config = ShitsuraeConfig(
            layouts: ["macbook-pro": layout(spaces: [1, 2])],
            layoutSets: ["mobile": LayoutSetDefinition(layouts: ["macbook-pro"])]
        )
        var state = RuntimeState(
            selectedLayoutSet: SelectedLayoutSet(
                name: "mobile",
                memberNames: ["macbook-pro"],
                definitionDigest: "stale"
            ),
            activeWorkspaces: [
                ActiveWorkspace(displayID: "primary", layoutName: "macbook-pro", spaceID: 2),
            ]
        )
        state.slots = []

        let item = try #require(LayoutSetPresentation.makeAll(
            config: config,
            state: state,
            displays: [primary]
        ).first)

        #expect(item.isSelected)
        #expect(item.needsReapply)
        #expect(item.members[0].targetSpaceID == 2)
    }

    @Test func unavailableDisplayAndRuntimeCollisionDisableApply() throws {
        let missingConfig = ShitsuraeConfig(
            monitors: MonitorsDefinition(["side": MonitorTargetDefinition(id: "secondary")]),
            layouts: ["side": layout(display: DisplayDefinition(monitor: "side"))],
            layoutSets: ["missing": LayoutSetDefinition(layouts: ["side"])]
        )
        let missing = try #require(LayoutSetPresentation.makeAll(
            config: missingConfig,
            state: RuntimeState(),
            displays: [primary]
        ).first)
        #expect(!missing.canApply)
        #expect(missing.members[0].issue == "Display unavailable")
        #expect(missing.blockingReason?.contains("Connect it or select another layout set") == true)
        #expect(missing.blockingReason?.contains("hostDisplayUnavailable(") == false)

        let collisionConfig = ShitsuraeConfig(
            layouts: ["a": layout(), "b": layout()],
            layoutSets: ["collision": LayoutSetDefinition(layouts: ["a", "b"])]
        )
        let collision = try #require(LayoutSetPresentation.makeAll(
            config: collisionConfig,
            state: RuntimeState(),
            displays: [primary, secondary]
        ).first)
        #expect(!collision.canApply)
        #expect(collision.members.contains { $0.issue == "Display collision" })
        #expect(collision.blockingReason?.contains("Assign each member to a different display") == true)
        #expect(collision.blockingReason?.contains("displayCollision(") == false)
    }

    @Test func deletedSelectedSetIsNeedsReapplyWithoutFabricatingAPresentation() {
        let config = ShitsuraeConfig(layouts: ["work": layout()])
        let state = RuntimeState(
            selectedLayoutSet: SelectedLayoutSet(
                name: "deleted",
                memberNames: ["work"],
                definitionDigest: "old"
            )
        )

        #expect(state.selectedSetNeedsReapply(config: config))
        #expect(LayoutSetPresentation.makeAll(config: config, state: state, displays: [primary]).isEmpty)
    }

    @Test func previewUsesCoreInitialFocusIgnoreRejection() throws {
        let definition = LayoutDefinition(initialFocus: InitialFocusDefinition(slot: 1), spaces: [SpaceDefinition(spaceID: 1,
            windows: [WindowDefinition(match: WindowMatchRule(bundleID: "Editor"), slot: 1)])])
        let config = ShitsuraeConfig(ignore: IgnoreDefinition(apply: IgnoreRuleSet(apps: ["Editor"])),
            layouts: ["work": definition], layoutSets: ["home": LayoutSetDefinition(layouts: ["work"])])
        let item = try #require(LayoutSetPresentation.makeAll(config: config, state: RuntimeState(), displays: [primary]).first)
        #expect(!item.canApply)
        do {
            _ = try LayoutSetPlanner.build(setName: "home", config: config, state: RuntimeState(), displays: [primary], currentWindows: nil)
            Issue.record("expected core preflight failure")
        } catch let error as LayoutSetPlanError {
            #expect(error == .initialFocusExcluded(layout: "work", bundleID: "Editor"))
            #expect(item.blockingReason == error.displayMessage)
            #expect(item.blockingReason?.contains("because it is ignored") == true)
            #expect(item.blockingReason?.contains("Update initial focus") == true)
            #expect(item.blockingReason?.contains("initialFocusExcluded(") == false)
        }
    }

    @Test func plannerFailuresUseHumanReasonAndActionWithoutEnumDescriptions() {
        let errors: [LayoutSetPlanError] = [.hostDisplayUnavailable("side"),
            .displayCollision(displayID: "private-id", layouts: ["main", "side"]),
            .candidateConflict(layouts: ["main", "side"], identity: WindowIdentity(pid: 1, processStartTime: 1, windowID: 1, bundleID: "Editor"))]
        #expect(errors[0].displayMessage.contains("Connect it"))
        #expect(errors[1].displayMessage.contains("different display"))
        #expect(errors[2].displayMessage.contains("window matching rules"))
        for error in errors {
            #expect(!error.displayMessage.contains(String(describing: error)))
            #expect(!error.displayMessage.contains("private-id"))
        }
    }

    @Test func membersShowActiveDormantAndInactiveWithoutChangingSelection() throws {
        let config = ShitsuraeConfig(layouts: ["main": layout(), "side": layout(display: DisplayDefinition(id: "secondary")),
            "extra": layout(display: DisplayDefinition(id: "third"))],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main", "side", "extra"])])
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 1),
            ActiveWorkspace(displayID: "secondary", layoutName: "side", spaceID: 1)])
        let item = try #require(LayoutSetPresentation.makeAll(config: config, state: state, displays: [primary]).first)
        #expect(item.members.first { $0.layoutName == "main" }?.managementState == "Active · Space 1")
        #expect(item.members.first { $0.layoutName == "side" }?.managementState == "Dormant · Space 1")
        #expect(item.members.first { $0.layoutName == "extra" }?.managementState == "Inactive")
        #expect(!item.isSelected && state.selectedLayoutSet == nil)
    }
}
