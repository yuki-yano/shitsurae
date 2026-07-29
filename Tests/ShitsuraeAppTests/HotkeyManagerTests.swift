import AppKit
import Carbon.HIToolbox
import Testing
@testable import Shitsurae

@Suite("FocusEventCoordinator")
@MainActor
struct FocusEventCoordinatorTests {
    @Test func latestSourceSequenceWinsAcrossOutOfOrderDelivery() {
        let coordinator = FocusEventCoordinator()
        #expect(coordinator.accept(2))
        #expect(!coordinator.accept(1))
        #expect(coordinator.isCurrent(2))
    }

    @Test func interactiveInvalidationMakesPendingEventStale() {
        let coordinator = FocusEventCoordinator()
        #expect(coordinator.accept(1))
        coordinator.invalidate(with: 2)
        #expect(!coordinator.isCurrent(1))
        #expect(coordinator.isCurrent(2))
    }

    @Test func sharedGateInvalidatesContinuationBeforeActorScheduling() {
        let gate = FocusEventGate()
        let coordinator = FocusEventCoordinator(gate: gate)
        #expect(coordinator.accept(1))

        // Models synchronous user-action invalidation while the engine actor's
        // older conditional switch is still queued.
        gate.invalidate(with: 2)

        #expect(!coordinator.isCurrent(1))
        #expect(!gate.isCurrent(1))
    }

    @Test func backgroundWindowEventDoesNotSupersedeFrontmostActivationRetry() {
        let coordinator = FocusEventCoordinator()
        #expect(coordinator.accept(1))

        #expect(!coordinator.acceptWindowEvent(2, isCurrentFrontmost: false))
        #expect(coordinator.isCurrent(1))
        #expect(coordinator.latestSequence == 1)

        #expect(coordinator.acceptWindowEvent(3, isCurrentFrontmost: true))
        #expect(coordinator.isCurrent(3))
    }

    @Test func thumbnailCacheKeyIncludesProcessGeneration() {
        let old = WindowIdentity(
            pid: 100,
            processStartTime: 1,
            windowID: 20,
            bundleID: "com.google.Chrome"
        )
        let replacement = WindowIdentity(
            pid: 100,
            processStartTime: 2,
            windowID: 20,
            bundleID: "com.google.Chrome"
        )

        #expect(WindowThumbnailProvider.cacheKey(for: old) != WindowThumbnailProvider.cacheKey(for: replacement))
    }

    @Test func thumbnailCacheIsOnlyASubsecondPlaceholder() {
        let identity = WindowIdentity(
            pid: 100,
            processStartTime: 1,
            windowID: 20,
            bundleID: "com.example.Editor"
        )
        var now = Date(timeIntervalSince1970: 100)
        let provider = WindowThumbnailProvider(
            placeholderTTL: 1,
            now: { now },
            processStartTime: { _ in 1 }
        )
        let image = NSImage(size: NSSize(width: 10, height: 10))
        provider.storeForTesting(image, identity: identity, capturedAt: now)

        #expect(provider.placeholder(identity: identity) === image)

        now.addTimeInterval(1.001)
        #expect(provider.placeholder(identity: identity) == nil)
    }

    @Test func thumbnailCacheRejectsReusedProcessGeneration() {
        let identity = WindowIdentity(
            pid: 100,
            processStartTime: 1,
            windowID: 20,
            bundleID: "com.example.Editor"
        )
        let now = Date(timeIntervalSince1970: 100)
        let provider = WindowThumbnailProvider(
            now: { now },
            processStartTime: { _ in 2 }
        )
        provider.storeForTesting(
            NSImage(size: NSSize(width: 10, height: 10)),
            identity: identity,
            capturedAt: now
        )

        #expect(provider.placeholder(identity: identity) == nil)
    }

    @Test func thumbnailSessionLoadsShareableContentOnlyOnce() async {
        var loadCount = 0
        let provider = WindowThumbnailProvider(processStartTime: { _ in 1 })
        let session = provider.beginSession {
            loadCount += 1
            return nil
        }

        _ = await session.captureFresh(
            identity: WindowIdentity(
                pid: 100,
                processStartTime: 1,
                windowID: 20,
                bundleID: "com.example.Editor"
            )
        )
        _ = await session.captureFresh(
            identity: WindowIdentity(
                pid: 100,
                processStartTime: 1,
                windowID: 21,
                bundleID: "com.example.Editor"
            )
        )

        #expect(loadCount == 1)
    }

    @Test func frontmostTerminationIsRecognizedBeforeReplacementActivation() {
        let terminated = RunningApplicationIdentity(
            pid: 100,
            bundleID: "com.example.Terminated",
            launchDate: Date(timeIntervalSince1970: 1)
        )
        var tracker = FrontmostApplicationTracker()
        tracker.reset(to: terminated)

        let consumed = tracker.consumeFrontmostTermination(
            terminated,
            now: Date(timeIntervalSince1970: 2)
        )
        #expect(consumed)
    }

    @Test func frontmostTerminationIsRecognizedAfterReplacementActivation() {
        let terminated = RunningApplicationIdentity(
            pid: 100,
            bundleID: "com.example.Terminated",
            launchDate: Date(timeIntervalSince1970: 1)
        )
        let replacement = RunningApplicationIdentity(
            pid: 200,
            bundleID: "com.example.Replacement",
            launchDate: Date(timeIntervalSince1970: 2)
        )
        let activatedAt = Date(timeIntervalSince1970: 10)
        var tracker = FrontmostApplicationTracker(terminationCoalescingWindow: 0.5)
        tracker.reset(to: terminated)
        tracker.recordActivation(replacement, now: activatedAt)

        let consumed = tracker.consumeFrontmostTermination(
            terminated,
            now: activatedAt.addingTimeInterval(0.1)
        )
        #expect(consumed)
        #expect(tracker.current == replacement)
    }

    @Test func backgroundTerminationOutsideCoalescingWindowIsIgnored() {
        let background = RunningApplicationIdentity(
            pid: 100,
            bundleID: "com.example.Background",
            launchDate: Date(timeIntervalSince1970: 1)
        )
        let frontmost = RunningApplicationIdentity(
            pid: 200,
            bundleID: "com.example.Frontmost",
            launchDate: Date(timeIntervalSince1970: 2)
        )
        let activatedAt = Date(timeIntervalSince1970: 10)
        var tracker = FrontmostApplicationTracker(terminationCoalescingWindow: 0.5)
        tracker.reset(to: background)
        tracker.recordActivation(frontmost, now: activatedAt)

        let consumed = tracker.consumeFrontmostTermination(
            background,
            now: activatedAt.addingTimeInterval(0.6)
        )
        #expect(!consumed)
    }
}
import ShitsuraeCore

@Suite("HotkeyManager")
struct HotkeyManagerTests {
    @Test func resolvesSwitcherDisplayFromCapturedCursorLocation() {
        let primary = DisplayInfo(
            id: "primary",
            width: 2_000,
            height: 1_200,
            scale: 2,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 600),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 575)
        )
        let secondary = DisplayInfo(
            id: "secondary",
            width: 1_600,
            height: 1_200,
            scale: 2,
            isPrimary: false,
            frame: CGRect(x: -800, y: 100, width: 800, height: 600),
            visibleFrame: CGRect(x: -800, y: 100, width: 800, height: 575)
        )

        #expect(HotkeyManager.targetDisplayID(
            cursorLocation: CGPoint(x: 400, y: 300),
            displays: [primary, secondary]
        ) == "primary")
        #expect(HotkeyManager.targetDisplayID(
            cursorLocation: CGPoint(x: -400, y: 300),
            displays: [primary, secondary]
        ) == "secondary")
        #expect(HotkeyManager.targetDisplayID(
            cursorLocation: CGPoint(x: 2_000, y: 2_000),
            displays: [primary, secondary]
        ) == nil)
    }

    @Test func cycleOverlayRepeatUsesConfiguredNextAndPrevDirections() {
        let shortcuts = ResolvedShortcuts(from: nil)

        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_J), shortcuts: shortcuts) == true)
        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_K), shortcuts: shortcuts) == false)
        #expect(HotkeyManager.cycleOverlayAdvanceForward(forKeyCode: Int(kVK_ANSI_L), shortcuts: shortcuts) == nil)
    }

    @Test func interactiveEngineActionsUseLatencyCriticalHighPriorityScheduling() {
        #expect(EngineActionUrgency.interactive.taskPriority == .high)
        #expect(EngineActionUrgency.interactive.activityOptions == [.userInitiated, .latencyCritical])
    }

    @Test func normalEngineActionsDoNotRequestLatencyCriticalScheduling() {
        #expect(EngineActionUrgency.normal.taskPriority == nil)
        #expect(EngineActionUrgency.normal.activityOptions == nil)
    }

    @Test func fastPathRecognizesVirtualSpaceSwitchShortcut() {
        let shortcuts = ResolvedShortcuts(from: nil)
        let location = CGPoint(x: 40, y: 80)

        let action = HotkeyFastPathAction.match(
            eventKeyCode: Int(kVK_ANSI_2),
            modifiers: ["ctrl"],
            cursorLocation: location,
            shortcuts: shortcuts,
            frontmostBundleID: "com.apple.Terminal",
            frontmostBelongsToActiveWorkspace: true
        )
        guard case let .switchSpace(candidates, cursorLocation) = action else {
            Issue.record("expected switchSpace")
            return
        }
        #expect(candidates.map(\.spaceID) == [2])
        #expect(cursorLocation == location)
    }

    @Test func fastPathRespectsDisabledShortcutPolicy() {
        let shortcuts = ResolvedShortcuts(
            from: ShortcutsDefinition(
                focusBySlot: nil,
                moveCurrentWindowToSpace: nil,
                switchVirtualSpace: nil,
                nextWindow: nil,
                prevWindow: nil,
                cycle: nil,
                switcher: nil,
                globalActions: nil,
                disabledInApps: ["com.apple.Terminal": ["switchVirtualSpace:primary:2"]],
                focusBySlotEnabledInApps: nil
            )
        )

        #expect(
            HotkeyFastPathAction.match(
                eventKeyCode: Int(kVK_ANSI_2),
                modifiers: ["ctrl"],
                cursorLocation: .zero,
                shortcuts: shortcuts,
                frontmostBundleID: "com.apple.Terminal",
                frontmostBelongsToActiveWorkspace: true
            ) == nil
        )
    }

    @Test func fastPathLeavesNonWorkspaceShortcutsOnMainPath() {
        let shortcuts = ResolvedShortcuts(from: nil)

        #expect(
            HotkeyFastPathAction.match(
                eventKeyCode: Int(kVK_ANSI_2),
                modifiers: ["cmd"],
                cursorLocation: .zero,
                shortcuts: shortcuts,
                frontmostBundleID: "com.apple.Terminal",
                frontmostBelongsToActiveWorkspace: true
            ) == nil
        )
    }

    @Test func fastPathPreparationInvalidatesFocusBeforePublishingStart() {
        var calls: [String] = []

        HotkeyFastPathPreparation.perform(
            invalidateFocusEvents: { calls.append("invalidate") },
            onStart: { calls.append("start") }
        )

        #expect(calls == ["invalidate", "start"])
    }

    @Test func fastPathCompletionClassifiesNonconvergedSwitchAsPartial() {
        #expect(
            SpaceSwitchCompletion.incompleteMessage(converged: true, unresolvedSlotCount: 0) == nil
        )
        #expect(
            SpaceSwitchCompletion.incompleteMessage(converged: false, unresolvedSlotCount: 0)
                == "space switch did not converge"
        )
        #expect(
            SpaceSwitchCompletion.incompleteMessage(converged: false, unresolvedSlotCount: 2)
                == "space switch incomplete: 2 unresolved slots"
        )
    }

    @Test func inactiveOverlayFlagsChangedBypassesMainActorFallback() {
        #expect(
            !HotkeyEventRouting.shouldUseMainFallback(
                eventType: .flagsChanged,
                overlaySessionActive: false
            )
        )
        #expect(
            HotkeyEventRouting.shouldUseMainFallback(
                eventType: .flagsChanged,
                overlaySessionActive: true
            )
        )
        #expect(
            HotkeyEventRouting.shouldUseMainFallback(
                eventType: .keyDown,
                overlaySessionActive: false
            )
        )
    }

    @Test func eventSnapshotCapturesKeyboardEventLocation() throws {
        let event = try #require(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(kVK_ANSI_2),
                keyDown: true
            )
        )
        event.location = CGPoint(x: 1440, y: 900)

        let snapshot = HotkeyEventSnapshot(type: .keyDown, event: event)

        #expect(snapshot.location == CGPoint(x: 1440, y: 900))
    }
}
