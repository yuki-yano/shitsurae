import Foundation

@MainActor
protocol ArrangeOperationMonitoring: AnyObject {
    /// Replaces any previous schedule and calls each tick synchronously on MainActor.
    func start(interval: Duration, tick: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// Production scheduling; the first tick is scheduled without waiting for the interval.
@MainActor
final class PeriodicArrangeOperationMonitor: ArrangeOperationMonitoring {
    private var task: Task<Void, Never>?
    func start(interval: Duration, tick: @escaping @MainActor @Sendable () -> Void) {
        stop()
        task = Task { @MainActor in
            while !Task.isCancelled {
                tick()
                try? await Task.sleep(for: interval)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
