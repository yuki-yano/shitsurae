import CoreGraphics
import XCTest
@testable import ShitsuraeCore

final class ArrangeServiceTests: XCTestCase {
    func testWindowNotFoundBecomesPartial51() throws {
        let driver = FakeArrangeDriver()
        let service = makeService(driver: driver)

        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "partial")
        XCTAssertEqual(result.exitCode, 51)
        XCTAssertEqual(result.softErrors.first?.code, ErrorCode.targetWindowNotFound.rawValue)
    }

    func testMoveSpaceFailureIsHard32() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[
            WindowSnapshot(
                windowID: 10,
                bundleID: "com.example.app",
                pid: 999,
                title: "Main",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 2,
                displayID: "display-1",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]]
        driver.moveWindowToSpaceResult = false

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "failed")
        XCTAssertEqual(result.exitCode, 32)
        XCTAssertEqual(result.hardErrors.first?.code, 32)
    }

    func testMoveSpaceUsesAppSpecificMethodOverride() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[
            WindowSnapshot(
                windowID: 10,
                bundleID: "org.alacritty",
                pid: 999,
                title: "Main",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 2,
                displayID: "display-1",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]]

        let config = baseConfig(
            initialFocusSlot: 1,
            windowMatch: WindowMatchRule(
                bundleID: "org.alacritty",
                title: nil,
                role: nil,
                subrole: nil,
                excludeTitleRegex: nil,
                index: nil
            ),
            executionPolicy: ExecutionPolicy(
                spaceMoveMethod: .drag,
                spaceMoveMethodInApps: ["org.alacritty": .displayRelay]
            )
        )

        let service = makeService(driver: driver, config: config)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.moveWindowToSpaceCalls.first?.method, .displayRelay)
    }

    func testSetFrameRetryExhaustedReturnsSoft50() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[sampleWindow(bundleID: "com.example.app")]]
        driver.setFrameResults = [false, false]

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "partial")
        XCTAssertEqual(result.exitCode, 51)
        XCTAssertEqual(result.softErrors.first?.code, 50)
    }

    func testMoveSuccessContinuesImmediatelyEvenWhenSnapshotLags() throws {
        let driver = FakeArrangeDriver()
        let stuckWindow = WindowSnapshot(
            windowID: 10,
            bundleID: "com.example.app",
            pid: 999,
            title: "Main",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: 2,
            displayID: "display-1",
            isFullscreen: false,
            frontIndex: 0
        )
        driver.windowsQueue = Array(repeating: [stuckWindow], count: 8)
        driver.allSpacesWindowsQueue = Array(repeating: [stuckWindow], count: 8)
        driver.moveWindowToSpaceResult = true
        driver.autoUpdateWindowSpaceOnMove = false

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.moveWindowToSpaceCalls.count, 1)
        XCTAssertEqual(driver.setFrameInvocations.count, 1)
        XCTAssertTrue(driver.sleepCalls.isEmpty)
    }

    func testWaitForWindowUsesShortPollingAndContinuesImmediatelyWhenWindowAppears() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [
            [],
            [sampleWindow(bundleID: "com.example.app")],
            [sampleWindow(bundleID: "com.example.app")],
        ]

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.sleepCalls.first, 100)
        XCTAssertLessThanOrEqual(driver.sleepCalls.reduce(0, +), 200)
    }

    func testSetFrameSuccessContinuesImmediatelyWhenWindowSnapshotsLag() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = Array(repeating: [
            sampleWindow(windowID: 10, bundleID: "com.example.first"),
            sampleWindow(windowID: 11, bundleID: "com.example.second", frontIndex: 1),
        ], count: 4)
        driver.allSpacesWindowsQueue = driver.windowsQueue
        driver.setFrameResults = [true, true]
        driver.autoUpdateWindowFrameOnSet = false

        let service = makeService(driver: driver, config: twoWindowPriorityConfig())
        let result = try service.execute(layoutName: "priorityWork")

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.setFrameInvocations.map(\.windowID), [10, 11])
        XCTAssertTrue(driver.sleepCalls.isEmpty)
    }

    func testLaunchFailureReturnsSoft41() throws {
        let driver = FakeArrangeDriver()
        driver.launchResults["com.example.app"] = false
        let service = makeService(driver: driver, config: baseConfig(initialFocusSlot: 1, launch: true))

        let result = try service.execute(layoutName: "work")
        XCTAssertEqual(result.result, "partial")
        XCTAssertEqual(result.exitCode, 51)
        XCTAssertEqual(result.softErrors.first?.code, ErrorCode.appLaunchFailed.rawValue)
    }

    func testExecuteMatchesChromiumWindowByProfileDirectory() throws {
        let driver = FakeArrangeDriver()
        driver.allSpacesWindowsQueue = [[
            sampleWindow(windowID: 10, bundleID: "com.google.Chrome", profileDirectory: "Default"),
            sampleWindow(windowID: 11, bundleID: "com.google.Chrome", frontIndex: 1, profileDirectory: "Profile 1"),
        ]]
        let service = makeService(
            driver: driver,
            config: baseConfig(
                initialFocusSlot: 1,
                launch: false,
                windowMatch: WindowMatchRule(
                    bundleID: "com.google.Chrome",
                    title: nil,
                    role: nil,
                    subrole: nil,
                    profile: "Profile 1",
                    excludeTitleRegex: nil,
                    index: nil
                )
            )
        )

        let result = try service.execute(layoutName: "work")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.setFrameInvocations.map(\.windowID), [11])
    }

    func testExecuteLaunchesChromiumProfileAndUsesNewWindowWhenProfileIsAmbiguous() throws {
        let driver = FakeArrangeDriver()
        driver.allSpacesWindowsQueue = [
            [sampleWindow(windowID: 10, bundleID: "com.google.Chrome")],
            [
                sampleWindow(windowID: 10, bundleID: "com.google.Chrome"),
                sampleWindow(windowID: 20, bundleID: "com.google.Chrome", frontIndex: 1),
            ],
        ]
        let service = makeService(
            driver: driver,
            config: baseConfig(
                initialFocusSlot: 1,
                launch: true,
                windowMatch: WindowMatchRule(
                    bundleID: "com.google.Chrome",
                    title: nil,
                    role: nil,
                    subrole: nil,
                    profile: "Default",
                    excludeTitleRegex: nil,
                    index: nil
                )
            )
        )

        let result = try service.execute(layoutName: "work")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.launchInvocations.map(\.bundleID), ["com.google.Chrome"])
        XCTAssertEqual(driver.launchInvocations.first?.profileDirectory, "Default")
        XCTAssertEqual(driver.setFrameInvocations.map(\.windowID), [20])
    }

    func testArrangeFindsWindowFromAllSpacesSnapshot() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[]]
        driver.allSpacesWindowsQueue = [[
            WindowSnapshot(
                windowID: 10,
                bundleID: "com.example.app",
                pid: 999,
                title: "Main",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 4,
                displayID: "display-1",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]]

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.hardErrors.isEmpty)
        XCTAssertTrue(result.softErrors.isEmpty)
    }

    func testArrangeSkipsMoveWhenWindowAlreadyOnTargetSpace() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[sampleWindow(bundleID: "com.example.app")]]
        driver.moveWindowToSpaceResult = false

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.moveWindowToSpaceCalls.count, 0)
    }

    func testExecuteSpecifiedSpaceOnlyTouchesMatchingSpace() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = Array(repeating: [
            sampleWindow(windowID: 10, bundleID: "com.example.first"),
            sampleWindow(windowID: 20, bundleID: "com.example.second", frontIndex: 1, spaceID: 2),
        ], count: 4)
        driver.allSpacesWindowsQueue = driver.windowsQueue

        let service = makeService(driver: driver, config: twoSpaceScopedConfig())
        let result = try service.execute(layoutName: "scopedWork", spaceID: 2)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(driver.setFrameInvocations.map(\.windowID), [20])
    }

    func testDryRunSpecifiedSpaceOnlyIncludesMatchingSpacePlan() throws {
        let driver = FakeArrangeDriver()
        let service = makeService(driver: driver, config: twoSpaceScopedConfig())

        let result = try service.dryRun(layoutName: "scopedWork", spaceID: 2)

        let slots = result.plan.compactMap(\.slot)
        XCTAssertEqual(slots, [2, 2, 2, 2])
    }



    func testFullscreenExcludedIsSkipNotSoftError() throws {
        let driver = FakeArrangeDriver()
        let fullscreen = sampleWindow(bundleID: "com.example.app", isFullscreen: true)
        driver.windowsQueue = [[fullscreen]]

        let service = makeService(driver: driver)
        let result = try service.execute(layoutName: "work")

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.softErrors.isEmpty)
        XCTAssertTrue(result.skipped.contains(where: { $0.reason == "fullscreenExcluded" }))
    }

    func testInitialFocusUnavailableIsWarningOnly() throws {
        let config = baseConfig(initialFocusSlot: 9)
        let context = ArrangeContext(config: config, supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let driver = FakeArrangeDriver()
        driver.backendAvailableResult = (true, nil)
        driver.windowsQueue = [[sampleWindow(bundleID: "com.example.app")]]

        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        let service = ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)

        let result = try service.execute(layoutName: "work")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.warnings.contains(where: { $0.code == "initial.focus.unavailable" }))
    }

    func testDryRunIncludesNoWindowMatched() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = [[]]
        let service = makeService(driver: driver)

        let result = try service.dryRun(layoutName: "work")
        XCTAssertTrue(result.skipped.contains(where: { $0.reason == "noWindowMatched" }))
    }

    func testDryRunDoesNotMutateRuntimeState() throws {
        let driver = FakeArrangeDriver()
        let config = baseConfig(initialFocusSlot: 1)
        let context = ArrangeContext(config: config, supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        let initialSlots = [
            SlotEntry(
                slot: 9,
                source: .window,
                bundleID: "com.example.persisted",
                title: "Persisted",
                spaceID: 9,
                displayID: "display-1",
                windowID: 999,
            ),
        ]
        store.save(slots: initialSlots)

        let service = ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)
        _ = try service.dryRun(layoutName: "work")

        XCTAssertEqual(store.load().slots, initialSlots)
    }

    func testDryRunPlanOrderPerWindowAndInitialFocusStep() throws {
        let driver = FakeArrangeDriver()
        let config = baseConfig(initialFocusSlot: 1, launch: true)
        let service = makeService(driver: driver, config: config)

        let result = try service.dryRun(layoutName: "work")
        let actions = result.plan.map(\.action)
        XCTAssertEqual(actions, ["launch", "waitWindow", "moveSpace", "setFrame", "registerSlot", "focusInitial"])
    }

    func testMonitorSecondaryPrefersMonitorsSecondaryID() throws {
        let driver = FakeArrangeDriver()
        driver.displaysResponse = [
            display(id: "display-primary", isPrimary: true, frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
            display(id: "display-a", isPrimary: false, frame: CGRect(x: 2000, y: 0, width: 1000, height: 700)),
            display(id: "display-z", isPrimary: false, frame: CGRect(x: 4000, y: 0, width: 900, height: 600)),
        ]

        let config = configForSecondaryMonitor(
            monitorID: "display-z",
            displayDefinition: DisplayDefinition(monitor: .secondary, id: nil, width: nil, height: nil)
        )

        let service = makeService(driver: driver, config: config)
        let result = try service.dryRun(layoutName: "work")
        let frame = try XCTUnwrap(result.plan.first(where: { $0.action == "setFrame" })?.frame)
        XCTAssertEqual(frame.width, 900, accuracy: 0.01)
        XCTAssertEqual(frame.height, 600, accuracy: 0.01)
    }

    func testMonitorSecondaryWithoutIDUsesDisplayIDAscendingFirstNonPrimary() throws {
        let driver = FakeArrangeDriver()
        driver.displaysResponse = [
            display(id: "display-primary", isPrimary: true, frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
            display(id: "display-z", isPrimary: false, frame: CGRect(x: 2000, y: 0, width: 1000, height: 700)),
            display(id: "display-a", isPrimary: false, frame: CGRect(x: 4000, y: 0, width: 900, height: 600)),
        ]

        let config = configForSecondaryMonitor(
            monitorID: nil,
            displayDefinition: DisplayDefinition(monitor: .secondary, id: nil, width: nil, height: nil)
        )

        let service = makeService(driver: driver, config: config)
        let result = try service.dryRun(layoutName: "work")
        let frame = try XCTUnwrap(result.plan.first(where: { $0.action == "setFrame" })?.frame)
        XCTAssertEqual(frame.width, 900, accuracy: 0.01)
        XCTAssertEqual(frame.height, 600, accuracy: 0.01)
    }

    func testArrangeSameSpaceIDUsesFirstMatchingCandidateOnly() throws {
        let driver = FakeArrangeDriver()
        driver.displaysResponse = [
            display(id: "display-primary", isPrimary: true, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        ]

        let service = makeService(driver: driver, config: firstMatchConfig())
        let dryRun = try service.dryRun(layoutName: "work")

        let setFrameSlots = dryRun.plan
            .filter { $0.action == "setFrame" }
            .compactMap(\.slot)
        XCTAssertEqual(setFrameSlots, [1])
    }



    func testArrangeExitCodePrioritizesHardErrorOverExistingSoftErrors() throws {
        let driver = FakeArrangeDriver()
        driver.displaysResponse = [
            display(id: "display-primary", isPrimary: true, frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
        ]
        driver.windowsQueue = [
            [], // first window wait attempt #1
            [], // first window wait attempt #2 -> soft 40
            [WindowSnapshot(
                windowID: 7101,
                bundleID: "com.example.second",
                pid: 7101,
                title: "Second",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 500, height: 300),
                spaceID: 2,
                displayID: "display-primary",
                isFullscreen: false,
                frontIndex: 0
            )],
        ]
        driver.moveWindowToSpaceResult = false

        let service = makeService(driver: driver, config: twoWindowPriorityConfig())
        let result = try service.execute(layoutName: "priorityWork")

        XCTAssertEqual(result.result, "failed")
        XCTAssertEqual(result.exitCode, ErrorCode.spaceMoveFailed.rawValue)
        XCTAssertEqual(result.hardErrors.first?.code, ErrorCode.spaceMoveFailed.rawValue)
        XCTAssertEqual(result.softErrors.first?.code, ErrorCode.targetWindowNotFound.rawValue)
    }

    func testArrangeQualityReportMeetsAcceptanceCriteriaAndWritesArtifact() throws {
        let driver = FakeArrangeDriver()
        driver.displaysResponse = [
            display(id: "display-primary", isPrimary: true, frame: CGRect(x: 0, y: 0, width: 1200, height: 800)),
        ]
        driver.windowsQueue = Array(repeating: qualityWindows(), count: 12)

        let config = qualityConfig()
        let service = makeService(driver: driver, config: config)

        let execution = try service.execute(layoutName: "qualityWork")
        XCTAssertEqual(execution.exitCode, 0)

        let dryRun = try service.dryRun(layoutName: "qualityWork")
        let expectedFrames = Dictionary(
            uniqueKeysWithValues: dryRun.plan.compactMap { item -> (Int, ResolvedFrame)? in
                guard item.action == "setFrame",
                      let slot = item.slot,
                      let frame = item.frame
                else {
                    return nil
                }
                return (slot, frame)
            }
        )

        let slot1 = try XCTUnwrap(expectedFrames[1])
        let slot2 = try XCTUnwrap(expectedFrames[2])
        let measurements = [
            ArrangeQualityMeasurement(
                slot: 1,
                expectedFrame: slot1,
                actualFrame: ResolvedFrame(
                    x: slot1.x + 1.5,
                    y: slot1.y + 0.5,
                    width: slot1.width - 1.0,
                    height: slot1.height
                )
            ),
            ArrangeQualityMeasurement(slot: 2, expectedFrame: slot2, actualFrame: slot2),
        ]

        let report = ArrangeQualityEvaluator.buildReport(
            layout: "qualityWork",
            execution: execution,
            measurements: measurements,
            displayMismatchActual: 1,
            executedAt: "2026-03-04T12:00:00.000Z"
        )

        XCTAssertEqual(report.expectedSlots, 2)
        XCTAssertEqual(report.matchedSlots, 2)
        XCTAssertEqual(report.slotMatchRate, 100)
        XCTAssertLessThanOrEqual(report.frameDiffMaxPt, 2.0)
        XCTAssertEqual(report.displayMismatchExpected, 1)
        XCTAssertEqual(report.displayMismatchActual, 1)

        let reportURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("artifacts/arrange-quality-report.json")
        try writePrettyJSON(report, to: reportURL)

        let persistedData = try Data(contentsOf: reportURL)
        let persisted = try JSONDecoder().decode(ArrangeQualityReport.self, from: persistedData)
        XCTAssertEqual(persisted, report)
    }

    func testPartialArrangePreservesExistingSlotStateForUnresolvedSlots() throws {
        let driver = FakeArrangeDriver()
        let secondWindow = sampleWindow(windowID: 20, bundleID: "com.example.second", frontIndex: 1)
        driver.windowsQueue = [
            [],
            [secondWindow],
            [secondWindow],
        ]

        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        let initialSlots = [
            SlotEntry(
                slot: 1,
                source: .window,
                bundleID: "com.example.first",
                title: "First Persisted",
                spaceID: 1,
                displayID: "display-1",
                windowID: 101
            ),
            SlotEntry(
                slot: 2,
                source: .window,
                bundleID: "com.example.second",
                title: "Second Persisted",
                spaceID: 1,
                displayID: "display-1",
                windowID: 202
            ),
        ]
        store.save(slots: initialSlots)

        let context = ArrangeContext(config: twoWindowPriorityConfig(), supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let service = ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)

        let result = try service.execute(layoutName: "priorityWork")

        XCTAssertEqual(result.result, "partial")
        XCTAssertEqual(result.exitCode, ErrorCode.partialSuccess.rawValue)

        let persisted = store.load().slots
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.first(where: { $0.slot == 1 })?.windowID, 101)
        XCTAssertEqual(persisted.first(where: { $0.slot == 1 })?.title, "First Persisted")
        XCTAssertEqual(persisted.first(where: { $0.slot == 2 })?.windowID, 20)
        XCTAssertEqual(persisted.first(where: { $0.slot == 2 })?.bundleID, "com.example.second")
    }

    func testScopedArrangePreservesRuntimeStateOutsideRequestedSpace() throws {
        let driver = FakeArrangeDriver()
        driver.windowsQueue = Array(repeating: [
            sampleWindow(windowID: 20, bundleID: "com.example.second", frontIndex: 1, spaceID: 2),
        ], count: 4)
        driver.allSpacesWindowsQueue = driver.windowsQueue

        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        let initialSlots = [
            SlotEntry(
                slot: 1,
                source: .window,
                bundleID: "com.example.first",
                title: "First Persisted",
                spaceID: 1,
                displayID: "display-1",
                windowID: 101
            ),
            SlotEntry(
                slot: 2,
                source: .window,
                bundleID: "com.example.second",
                title: "Second Persisted",
                spaceID: 2,
                displayID: "display-1",
                windowID: 202
            ),
        ]
        store.save(slots: initialSlots)

        let context = ArrangeContext(config: twoSpaceScopedConfig(), supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let service = ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)

        let result = try service.execute(layoutName: "scopedWork", spaceID: 2)

        XCTAssertEqual(result.exitCode, 0)

        let persisted = store.load().slots
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted.first(where: { $0.slot == 1 })?.windowID, 101)
        XCTAssertEqual(persisted.first(where: { $0.slot == 2 })?.windowID, 20)
        XCTAssertEqual(persisted.first(where: { $0.slot == 2 })?.spaceID, 2)
    }

    func testStateOnlyPersistsLayoutWithoutRunningArrangeOperations() throws {
        let driver = FakeArrangeDriver()
        driver.accessibility = false
        driver.backendAvailableResult = (false, "unsupportedOSBuild")

        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        let context = ArrangeContext(config: baseConfig(initialFocusSlot: 1), supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let service = ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)

        let result = try service.execute(layoutName: "work", stateOnly: true)

        XCTAssertEqual(result.result, "success")
        XCTAssertEqual(result.exitCode, ErrorCode.success.rawValue)
        XCTAssertTrue(result.warnings.contains(where: { $0.code == "arrange.stateOnly" }))
        XCTAssertTrue(driver.launchInvocations.isEmpty)
        XCTAssertTrue(driver.moveWindowToSpaceCalls.isEmpty)
        XCTAssertTrue(driver.setFrameInvocations.isEmpty)
        XCTAssertTrue(driver.activateInvocations.isEmpty)
        XCTAssertTrue(driver.sleepCalls.isEmpty)

        let persisted = store.load().slots
        XCTAssertEqual(
            persisted,
            [
                SlotEntry(
                    slot: 1,
                    source: .window,
                    bundleID: "com.example.app",
                    title: "com.example.app",
                    spaceID: 1,
                    displayID: nil,
                    windowID: nil
                ),
            ]
        )
    }



    private func makeService(driver: FakeArrangeDriver) -> ArrangeService {
        makeService(driver: driver, config: baseConfig(initialFocusSlot: 1))
    }

    private func makeService(driver: FakeArrangeDriver, config: ShitsuraeConfig) -> ArrangeService {
        let context = ArrangeContext(config: config, supportedBuildCatalogURL: URL(fileURLWithPath: "/tmp/missing.json"))
        let logger = ShitsuraeLogger(logFileURL: tempFile("arrange-log.jsonl"))
        let store = RuntimeStateStore(stateFileURL: tempFile("state.json"))
        return ArrangeService(context: context, logger: logger, stateStore: store, driver: driver)
    }

    private func baseConfig(
        initialFocusSlot: Int,
        launch: Bool = false,
        windowMatch: WindowMatchRule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: nil,
            index: nil
        ),
        executionPolicy: ExecutionPolicy = ExecutionPolicy()
    ) -> ShitsuraeConfig {
        let window = WindowDefinition(
            source: .window,
            match: windowMatch,
            slot: 1,
            launch: launch,
            frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
        )

        let layout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: initialFocusSlot),
            spaces: [
                SpaceDefinition(spaceID: 1, display: nil, windows: [window]),
            ]
        )

        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: executionPolicy,
            monitors: nil,
            layouts: ["work": layout],
            shortcuts: nil
        )
    }

    private func configForSecondaryMonitor(monitorID: String?, displayDefinition: DisplayDefinition?) -> ShitsuraeConfig {
        let window = WindowDefinition(
            source: .window,
            match: WindowMatchRule(bundleID: "com.example.app", title: nil, role: nil, subrole: nil, profile: nil, excludeTitleRegex: nil, index: nil),
            slot: 1,
            launch: false,
            frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("100%"), height: .expression("100%"))
        )

        let layout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 1),
            spaces: [
                SpaceDefinition(spaceID: 1, display: displayDefinition, windows: [window]),
            ]
        )

        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: ExecutionPolicy(),
            monitors: MonitorsDefinition(
                primary: nil,
                secondary: MonitorTargetDefinition(id: monitorID)
            ),
            layouts: ["work": layout],
            shortcuts: nil
        )
    }



    private func firstMatchConfig() -> ShitsuraeConfig {
        let firstCandidate = SpaceDefinition(
            spaceID: 1,
            display: DisplayDefinition(monitor: .primary, id: nil, width: 2000, height: nil),
            windows: [
                WindowDefinition(
                    source: .window,
                    match: WindowMatchRule(bundleID: "com.example.first", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                    slot: 9,
                    launch: false,
                    frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("100%"), height: .expression("100%"))
                ),
            ]
        )

        let secondCandidate = SpaceDefinition(
            spaceID: 1,
            display: DisplayDefinition(monitor: .primary, id: nil, width: 1440, height: nil),
            windows: [
                WindowDefinition(
                    source: .window,
                    match: WindowMatchRule(bundleID: "com.example.second", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                    slot: 1,
                    launch: false,
                    frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
                ),
            ]
        )

        let thirdCandidate = SpaceDefinition(
            spaceID: 1,
            display: DisplayDefinition(monitor: .primary, id: nil, width: 1440, height: nil),
            windows: [
                WindowDefinition(
                    source: .window,
                    match: WindowMatchRule(bundleID: "com.example.third", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                    slot: 2,
                    launch: false,
                    frame: FrameDefinition(x: .expression("50%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
                ),
            ]
        )

        let layout = LayoutDefinition(initialFocus: nil, spaces: [firstCandidate, secondCandidate, thirdCandidate])
        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: ExecutionPolicy(),
            monitors: nil,
            layouts: ["work": layout],
            shortcuts: nil
        )
    }



    private func twoWindowPriorityConfig() -> ShitsuraeConfig {
        let windows = [
            WindowDefinition(
                source: .window,
                match: WindowMatchRule(bundleID: "com.example.first", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                slot: 1,
                launch: false,
                frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
            ),
            WindowDefinition(
                source: .window,
                match: WindowMatchRule(bundleID: "com.example.second", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                slot: 2,
                launch: false,
                frame: FrameDefinition(x: .expression("50%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
            ),
        ]

        let layout = LayoutDefinition(initialFocus: nil, spaces: [SpaceDefinition(spaceID: 1, display: nil, windows: windows)])
        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: ExecutionPolicy(),
            monitors: nil,
            layouts: ["priorityWork": layout],
            shortcuts: nil
        )
    }

    private func qualityConfig() -> ShitsuraeConfig {
        let primaryWindows = [
            WindowDefinition(
                source: .window,
                match: WindowMatchRule(bundleID: "com.example.q1", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                slot: 1,
                launch: false,
                frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
            ),
            WindowDefinition(
                source: .window,
                match: WindowMatchRule(bundleID: "com.example.q2", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                slot: 2,
                launch: false,
                frame: FrameDefinition(x: .expression("50%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
            ),
        ]

        let displayMismatchSpace = SpaceDefinition(
            spaceID: 2,
            display: DisplayDefinition(monitor: nil, id: "missing-display", width: nil, height: nil),
            windows: [
                WindowDefinition(
                    source: .window,
                    match: WindowMatchRule(bundleID: "com.example.skip", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
                    slot: 3,
                    launch: false,
                    frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("100%"), height: .expression("100%"))
                ),
            ]
        )

        let layout = LayoutDefinition(
            initialFocus: InitialFocusDefinition(slot: 1),
            spaces: [
                SpaceDefinition(
                    spaceID: 1,
                    display: DisplayDefinition(monitor: .primary, id: nil, width: nil, height: nil),
                    windows: primaryWindows
                ),
                displayMismatchSpace,
            ]
        )

        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: ExecutionPolicy(),
            monitors: nil,
            layouts: ["qualityWork": layout],
            shortcuts: nil
        )
    }

    private func twoSpaceScopedConfig() -> ShitsuraeConfig {
        let first = WindowDefinition(
            source: .window,
            match: WindowMatchRule(bundleID: "com.example.first", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
            slot: 1,
            launch: false,
            frame: FrameDefinition(x: .expression("0%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
        )
        let second = WindowDefinition(
            source: .window,
            match: WindowMatchRule(bundleID: "com.example.second", title: nil, role: nil, subrole: nil, excludeTitleRegex: nil, index: nil),
            slot: 2,
            launch: false,
            frame: FrameDefinition(x: .expression("50%"), y: .expression("0%"), width: .expression("50%"), height: .expression("100%"))
        )

        return ShitsuraeConfig(
            ignore: nil,
            overlay: nil,
            executionPolicy: ExecutionPolicy(),
            monitors: nil,
            layouts: [
                "scopedWork": LayoutDefinition(
                    initialFocus: nil,
                    spaces: [
                        SpaceDefinition(spaceID: 1, display: nil, windows: [first]),
                        SpaceDefinition(spaceID: 2, display: nil, windows: [second]),
                    ]
                ),
            ],
            shortcuts: nil
        )
    }

    private func qualityWindows() -> [WindowSnapshot] {
        [
            WindowSnapshot(
                windowID: 101,
                bundleID: "com.example.q1",
                pid: 101,
                title: "Q1",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
                spaceID: 1,
                displayID: "display-primary",
                isFullscreen: false,
                frontIndex: 0
            ),
            WindowSnapshot(
                windowID: 102,
                bundleID: "com.example.q2",
                pid: 102,
                title: "Q2",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 200, y: 0, width: 100, height: 100),
                spaceID: 1,
                displayID: "display-primary",
                isFullscreen: false,
                frontIndex: 1
            ),
        ]
    }





    private func perfWindows() -> [WindowSnapshot] {
        var windows: [WindowSnapshot] = [
            WindowSnapshot(
                windowID: 9001,
                bundleID: "com.apple.Terminal",
                pid: 9001,
                title: "Terminal",
                role: "AXWindow",
                subrole: nil,
                minimized: false,
                hidden: false,
                frame: ResolvedFrame(x: 0, y: 0, width: 400, height: 300),
                spaceID: 1,
                displayID: "display-primary",
                isFullscreen: false,
                frontIndex: 0
            ),
        ]

        for slot in 1 ... 10 {
            windows.append(
                WindowSnapshot(
                    windowID: UInt32(9100 + slot),
                    bundleID: "com.example.perf\(slot)",
                    pid: 9100 + slot,
                    title: "Perf\(slot)",
                    role: "AXWindow",
                    subrole: nil,
                    minimized: false,
                    hidden: false,
                    frame: ResolvedFrame(x: Double(slot * 10), y: 0, width: 120, height: 100),
                    spaceID: 1,
                    displayID: "display-primary",
                    isFullscreen: false,
                    frontIndex: slot
                )
            )
        }

        return windows
    }

    private func percentile95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = Int(ceil(Double(sorted.count) * 0.95)) - 1
        return sorted[max(0, min(index, sorted.count - 1))]
    }

    private func writePrettyJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try JSONEncoder.pretty.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func display(id: String, isPrimary: Bool, frame: CGRect) -> DisplayInfo {
        DisplayInfo(
            id: id,
            width: Int(frame.width),
            height: Int(frame.height),
            scale: 1,
            isPrimary: isPrimary,
            frame: frame,
            visibleFrame: frame
        )
    }

    private func sampleWindow(
        windowID: UInt32 = 10,
        bundleID: String,
        isFullscreen: Bool = false,
        frontIndex: Int = 0,
        spaceID: Int? = 1,
        profileDirectory: String? = nil
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: bundleID,
            pid: 999,
            title: "Main",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: spaceID,
            displayID: "display-1",
            profileDirectory: profileDirectory,
            isFullscreen: isFullscreen,
            frontIndex: frontIndex
        )
    }

    private func tempFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests")
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

private final class FakeArrangeDriver: ArrangeDriver {
    var displaysResponse: [DisplayInfo] = [
        DisplayInfo(
            id: "display-1",
            width: 2560,
            height: 1440,
            scale: 2,
            isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860)
        ),
    ]
    var windowsQueue: [[WindowSnapshot]] = []
    var allSpacesWindowsQueue: [[WindowSnapshot]] = []
    var launchResults: [String: Bool] = [:]
    var launchInvocations: [ApplicationLaunchRequest] = []
    var moveWindowToSpaceResult: Bool = true
    var autoUpdateWindowSpaceOnMove: Bool = true
    var moveWindowToSpaceCalls: [(windowID: UInt32, bundleID: String, displayID: String?, spaceID: Int, spacesMode: SpacesMode, method: SpaceMoveMethod)] = []
    var setFrameResults: [Bool] = [true]
    var autoUpdateWindowFrameOnSet: Bool = true
    var setFrameInvocations: [(windowID: UInt32, bundleID: String, frame: ResolvedFrame)] = []
    var activateResults: [String: Bool] = [:]
    var activateInvocations: [String] = []
    var accessibility: Bool = true
    var spacesMode: SpacesMode? = .perDisplay
    var backendAvailableResult: (Bool, String?) = (true, nil)
    var sleepCalls: [Int] = []

    private var queryCount = 0
    private var setFrameCount = 0

    func displays() -> [DisplayInfo] {
        displaysResponse
    }

    func queryWindows() -> [WindowSnapshot] {
        if windowsQueue.isEmpty {
            return []
        }

        let index = min(queryCount, windowsQueue.count - 1)
        queryCount += 1
        return windowsQueue[index]
    }

    func queryWindowsOnAllSpaces() -> [WindowSnapshot] {
        if allSpacesWindowsQueue.isEmpty {
            return queryWindows()
        }

        let index = min(queryCount, allSpacesWindowsQueue.count - 1)
        queryCount += 1
        return allSpacesWindowsQueue[index]
    }

    func launch(request: ApplicationLaunchRequest) -> Bool {
        launchInvocations.append(request)
        return launchResults[request.bundleID] ?? true
    }

    func moveWindowToSpace(
        windowID: UInt32,
        bundleID: String,
        displayID: String?,
        spaceID: Int,
        spacesMode: SpacesMode,
        method: SpaceMoveMethod
    ) -> Bool {
        moveWindowToSpaceCalls.append(
            (
                windowID: windowID,
                bundleID: bundleID,
                displayID: displayID,
                spaceID: spaceID,
                spacesMode: spacesMode,
                method: method
            )
        )
        if moveWindowToSpaceResult, autoUpdateWindowSpaceOnMove {
            windowsQueue = windowsQueue.map { update($0, windowID: windowID) { snapshot in
                WindowSnapshot(
                    windowID: snapshot.windowID,
                    bundleID: snapshot.bundleID,
                    pid: snapshot.pid,
                    title: snapshot.title,
                    role: snapshot.role,
                    subrole: snapshot.subrole,
                    minimized: snapshot.minimized,
                    hidden: snapshot.hidden,
                    frame: snapshot.frame,
                    spaceID: spaceID,
                    displayID: snapshot.displayID,
                    isFullscreen: snapshot.isFullscreen,
                    frontIndex: snapshot.frontIndex
                )
            } }
            allSpacesWindowsQueue = allSpacesWindowsQueue.map { update($0, windowID: windowID) { snapshot in
                WindowSnapshot(
                    windowID: snapshot.windowID,
                    bundleID: snapshot.bundleID,
                    pid: snapshot.pid,
                    title: snapshot.title,
                    role: snapshot.role,
                    subrole: snapshot.subrole,
                    minimized: snapshot.minimized,
                    hidden: snapshot.hidden,
                    frame: snapshot.frame,
                    spaceID: spaceID,
                    displayID: snapshot.displayID,
                    isFullscreen: snapshot.isFullscreen,
                    frontIndex: snapshot.frontIndex
                )
            } }
        }
        return moveWindowToSpaceResult
    }

    func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool {
        setFrameInvocations.append((windowID: windowID, bundleID: bundleID, frame: frame))
        let index = min(setFrameCount, setFrameResults.count - 1)
        setFrameCount += 1
        let result = setFrameResults[index]
        if result, autoUpdateWindowFrameOnSet {
            windowsQueue = windowsQueue.map { update($0, windowID: windowID) { snapshot in
                WindowSnapshot(
                    windowID: snapshot.windowID,
                    bundleID: snapshot.bundleID,
                    pid: snapshot.pid,
                    title: snapshot.title,
                    role: snapshot.role,
                    subrole: snapshot.subrole,
                    minimized: snapshot.minimized,
                    hidden: snapshot.hidden,
                    frame: frame,
                    spaceID: snapshot.spaceID,
                    displayID: snapshot.displayID,
                    isFullscreen: snapshot.isFullscreen,
                    frontIndex: snapshot.frontIndex
                )
            } }
            allSpacesWindowsQueue = allSpacesWindowsQueue.map { update($0, windowID: windowID) { snapshot in
                WindowSnapshot(
                    windowID: snapshot.windowID,
                    bundleID: snapshot.bundleID,
                    pid: snapshot.pid,
                    title: snapshot.title,
                    role: snapshot.role,
                    subrole: snapshot.subrole,
                    minimized: snapshot.minimized,
                    hidden: snapshot.hidden,
                    frame: frame,
                    spaceID: snapshot.spaceID,
                    displayID: snapshot.displayID,
                    isFullscreen: snapshot.isFullscreen,
                    frontIndex: snapshot.frontIndex
                )
            } }
        }
        return result
    }

    func activate(bundleID: String) -> Bool {
        activateInvocations.append(bundleID)
        return activateResults[bundleID] ?? true
    }

    func sleep(milliseconds: Int) {
        sleepCalls.append(milliseconds)
    }

    func accessibilityGranted() -> Bool {
        accessibility
    }

    func actualSpacesMode() -> SpacesMode? {
        spacesMode
    }

    func backendAvailable(catalogURL _: URL) -> (Bool, String?) {
        backendAvailableResult
    }

    private func update(
        _ snapshots: [WindowSnapshot],
        windowID: UInt32,
        transform: (WindowSnapshot) -> WindowSnapshot
    ) -> [WindowSnapshot] {
        snapshots.map { snapshot in
            snapshot.windowID == windowID ? transform(snapshot) : snapshot
        }
    }
}
