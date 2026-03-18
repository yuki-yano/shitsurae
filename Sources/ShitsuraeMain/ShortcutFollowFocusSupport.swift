import Foundation

enum ShortcutFollowFocusDecision {
    case skip
    case switchSpace(Int)
}

func resolveShortcutFollowFocusDecision(
    followFocusEnabled: Bool,
    lastFollowFocusSwitchAt: Date?,
    lastActiveSpaceChangeAt: Date?,
    debounceInterval: TimeInterval,
    targetSpaceID: Int?,
    activeSpaceID: Int?,
    now: Date = Date()
) -> ShortcutFollowFocusDecision {
    guard followFocusEnabled else {
        return .skip
    }

    if let lastFollowFocusSwitchAt,
       now.timeIntervalSince(lastFollowFocusSwitchAt) < debounceInterval
    {
        return .skip
    }

    if let lastActiveSpaceChangeAt,
       now.timeIntervalSince(lastActiveSpaceChangeAt) < debounceInterval
    {
        return .skip
    }

    guard let targetSpaceID else {
        return .skip
    }

    guard activeSpaceID != targetSpaceID else {
        return .skip
    }

    return .switchSpace(targetSpaceID)
}
