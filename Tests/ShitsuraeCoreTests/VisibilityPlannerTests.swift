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

    @Test func rebindNeverRestoresGeometryFromPreviousExactWindow() throws {
        let layout = TestFixtures.twoSpaceLayout()
        let previousWindow = TestFixtures.window(
            id: 1,
            bundleID: "com.google.Chrome",
            pid: 100,
            processStartTime: 100_000_000,
            frame: ResolvedFrame(x: 40, y: 50, width: 500, height: 300),
            isAXBacked: true
        )
        let replacement = TestFixtures.window(
            id: 2,
            bundleID: "com.google.Chrome",
            pid: 200,
            processStartTime: 200_000_000,
            frame: ResolvedFrame(x: 300, y: 200, width: 800, height: 500),
            isAXBacked: true
        )
        var entry = makeEntry(spaceID: 1, bundleID: "com.google.Chrome")
        entry = entry.bound(to: previousWindow)
        entry.spaceID = 2
        entry.visibilityState = .hiddenOffscreen
        entry.lastVisibleFrame = previousWindow.frame
        entry.lastHiddenFrame = ResolvedFrame(x: -499, y: 50, width: 500, height: 300)
        entry.lastActivatedAt = "2026-07-14T00:00:00Z"

        let plan = try #require(VisibilityPlanner.plan(
            entry: entry,
            window: replacement,
            transition: .show,
            layout: layout,
            hostDisplay: display,
            displays: [display]
        ))

        #expect(plan.mutation == .frame(replacement.frame))
        #expect(plan.desiredEntry.boundIdentity == replacement.identity)
        #expect(plan.desiredEntry.lastVisibleFrame == replacement.frame)
        #expect(plan.desiredEntry.lastHiddenFrame == nil)
        #expect(plan.desiredEntry.lastActivatedAt == nil)
    }

    @Test func portraitWindowUsesHorizontalParkingOutsideDisplayArrangement() {
        let display = DisplayInfo(
            id: "large-main",
            width: 5120,
            height: 1968,
            scale: 1,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1968),
            visibleFrame: CGRect(x: 0, y: 0, width: 5120, height: 1966)
        )
        let frame = ResolvedFrame(x: 1794, y: 153, width: 1660, height: 1791)
        let entry = makeEntry(spaceID: 1, lastVisibleFrame: frame)
        let window = TestFixtures.window(
            id: 1,
            bundleID: "com.openai.codex",
            frame: frame,
            isAXBacked: true
        )

        let hidden = VisibilityPlanner.resolveHiddenFrame(
            entry: entry,
            window: window,
            hostDisplay: display,
            displays: [display]
        )

        #expect(hidden.x == display.frame.minX - frame.width + 1
            || hidden.x == display.frame.maxX - 1)
        #expect(hidden.y >= display.visibleFrame.minY)
        #expect(hidden.y <= display.visibleFrame.maxY - frame.height)
    }

    @Test func hiddenFrameAvoidsBothNeighborsForMiddleDisplay() {
        let left = DisplayInfo(
            id: "left",
            width: 1440,
            height: 900,
            scale: 1,
            isPrimary: true,
            frame: CGRect(x: -1440, y: 120, width: 1440, height: 900),
            visibleFrame: CGRect(x: -1390, y: 120, width: 1390, height: 875)
        )
        let middle = DisplayInfo(
            id: "middle",
            width: 1440,
            height: 900,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875)
        )
        let right = DisplayInfo(
            id: "right",
            width: 1440,
            height: 900,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 1440, y: -80, width: 1440, height: 900),
            visibleFrame: CGRect(x: 1440, y: -80, width: 1390, height: 875)
        )
        let displays = [left, middle, right]
        var entry = makeEntry(
            spaceID: 1,
            lastVisibleFrame: ResolvedFrame(x: 160, y: 100, width: 700, height: 400)
        )
        entry.displayID = middle.id
        let window = TestFixtures.window(
            id: 1,
            bundleID: "com.apple.TextEdit",
            frame: ResolvedFrame(x: 160, y: 100, width: 700, height: 400),
            isAXBacked: true
        )

        let hidden = VisibilityPlanner.resolveHiddenFrame(
            entry: entry,
            window: window,
            hostDisplay: middle,
            displays: displays
        )
        let reversed = VisibilityPlanner.resolveHiddenFrame(
            entry: entry,
            window: window,
            hostDisplay: middle,
            displays: Array(displays.reversed())
        )

        #expect(reversed == hidden)
        #expect(VisibilityPlanner.isHiddenWindowFrame(frame: hidden, displays: displays))
        let hiddenRect = CGRect(
            x: hidden.x,
            y: hidden.y,
            width: hidden.width,
            height: hidden.height
        )
        let overlaps: [CGRect] = displays.compactMap { display in
            let overlap = hiddenRect.intersection(display.frame)
            return overlap.isNull || overlap.isEmpty ? nil : overlap
        }
        #expect(overlaps.allSatisfy { $0.width <= 1 || $0.height <= 1 })
        #expect(overlaps.allSatisfy { $0.width <= 1 })
        #expect(hidden.x == left.frame.minX - window.frame.width + 1
            || hidden.x == right.frame.maxX - 1)

        let leakedIntoLeftNeighbor = ResolvedFrame(
            x: -699,
            y: 100,
            width: 700,
            height: 400
        )
        #expect(!VisibilityPlanner.isHiddenWindowFrame(
            frame: leakedIntoLeftNeighbor,
            displays: displays
        ))
    }

    @Test func horizontalParkingRanksAreaThenTravelThenLeftSide() {
        let left = DisplayInfo(
            id: "left",
            width: 1000,
            height: 1000,
            scale: 1,
            isPrimary: true,
            frame: CGRect(x: -1000, y: 0, width: 1000, height: 1000),
            visibleFrame: CGRect(x: -1000, y: 0, width: 1000, height: 1000)
        )
        let shortRight = DisplayInfo(
            id: "right",
            width: 1000,
            height: 200,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 200)
        )
        let frameNearLeft = ResolvedFrame(x: -900, y: 400, width: 400, height: 400)
        let entryNearLeft = makeEntry(spaceID: 1, lastVisibleFrame: frameNearLeft)
        let windowNearLeft = TestFixtures.window(
            id: 1,
            bundleID: "app",
            frame: frameNearLeft,
            displayID: left.id,
            isAXBacked: true
        )

        let lowerArea = VisibilityPlanner.resolveHiddenFrame(
            entry: entryNearLeft,
            window: windowNearLeft,
            hostDisplay: left,
            displays: [left, shortRight]
        )
        #expect(abs(lowerArea.x - (shortRight.frame.maxX - 1)) <= 0.001)

        let fullRight = DisplayInfo(
            id: "right",
            width: 1000,
            height: 1000,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
        )
        let frameNearRight = ResolvedFrame(x: 500, y: 400, width: 400, height: 400)
        let nearerRight = VisibilityPlanner.resolveHiddenFrame(
            entry: makeEntry(spaceID: 1, lastVisibleFrame: frameNearRight),
            window: TestFixtures.window(
                id: 2,
                bundleID: "app",
                frame: frameNearRight,
                displayID: fullRight.id,
                isAXBacked: true
            ),
            hostDisplay: fullRight,
            displays: [fullRight, left]
        )
        #expect(abs(nearerRight.x - (fullRight.frame.maxX - 1)) <= 0.001)

        let centeredFrame = ResolvedFrame(x: -200, y: 400, width: 400, height: 400)
        let tied = VisibilityPlanner.resolveHiddenFrame(
            entry: makeEntry(spaceID: 1, lastVisibleFrame: centeredFrame),
            window: TestFixtures.window(
                id: 3,
                bundleID: "app",
                frame: centeredFrame,
                displayID: left.id,
                isAXBacked: true
            ),
            hostDisplay: left,
            displays: [fullRight, left]
        )
        #expect(tied.x == left.frame.minX - centeredFrame.width + 1)
    }

    @Test func horizontalParkingKeepsAnchorInLShapedArrangement() {
        let upper = DisplayInfo(
            id: "upper",
            width: 1000,
            height: 1000,
            scale: 1,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 975)
        )
        let lowerLeft = DisplayInfo(
            id: "lower-left",
            width: 1000,
            height: 1000,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: -1000, y: 1000, width: 1000, height: 1000),
            visibleFrame: CGRect(x: -1000, y: 1000, width: 1000, height: 975)
        )
        let lowestRight = DisplayInfo(
            id: "lowest-right",
            width: 1000,
            height: 1000,
            scale: 1,
            isPrimary: false,
            frame: CGRect(x: 1000, y: 2000, width: 1000, height: 1000),
            visibleFrame: CGRect(x: 1000, y: 2000, width: 1000, height: 975)
        )
        let displays = [upper, lowerLeft, lowestRight]
        let frame = ResolvedFrame(x: 100, y: 100, width: 600, height: 400)
        let hidden = VisibilityPlanner.resolveHiddenFrame(
            entry: makeEntry(spaceID: 1, lastVisibleFrame: frame),
            window: TestFixtures.window(
                id: 1,
                bundleID: "app",
                frame: frame,
                displayID: upper.id,
                isAXBacked: true
            ),
            hostDisplay: upper,
            displays: displays
        )
        let hiddenRect = CGRect(x: hidden.x, y: hidden.y, width: hidden.width, height: hidden.height)
        let overlaps = displays.compactMap { display -> CGRect? in
            let overlap = hiddenRect.intersection(display.frame)
            return overlap.isNull || overlap.isEmpty ? nil : overlap
        }

        #expect(!overlaps.isEmpty)
        #expect(overlaps.allSatisfy { $0.width <= 1 })
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

    @Test func convergeRollsBackAndStopsAfterRejectedRetry() {
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
        #expect(outcome.retryCount == 1)
        #expect(control.setPositionAttemptWindowIDs == [1])
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
