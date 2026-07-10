import Foundation

/// Cross-actor freshness gate for OS focus notifications. App-side receipt
/// and user-initiated invalidation update it synchronously; the engine checks
/// the same token immediately before a follow-focus switch. This closes the
/// scheduling gap where an actor invalidation Task could arrive after an old
/// switch Task.
public final class FocusEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var latestSequence: UInt64 = 0
    private var currentInvalidated = false

    public init() {}

    /// Accepts a new sequence or confirms the current one. Older work is
    /// rejected. Equality is allowed because AppModel and the engine observe
    /// the same event at different stages.
    @discardableResult
    public func accept(_ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sequence >= latestSequence else { return false }
        if sequence > latestSequence {
            latestSequence = sequence
            currentInvalidated = false
            return true
        }
        return !currentInvalidated
    }

    public func isCurrent(_ sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sequence == latestSequence && !currentInvalidated
    }

    public func invalidate(with sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if sequence > latestSequence {
            latestSequence = sequence
            currentInvalidated = false
        }
    }

    /// Invalidates current work when the caller has no OS source sequence
    /// (for example an IPC command received before AppModel participates).
    /// This must not synthesize a sequence number: doing so can run ahead of
    /// the OS source counter and reject the next legitimate focus events.
    @discardableResult
    public func invalidateCurrent() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        currentInvalidated = true
        return latestSequence
    }
}

public struct FollowFocusPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case adoptIntoActiveWorkspace
        case markActivated
        case switchSpace(Int)
    }

    private let debounce: TimeInterval

    public init(debounce: TimeInterval = 0.5) {
        self.debounce = debounce
    }

    /// Shortcut policy only ignores the frontmost app when its tracked entry
    /// proves that the window belongs to another virtual workspace. An
    /// unmanaged window (including one excluded by a focus-ignore rule) is
    /// physically present on the workspace the user is currently viewing, so
    /// its per-app shortcut policy must remain effective.
    public static func frontmostBelongsToActiveWorkspace(
        targetSpaceID: Int?,
        activeSpaceID: Int?
    ) -> Bool {
        targetSpaceID == nil || targetSpaceID == activeSpaceID
    }

    public func decisionForFocusedWindow(
        targetSpaceID: Int?,
        activeSpaceID: Int?,
        followFocusEnabled: Bool,
        lastFollowFocusSwitchAt: Date?,
        lastActiveSpaceChangeAt: Date?,
        now: Date
    ) -> Decision {
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
}
