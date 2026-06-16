import Foundation

public struct FollowFocusPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case adoptIntoActiveWorkspace
        case markActivated
        case switchSpace(Int)
    }

    private let newWindowGrace: TimeInterval
    private let debounce: TimeInterval
    private var createdWindowIDs: [UInt32: Date] = [:]

    public init(newWindowGrace: TimeInterval = 0.75, debounce: TimeInterval = 0.5) {
        self.newWindowGrace = newWindowGrace
        self.debounce = debounce
    }

    public mutating func recordWindowCreated(windowID: UInt32, now: Date) {
        pruneCreatedWindows(now: now)
        createdWindowIDs[windowID] = now
    }

    public mutating func decisionForFocusedWindow(
        windowID: UInt32,
        targetSpaceID: Int?,
        activeSpaceID: Int?,
        followFocusEnabled: Bool,
        lastFollowFocusSwitchAt: Date?,
        lastActiveSpaceChangeAt: Date?,
        now: Date
    ) -> Decision {
        pruneCreatedWindows(now: now)

        if createdWindowIDs[windowID] != nil {
            return .adoptIntoActiveWorkspace
        }

        if targetSpaceID == nil {
            return .adoptIntoActiveWorkspace
        }

        guard followFocusEnabled,
              let targetSpaceID,
              targetSpaceID != activeSpaceID
        else {
            return .markActivated
        }

        if let lastFollowFocusSwitchAt,
           now.timeIntervalSince(lastFollowFocusSwitchAt) < debounce
        {
            return .markActivated
        }

        if let lastActiveSpaceChangeAt,
           now.timeIntervalSince(lastActiveSpaceChangeAt) < debounce
        {
            return .markActivated
        }

        return .switchSpace(targetSpaceID)
    }

    private mutating func pruneCreatedWindows(now: Date) {
        createdWindowIDs = createdWindowIDs.filter { _, createdAt in
            now.timeIntervalSince(createdAt) <= newWindowGrace
        }
    }
}
