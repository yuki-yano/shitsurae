import CoreGraphics
import Testing
import ShitsuraeCore
@testable import Shitsurae

@Suite("Layout preview geometry")
struct LayoutPreviewTests {
    @Test func includesEverySelectedDisplayInArrangePreviewOrder() {
        let choices = [
            DisplayLayoutChoice(
                displayID: "primary",
                isPrimary: true,
                monitorAlias: "main",
                layoutNames: ["default"],
                activeLayoutName: "default"
            ),
            DisplayLayoutChoice(
                displayID: "research",
                isPrimary: false,
                monitorAlias: "research",
                layoutNames: ["research"],
                activeLayoutName: "research"
            ),
            DisplayLayoutChoice(
                displayID: "calendar",
                isPrimary: false,
                monitorAlias: "calendar",
                layoutNames: ["calendar"],
                activeLayoutName: "calendar"
            ),
        ]

        let selections = selectedDisplayLayouts(
            choices: choices,
            selectionByDisplayID: [
                "primary": "default",
                "research": "research",
                "calendar": "calendar",
            ],
            spaceByDisplayID: ["research": 2]
        )

        #expect(selections == [
            DisplayLayoutSelection(
                displayID: "primary",
                displayTitle: "main Display",
                layoutName: "default",
                spaceID: nil
            ),
            DisplayLayoutSelection(
                displayID: "research",
                displayTitle: "research Display",
                layoutName: "research",
                spaceID: 2
            ),
            DisplayLayoutSelection(
                displayID: "calendar",
                displayTitle: "calendar Display",
                layoutName: "calendar",
                spaceID: nil
            ),
        ])
    }

    @Test func omitsDisplaysMarkedDoNotApplyFromArrangePreview() {
        let choices = [
            DisplayLayoutChoice(
                displayID: "primary",
                isPrimary: true,
                monitorAlias: nil,
                layoutNames: ["default"],
                activeLayoutName: nil
            ),
            DisplayLayoutChoice(
                displayID: "secondary",
                isPrimary: false,
                monitorAlias: nil,
                layoutNames: ["calendar"],
                activeLayoutName: nil
            ),
        ]

        let selections = selectedDisplayLayouts(
            choices: choices,
            selectionByDisplayID: ["secondary": "calendar"],
            spaceByDisplayID: [:]
        )

        #expect(selections.map(\.displayID) == ["secondary"])
    }

    @Test func resolvesLengthsAgainstTheSelectedDisplaysVisibleFrameAndScale() throws {
        let display = DisplayInfo(
            id: "secondary",
            width: 2_000,
            height: 1_000,
            scale: 2,
            isPrimary: false,
            frame: CGRect(x: 100, y: 20, width: 1_000, height: 500),
            visibleFrame: CGRect(x: 100, y: 50, width: 1_000, height: 500)
        )
        let frame = FrameDefinition(
            x: .expression("100pt"),
            y: .expression("10%"),
            width: .expression("500px"),
            height: .expression("50%")
        )

        let result = try #require(resolveProportionalRect(frame: frame, display: display))

        #expect(result == ProportionalRect(x: 0.1, y: 0.1, width: 0.25, height: 0.5))
    }

    @Test func refusesToFabricateGeometryWithoutAUsableDisplay() {
        let display = DisplayInfo(
            id: "unavailable",
            width: 0,
            height: 0,
            scale: 2,
            isPrimary: true,
            frame: .zero,
            visibleFrame: .zero
        )
        let frame = FrameDefinition(
            x: .expression("0%"),
            y: .expression("0%"),
            width: .expression("50%"),
            height: .expression("100%")
        )

        #expect(resolveProportionalRect(frame: frame, display: display) == nil)
    }
}
