import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServicePermissionContractTests: CommandServiceContractTestCase {
    func testPermissionBranchReturns20ForWindowCurrentFocusAndArrange() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.validConfigYAML])
        defer { workspace.cleanup() }

        let runtimeHooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { false },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") }
        )

        let service = workspace.makeService(runtimeHooks: runtimeHooks)

        let current = service.windowCurrent(json: true)
        XCTAssertEqual(current.exitCode, Int32(ErrorCode.missingPermission.rawValue))

        let focus = service.focus(slot: 1)
        XCTAssertEqual(focus.exitCode, Int32(ErrorCode.missingPermission.rawValue))

        let arrangeService = workspace.makeService(arrangeDriver: MissingPermissionArrangeDriver())
        let arrange = arrangeService.arrange(layoutName: "work", dryRun: false, verbose: false, json: true)
        XCTAssertEqual(arrange.exitCode, Int32(ErrorCode.missingPermission.rawValue))
        let payload = try decode(ArrangeExecutionJSON.self, from: arrange.stdout)
        XCTAssertEqual(payload.hardErrors.first?.code, ErrorCode.missingPermission.rawValue)
    }
}
