import Foundation

public struct CycleFocusTiming: Equatable {
    public let hasCachedCandidates: Bool
    public let lastCycleAt: Date?
    public let lastActiveSpaceChangeAt: Date?

    public init(
        hasCachedCandidates: Bool,
        lastCycleAt: Date?,
        lastActiveSpaceChangeAt: Date?
    ) {
        self.hasCachedCandidates = hasCachedCandidates
        self.lastCycleAt = lastCycleAt
        self.lastActiveSpaceChangeAt = lastActiveSpaceChangeAt
    }

    public func shouldRefreshCandidates(now: Date, cycleSessionTimeout: TimeInterval) -> Bool {
        if !hasCachedCandidates {
            return true
        }

        guard let lastCycleAt else {
            return true
        }

        if let lastActiveSpaceChangeAt, lastActiveSpaceChangeAt >= lastCycleAt {
            return true
        }

        return now.timeIntervalSince(lastCycleAt) > cycleSessionTimeout
    }

    public func dispatchDelay(now: Date, activeSpaceSettleDelay: TimeInterval) -> TimeInterval {
        guard let lastActiveSpaceChangeAt else {
            return 0
        }

        return max(0, activeSpaceSettleDelay - now.timeIntervalSince(lastActiveSpaceChangeAt))
    }
}
