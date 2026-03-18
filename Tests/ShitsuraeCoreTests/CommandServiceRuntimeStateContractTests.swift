import Foundation
import XCTest
@testable import ShitsuraeCore

final class CommandServiceRuntimeStateContractTests: CommandServiceContractTestCase {
    func testArrangeSerializesConcurrentSameProcessMutationsViaStateMutationLock() throws {
        let workspace = try TestConfigWorkspace(files: ["config.yaml": Self.virtualMultiSpaceConfigYAML])
        defer { workspace.cleanup() }

        let driver = SerializingVirtualArrangeDriver()
        let deduplicator = NeverSuppressArrangeDeduplicator()
        let lockURL = workspace.root.appendingPathComponent("virtual-space-state.lock")

        let serviceA = UnsafeSendableBox(value: workspace.makeService(
            arrangeDriver: driver,
            arrangeRequestDeduplicator: deduplicator,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL)
        ))
        let serviceB = UnsafeSendableBox(value: workspace.makeService(
            arrangeDriver: driver,
            arrangeRequestDeduplicator: deduplicator,
            stateMutationLock: VirtualSpaceStateMutationLock(fileURL: lockURL)
        ))

        let firstStarted = expectation(description: "first arrange entered critical section")
        let secondFinished = expectation(description: "second arrange finished")
        secondFinished.isInverted = true

        let firstResult = LockedValueBox<CommandResult?>(nil)
        let secondResult = LockedValueBox<CommandResult?>(nil)
        let completionGroup = DispatchGroup()

        driver.onFirstQueryEntered = {
            firstStarted.fulfill()
        }

        completionGroup.enter()
        DispatchQueue.global().async {
            firstResult.set(serviceA.value.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true))
            completionGroup.leave()
        }

        wait(for: [firstStarted], timeout: 5.0)

        completionGroup.enter()
        DispatchQueue.global().async {
            secondResult.set(serviceB.value.arrange(layoutName: "work", spaceID: 1, dryRun: false, verbose: false, json: true))
            secondFinished.fulfill()
            completionGroup.leave()
        }

        wait(for: [secondFinished], timeout: 0.2)
        XCTAssertEqual(driver.queryInvocationCount, 1)

        driver.releaseFirstQuery()

        XCTAssertEqual(completionGroup.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(firstResult.get()?.exitCode, 0)
        XCTAssertEqual(secondResult.get()?.exitCode, 0)
        XCTAssertGreaterThanOrEqual(driver.queryInvocationCount, 2)
    }

}
