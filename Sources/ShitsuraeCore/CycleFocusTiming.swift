import Foundation

public struct CycleFocusTiming: Equatable {
    public let lastActiveSpaceChangeAt: Date?

    public init(lastActiveSpaceChangeAt: Date?) {
        self.lastActiveSpaceChangeAt = lastActiveSpaceChangeAt
    }

    public func dispatchDelay(now: Date, activeSpaceSettleDelay: TimeInterval) -> TimeInterval {
        guard let lastActiveSpaceChangeAt else {
            return 0
        }

        return max(0, activeSpaceSettleDelay - now.timeIntervalSince(lastActiveSpaceChangeAt))
    }
}
