import CoreGraphics
import XCTest
@testable import ShitsuraeCore

final class RuntimeWindowServicesTests: XCTestCase {
    func testListWindowsTransformsRawWindowInfoAndSortsByFrontAndWindowID() {
        let display = DisplayInfo(
            id: "display-a",
            width: 3000,
            height: 2000,
            scale: 2.0,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1500, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )

        let raw: [[String: Any]] = [
            // layer != 0 -> skip
            [
                kCGWindowLayer as String: 3,
                kCGWindowNumber as String: NSNumber(value: 999),
                kCGWindowOwnerPID as String: NSNumber(value: 99),
                kCGWindowBounds as String: boundsDictionary(CGRect(x: 0, y: 0, width: 100, height: 100)),
            ],
            // valid
            [
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: NSNumber(value: 102),
                kCGWindowOwnerPID as String: NSNumber(value: 2),
                kCGWindowName as String: "B",
                "kCGWindowWorkspace": 2,
                kCGWindowBounds as String: boundsDictionary(CGRect(x: 50, y: 60, width: 500, height: 400)),
            ],
            // invalid size -> skip
            [
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: NSNumber(value: 103),
                kCGWindowOwnerPID as String: NSNumber(value: 3),
                kCGWindowBounds as String: boundsDictionary(CGRect(x: 10, y: 10, width: 0, height: 40)),
            ],
            // valid and same front group tie-break by windowID
            [
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: NSNumber(value: 101),
                kCGWindowOwnerPID as String: NSNumber(value: 1),
                kCGWindowName as String: "A",
                "kCGWindowWorkspace": 1,
                kCGWindowBounds as String: boundsDictionary(CGRect(x: 0, y: 0, width: 1500, height: 1000)),
            ],
        ]

        let windows = WindowQueryService.listWindows(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in
                switch pid {
                case 1: return (bundleID: "com.example.a", isHidden: false)
                case 2: return (bundleID: "com.example.b", isHidden: true)
                default: return nil
                }
            },
            spaceResolver: { _, _ in nil }
        )

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows.map(\.windowID), [102, 101])
        XCTAssertEqual(windows[0].bundleID, "com.example.b")
        XCTAssertTrue(windows[0].hidden)
        XCTAssertEqual(windows[0].spaceID, 2)
        XCTAssertEqual(windows[0].displayID, "display-a")
        XCTAssertFalse(windows[0].isFullscreen)
        XCTAssertTrue(windows[1].isFullscreen)
    }

    func testListWindowsUsesSpaceResolverWhenWorkspaceKeyIsMissing() {
        let display = DisplayInfo(
            id: "display-a",
            width: 3000,
            height: 2000,
            scale: 2.0,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1500, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1400, height: 900)
        )

        let raw: [[String: Any]] = [[
            kCGWindowLayer as String: 0,
            kCGWindowNumber as String: NSNumber(value: 102),
            kCGWindowOwnerPID as String: NSNumber(value: 2),
            kCGWindowName as String: "B",
            kCGWindowBounds as String: boundsDictionary(CGRect(x: 50, y: 60, width: 500, height: 400)),
        ]]

        let windows = WindowQueryService.listWindows(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.example.b", isHidden: false) },
            spaceResolver: { _, _ in 4 }
        )

        XCTAssertEqual(windows.first?.spaceID, 4)
    }

    func testResolveFocusedWindowPrefersPIDThenBundleFallback() {
        let byPID = WindowSnapshot(
            windowID: 1,
            bundleID: "com.example.app",
            pid: 200,
            title: "Exact",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: 1,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: 0
        )
        let byBundle = WindowSnapshot(
            windowID: 2,
            bundleID: "com.example.app",
            pid: 201,
            title: "Bundle",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: 1,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: 1
        )

        let exact = WindowQueryService.resolveFocusedWindow(
            frontmostPID: 200,
            frontmostBundleID: "com.example.app",
            windows: [byBundle, byPID]
        )
        XCTAssertEqual(exact?.windowID, 1)

        let fallback = WindowQueryService.resolveFocusedWindow(
            frontmostPID: 999,
            frontmostBundleID: "com.example.app",
            windows: [byBundle]
        )
        XCTAssertEqual(fallback?.windowID, 2)
    }

    func testResolveDisplayAndRoughlySame() {
        let displays = [
            DisplayInfo(
                id: "display-b",
                width: 2000,
                height: 1000,
                scale: 2.0,
                isPrimary: false,
                frame: CGRect(x: 1000, y: 0, width: 1000, height: 1000),
                visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 980)
            ),
            DisplayInfo(
                id: "display-a",
                width: 2000,
                height: 1000,
                scale: 2.0,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 980)
            ),
        ]

        // center-in-frame
        XCTAssertEqual(
            WindowQueryService.resolveDisplay(for: CGRect(x: 100, y: 100, width: 200, height: 200), displays: displays)?.id,
            "display-a"
        )

        // no center containment -> choose max intersection
        XCTAssertEqual(
            WindowQueryService.resolveDisplay(for: CGRect(x: 900, y: 100, width: 300, height: 200), displays: displays)?.id,
            "display-b"
        )

        // no intersection -> lexical first
        XCTAssertEqual(
            WindowQueryService.resolveDisplay(for: CGRect(x: 5000, y: 0, width: 100, height: 100), displays: displays)?.id,
            "display-a"
        )

        XCTAssertTrue(
            WindowQueryService.roughlySame(
                rect: CGRect(x: 0.5, y: 1.0, width: 999.0, height: 1001.5),
                displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
            )
        )
        XCTAssertFalse(
            WindowQueryService.roughlySame(
                rect: CGRect(x: 10, y: 0, width: 1000, height: 1000),
                displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
            )
        )
    }

    private func boundsDictionary(_ rect: CGRect) -> NSDictionary {
        CGRectCreateDictionaryRepresentation(rect) as NSDictionary
    }
}
