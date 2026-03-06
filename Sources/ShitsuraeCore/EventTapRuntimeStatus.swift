import Foundation

public final class EventTapRuntimeStatusStore: @unchecked Sendable {
    public static let shared = EventTapRuntimeStatusStore()

    private let lock = NSLock()
    private var status: EventTapStatus?

    private init() {}

    public func set(_ status: EventTapStatus) {
        lock.lock()
        defer { lock.unlock() }
        self.status = status
    }

    public func get() -> EventTapStatus? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
