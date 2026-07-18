import CoreGraphics
import Testing
import ShitsuraeCore
@testable import Shitsurae

@Suite("Workspace state preview geometry")
struct WorkspaceStatePreviewTests {
    @Test func preservesThePhysicalArrangementOfMultipleDisplays() throws {
        let secondary = DisplayInfo(
            id: "secondary",
            width: 1_600,
            height: 1_200,
            scale: 2,
            isPrimary: false,
            frame: CGRect(x: -800, y: 100, width: 800, height: 600),
            visibleFrame: CGRect(x: -800, y: 100, width: 800, height: 575)
        )
        let primary = DisplayInfo(
            id: "primary",
            width: 2_880,
            height: 1_800,
            scale: 2,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: CGRect(x: 0, y: 25, width: 1_440, height: 850)
        )

        let layout = try #require(
            WorkspaceStatePreviewLayout(displays: [secondary, primary], windows: [])
        )

        #expect(isApproximatelyEqual(layout.aspectRatio, 2_240.0 / 900.0))
        let secondaryPreview = try #require(layout.displays.first { $0.id == "secondary" })
        let primaryPreview = try #require(layout.displays.first { $0.id == "primary" })
        #expect(secondaryPreview.normalizedFrame.minX == 0)
        #expect(isApproximatelyEqual(secondaryPreview.normalizedFrame.minY, 100.0 / 900.0))
        #expect(isApproximatelyEqual(secondaryPreview.normalizedFrame.width, 800.0 / 2_240.0))
        #expect(isApproximatelyEqual(primaryPreview.normalizedFrame.minX, 800.0 / 2_240.0))
        #expect(primaryPreview.normalizedFrame.minY == 0)
        #expect(isApproximatelyEqual(primaryPreview.normalizedFrame.width, 1_440.0 / 2_240.0))
        let primaryVisibleFrame = try #require(primaryPreview.normalizedVisibleFrame)
        #expect(isApproximatelyEqual(primaryVisibleFrame.minY, 25.0 / 900.0))
    }

    @Test func clipsPartiallyVisibleWindowsAndRejectsFullyOffscreenFrames() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 800)

        let partial = try #require(
            WorkspaceStatePreviewLayout.normalizedFrame(
                CGRect(x: -100, y: 200, width: 300, height: 400),
                within: bounds
            )
        )

        #expect(partial == CGRect(x: 0, y: 0.25, width: 0.2, height: 0.5))
        #expect(WorkspaceStatePreviewLayout.normalizedFrame(
            CGRect(x: 1_100, y: 100, width: 200, height: 200),
            within: bounds
        ) == nil)
    }

    @Test func rejectsMissingOrUnusableDisplayGeometry() {
        #expect(WorkspaceStatePreviewLayout.canvasBounds(for: []) == nil)
        #expect(WorkspaceStatePreviewLayout.canvasBounds(for: [.zero]) == nil)
    }

    @Test func retainsAUsableDisplayWhenItsVisibleFrameIsUnavailable() throws {
        let display = DisplayInfo(
            id: "display",
            width: 2_000,
            height: 1_200,
            scale: 2,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 600),
            visibleFrame: .zero
        )

        let layout = try #require(
            WorkspaceStatePreviewLayout(displays: [display], windows: [])
        )

        #expect(layout.displays.count == 1)
        #expect(layout.displays[0].normalizedVisibleFrame == nil)
    }

    private func isApproximatelyEqual(_ lhs: CGFloat, _ rhs: Double) -> Bool {
        abs(Double(lhs) - rhs) < 1e-12
    }
}
