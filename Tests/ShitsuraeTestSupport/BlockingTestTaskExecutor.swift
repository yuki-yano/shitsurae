import Dispatch

/// Holds synchronous fixture blockers on Dispatch threads so even a
/// single cooperative worker can observe and explicitly release them.
public final class BlockingTestTaskExecutor: TaskExecutor {
    private let queue = DispatchQueue(label: "shitsurae.tests.blocking", attributes: .concurrent)

    public init() {}

    public func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}
