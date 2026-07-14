import CoreGraphics
import Testing
@testable import ShitsuraeCore

@Suite("Display coordinates")
struct DisplayCoordinateTests {
    @Test func convertsAppKitRectsToStableCGGlobalCoordinates() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)

        #expect(SystemProbe.cgGlobalRect(
            fromAppKit: primary,
            primaryAppKitFrame: primary
        ) == CGRect(x: 0, y: 0, width: 1_440, height: 900))

        #expect(SystemProbe.cgGlobalRect(
            fromAppKit: CGRect(x: -1_920, y: 100, width: 1_920, height: 1_080),
            primaryAppKitFrame: primary
        ) == CGRect(x: -1_920, y: -280, width: 1_920, height: 1_080))

        #expect(SystemProbe.cgGlobalRect(
            fromAppKit: CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080),
            primaryAppKitFrame: primary
        ) == CGRect(x: 0, y: 900, width: 1_920, height: 1_080))

        #expect(SystemProbe.cgGlobalRect(
            fromAppKit: CGRect(x: 0, y: 900, width: 1_920, height: 1_080),
            primaryAppKitFrame: primary
        ) == CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080))

        #expect(SystemProbe.cgGlobalRect(
            fromAppKit: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
            primaryAppKitFrame: primary
        ) == CGRect(x: 1_440, y: -180, width: 1_920, height: 1_080))
    }

    @Test func resolvesAndClassifiesWindowsUsingTheSameCGCoordinateSpace() {
        let primary = TestFixtures.display
        let upper = DisplayInfo(
            id: "uuid-upper",
            width: 1_920,
            height: 1_080,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: -480, y: -1_080, width: 1_920, height: 1_080),
            visibleFrame: CGRect(x: -480, y: -1_055, width: 1_920, height: 1_055)
        )
        let frame = ResolvedFrame(x: 100, y: -900, width: 700, height: 500)
        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)

        #expect(WindowEnumerator.resolveDisplay(for: rect, displays: [primary, upper])?.id == upper.id)
        #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: frame, displays: [primary, upper]))
    }
}
