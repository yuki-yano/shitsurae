import AppKit
import Foundation
import Testing
@testable import Shitsurae

@Suite("AXWindowEventMonitor")
struct AXWindowEventMonitorTests {
    @Test func initialRegistrationDoesNotBlockTheCallingThread() throws {
        let registrationStarted = DispatchSemaphore(value: 0)
        let allowRegistrationToFinish = DispatchSemaphore(value: 0)
        let bootstrapCompleted = DispatchSemaphore(value: 0)
        let application = try #require(NSWorkspace.shared.runningApplications.first)
        let monitor = AXWindowEventMonitor(
            applicationProvider: { [application] },
            registrationHook: { _ in
                registrationStarted.signal()
                allowRegistrationToFinish.wait()
            }
        )

        let startedAt = ContinuousClock.now
        monitor.start(
            handler: { _ in },
            completion: {
                bootstrapCompleted.signal()
            }
        )
        let startDuration = startedAt.duration(to: .now)

        #expect(startDuration < .milliseconds(100))
        #expect(registrationStarted.wait(timeout: .now() + 1) == .success)
        #expect(bootstrapCompleted.wait(timeout: .now() + 0.05) == .timedOut)

        allowRegistrationToFinish.signal()
        #expect(bootstrapCompleted.wait(timeout: .now() + 1) == .success)
        monitor.stop()
    }
}
