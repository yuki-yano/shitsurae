import Foundation

public struct InteractiveActivationTiming: Equatable {
    public let deferredUntil: Date?

    public init(deferredUntil: Date?) {
        self.deferredUntil = deferredUntil
    }

    public func handlingDelay(now: Date) -> TimeInterval {
        guard let deferredUntil else {
            return 0
        }

        return max(0, deferredUntil.timeIntervalSince(now))
    }
}
