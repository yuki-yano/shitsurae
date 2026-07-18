import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("SystemProbe process execution")
struct SystemProbeProcessTests {
    @Test func returnsStandardOutputForSuccessfulProcess() {
        let output = SystemProbe.runProcess(
            executable: "/bin/echo",
            arguments: ["ready"],
            timeoutSeconds: 1
        )

        #expect(output == "ready\n")
    }

    @Test func returnsNilForNonzeroExit() {
        let output = SystemProbe.runProcess(
            executable: "/usr/bin/false",
            arguments: [],
            timeoutSeconds: 1
        )

        #expect(output == nil)
    }

    @Test func terminatesProcessAtDeadline() {
        let startedAt = ContinuousClock.now
        let output = SystemProbe.runProcess(
            executable: "/bin/sleep",
            arguments: ["5"],
            timeoutSeconds: 0.05
        )
        let elapsed = startedAt.duration(to: .now)

        #expect(output == nil)
        #expect(elapsed < .seconds(1))
    }
}
