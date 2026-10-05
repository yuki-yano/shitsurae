import AppKit
import Foundation
import Testing
@testable import Shitsurae

private final class RegistrationOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ event: String) { lock.lock(); recorded.append(event); lock.unlock() }
}

@Suite("AXWindowEventMonitor")
struct AXWindowEventMonitorTests {
    @Test func initialRegistrationDoesNotBlockTheCallingThread() throws {
        let order = RegistrationOrder()
        let registrationStarted = DispatchSemaphore(value: 0)
        let allowRegistrationToFinish = DispatchSemaphore(value: 0)
        let bootstrapCompleted = DispatchSemaphore(value: 0)
        // Registration is intercepted by the hook, so no external GUI app is required.
        let application = NSRunningApplication.current
        let monitor = AXWindowEventMonitor(
            applicationProvider: { [application] },
            registrationHook: { _ in
                order.record("entered")
                registrationStarted.signal()
                allowRegistrationToFinish.wait()
                order.record("returned")
            }
        )

        defer { allowRegistrationToFinish.signal(); monitor.stop() }
        let startedAt = ContinuousClock.now
        monitor.start(
            handler: { _ in },
            completion: {
                order.record("completed")
                bootstrapCompleted.signal()
            }
        )
        let startDuration = startedAt.duration(to: .now)

        #expect(startDuration < .milliseconds(100))
        try #require(registrationStarted.wait(timeout: .now() + 1) == .success)
        #expect(order.events == ["entered"])

        allowRegistrationToFinish.signal()
        try #require(bootstrapCompleted.wait(timeout: .now() + 1) == .success)
        #expect(order.events == ["entered", "returned", "completed"])
    }
}
