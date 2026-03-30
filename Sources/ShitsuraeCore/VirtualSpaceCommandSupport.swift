import CoreGraphics
import Foundation

struct VirtualSwitchWindow {
    let entry: SlotEntry
    let window: WindowSnapshot
}

enum VirtualHideCorner {
    case bottomLeft
    case bottomRight
}

struct AppliedVirtualVisibilityChange {
    let window: WindowSnapshot
    let originalEntry: SlotEntry
    let updatedEntry: SlotEntry
    let desiredEntry: SlotEntry
    let previousFrame: ResolvedFrame
    let restoredFromMinimized: Bool
}

struct VirtualSwitchOperationResult {
    let succeeded: Bool
    let failedOperation: String?
    let rootCauseCategory: String?
    let appliedChanges: [AppliedVirtualVisibilityChange]
    let focusedTarget: VirtualSwitchWindow?
    let frameMutationCount: Int
    let positionMutationCount: Int
    let profile: VirtualSwitchOperationProfile
}

struct VirtualSwitchOperationProfile {
    let displaysLoadMS: Int
    let targetPlanMS: Int
    let showTargetsMS: Int
    let hideOthersMS: Int
    let focusMS: Int
}

func isManagedByVirtualHostDisplay(
    _ target: VirtualSwitchWindow,
    hostDisplayID: String
) -> Bool {
    let displayID = target.window.displayID ?? target.entry.displayID
    return displayID == hostDisplayID
}

func uniqueSpaces(in layout: LayoutDefinition) -> [SpaceDefinition] {
    var seen = Set<Int>()
    return layout.spaces
        .filter { seen.insert($0.spaceID).inserted }
        .sorted { $0.spaceID < $1.spaceID }
}

func isShitsuraeManagedBundle(_ bundleID: String) -> Bool {
    bundleID.hasPrefix("com.yuki-yano.shitsurae")
}

func applyVirtualVisibilityChanges(
    _ changes: [AppliedVirtualVisibilityChange],
    to slots: [SlotEntry]
) -> [SlotEntry] {
    var nextSlots = slots
    for change in changes {
        guard let index = nextSlots.firstIndex(where: {
            $0.layoutName == change.originalEntry.layoutName
                && $0.definitionFingerprint == change.originalEntry.definitionFingerprint
                && $0.slot == change.originalEntry.slot
        }) else {
            continue
        }
        nextSlots[index] = change.updatedEntry
    }
    return nextSlots
}

func resolveVirtualSwitchWindow(entry: SlotEntry, windows: [WindowSnapshot]) -> VirtualSwitchWindow? {
    if let windowID = entry.windowID,
       let exact = windows.first(where: { $0.windowID == windowID })
    {
        return VirtualSwitchWindow(entry: entry, window: exact)
    }

    let matcher = WindowMatchRule(
        bundleID: entry.bundleID,
        title: persistedTitleMatcher(for: entry),
        role: entry.role,
        subrole: entry.subrole,
        profile: entry.profile,
        excludeTitleRegex: entry.excludeTitleRegex,
        index: entry.matchIndex
    )

    guard let matched = WindowMatchEngine.select(rule: matcher, candidates: windows) else {
        return nil
    }
    return VirtualSwitchWindow(entry: entry, window: matched)
}

func persistedTitleMatcher(for entry: SlotEntry) -> TitleMatcher? {
    guard let value = entry.titleMatchValue else {
        return nil
    }

    switch entry.titleMatchKind {
    case .none:
        return nil
    case .equals:
        return TitleMatcher(equals: value, contains: nil, regex: nil)
    case .contains:
        return TitleMatcher(equals: nil, contains: value, regex: nil)
    case .regex:
        return TitleMatcher(equals: nil, contains: nil, regex: value)
    }
}

func virtualInspectionStateSubcode(
    loadedConfig: LoadedConfig?,
    state: RuntimeState
) -> String? {
    guard RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
        loadedConfig: loadedConfig,
        state: state
    ) == .virtual else {
        return nil
    }

    if RuntimeStateReadResolver.isStaleVirtualReadState(loadedConfig: loadedConfig, state: state) {
        return "virtualStateUnavailable"
    }

    if RuntimeStateReadResolver.activeVirtualLayout(loadedConfig: loadedConfig, state: state) == nil {
        return "virtualStateUnavailable"
    }

    return nil
}

func virtualInspectionStateMessage(_ subcode: String) -> String {
    switch subcode {
    default:
        return "active virtual space is unavailable"
    }
}

func requiresVirtualShutdownRestore(_ state: RuntimeState) -> Bool {
    state.activeLayoutName != nil
        || state.activeVirtualSpaceID != nil
        || state.slots.contains(where: { $0.lastVisibleFrame != nil })
}

func recoveryForceClearEligible(
    loadedConfig: LoadedConfig?,
    state: RuntimeState
) -> Bool {
    guard let pending = state.pendingSwitchTransaction else {
        return false
    }

    if pending.manualRecoveryRequired {
        return true
    }

    guard let config = loadedConfig?.config,
          let layout = config.layouts[pending.activeLayoutName]
    else {
        return true
    }

    let availableSpaceIDs = Set(layout.spaces.map(\.spaceID))
    if !availableSpaceIDs.contains(pending.attemptedTargetSpaceID) {
        return true
    }
    if let previousActiveSpaceID = pending.previousActiveSpaceID,
       !availableSpaceIDs.contains(previousActiveSpaceID)
    {
        return true
    }

    return false
}

func makeRecoveryContext(
    state: RuntimeState,
    loadedConfig: LoadedConfig?,
    attemptedTargetSpaceID: Int? = nil,
    unresolvedSlots: [PendingUnresolvedSlot] = [],
    lockOwnerMetadata: VirtualSpaceLockOwnerMetadata? = nil,
    lockWaitTimeoutMS: Int? = nil
) -> RecoveryContextJSON? {
    guard state.stateMode == .virtual || state.pendingSwitchTransaction != nil else {
        return nil
    }

    let pending = state.pendingSwitchTransaction
    return RecoveryContextJSON(
        activeLayoutName: state.activeLayoutName ?? pending?.activeLayoutName,
        activeVirtualSpaceID: state.activeVirtualSpaceID,
        attemptedTargetSpaceID: attemptedTargetSpaceID ?? pending?.attemptedTargetSpaceID,
        previousActiveSpaceID: pending?.previousActiveSpaceID,
        lockOwnerPID: lockOwnerMetadata?.pid,
        lockOwnerProcessKind: lockOwnerMetadata?.processKind,
        lockOwnerStartedAt: lockOwnerMetadata?.startedAt,
        lockWaitTimeoutMS: lockWaitTimeoutMS,
        recoveryForceClearEligible: recoveryForceClearEligible(loadedConfig: loadedConfig, state: state),
        manualRecoveryRequired: pending?.manualRecoveryRequired,
        unresolvedSlots: unresolvedSlots.isEmpty ? (pending?.unresolvedSlots ?? []) : unresolvedSlots
    )
}

func virtualSwitchWindowOrdering(lhs: VirtualSwitchWindow, rhs: VirtualSwitchWindow) -> Bool {
    if lhs.entry.slot != rhs.entry.slot {
        return lhs.entry.slot < rhs.entry.slot
    }
    if lhs.window.frontIndex != rhs.window.frontIndex {
        return lhs.window.frontIndex < rhs.window.frontIndex
    }
    return lhs.window.windowID < rhs.window.windowID
}

func preferredVirtualFocusTarget(from targets: [VirtualSwitchWindow]) -> VirtualSwitchWindow? {
    targets.max { lhs, rhs in
        switch compareVirtualActivationRecency(lhs.entry.lastActivatedAt, rhs.entry.lastActivatedAt) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return virtualSwitchWindowOrdering(lhs: rhs, rhs: lhs)
        }
    }
}

func compareVirtualActivationRecency(_ lhs: String?, _ rhs: String?) -> ComparisonResult {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        if lhs == rhs {
            return .orderedSame
        }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    case (.some, nil):
        return .orderedDescending
    case (nil, .some):
        return .orderedAscending
    case (nil, nil):
        return .orderedSame
    }
}

func requiresVirtualHostDisplayPreflight(didChangeSpace: Bool, reconcile: Bool) -> Bool {
    didChangeSpace || reconcile
}

func resolveVirtualHostDisplayContext(
    layout: LayoutDefinition,
    config: ShitsuraeConfig?,
    focusedWindow: WindowSnapshot?,
    displays: [DisplayInfo],
    spaces: [SpaceInfo]
) -> (display: DisplayInfo, visibleSpace: SpaceInfo)? {
    guard let hostDisplay = resolveVirtualHostDisplay(
        layout: layout,
        config: config,
        focusedWindow: focusedWindow,
        displays: displays,
        spaces: spaces
    ) else {
        return nil
    }

    let visibleSpaces = spaces.filter { $0.displayID == hostDisplay.id && $0.isVisible }
    guard visibleSpaces.count == 1, let visibleSpace = visibleSpaces.first else {
        return nil
    }

    return (hostDisplay, visibleSpace)
}

func resolveVirtualHostDisplay(
    layout: LayoutDefinition,
    config: ShitsuraeConfig?,
    focusedWindow: WindowSnapshot?,
    displays: [DisplayInfo],
    spaces: [SpaceInfo]
) -> DisplayInfo? {
    guard !displays.isEmpty else {
        return nil
    }

    let spacesInLayout = uniqueSpaces(in: layout)
    let definitions = spacesInLayout.compactMap(\.display)
    if let firstDefinition = definitions.first {
        return resolveDisplay(
            for: firstDefinition,
            available: displays,
            monitors: config?.monitors
        )
    }

    if let focusedWindow,
       let displayID = focusedWindow.displayID,
       !isShitsuraeManagedBundle(focusedWindow.bundleID)
    {
        return displays.first(where: { $0.id == displayID })
    }

    let visibleDisplayIDs = Set(spaces.compactMap { $0.isVisible ? $0.displayID : nil })
    guard visibleDisplayIDs.count == 1,
          let displayID = visibleDisplayIDs.first
    else {
        return nil
    }

    return displays.first(where: { $0.id == displayID })
}

func resolveDisplay(
    for definition: DisplayDefinition?,
    available: [DisplayInfo],
    monitors: MonitorsDefinition?
) -> DisplayInfo? {
    guard !available.isEmpty else { return nil }

    if definition == nil {
        return available.first(where: \.isPrimary) ?? available.sorted(by: { $0.id < $1.id }).first
    }

    var candidates = available

    if let monitor = definition?.monitor {
        switch monitor {
        case .primary:
            candidates = available.filter(\.isPrimary)
        case .secondary:
            if let explicit = monitors?.secondary?.id {
                candidates = available.filter { $0.id == explicit }
            } else {
                let primaryID = available.first(where: \.isPrimary)?.id
                candidates = available
                    .filter { $0.id != primaryID }
                    .sorted { $0.id < $1.id }
                if candidates.count > 1 {
                    candidates = [candidates[0]]
                }
            }
        }
    }

    if let id = definition?.id {
        candidates = candidates.filter { $0.id == id }
    }

    if let width = definition?.width {
        candidates = candidates.filter { $0.width == width }
    }

    if let height = definition?.height {
        candidates = candidates.filter { $0.height == height }
    }

    guard candidates.count == 1 else {
        return nil
    }
    return candidates.first
}
