import CoreGraphics
import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("VisibilityPlanner")
struct VisibilityPlannerTests {
    private let display = TestFixtures.display

    private func makeEntry(
        spaceID: Int,
        slot: Int = 1,
        bundleID: String = "com.apple.TextEdit",
        visibilityState: VisibilityState = .visible,
        lastVisibleFrame: ResolvedFrame? = nil
    ) -> SlotEntry {
        SlotEntry(
            layoutName: "work",
            spaceID: spaceID,
            slot: slot,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: spaceID,
            bundleID: bundleID,
            lastVisibleFrame: lastVisibleFrame,
            visibilityState: visibilityState
        )
    }

    @Test func cgOnlySurfaceNeverProducesVisibilityPlan() {
        let layout = TestFixtures.twoSpaceLayout()
        let entry = makeEntry(spaceID: 1)
        let surface = TestFixtures.window(
            id: 99,
            bundleID: "com.google.Chrome",
            isAXBacked: false
        )

        let show = VisibilityPlanner.plan(
            entry: entry,
            window: surface,
            transition: .show,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )
        let hide = VisibilityPlanner.plan(
            entry: entry,
            window: surface,
            transition: .hide,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(show == nil)
        #expect(hide == nil)
    }

    @Test func showPlanUsesLayoutFrame() {
        let layout = TestFixtures.twoSpaceLayout()
        let entry = makeEntry(spaceID: 1)
        let window = TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true)

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: window,
            transition: .show,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        guard case let .frame(frame)? = plan?.mutation else {
            Issue.record("expected frame mutation")
            return
        }
        // 50% width of the 1440pt visible frame.
        #expect(abs(frame.width - 720) <= 1)
        #expect(plan?.desiredEntry.visibilityState == .visible)
    }

    // バグ2-b 回帰: 最小化ウィンドウの show プランはアンミニマイズを含む
    @Test func showPlanRestoresMinimizedWindow() {
        let layout = TestFixtures.twoSpaceLayout()
        let entry = makeEntry(spaceID: 1)
        let window = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            isAXBacked: true,
            minimized: true
        )

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: window,
            transition: .show,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(plan?.restoreFromMinimized == true)
    }

    @Test func hidePlanParksWindowOnePixelOutside() {
        let layout = TestFixtures.twoSpaceLayout()
        let entry = makeEntry(spaceID: 1)
        let window = TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true)

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: window,
            transition: .hide,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        guard case let .position(position)? = plan?.mutation else {
            Issue.record("expected position mutation")
            return
        }

        let hiddenFrame = ResolvedFrame(
            x: position.x,
            y: position.y,
            width: window.frame.width,
            height: window.frame.height
        )
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: hiddenFrame, displays: [display]))
        #expect(plan?.desiredEntry.visibilityState == .hiddenOffscreen)
        // The pre-hide frame is remembered for restoration.
        #expect(plan?.desiredEntry.lastVisibleFrame == window.frame)
    }

    @Test func hidePlanSkipsMinimizedButStillPlansFullscreenWindow() {
        let layout = TestFixtures.twoSpaceLayout()
        let previousWindowedFrame = ResolvedFrame(x: 80, y: 90, width: 900, height: 600)
        let entry = makeEntry(spaceID: 1, lastVisibleFrame: previousWindowedFrame)
        let minimized = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            isAXBacked: true,
            minimized: true
        )

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: minimized,
            transition: .hide,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(plan?.mutation == VisibilityMutation.none)
        #expect(plan?.action == "unchanged")

        let fullscreen = TestFixtures.window(
            id: 2,
            bundleID: "com.apple.TextEdit",
            isAXBacked: true,
            isFullscreen: true
        )
        let fullscreenPlan = VisibilityPlanner.plan(
            entry: entry,
            window: fullscreen,
            transition: .hide,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )
        if case .position = fullscreenPlan?.mutation {
            // expected
        } else {
            Issue.record("fullscreen hide must attempt a physical mutation")
        }
        #expect(fullscreenPlan?.desiredEntry.lastVisibleFrame == previousWindowedFrame)
        #expect(fullscreenPlan?.desiredEntry.lastVisibleFrame != fullscreen.frame)
    }

    @Test func fullscreenShowWithoutWindowedGeometryDoesNotStoreDisplayFrame() {
        let layout = TestFixtures.twoSpaceLayout()
        var entry = makeEntry(
            spaceID: 1,
            visibilityState: .hiddenOffscreen,
            lastVisibleFrame: nil
        )
        entry.origin = .adopted
        entry.layoutSpaceID = nil
        let fullscreen = TestFixtures.window(
            id: 2,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: 0, y: 0, width: 1440, height: 900),
            isAXBacked: true,
            isFullscreen: true
        )

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: fullscreen,
            transition: .show,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(plan == nil)
        #expect(entry.lastVisibleFrame == nil)
    }

    @Test func rehidePreservesOriginalVisibleFrame() {
        let layout = TestFixtures.twoSpaceLayout()
        let originalFrame = ResolvedFrame(x: 100, y: 100, width: 600, height: 400)
        let entry = makeEntry(
            spaceID: 1,
            visibilityState: .hiddenOffscreen,
            lastVisibleFrame: originalFrame
        )
        // Window currently parked offscreen.
        let parked = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: -699, y: 100, width: 700, height: 400),
            isAXBacked: true
        )

        let plan = VisibilityPlanner.plan(
            entry: entry,
            window: parked,
            transition: .hide,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        // Already hidden: the parking spot must not overwrite the real frame.
        #expect(plan?.desiredEntry.lastVisibleFrame == originalFrame)
    }

    @Test func movedEntryFallsBackToLastVisibleFrame() {
        let layout = TestFixtures.twoSpaceLayout()
        // Entry moved off its layout space (1 → 2): layout frame no longer
        // applies; lastVisibleFrame wins.
        var entry = makeEntry(spaceID: 1, lastVisibleFrame: ResolvedFrame(x: 50, y: 60, width: 500, height: 300))
        entry.spaceID = 2

        let window = TestFixtures.window(id: 1, bundleID: "com.apple.TextEdit", isAXBacked: true)
        let frame = VisibilityPlanner.resolveVisibleFrame(
            entry: entry,
            window: window,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(frame == ResolvedFrame(x: 50, y: 60, width: 500, height: 300))
    }

    @Test func offscreenSourceFrameIsClampedIntoDisplay() {
        let layout = TestFixtures.twoSpaceLayout()
        var entry = makeEntry(spaceID: 1, lastVisibleFrame: ResolvedFrame(x: -5000, y: -5000, width: 700, height: 400))
        entry.spaceID = 2 // off layout space → fallback chain
        let window = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: -5000, y: -5000, width: 700, height: 400),
            isAXBacked: true
        )

        let frame = VisibilityPlanner.resolveVisibleFrame(
            entry: entry,
            window: window,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        )

        #expect(frame != nil)
        if let frame {
            #expect(!VisibilityPlanner.isHiddenWindowFrame(frame: frame, displays: [display]))
            #expect(frame.x >= 0)
            #expect(frame.y >= 0)
        }
    }

    @Test func hideCornerAvoidsAdjacentDisplay() {
        // Secondary display to the LEFT of main: hiding bottom-left would
        // bleed into it, so the corner must be bottom-right.
        let leftDisplay = DisplayInfo(
            id: "uuid-left",
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        )
        let corner = VisibilityPlanner.optimalHideCorner(
            for: TestFixtures.display,
            displays: [TestFixtures.display, leftDisplay]
        )
        #expect(corner == .bottomRight)

        // Mirror case: display to the right → hide bottom-left.
        let rightDisplay = DisplayInfo(
            id: "uuid-right",
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        )
        let mirrored = VisibilityPlanner.optimalHideCorner(
            for: TestFixtures.display,
            displays: [TestFixtures.display, rightDisplay]
        )
        #expect(mirrored == .bottomLeft)
    }
}

@Suite("VisibilityApplier")
struct VisibilityApplierTests {
    @Test func fullscreenWindowMustReachHiddenPositionToConverge() {
        let window = TestFixtures.window(
            id: 1,
            bundleID: "app",
            frame: ResolvedFrame(x: 0, y: 0, width: 1440, height: 900),
            isAXBacked: true,
            isFullscreen: true
        )
        var desired = SlotEntry(
            layoutName: "work",
            spaceID: 2,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: 2,
            bundleID: "app",
            visibilityState: .hiddenOffscreen
        )
        desired.lastHiddenFrame = ResolvedFrame(x: -1439, y: 0, width: 1440, height: 900)
        let change = AppliedVisibilityChange(
            window: window,
            originalEntry: desired,
            effectiveEntry: desired,
            desiredEntry: desired,
            restoredFromMinimized: false
        )

        #expect(!VisibilityApplier.matchesDesiredState(change: change, windows: [window]))
        #expect(VisibilityApplier.matchesDesiredState(
            change: change,
            windows: [window.withFrame(desired.lastHiddenFrame!)]
        ))
    }

    @Test func convergeRollsBackUnconvergedChanges() {
        let window = TestFixtures.window(id: 1, bundleID: "app", isAXBacked: true)
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])
        control.failPositionWindowIDs = [1]

        var desired = SlotEntry(
            layoutName: "work",
            spaceID: 2,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: 2,
            bundleID: "app"
        )
        desired.lastHiddenFrame = ResolvedFrame(x: -699, y: 10, width: 700, height: 400)
        desired.visibilityState = .hiddenOffscreen
        var original = desired
        original.visibilityState = .visible
        original.lastHiddenFrame = nil

        let change = AppliedVisibilityChange(
            window: window,
            originalEntry: original,
            effectiveEntry: original,
            desiredEntry: desired,
            restoredFromMinimized: false
        )

        let outcome = VisibilityApplier.converge(
            changes: [change],
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1, 1]
        )

        #expect(outcome.hasPending)
        #expect(outcome.changes.first?.effectiveEntry.visibilityState == .visible)
        #expect(outcome.desiredUnresolvedWindowIdentities == [window.identity])
        #expect(outcome.retryCount == 2)
    }

    @Test func convergeAcceptsSuccessfulMutations() {
        let window = TestFixtures.window(id: 1, bundleID: "app", isAXBacked: true)
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])

        var desired = SlotEntry(
            layoutName: "work",
            spaceID: 2,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: 2,
            bundleID: "app",
            windowID: 1
        )
        desired.lastHiddenFrame = ResolvedFrame(x: -699, y: 10, width: 700, height: 400)
        desired.visibilityState = .hiddenOffscreen

        // Apply moved the window already.
        _ = control.setWindowPosition(
            windowID: 1,
            pid: window.pid,
            processStartTime: window.processStartTime,
            bundleID: "app",
            position: CGPoint(x: -699, y: 10)
        )

        let change = AppliedVisibilityChange(
            window: window,
            originalEntry: desired,
            effectiveEntry: desired,
            desiredEntry: desired,
            restoredFromMinimized: false
        )

        let outcome = VisibilityApplier.converge(
            changes: [change],
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1]
        )

        #expect(!outcome.hasPending)
        #expect(outcome.retryCount == 0)
        #expect(outcome.verifyCount == 1)
    }

    @Test func unavailableInventoryDoesNotRollbackOrRetrySuccessfulMutation() {
        let window = TestFixtures.window(id: 1, bundleID: "app", isAXBacked: true)
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])
        var original = SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: 1,
            bundleID: "app",
            visibilityState: .visible
        )
        original.lastVisibleFrame = window.frame
        var desired = original
        desired.visibilityState = .hiddenOffscreen
        desired.lastHiddenFrame = ResolvedFrame(x: -699, y: 10, width: window.frame.width, height: window.frame.height)
        let change = AppliedVisibilityChange(
            window: window,
            originalEntry: original,
            effectiveEntry: desired,
            desiredEntry: desired,
            restoredFromMinimized: false
        )
        control.windowInventoryAvailable = false
        let attemptsBefore = control.frameMutationAttemptWindowIDs.count

        let outcome = VisibilityApplier.converge(
            changes: [change],
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: [1, 1]
        )

        #expect(outcome.hasPending)
        #expect(outcome.changes.first?.effectiveEntry == desired)
        #expect(outcome.retryCount == 0)
        #expect(outcome.verifyCount == 3)
        #expect(outcome.unverifiedWindowIdentities == [window.identity])
        #expect(control.frameMutationAttemptWindowIDs.count == attemptsBefore)
    }

    @Test func rawLiveHandlePreventsSnapshotAssemblyGapFromRollingBackMutation() {
        let window = TestFixtures.window(id: 1, bundleID: "app", isAXBacked: true)
        let control = MockWindowControl(windows: [window], displays: [TestFixtures.display])
        var original = SlotEntry(
            layoutName: "work",
            spaceID: 1,
            slot: 1,
            origin: .layout,
            definitionFingerprint: "fp",
            layoutSpaceID: 1,
            bundleID: "app",
            visibilityState: .visible
        )
        original.lastVisibleFrame = window.frame
        var desired = original
        desired.visibilityState = .hiddenOffscreen
        desired.lastHiddenFrame = ResolvedFrame(x: -699, y: 10, width: window.frame.width, height: window.frame.height)
        let change = AppliedVisibilityChange(
            window: window,
            originalEntry: original,
            effectiveEntry: desired,
            desiredEntry: desired,
            restoredFromMinimized: false
        )
        control.removeWindow(window.windowID)
        control.liveWindowHandlesOverride = [window.handle]

        let outcome = VisibilityApplier.converge(
            changes: [change],
            control: control,
            logger: TestFixtures.nullLogger(),
            retryDelaysMS: []
        )

        #expect(outcome.hasPending)
        #expect(outcome.changes.first?.effectiveEntry == desired)
        #expect(outcome.unverifiedWindowIdentities == [window.identity])
        #expect(outcome.unconvergedWindowIdentities.isEmpty)
    }
}
