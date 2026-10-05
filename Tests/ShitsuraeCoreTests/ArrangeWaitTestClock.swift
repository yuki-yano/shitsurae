import Foundation

/// This advances only local appearance waits, not the coordinator deadline.
final class ArrangeWaitTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 10_000_000_000
    var now: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(milliseconds: Int) {
        lock.lock(); defer { lock.unlock() }
        value += UInt64(max(0, milliseconds)) * 1_000_000
    }
    static func connected(to control: MockWindowControl) -> ArrangeWaitTestClock {
        let clock = ArrangeWaitTestClock()
        control.onSleep = { clock.advance(milliseconds: $0) }
        return clock
    }
}
