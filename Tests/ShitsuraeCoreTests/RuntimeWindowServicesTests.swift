import CoreGraphics
import XCTest
@testable import ShitsuraeCore

final class RuntimeWindowServicesTests: XCTestCase {
    func testPrepareForTargetedWindowInteractionUnhidesOnlyWhenAppIsHidden() {
        var unhideCount = 0

        WindowQueryService.prepareForTargetedWindowInteraction(isHidden: true) {
            unhideCount += 1
        }
        WindowQueryService.prepareForTargetedWindowInteraction(isHidden: false) {
            unhideCount += 1
        }

        XCTAssertEqual(unhideCount, 1)
    }

    func testBundleActivationOptionsDoesNotActivateAllWindows() {
        let options = WindowQueryService.bundleActivationOptions()

        XCTAssertFalse(options.contains(.activateAllWindows))
        XCTAssertTrue(options.isEmpty)
    }

    func testMakeKeyWindowEventBytesEncodesWindowIDAndEventType() {
        let bytes = WindowQueryService.makeKeyWindowEventBytes(windowID: 0x01020304, eventType: 0x02)

        XCTAssertEqual(bytes.count, 0xf8)
        XCTAssertEqual(bytes[0x04], 0xf8)
        XCTAssertEqual(bytes[0x08], 0x02)
        XCTAssertEqual(bytes[0x3a], 0x10)
        XCTAssertEqual(Array(bytes[0x20 ..< 0x30]), Array(repeating: 0xff, count: 0x10))
        XCTAssertEqual(Array(bytes[0x3c ..< 0x40]), [0x04, 0x03, 0x02, 0x01])
    }

    func testMakeKeyWindowPostsPressThenReleaseEvents() {
        var psn = ProcessSerialNumber()
        var capturedEventTypes: [UInt8] = []
        var capturedWindowIDs: [[UInt8]] = []

        let succeeded = WindowQueryService.makeKeyWindow(psn: &psn, windowID: 0x11223344) { _, bytes in
            let buffer = UnsafeBufferPointer(start: bytes, count: 0xf8)
            capturedEventTypes.append(buffer[0x08])
            capturedWindowIDs.append(Array(buffer[0x3c ..< 0x40]))
            return .success
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(capturedEventTypes, [0x01, 0x02])
        XCTAssertEqual(capturedWindowIDs, [[0x44, 0x33, 0x22, 0x11], [0x44, 0x33, 0x22, 0x11]])
    }

    func testPromoteWindowToFrontUsesInjectedSkyLightCallbacks() {
        var requestedPID: pid_t?
        var frontProcessCalls: [(CGWindowID, UInt32)] = []
        var postedEventTypes: [UInt8] = []

        let succeeded = WindowQueryService.promoteWindowToFront(
            pid: 321,
            windowID: 0x55667788,
            getProcessForPID: { pid, _ in
                requestedPID = pid
                return noErr
            },
            setFrontProcessWithOptions: { _, windowID, mode in
                frontProcessCalls.append((windowID, mode))
                return .success
            },
            postEventRecordTo: { _, bytes in
                let buffer = UnsafeBufferPointer(start: bytes, count: 0xf8)
                postedEventTypes.append(buffer[0x08])
                return .success
            }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(requestedPID, 321)
        XCTAssertEqual(frontProcessCalls.count, 1)
        XCTAssertEqual(frontProcessCalls.first?.0, 0x55667788)
        XCTAssertEqual(frontProcessCalls.first?.1, 0x200)
        XCTAssertEqual(postedEventTypes, [0x01, 0x02])
    }

    func testApplyTargetedWindowFocusPromotesThenAppliesAccessibilityFocusAndRaise() {
        var events: [String] = []

        let result = WindowQueryService.applyTargetedWindowFocus(
            pid: 321,
            windowID: 0x55667788,
            promoteWindow: { pid, windowID in
                events.append("promote:\(pid):\(windowID)")
                return true
            },
            applyAccessibilityFocus: { events.append("applyAccessibilityFocus") },
            raiseWindow: { events.append("raiseWindow") }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(
            events,
            ["promote:321:1432778632", "applyAccessibilityFocus", "raiseWindow"]
        )
    }

    func testApplyTargetedWindowFocusStopsWhenWindowPromotionFails() {
        var events: [String] = []

        let result = WindowQueryService.applyTargetedWindowFocus(
            pid: 123,
            windowID: 456,
            promoteWindow: { _, _ in
                events.append("promote")
                return false
            },
            applyAccessibilityFocus: { events.append("applyAccessibilityFocus") },
            raiseWindow: { events.append("raiseWindow") }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(events, ["promote"])
    }

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
            focusedWindowID: nil,
            windows: [byBundle, byPID]
        )
        XCTAssertEqual(exact?.windowID, 1)

        let fallback = WindowQueryService.resolveFocusedWindow(
            frontmostPID: 999,
            frontmostBundleID: "com.example.app",
            focusedWindowID: nil,
            windows: [byBundle]
        )
        XCTAssertEqual(fallback?.windowID, 2)
    }

    func testResolveFocusedWindowUsesFocusedWindowIDBeforePIDFallback() {
        let first = WindowSnapshot(
            windowID: 1,
            bundleID: "com.example.finder",
            pid: 200,
            title: "First",
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
        let second = WindowSnapshot(
            windowID: 2,
            bundleID: "com.example.finder",
            pid: 200,
            title: "Second",
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

        let focused = WindowQueryService.resolveFocusedWindow(
            frontmostPID: 200,
            frontmostBundleID: "com.example.finder",
            focusedWindowID: 2,
            windows: [first, second]
        )

        XCTAssertEqual(focused?.windowID, 2)
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
