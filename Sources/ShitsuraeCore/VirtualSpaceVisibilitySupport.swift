import CoreGraphics
import Foundation

private func virtualSwitchNowMS() -> Int {
    Int(ProcessInfo.processInfo.systemUptime * 1000)
}

enum VirtualVisibilityTransition {
    case show
    case hide
}

enum VirtualVisibilityMutation {
    case none
    case frame(ResolvedFrame)
    case position(CGPoint)
}

struct VirtualVisibilityPlan {
    let updatedEntry: SlotEntry
    let mutation: VirtualVisibilityMutation
    let restoreFromMinimized: Bool
    let action: String
}

func slotEntry(
    _ entry: SlotEntry,
    window: WindowSnapshot?,
    lastVisibleFrame: ResolvedFrame?,
    lastHiddenFrame: ResolvedFrame?,
    visibilityState: VirtualWindowVisibilityState?,
    lastActivatedAt: String?
) -> SlotEntry {
    SlotEntry(
        layoutName: entry.layoutName,
        slot: entry.slot,
        layoutOriginSpaceID: entry.layoutOriginSpaceID,
        layoutOriginSlot: entry.layoutOriginSlot,
        source: entry.source,
        bundleID: entry.bundleID,
        definitionFingerprint: entry.definitionFingerprint,
        pid: window?.pid ?? entry.pid,
        titleMatchKind: entry.titleMatchKind,
        titleMatchValue: entry.titleMatchValue,
        excludeTitleRegex: entry.excludeTitleRegex,
        role: entry.role,
        subrole: entry.subrole,
        matchIndex: entry.matchIndex,
        lastKnownTitle: window?.title ?? entry.lastKnownTitle,
        profile: entry.profile,
        spaceID: entry.spaceID,
        nativeSpaceID: window?.spaceID ?? entry.nativeSpaceID,
        displayID: window?.displayID ?? entry.displayID,
        windowID: window?.windowID ?? entry.windowID,
        lastVisibleFrame: lastVisibleFrame,
        lastHiddenFrame: lastHiddenFrame,
        visibilityState: visibilityState,
        lastActivatedAt: lastActivatedAt
    )
}

func planVirtualVisibility(
    entry: SlotEntry,
    window: WindowSnapshot,
    transition: VirtualVisibilityTransition,
    layout: LayoutDefinition,
    hostDisplay: DisplayInfo,
    displays: [DisplayInfo]
) -> VirtualVisibilityPlan? {
    switch transition {
    case .show:
        guard let visibleFrame = resolveVirtualVisibleFrame(
            entry: entry,
            window: window,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        ) else {
            return nil
        }
        return VirtualVisibilityPlan(
            updatedEntry: slotEntry(
                entry,
                window: window,
                lastVisibleFrame: visibleFrame,
                lastHiddenFrame: entry.lastHiddenFrame,
                visibilityState: .visible,
                lastActivatedAt: entry.lastActivatedAt
            ),
            mutation: .frame(visibleFrame),
            restoreFromMinimized: false,
            action: "shown"
        )
    case .hide:
        guard !window.minimized, !window.isFullscreen else {
            return VirtualVisibilityPlan(
                updatedEntry: entry,
                mutation: .none,
                restoreFromMinimized: false,
                action: "unchanged"
            )
        }
        let hiddenFrame = resolveVirtualHiddenFrame(
            entry: entry,
            window: window,
            hostDisplay: hostDisplay,
            displays: displays
        )
        let preservedVisibleFrame: ResolvedFrame?
        if entry.visibilityState == .hiddenOffscreen {
            preservedVisibleFrame = entry.lastVisibleFrame
        } else {
            preservedVisibleFrame = window.frame
        }
        return VirtualVisibilityPlan(
            updatedEntry: slotEntry(
                entry,
                window: window,
                lastVisibleFrame: preservedVisibleFrame,
                lastHiddenFrame: hiddenFrame,
                visibilityState: .hiddenOffscreen,
                lastActivatedAt: entry.lastActivatedAt
            ),
            mutation: .position(CGPoint(x: hiddenFrame.x, y: hiddenFrame.y)),
            restoreFromMinimized: false,
            action: "hiddenOffscreen"
        )
    }
}

func applyVirtualVisibilityPlan(
    window: WindowSnapshot,
    plan: VirtualVisibilityPlan,
    hooks: CommandServiceRuntimeHooks,
    logger: ShitsuraeLogger
) -> Bool {
    if plan.restoreFromMinimized,
       !hooks.setWindowMinimized(window.windowID, window.bundleID, false).isSuccess
    {
        logger.log(
            level: "warn",
            event: "virtual.visibility.apply.skipped",
            fields: [
                "windowID": Int(window.windowID),
                "bundleID": window.bundleID,
                "action": plan.action,
                "reason": "restoreFromMinimizedFailed",
            ]
        )
    }

    switch plan.mutation {
    case .none:
        break
    case let .frame(frame):
        let frameTolerance = 2.0
        if abs(window.frame.x - frame.x) <= frameTolerance,
           abs(window.frame.y - frame.y) <= frameTolerance,
           abs(window.frame.width - frame.width) <= frameTolerance,
           abs(window.frame.height - frame.height) <= frameTolerance
        {
            break
        }
        guard hooks.setWindowFrame(window.windowID, window.bundleID, frame) else {
            logger.log(
                level: "error",
                event: "virtual.visibility.apply.failed",
                fields: [
                    "windowID": Int(window.windowID),
                    "bundleID": window.bundleID,
                    "action": plan.action,
                    "reason": "setWindowFrameFailed",
                    "frame": [
                        "x": frame.x,
                        "y": frame.y,
                        "width": frame.width,
                        "height": frame.height,
                    ],
                ]
            )
            return false
        }
    case let .position(position):
        let posTolerance: CGFloat = 2.0
        if abs(window.frame.x - position.x) <= posTolerance,
           abs(window.frame.y - position.y) <= posTolerance
        {
            break
        }
        guard hooks.setWindowPosition(window.windowID, window.bundleID, position) else {
            logger.log(
                level: "error",
                event: "virtual.visibility.apply.failed",
                fields: [
                    "windowID": Int(window.windowID),
                    "bundleID": window.bundleID,
                    "action": plan.action,
                    "reason": "setWindowPositionFailed",
                    "position": [
                        "x": position.x,
                        "y": position.y,
                    ],
                ]
            )
            return false
        }
    }

    return true
}

func resolveVirtualVisibleFrame(
    entry: SlotEntry,
    window: WindowSnapshot,
    layout: LayoutDefinition,
    hostDisplay: DisplayInfo,
    displays: [DisplayInfo]
) -> ResolvedFrame? {
    if let layoutFrame = resolvedVirtualLayoutFrame(
        entry: entry,
        layout: layout,
        hostDisplay: hostDisplay,
        displays: displays
    ) {
        return layoutFrame
    }

    if shouldUseVirtualVisibleFrameFallback(entry: entry) {
        if let frame = entry.lastVisibleFrame,
           isWithinVisibleArea(frame: frame, hostDisplay: hostDisplay, displays: displays)
        {
            return frame
        }

        if isWithinVisibleArea(frame: window.frame, hostDisplay: hostDisplay, displays: displays) {
            return window.frame
        }
    }

    return nil
}

func shouldUseVirtualVisibleFrameFallback(entry: SlotEntry) -> Bool {
    if entry.slot >= CommandService.untrackedSlotOffset {
        return true
    }

    guard let layoutOriginSpaceID = entry.layoutOriginSpaceID else {
        return false
    }

    return entry.spaceID != layoutOriginSpaceID
}

func isWithinVisibleArea(frame: ResolvedFrame, hostDisplay: DisplayInfo, displays: [DisplayInfo]) -> Bool {
    for display in displays {
        let displayRight = display.frame.origin.x + display.frame.width
        let displayBottom = display.frame.origin.y + display.frame.height
        if frame.x < displayRight,
           frame.x + frame.width > display.frame.origin.x,
           frame.y < displayBottom,
           frame.y + frame.height > display.frame.origin.y
        {
            return true
        }
    }
    if displays.isEmpty {
        return frame.x < hostDisplay.frame.width && frame.y < hostDisplay.frame.height
    }
    return false
}

func resolvedVirtualLayoutFrame(
    entry: SlotEntry,
    layout: LayoutDefinition,
    hostDisplay: DisplayInfo,
    displays: [DisplayInfo]
) -> ResolvedFrame? {
    let targetSpaceID: Int
    let targetSlot: Int

    if let layoutOriginSpaceID = entry.layoutOriginSpaceID,
       let layoutOriginSlot = entry.layoutOriginSlot
    {
        guard entry.spaceID == layoutOriginSpaceID else {
            return nil
        }
        targetSpaceID = layoutOriginSpaceID
        targetSlot = layoutOriginSlot
    } else {
        guard let entrySpaceID = entry.spaceID else {
            return nil
        }
        targetSpaceID = entrySpaceID
        targetSlot = entry.slot
    }

    guard let space = layout.spaces.first(where: { $0.spaceID == targetSpaceID }),
          let window = space.windows.first(where: { $0.slot == targetSlot })
    else {
        return nil
    }

    let basis = virtualCoordinateRect(hostDisplay.visibleFrame, displays: displays)
    return try? LengthParser.resolveFrame(
        window.frame,
        basis: basis,
        scale: hostDisplay.scale
    )
}

func resolveVirtualHiddenFrame(
    entry: SlotEntry,
    window: WindowSnapshot,
    hostDisplay: DisplayInfo,
    displays: [DisplayInfo]
) -> ResolvedFrame {
    let width = max(1, window.frame.width)
    let height = max(1, window.frame.height)
    let targetDisplay = resolveVirtualTargetDisplay(
        entry: entry,
        window: window,
        displays: displays
    ) ?? hostDisplay
    let targetVisibleFrame = virtualCoordinateRect(targetDisplay.visibleFrame, displays: displays)
    let corner = optimalVirtualHideCorner(for: targetDisplay, displays: displays)
    let x: Double
    switch corner {
    case .bottomLeft:
        x = targetVisibleFrame.minX - width + 1
    case .bottomRight:
        x = targetVisibleFrame.maxX - 1
    }
    let referenceFrame = entry.lastVisibleFrame ?? window.frame
    let minY = targetVisibleFrame.minY
    let maxY = max(minY, targetVisibleFrame.maxY - height)
    let y = min(max(referenceFrame.y, minY), maxY)
    return ResolvedFrame(x: x, y: y, width: width, height: height)
}

func resolveVirtualTargetDisplay(
    entry: SlotEntry,
    window: WindowSnapshot,
    displays: [DisplayInfo]
) -> DisplayInfo? {
    if let displayID = entry.displayID ?? window.displayID,
       let matched = displays.first(where: { $0.id == displayID })
    {
        return matched
    }
    return WindowQueryService.resolveDisplay(
        for: CGRect(
            x: window.frame.x,
            y: window.frame.y,
            width: window.frame.width,
            height: window.frame.height
        ),
        displays: displays
    )
}

func optimalVirtualHideCorner(for display: DisplayInfo, displays: [DisplayInfo]) -> VirtualHideCorner {
    let normalizedDisplayFrame = virtualCoordinateRect(display.frame, displays: displays)
    let normalizedDisplayFrames = displays.map { virtualCoordinateRect($0.frame, displays: displays) }
    let xOffset = normalizedDisplayFrame.width * 0.1
    let yOffset = normalizedDisplayFrame.height * 0.1

    let bottomRightPrimary = CGPoint(x: normalizedDisplayFrame.maxX + 2, y: normalizedDisplayFrame.maxY - yOffset)
    let bottomRightSecondary = CGPoint(x: normalizedDisplayFrame.maxX - xOffset, y: normalizedDisplayFrame.maxY + 2)
    let bottomRightCritical = CGPoint(x: normalizedDisplayFrame.maxX + 2, y: normalizedDisplayFrame.maxY + 2)

    let bottomLeftPrimary = CGPoint(x: normalizedDisplayFrame.minX - 2, y: normalizedDisplayFrame.maxY - yOffset)
    let bottomLeftSecondary = CGPoint(x: normalizedDisplayFrame.minX + xOffset, y: normalizedDisplayFrame.maxY + 2)
    let bottomLeftCritical = CGPoint(x: normalizedDisplayFrame.minX - 2, y: normalizedDisplayFrame.maxY + 2)

    func containmentScore(for points: [CGPoint]) -> Int {
        normalizedDisplayFrames.reduce(into: 0) { total, candidate in
            total += candidate.contains(points[0]) ? 1 : 0
            total += candidate.contains(points[1]) ? 1 : 0
            total += candidate.contains(points[2]) ? 10 : 0
        }
    }

    let leftScore = containmentScore(for: [bottomLeftPrimary, bottomLeftSecondary, bottomLeftCritical])
    let rightScore = containmentScore(for: [bottomRightPrimary, bottomRightSecondary, bottomRightCritical])
    return leftScore < rightScore ? .bottomLeft : .bottomRight
}

func virtualCoordinateRect(_ rect: CGRect, displays: [DisplayInfo]) -> CGRect {
    let mainDisplayHeight = displays.first(where: \.isPrimary)?.frame.height
        ?? displays.map { $0.frame.height }.max()
        ?? rect.height
    return CGRect(
        x: rect.minX,
        y: mainDisplayHeight - rect.maxY,
        width: rect.width,
        height: rect.height
    )
}

func virtualSwitchInteractionRootCause(_ interactionResult: WindowInteractionResult) -> String {
    switch interactionResult {
    case .success:
        return "visibilityConvergenceFailed"
    case .permissionDenied:
        return "permissionDenied"
    case .failed:
        return "visibilityConvergenceFailed"
    }
}

func performVirtualSpaceSwitch(
    targets: [VirtualSwitchWindow],
    others: [VirtualSwitchWindow],
    layout: LayoutDefinition,
    hostDisplay: DisplayInfo?,
    hooks: CommandServiceRuntimeHooks,
    logger: ShitsuraeLogger
) -> VirtualSwitchOperationResult {
    guard let hostDisplay else {
        return VirtualSwitchOperationResult(
            succeeded: false,
            failedOperation: "hostDisplayResolve",
            rootCauseCategory: "virtualHostDisplayUnavailable",
            appliedChanges: [],
            focusedTarget: nil,
            frameMutationCount: 0,
            positionMutationCount: 0,
            profile: VirtualSwitchOperationProfile(
                displaysLoadMS: 0,
                targetPlanMS: 0,
                showTargetsMS: 0,
                hideOthersMS: 0,
                focusMS: 0
            )
        )
    }

    let displaysStartMS = virtualSwitchNowMS()
    let displays = hooks.displays()
    let displaysLoadMS = virtualSwitchNowMS() - displaysStartMS
    var appliedChanges: [AppliedVirtualVisibilityChange] = []
    var frameMutationCount = 0
    var positionMutationCount = 0
    let targetPlanStartMS = virtualSwitchNowMS()
    let targetPlans: [(target: VirtualSwitchWindow, plan: VirtualVisibilityPlan)] =
        targets.sorted(by: virtualSwitchWindowOrdering).compactMap { target in
        guard let plan = planVirtualVisibility(
            entry: target.entry,
            window: target.window,
            transition: .show,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        ) else {
            return nil
        }

        return (target: target, plan: plan)
    }
    let targetPlanMS = virtualSwitchNowMS() - targetPlanStartMS

    guard targetPlans.count == targets.count else {
        return VirtualSwitchOperationResult(
            succeeded: false,
            failedOperation: "visibleFrameResolve",
            rootCauseCategory: "virtualVisibleFrameUnavailable",
            appliedChanges: [],
            focusedTarget: nil,
            frameMutationCount: 0,
            positionMutationCount: 0,
            profile: VirtualSwitchOperationProfile(
                displaysLoadMS: displaysLoadMS,
                targetPlanMS: targetPlanMS,
                showTargetsMS: 0,
                hideOthersMS: 0,
                focusMS: 0
            )
        )
    }

    let showTargetsStartMS = virtualSwitchNowMS()
    for (target, plan) in targetPlans {
        switch plan.mutation {
        case .frame:
            frameMutationCount += 1
        case .position:
            positionMutationCount += 1
        case .none:
            break
        }
        let showSucceeded = applyVirtualVisibilityPlan(
            window: target.window,
            plan: plan,
            hooks: hooks,
            logger: logger
        )
        if !showSucceeded {
            logger.log(
                level: "warn",
                event: "virtual.visibility.bestEffort.skipped",
                fields: [
                    "windowID": Int(target.window.windowID),
                    "bundleID": target.window.bundleID,
                    "action": plan.action,
                    "phase": "showTarget",
                ]
            )
        }
        let effectiveEntry = showSucceeded ? plan.updatedEntry : target.entry
        appliedChanges.append(
            AppliedVirtualVisibilityChange(
                window: target.window,
                originalEntry: target.entry,
                updatedEntry: effectiveEntry,
                desiredEntry: plan.updatedEntry,
                previousFrame: target.window.frame,
                restoredFromMinimized: plan.restoreFromMinimized
            )
        )
    }
    let showTargetsMS = virtualSwitchNowMS() - showTargetsStartMS

    let hideOthersStartMS = virtualSwitchNowMS()
    for other in others.sorted(by: virtualSwitchWindowOrdering) {
        guard let plan = planVirtualVisibility(
            entry: other.entry,
            window: other.window,
            transition: .hide,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        ) else {
            continue
        }
        switch plan.mutation {
        case .frame:
            frameMutationCount += 1
        case .position:
            positionMutationCount += 1
        case .none:
            break
        }
        let hideSucceeded = applyVirtualVisibilityPlan(
            window: other.window,
            plan: plan,
            hooks: hooks,
            logger: logger
        )
        if !hideSucceeded {
            logger.log(
                level: "warn",
                event: "virtual.visibility.bestEffort.skipped",
                fields: [
                    "windowID": Int(other.window.windowID),
                    "bundleID": other.window.bundleID,
                    "action": plan.action,
                    "phase": "hideOther",
                ]
            )
        }
        let effectiveEntry = hideSucceeded ? plan.updatedEntry : other.entry
        appliedChanges.append(
            AppliedVirtualVisibilityChange(
                window: other.window,
                originalEntry: other.entry,
                updatedEntry: effectiveEntry,
                desiredEntry: plan.updatedEntry,
                previousFrame: other.window.frame,
                restoredFromMinimized: plan.restoreFromMinimized
            )
        )
    }
    let hideOthersMS = virtualSwitchNowMS() - hideOthersStartMS

    let preferredFocusTarget = preferredVirtualFocusTarget(from: targets)
    var appliedFocusTarget: VirtualSwitchWindow?
    let focusStartMS = virtualSwitchNowMS()
    if let focusTarget = preferredFocusTarget {
        let interactionResult = hooks.focusWindow(focusTarget.window.windowID, focusTarget.window.bundleID)
        if interactionResult.isSuccess || hooks.activateBundle(focusTarget.window.bundleID) {
            appliedFocusTarget = focusTarget
        } else {
            logger.log(
                level: "warn",
                event: "virtual.visibility.focus.skipped",
                fields: [
                    "windowID": Int(focusTarget.window.windowID),
                    "bundleID": focusTarget.window.bundleID,
                    "reason": virtualSwitchInteractionRootCause(interactionResult),
                ]
            )
        }
    }
    let focusMS = virtualSwitchNowMS() - focusStartMS

    return VirtualSwitchOperationResult(
        succeeded: true,
        failedOperation: nil,
        rootCauseCategory: nil,
        appliedChanges: appliedChanges,
        focusedTarget: appliedFocusTarget,
        frameMutationCount: frameMutationCount,
        positionMutationCount: positionMutationCount,
        profile: VirtualSwitchOperationProfile(
            displaysLoadMS: displaysLoadMS,
            targetPlanMS: targetPlanMS,
            showTargetsMS: showTargetsMS,
            hideOthersMS: hideOthersMS,
            focusMS: focusMS
        )
    )
}

struct VirtualVisibilityConvergenceProfile {
    let retryCount: Int
    let verifyCount: Int
}

func resolveVirtualVisibilityConvergence(
    changes: [AppliedVirtualVisibilityChange],
    hooks: CommandServiceRuntimeHooks,
    logger: ShitsuraeLogger,
    retryDelaysMS: [Int]
) -> (resolvedChanges: [AppliedVirtualVisibilityChange], hasPending: Bool, profile: VirtualVisibilityConvergenceProfile) {
    guard !changes.isEmpty else {
        return ([], false, VirtualVisibilityConvergenceProfile(retryCount: 0, verifyCount: 0))
    }

    var latestWindows = hooks.listWindowsOnAllSpaces()
    var verifyCount = 1
    var retryCount = 0
    var pendingChanges = changes.filter { !virtualVisibilityMatchesDesiredState(change: $0, windows: latestWindows) }

    for delayMS in retryDelaysMS where !pendingChanges.isEmpty {
        retryCount += 1
        retryVirtualVisibilityChanges(pendingChanges, hooks: hooks, logger: logger)
        Thread.sleep(forTimeInterval: TimeInterval(delayMS) / 1000)
        latestWindows = hooks.listWindowsOnAllSpaces()
        verifyCount += 1
        pendingChanges = changes.filter { !virtualVisibilityMatchesDesiredState(change: $0, windows: latestWindows) }
    }

    let unresolvedWindowIDs = Set(pendingChanges.map { $0.window.windowID })
    let resolvedChanges = changes.map { change in
        guard !unresolvedWindowIDs.contains(change.window.windowID) else {
            return AppliedVirtualVisibilityChange(
                window: change.window,
                originalEntry: change.originalEntry,
                updatedEntry: change.originalEntry,
                desiredEntry: change.desiredEntry,
                previousFrame: change.previousFrame,
                restoredFromMinimized: change.restoredFromMinimized
            )
        }

        return AppliedVirtualVisibilityChange(
            window: change.window,
            originalEntry: change.originalEntry,
            updatedEntry: change.desiredEntry,
            desiredEntry: change.desiredEntry,
            previousFrame: change.previousFrame,
            restoredFromMinimized: change.restoredFromMinimized
        )
    }

    return (
        resolvedChanges,
        !pendingChanges.isEmpty,
        VirtualVisibilityConvergenceProfile(
            retryCount: retryCount,
            verifyCount: verifyCount
        )
    )
}

private func virtualVisibilityMatchesDesiredState(
    change: AppliedVirtualVisibilityChange,
    windows: [WindowSnapshot]
) -> Bool {
    guard let actualWindow = windows.first(where: { $0.windowID == change.window.windowID }) else {
        return false
    }

    switch change.desiredEntry.visibilityState {
    case .visible:
        guard !actualWindow.minimized else {
            return false
        }
        if let expectedFrame = change.desiredEntry.lastVisibleFrame {
            return virtualVisibilityFrameMatches(actualWindow.frame, expectedFrame)
        }
        return true
    case .hiddenOffscreen:
        if actualWindow.minimized || actualWindow.isFullscreen {
            return true
        }
        guard let expectedFrame = change.desiredEntry.lastHiddenFrame else {
            return false
        }
        return virtualVisibilityPositionMatches(actualWindow.frame, expectedFrame)
    case nil:
        return true
    }
}

private func retryVirtualVisibilityChanges(
    _ changes: [AppliedVirtualVisibilityChange],
    hooks: CommandServiceRuntimeHooks,
    logger: ShitsuraeLogger
) {
    for change in changes {
        switch change.desiredEntry.visibilityState {
        case .visible:
            guard let frame = change.desiredEntry.lastVisibleFrame else {
                continue
            }
            if !hooks.setWindowFrame(change.window.windowID, change.window.bundleID, frame) {
                logger.log(
                    level: "warn",
                    event: "virtual.visibility.retry.failed",
                    fields: [
                        "windowID": Int(change.window.windowID),
                        "bundleID": change.window.bundleID,
                        "action": "show",
                    ]
                )
            }
        case .hiddenOffscreen:
            guard let frame = change.desiredEntry.lastHiddenFrame else {
                continue
            }
            if !hooks.setWindowPosition(
                change.window.windowID,
                change.window.bundleID,
                CGPoint(x: frame.x, y: frame.y)
            ) {
                logger.log(
                    level: "warn",
                    event: "virtual.visibility.retry.failed",
                    fields: [
                        "windowID": Int(change.window.windowID),
                        "bundleID": change.window.bundleID,
                        "action": "hide",
                    ]
                )
            }
        case nil:
            continue
        }
    }
}

private func virtualVisibilityFrameMatches(
    _ actual: ResolvedFrame,
    _ expected: ResolvedFrame,
    tolerance: Double = 4
) -> Bool {
    abs(actual.x - expected.x) <= tolerance
        && abs(actual.y - expected.y) <= tolerance
        && abs(actual.width - expected.width) <= tolerance
        && abs(actual.height - expected.height) <= tolerance
}

private func virtualVisibilityPositionMatches(
    _ actual: ResolvedFrame,
    _ expected: ResolvedFrame,
    tolerance: Double = 4
) -> Bool {
    abs(actual.x - expected.x) <= tolerance
        && abs(actual.y - expected.y) <= tolerance
}
