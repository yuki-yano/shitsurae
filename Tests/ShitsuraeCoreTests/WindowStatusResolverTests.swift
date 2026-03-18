import XCTest
@testable import ShitsuraeCore

final class WindowStatusResolverTests: XCTestCase {
    func testResolveLiveDropsEntriesWhenTrackedWindowIsGone() {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(
                    windowID: 42,
                    titleMatchKind: .none,
                    titleMatchValue: nil,
                    lastKnownTitle: "Finder - Downloads",
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
                    visibilityState: .visible
                ),
            ]
        )

        let resolved = WindowStatusResolver.resolveLive(
            state: state,
            windows: [],
            displays: [mainDisplay]
        )

        XCTAssertTrue(resolved.slots.isEmpty)
    }

    func testResolveOverlaysLiveFrameAndTitleForTrackedWindow() throws {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(
                    windowID: 42,
                    titleMatchKind: .none,
                    titleMatchValue: nil,
                    lastKnownTitle: "Old Title",
                    lastVisibleFrame: ResolvedFrame(x: 0, y: 0, width: 800, height: 600),
                    visibilityState: .hiddenOffscreen
                ),
            ]
        )

        let resolved = WindowStatusResolver.resolve(
            state: state,
            windows: [
                makeWindow(
                    windowID: 42,
                    title: "Live Title",
                    frame: ResolvedFrame(x: 120, y: 80, width: 1440, height: 900),
                    hidden: false,
                    minimized: false
                ),
            ],
            displays: [mainDisplay]
        )

        let slot = try XCTUnwrap(resolved.slots.first)
        XCTAssertEqual(slot.lastKnownTitle, "Live Title")
        XCTAssertEqual(slot.lastVisibleFrame, ResolvedFrame(x: 120, y: 80, width: 1440, height: 900))
        XCTAssertEqual(slot.visibilityState, .visible)
    }

    func testResolveMarksOffscreenWindowHiddenWithoutOverwritingLastVisibleFrame() throws {
        let visibleFrame = ResolvedFrame(x: 20, y: 30, width: 800, height: 600)
        let hiddenFrame = ResolvedFrame(x: -779, y: 30, width: 800, height: 600)
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(
                    windowID: 42,
                    titleMatchKind: .none,
                    titleMatchValue: nil,
                    lastKnownTitle: "Tracked",
                    lastVisibleFrame: visibleFrame,
                    lastHiddenFrame: hiddenFrame,
                    visibilityState: .visible
                ),
            ]
        )

        let resolved = WindowStatusResolver.resolve(
            state: state,
            windows: [
                makeWindow(
                    windowID: 42,
                    title: "Tracked",
                    frame: hiddenFrame,
                    hidden: false,
                    minimized: false
                ),
            ],
            displays: [mainDisplay]
        )

        let slot = try XCTUnwrap(resolved.slots.first)
        XCTAssertEqual(slot.lastVisibleFrame, visibleFrame)
        XCTAssertEqual(slot.lastHiddenFrame, hiddenFrame)
        XCTAssertEqual(slot.visibilityState, .hiddenOffscreen)
    }

    func testResolveTreatsOnePixelPinnedHiddenFrameAsHidden() throws {
        let visibleFrame = ResolvedFrame(x: 100, y: 40, width: 800, height: 600)
        let hiddenFrame = ResolvedFrame(x: -799, y: 40, width: 800, height: 600)
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(
                    windowID: 42,
                    titleMatchKind: .none,
                    titleMatchValue: nil,
                    lastKnownTitle: "Tracked",
                    lastVisibleFrame: visibleFrame,
                    lastHiddenFrame: nil,
                    visibilityState: .hiddenOffscreen
                ),
            ]
        )

        let resolved = WindowStatusResolver.resolve(
            state: state,
            windows: [
                makeWindow(
                    windowID: 42,
                    title: "Tracked",
                    frame: hiddenFrame,
                    hidden: false,
                    minimized: false
                ),
            ],
            displays: [mainDisplay]
        )

        let slot = try XCTUnwrap(resolved.slots.first)
        XCTAssertEqual(slot.lastVisibleFrame, visibleFrame)
        XCTAssertEqual(slot.lastHiddenFrame, hiddenFrame)
        XCTAssertEqual(slot.visibilityState, .hiddenOffscreen)
    }

    func testResolveFallsBackToPersistedMatcherWhenTrackedWindowIDChanged() throws {
        let state = RuntimeState(
            updatedAt: "2026-03-16T00:00:00Z",
            slots: [
                makeSlot(
                    windowID: 42,
                    titleMatchKind: .contains,
                    titleMatchValue: "Notes",
                    lastKnownTitle: "Old Notes",
                    lastVisibleFrame: nil,
                    visibilityState: nil
                ),
            ]
        )

        let resolved = WindowStatusResolver.resolve(
            state: state,
            windows: [
                makeWindow(
                    windowID: 77,
                    title: "Notes - Daily",
                    frame: ResolvedFrame(x: 300, y: 140, width: 1000, height: 700),
                    hidden: false,
                    minimized: false
                ),
            ],
            displays: [mainDisplay]
        )

        let slot = try XCTUnwrap(resolved.slots.first)
        XCTAssertEqual(slot.windowID, 77)
        XCTAssertEqual(slot.lastKnownTitle, "Notes - Daily")
        XCTAssertEqual(slot.visibilityState, .visible)
    }

    private func makeSlot(
        windowID: UInt32?,
        titleMatchKind: PersistedTitleMatchKind,
        titleMatchValue: String?,
        lastKnownTitle: String?,
        lastVisibleFrame: ResolvedFrame?,
        lastHiddenFrame: ResolvedFrame? = nil,
        visibilityState: VirtualWindowVisibilityState?
    ) -> SlotEntry {
        SlotEntry(
            layoutName: "layout",
            slot: 1,
            source: .window,
            bundleID: "com.example.app",
            definitionFingerprint: "fingerprint",
            pid: nil,
            titleMatchKind: titleMatchKind,
            titleMatchValue: titleMatchValue,
            excludeTitleRegex: nil,
            role: "AXWindow",
            subrole: nil,
            matchIndex: nil,
            lastKnownTitle: lastKnownTitle,
            profile: nil,
            spaceID: 3,
            nativeSpaceID: 9,
            displayID: "display-1",
            windowID: windowID,
            lastVisibleFrame: lastVisibleFrame,
            lastHiddenFrame: lastHiddenFrame,
            visibilityState: visibilityState,
            lastActivatedAt: nil
        )
    }

    private func makeWindow(
        windowID: UInt32,
        title: String,
        frame: ResolvedFrame,
        hidden: Bool,
        minimized: Bool
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: "com.example.app",
            pid: 999,
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: minimized,
            hidden: hidden,
            frame: frame,
            spaceID: 9,
            displayID: "display-1",
            isFullscreen: false,
            frontIndex: 0
        )
    }

    private var mainDisplay: DisplayInfo {
        DisplayInfo(
            id: "display-1",
            width: 1440,
            height: 900,
            scale: 2,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
    }
}
