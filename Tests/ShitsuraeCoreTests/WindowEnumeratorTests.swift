import CoreGraphics
import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowEnumerator")
struct WindowEnumeratorTests {
    private let display = DisplayInfo(
        id: "uuid-main",
        width: 2880,
        height: 1800,
        scale: 2,
        isPrimary: true,
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 875)
    )

    private func rawWindow(
        id: UInt32,
        pid: Int,
        layer: Int = 0,
        title: String = "win",
        x: Double = 10,
        y: Double = 10,
        width: Double = 800,
        height: Double = 600
    ) -> [String: Any] {
        [
            kCGWindowLayer as String: layer,
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowName as String: title,
            kCGWindowBounds as String: [
                "X": x, "Y": y, "Width": width, "Height": height,
            ] as NSDictionary,
        ]
    }

    @Test func buildsSnapshotsWithMinimizedAndSubroleFromResolver() {
        let raw = [
            rawWindow(id: 1, pid: 100),
            rawWindow(id: 2, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.example.App", isHidden: false) },
            windowAXInfoResolver: { pids in
                #expect(pids == [100])
                return WindowEnumerator.WindowAXInfo(
                    minimized: [2],
                    subroles: [1: "AXStandardWindow", 2: "AXDialog"]
                )
            }
        )

        #expect(snapshots.count == 2)
        #expect(snapshots.first { $0.windowID == 1 }?.minimized == false)
        #expect(snapshots.first { $0.windowID == 2 }?.minimized == true)
        #expect(snapshots.first { $0.windowID == 1 }?.subrole == "AXStandardWindow")
        #expect(snapshots.first { $0.windowID == 2 }?.subrole == "AXDialog")
    }

    @Test func skipsNonZeroLayersAndZeroSizeWindows() {
        let raw = [
            rawWindow(id: 1, pid: 100, layer: 25),
            rawWindow(id: 2, pid: 100, width: 0, height: 0),
            rawWindow(id: 3, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.example.App", isHidden: false) }
        )

        #expect(snapshots.map(\.windowID) == [3])
    }

    @Test func skipsWindowsWithoutResolvableApp() {
        let raw = [rawWindow(id: 1, pid: 100), rawWindow(id: 2, pid: 200)]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in pid == 100 ? (bundleID: "com.example.App", isHidden: false) : nil }
        )

        #expect(snapshots.map(\.windowID) == [1])
    }

    @Test func memoizesProfileResolutionPerPID() {
        let raw = [
            rawWindow(id: 1, pid: 100),
            rawWindow(id: 2, pid: 100),
            rawWindow(id: 3, pid: 200),
        ]
        var calls: [Int] = []

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.google.Chrome", isHidden: false) },
            profileResolver: { _, pid in
                calls.append(pid)
                return pid == 100 ? "Default" : nil
            }
        )

        #expect(calls == [100, 200])
        #expect(snapshots.first { $0.windowID == 1 }?.profileDirectory == "Default")
        #expect(snapshots.first { $0.windowID == 3 }?.profileDirectory == nil)
    }

    @Test func detectsFullscreenByDisplayFrame() {
        let raw = [
            rawWindow(id: 1, pid: 100, x: 0, y: 0, width: 1440, height: 900),
            rawWindow(id: 2, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.example.App", isHidden: false) }
        )

        #expect(snapshots.first { $0.windowID == 1 }?.isFullscreen == true)
        #expect(snapshots.first { $0.windowID == 2 }?.isFullscreen == false)
    }

    @Test func resolveDisplayPrefersCenterContainment() {
        let secondary = DisplayInfo(
            id: "uuid-side",
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )

        let rect = CGRect(x: 1400, y: 100, width: 400, height: 300) // center on secondary
        let resolved = WindowEnumerator.resolveDisplay(for: rect, displays: [display, secondary])
        #expect(resolved?.id == "uuid-side")
    }

    @Test func sortsByFrontIndex() {
        let raw = [
            rawWindow(id: 9, pid: 100),
            rawWindow(id: 3, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { _ in (bundleID: "com.example.App", isHidden: false) }
        )

        #expect(snapshots.map(\.windowID) == [9, 3])
        #expect(snapshots.map(\.frontIndex) == [0, 1])
    }
}
