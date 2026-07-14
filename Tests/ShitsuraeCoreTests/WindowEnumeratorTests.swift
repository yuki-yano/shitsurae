import CoreGraphics
import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("WindowEnumerator")
struct WindowEnumeratorTests {
    @Test func resolvesKernelGenerationForCurrentProcess() {
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        #expect(ProcessGenerationResolver.startTime(pid: pid) != nil)
    }

    private func ax(
        _ pid: Int,
        _ windowID: UInt32,
        bundleID: String = "com.example.App"
    ) -> WindowIdentity {
        WindowIdentity(
            pid: pid,
            processStartTime: UInt64(pid) * 1_000_000,
            windowID: windowID,
            bundleID: bundleID
        )
    }

    private func app(_ bundleID: String, pid: Int) -> (
        bundleID: String,
        isHidden: Bool,
        processStartTime: UInt64
    ) {
        (bundleID, false, UInt64(pid) * 1_000_000)
    }

    private func owner(_ bundleID: String, pid: Int) -> WindowEnumerator.ProcessOwnerIdentity {
        WindowEnumerator.ProcessOwnerIdentity(
            bundleID: bundleID,
            processStartTime: UInt64(pid) * 1_000_000
        )
    }

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

    @Test func buildsSnapshotsWithRawAXClassificationAttributesFromResolver() {
        let raw = [
            rawWindow(id: 1, pid: 100),
            rawWindow(id: 2, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in app("com.example.App", pid: pid) },
            windowAXInfoResolver: { owners in
                #expect(owners == [100: owner("com.example.App", pid: 100)])
                return WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [ax(100, 1), ax(100, 2)],
                    minimized: [ax(100, 2)],
                    roles: [ax(100, 1): "AXWindow", ax(100, 2): "AXWindow"],
                    subroles: [ax(100, 1): "AXStandardWindow", ax(100, 2): "AXDialog"],
                    modals: [ax(100, 1): false, ax(100, 2): true]
                )
            }
        )

        #expect(snapshots.count == 2)
        #expect(snapshots.first { $0.windowID == 1 }?.minimized == false)
        #expect(snapshots.first { $0.windowID == 2 }?.minimized == true)
        #expect(snapshots.allSatisfy { $0.isAXBacked })
        #expect(snapshots.first { $0.windowID == 1 }?.role == "AXWindow")
        #expect(snapshots.first { $0.windowID == 1 }?.subrole == "AXStandardWindow")
        #expect(snapshots.first { $0.windowID == 1 }?.modal == false)
        #expect(snapshots.first { $0.windowID == 2 }?.subrole == "AXDialog")
        #expect(snapshots.first { $0.windowID == 2 }?.modal == true)
    }

    @Test func focusedCompanionBlocksOnlyItsExactProcessMainWindow() {
        let chromeBundleID = "com.google.Chrome"
        let main = ax(100, 1, bundleID: chromeBundleID)
        let sheet = ax(100, 2, bundleID: chromeBundleID)
        let siblingProcessMain = ax(200, 3, bundleID: chromeBundleID)
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: [
                rawWindow(id: 1, pid: 100, title: "Main"),
                rawWindow(id: 2, pid: 100, title: "Confirm"),
                rawWindow(id: 3, pid: 200, title: "Other Chrome"),
            ],
            displays: [display],
            appResolver: { pid in app(chromeBundleID, pid: pid) },
            windowAXInfoResolver: { _ in
                WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [main, sheet, siblingProcessMain],
                    roles: [main: "AXWindow", sheet: "AXWindow", siblingProcessMain: "AXWindow"],
                    subroles: [
                        main: "AXStandardWindow",
                        sheet: "AXSheet",
                        siblingProcessMain: "AXStandardWindow",
                    ],
                    modals: [main: false, sheet: true, siblingProcessMain: false],
                    focusedWindowIdentities: [sheet, siblingProcessMain],
                    mainWindowIdentities: [main, siblingProcessMain]
                )
            }
        )

        #expect(snapshots.first { $0.identity == main }?.geometryBlocked == true)
        #expect(snapshots.first { $0.identity == sheet }?.geometryBlocked == false)
        #expect(snapshots.first { $0.identity == siblingProcessMain }?.geometryBlocked == false)
        #expect(snapshots.first { $0.identity == siblingProcessMain }
            .map(WindowEligibility.isManageableForVirtualWorkspace) == true)
    }

    @Test func missingFocusedCGSnapshotStillBlocksExactMainWindow() {
        let chromeBundleID = "com.google.Chrome"
        let main = ax(100, 1, bundleID: chromeBundleID)
        let missingSheet = ax(100, 2, bundleID: chromeBundleID)
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: [rawWindow(id: 1, pid: 100, title: "Main")],
            displays: [display],
            appResolver: { pid in app(chromeBundleID, pid: pid) },
            windowAXInfoResolver: { _ in
                WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [main],
                    roles: [main: "AXWindow"],
                    subroles: [main: "AXStandardWindow"],
                    modals: [main: false],
                    focusedWindowIdentities: [missingSheet],
                    mainWindowIdentities: [main]
                )
            }
        )

        #expect(snapshots.first?.identity == main)
        #expect(snapshots.first?.geometryBlocked == true)
        #expect(snapshots.first.map(WindowEligibility.isManageableForVirtualWorkspace) == false)
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
            appResolver: { pid in app("com.example.App", pid: pid) },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(axBackedWindowIDs: [ax(100, 3)]) }
        )

        #expect(snapshots.map(\.windowID) == [3])
    }

    @Test func skipsWindowsWithoutResolvableApp() {
        let raw = [rawWindow(id: 1, pid: 100), rawWindow(id: 2, pid: 200)]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in pid == 100 ? app("com.example.App", pid: pid) : nil },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(axBackedWindowIDs: [ax(100, 1)]) }
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
            appResolver: { pid in app("com.google.Chrome", pid: pid) },
            profileResolver: { _, pid, _ in
                calls.append(pid)
                return pid == 100 ? "Default" : nil
            },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(
                axBackedWindowIDs: [
                    ax(100, 1, bundleID: "com.google.Chrome"),
                    ax(100, 2, bundleID: "com.google.Chrome"),
                    ax(200, 3, bundleID: "com.google.Chrome"),
                ]
            ) }
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
            appResolver: { pid in app("com.example.App", pid: pid) },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(
                axBackedWindowIDs: [ax(100, 1), ax(100, 2)]
            ) }
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
            appResolver: { pid in app("com.example.App", pid: pid) },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(
                axBackedWindowIDs: [ax(100, 3), ax(100, 9)]
            ) }
        )

        #expect(snapshots.map(\.windowID) == [9, 3])
        #expect(snapshots.map(\.frontIndex) == [0, 1])
    }

    @Test func marksCGOnlySurfaceAsNotAXBacked() {
        let raw = [
            rawWindow(id: 1, pid: 100),
            rawWindow(id: 2, pid: 100),
        ]

        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in app("com.google.Chrome", pid: pid) },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(
                axBackedWindowIDs: [ax(100, 1, bundleID: "com.google.Chrome")]
            ) }
        )

        #expect(snapshots.first { $0.windowID == 1 }?.isAXBacked == true)
        #expect(snapshots.first { $0.windowID == 2 }?.isAXBacked == false)
    }

    @Test func axMetadataNeverCrossesProcessIdentity() {
        let raw = [
            rawWindow(id: 1, pid: 100),
            rawWindow(id: 2, pid: 200),
        ]
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in
                app("com.example.\(pid)", pid: pid)
            },
            windowAXInfoResolver: { _ in
                WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [
                        ax(200, 1, bundleID: "com.example.200"),
                        ax(200, 2, bundleID: "com.example.200"),
                    ],
                    minimized: [ax(200, 1, bundleID: "com.example.200")],
                    roles: [
                        ax(200, 1, bundleID: "com.example.200"): "AXWindow",
                        ax(200, 2, bundleID: "com.example.200"): "AXWindow",
                    ],
                    subroles: [
                        ax(200, 1, bundleID: "com.example.200"): "AXDialog",
                        ax(200, 2, bundleID: "com.example.200"): "AXStandardWindow",
                    ],
                    modals: [ax(200, 1, bundleID: "com.example.200"): true]
                )
            }
        )

        let oldOwner = snapshots.first { $0.pid == 100 }
        #expect(oldOwner?.isAXBacked == false)
        #expect(oldOwner?.minimized == false)
        #expect(oldOwner?.role == nil)
        #expect(oldOwner?.subrole == nil)
        #expect(oldOwner?.modal == nil)
        let currentOwner = snapshots.first { $0.pid == 200 }
        #expect(currentOwner?.isAXBacked == true)
        #expect(currentOwner?.subrole == "AXStandardWindow")
    }

    @Test func axMetadataNeverCrossesBundleIdentityWithinReusedPID() {
        let raw = [rawWindow(id: 1, pid: 100)]
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in app("com.example.Old", pid: pid) },
            windowAXInfoResolver: { owners in
                #expect(owners == [100: owner("com.example.Old", pid: 100)])
                return WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [ax(100, 1, bundleID: "com.example.New")],
                    minimized: [ax(100, 1, bundleID: "com.example.New")],
                    roles: [ax(100, 1, bundleID: "com.example.New"): "AXWindow"],
                    subroles: [ax(100, 1, bundleID: "com.example.New"): "AXDialog"],
                    modals: [ax(100, 1, bundleID: "com.example.New"): true]
                )
            }
        )

        #expect(snapshots.first?.isAXBacked == false)
        #expect(snapshots.first?.minimized == false)
        #expect(snapshots.first?.role == nil)
        #expect(snapshots.first?.subrole == nil)
        #expect(snapshots.first?.modal == nil)
    }

    @Test func axMetadataNeverCrossesProcessGenerationWithinReusedPID() {
        let raw = [rawWindow(id: 1, pid: 100)]
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in app("com.example.App", pid: pid) },
            windowAXInfoResolver: { owners in
                #expect(owners == [100: owner("com.example.App", pid: 100)])
                let staleIdentity = WindowIdentity(
                    pid: 100,
                    processStartTime: 100_000_001,
                    windowID: 1,
                    bundleID: "com.example.App"
                )
                return WindowEnumerator.WindowAXInfo(
                    axBackedWindowIDs: [staleIdentity],
                    minimized: [staleIdentity],
                    roles: [staleIdentity: "AXWindow"],
                    subroles: [staleIdentity: "AXDialog"],
                    modals: [staleIdentity: true]
                )
            }
        )

        #expect(snapshots.first?.isAXBacked == false)
        #expect(snapshots.first?.minimized == false)
        #expect(snapshots.first?.role == nil)
        #expect(snapshots.first?.subrole == nil)
        #expect(snapshots.first?.modal == nil)
    }

    @Test func rawCGHandlesIncludeRecordsDroppedFromSnapshots() {
        let raw = [
            rawWindow(id: 1, pid: 100, width: 0),
            rawWindow(id: 2, pid: 200),
        ]
        let snapshots = WindowEnumerator.buildSnapshots(
            rawWindowInfo: raw,
            displays: [display],
            appResolver: { pid in pid == 200 ? nil : app("com.example.App", pid: pid) },
            windowAXInfoResolver: { _ in WindowEnumerator.WindowAXInfo(axBackedWindowIDs: []) }
        )
        let handles = WindowEnumerator.rawWindowHandles(rawWindowInfo: raw)

        #expect(snapshots.isEmpty)
        #expect(handles == [
            WindowHandle(pid: 100, processStartTime: nil, windowID: 1),
            WindowHandle(pid: 200, processStartTime: nil, windowID: 2),
        ])
    }

    @Test func focusedWindowResolutionNeverCrossesProcessIdentity() {
        let reusedID = WindowSnapshot(
            windowID: 41,
            bundleID: "com.google.Chrome",
            pid: 200,
            processStartTime: 200_000_000,
            title: "DevTools helper",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            modal: false,
            geometryBlocked: false,
            isAXBacked: true,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 500, height: 500),
            displayID: "uuid-main",
            isFullscreen: false,
            frontIndex: 0
        )
        let frontmost = WindowSnapshot(
            windowID: 42,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 100_000_000,
            title: "Main Chrome",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            modal: false,
            geometryBlocked: false,
            isAXBacked: true,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
            displayID: "uuid-main",
            isFullscreen: false,
            frontIndex: 1
        )

        let resolved = WindowEnumerator.resolveFocusedWindow(
            frontmostPID: 100,
            frontmostProcessStartTime: 100_000_000,
            frontmostBundleID: "com.google.Chrome",
            focusedWindowID: 41,
            windows: [reusedID, frontmost],
            requireExactFocusedWindow: true
        )

        #expect(resolved == nil)
    }

    @Test func focusedWindowResolutionNeverFallsBackToSameBundleSiblingProcess() {
        let sibling = WindowSnapshot(
            windowID: 41,
            bundleID: "com.google.Chrome",
            pid: 200,
            processStartTime: 200_000_000,
            title: "DevTools helper",
            role: "AXWindow",
            subrole: "AXStandardWindow",
            modal: false,
            geometryBlocked: false,
            isAXBacked: true,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 500, height: 500),
            displayID: "uuid-main",
            isFullscreen: false,
            frontIndex: 0
        )

        let resolved = WindowEnumerator.resolveFocusedWindow(
            frontmostPID: 100,
            frontmostProcessStartTime: 100_000_000,
            frontmostBundleID: "com.google.Chrome",
            focusedWindowID: nil,
            windows: [sibling],
            requireExactFocusedWindow: true
        )

        #expect(resolved == nil)
    }
}
