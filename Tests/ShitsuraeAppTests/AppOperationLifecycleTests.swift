import CoreGraphics
import Foundation
import ShitsuraeCore
import ShitsuraeTestSupport
import Testing
@testable import Shitsurae

/// Never delegates to live AX, never creates an app/window/socket or starts
/// the production app's permission/server/hotkey/notification lifecycle.
private final class LifecycleWindowControl: WindowControl, @unchecked Sendable {
    private let windows: [WindowSnapshot]
    init(windows: [WindowSnapshot] = []) { self.windows = windows }
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var shouldBlockInventory = false
    private var inventoryBlocked = false
    var isInventoryBlocked: Bool { lock.lock(); defer { lock.unlock() }; return inventoryBlocked }
    func blockNextInventory() { lock.lock(); shouldBlockInventory = true; lock.unlock() }
    func releaseInventory() { release.signal() }
    func windowInventory() -> WindowInventory {
        lock.lock()
        let blocking = shouldBlockInventory
        shouldBlockInventory = false
        inventoryBlocked = blocking
        lock.unlock()
        if blocking {
            release.wait()
            lock.lock(); inventoryBlocked = false; lock.unlock()
        }
        return .available(windows)
    }
    func listWindows() -> [WindowSnapshot] { windows }
    func listAllWindows() -> [WindowSnapshot] { windows }
    func focusedWindow() -> WindowSnapshot? { nil }
    func displays() -> [DisplayInfo] {
        [DisplayInfo(id: "primary", width: 2880, height: 1800, scale: 2, isPrimary: true,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
    }
    func setWindowFrame(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, frame: ResolvedFrame) -> WindowGeometryMutationResult { .rejected }
    func setWindowPosition(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, position: CGPoint) -> WindowGeometryMutationResult { .rejected }
    func setWindowMinimized(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, minimized: Bool) -> WindowInteractionResult { .failed }
    func focusWindow(windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String) -> WindowInteractionResult { .failed }
    func activateApplication(pid: Int, processStartTime: UInt64, bundleID: String) -> Bool { false }
    func launchApplication(request: ApplicationLaunchRequest) -> Bool { false }
}

@MainActor
private final class ManualArrangeOperationMonitor: ArrangeOperationMonitoring {
    private var callback: (@MainActor @Sendable () -> Void)?
    func start(interval: Duration, tick: @escaping @MainActor @Sendable () -> Void) { callback = tick }
    func stop() { callback = nil }
    func tick() { callback?() }
}

@Suite("Application operation lifecycle")
@MainActor
struct AppOperationLifecycleTests {
    private let yaml = """
    layouts:
      main:
        spaces:
          - spaceID: 1
            windows: []
    layoutSets:
      home:
        layouts: [main]
    """
    private func fixture(state: RuntimeState = RuntimeState(), configText: String? = nil,
        control: LifecycleWindowControl = LifecycleWindowControl(),
        monitor: (any ArrangeOperationMonitoring)? = nil, useLiveStatusProbes: Bool = false
    ) throws -> (AppModel, RuntimeStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shitsurae-r2-app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let configText { try Data(configText.utf8).write(to: directory.appendingPathComponent("config.yml")) }
        let logger = ShitsuraeLogger(logFileURL: directory.appendingPathComponent("test.log"))
        let manager = ConfigManager(directoryURL: directory, logger: logger)
        _ = manager.reload(trigger: "test")
        let store = RuntimeStateStore(stateFileURL: directory.appendingPathComponent("runtime-state.json"))
        try store.saveStrict(state: state)
        let engine = try VirtualSpaceEngine(store: store, control: control, logger: logger,
            operationCoordinator: ArrangeOperationCoordinator())
        if useLiveStatusProbes {
            // Omit the provider argument to exercise both production defaults.
            return (AppModel(engine: engine, configManager: manager, logger: logger), store, directory)
        }
        let displayInputs = control.displays()
        let probes = StatusProbes(accessibilityGranted: { true }, screenRecordingGranted: { false },
            displays: { displayInputs })
        return (AppModel(engine: engine, configManager: manager, logger: logger,
            statusProbes: probes, arrangeOperationMonitor: monitor), store, directory)
    }
    private func admittedGenerations(_ model: AppModel) -> [Int] {
        ((try? String(contentsOf: model.logger.logFileURL, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["event"] as? String == "app.displayChange.admitted" else { return nil }
            return object["generation"] as? Int
        }
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func drainWork(_ model: AppModel) async throws {
        // Bounded state arrival, followed by a FIFO file-write completion.
        try #require(await eventually { !model.hasPendingArrangeOperationWork })
        await model.logger.flush()
    }

    @Test func actualCLIRouterLeaseCompletionDrainsLatestDisplayEventWithoutAView() async throws {
        let control = LifecycleWindowControl()
        let monitor = ManualArrangeOperationMonitor()
        let (model, _, directory) = try fixture(configText: yaml, control: control, monitor: monitor)
        defer { control.releaseInventory(); model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        control.blockNextInventory()
        var request = CommandRequest(command: "arrangeSet")
        request.setName = "home"
        request.requestID = "actual-cli-route"
        let data = try JSONEncoder().encode(request)
        let router = model.router
        let cli = Task.detached(executorPreference: BlockingTestTaskExecutor()) {
            await router.handle(requestData: data)
        }
        try #require(await eventually { control.isInventoryBlocked })
        model.startArrangeOperationMonitoring(interval: .milliseconds(10))
        model.handleDisplayChange(); model.handleDisplayChange(); model.handleDisplayChange()
        for _ in 0..<3 { monitor.tick(); try await drainWork(model) }
        #expect(control.isInventoryBlocked && admittedGenerations(model).isEmpty)
        #expect(model.engine.operationCoordinator.status().active?.requestID == "actual-cli-route")
        control.releaseInventory()
        let response = try JSONDecoder().decode(CommandResponseProbe.self, from: await cli.value)
        #expect(response.exitCode == 54)
        monitor.tick()
        try await drainWork(model)
        #expect(admittedGenerations(model) == [3] && model.engine.operationCoordinator.status().active == nil)
        #expect(model.engine.operationCoordinator.status().lastOutcome?.operation == .displayChange)
        for _ in 0..<3 { monitor.tick(); try await drainWork(model) }
        #expect(admittedGenerations(model) == [3])
    }

    @Test(arguments: ["arrange", "arrangeRecover"])
    func actualCLIRouterPartialReasonReachesAppModelPollWithoutManualFinish(command: String) async throws {
        let blocked = WindowSnapshot(windowID: 2, bundleID: "Extra", pid: 20, processStartTime: 20_000_000,
            title: "Blocked", role: "AXWindow", subrole: "AXStandardWindow", modal: false,
            geometryBlocked: true, isAXBacked: true, minimized: false, hidden: false,
            frame: ResolvedFrame(x: 4000, y: 50, width: 500, height: 400), displayID: "primary", isFullscreen: false, frontIndex: 0)
        var adopted = SlotEntry.makeEntry(layoutName: "main", spaceID: 2,
            definition: WindowDefinition(match: WindowMatchRule(bundleID: "Extra"), slot: 7, launch: false)).bound(to: blocked)
        adopted.origin = .adopted
        adopted.layoutSpaceID = nil
        adopted.visibilityState = .hiddenOffscreen
        adopted.lastHiddenFrame = blocked.frame
        adopted.lastVisibleFrame = ResolvedFrame(x: 30, y: 30, width: 500, height: 400)
        let journal = command == "arrangeRecover" ? PendingLayoutTransition(requestID: "old", scopeKind: .local, phase: .postcommit,
            sourceLayoutNames: ["main"], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil,
            definitionDigest: "old", topologyDigest: "old") : nil
        let state = RuntimeState(pendingLayoutTransition: journal,
            activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 2)], slots: [adopted])
        let (model, store, directory) = try fixture(state: state, configText: yaml,
            control: LifecycleWindowControl(windows: [blocked]))
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        model.startArrangeOperationMonitoring(interval: .milliseconds(10))
        var request = CommandRequest(command: command)
        request.requestID = "cli-reason"
        if command == "arrange" { request.layouts = ["main"] }
        let response = await model.router.handle(requestData: try JSONEncoder().encode(request))
        #expect(try JSONDecoder().decode(CommandResponseProbe.self, from: response).exitCode == 51)
        let reason = command == "arrange" ? "retainedAdoptedGeometryBlocked" : "1 windows still need recovery"
        let outcome = try #require(model.engine.operationCoordinator.status().lastOutcome)
        #expect(outcome.result == "partial" && outcome.exitCode == 51 && outcome.detail?.contains(reason) == true)
        #expect(await eventually {
            if case let .partial(_, message) = model.actionStatus { return message.contains(reason) }
            return false
        })
        try await drainWork(model)
        let diagnostics = try #require(model.diagnostics)
        #expect(model.accessibilityGranted && !model.screenRecordingGranted)
        #expect(diagnostics.permissions.accessibility && !diagnostics.permissions.screenRecording)
        #expect(model.displays.map(\.id) == ["primary"])
        #expect(diagnostics.displays == model.displays.map(DisplaySummaryJSON.init(display:)))
        #expect(model.runtimeState == (await model.engine.currentState))
        #expect(model.runtimeState.slots.count == 1 && diagnostics.state.slotCount == 1)
        #expect(diagnostics.state.revision == model.runtimeState.revision)
        let message = try #require(model.lastActionMessage)
        #expect(message.contains(reason) && !message.contains("exitCode=51"))
        let saved = try store.loadStrict()
        let kept = try #require(saved.slots.first { $0.id == adopted.id })
        #expect(kept.boundIdentity == adopted.boundIdentity && kept.lastVisibleFrame == adopted.lastVisibleFrame
            && kept.lastHiddenFrame == adopted.lastHiddenFrame && kept.visibilityState == .hiddenOffscreen)
        #expect(saved.pendingLayoutTransition != nil)
    }

    @Test(arguments: ["configuration", "invalidReload", "stopped", "shutdown"])
    func obsoleteDisplayEventDoesNotRunAfterLifecycleInvalidation(reason: String) async throws {
        let monitor = ManualArrangeOperationMonitor()
        let (model, _, directory) = try fixture(configText: yaml, monitor: monitor)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        let coordinator = model.engine.operationCoordinator
        let token = try coordinator.tryAdmit(requestID: "cli-lease", operation: .arrangeSet)
        model.startArrangeOperationMonitoring(interval: .milliseconds(10))
        model.handleDisplayChange(); model.handleDisplayChange()
        switch reason {
        case "configuration": model.handleConfigChange()
        case "invalidReload":
            try Data("layouts: invalid".utf8).write(to: directory.appendingPathComponent("config.yml"))
            #expect(!model.configManager.reload(trigger: "test"))
            model.handleConfigChange()
            #expect(!model.configErrors.isEmpty)
        case "stopped": model.stopArrangeOperationMonitoring()
        default:
            var completed = false
            model.shutdown { completed = true }
            try #require(await eventually { completed })
        }
        coordinator.finish(token: token, result: "failed", exitCode: 54)
        model.handleDisplayChange() // A new event is also forbidden if invalid/stopped/shutdown.
        monitor.tick()
        try await drainWork(model)
        if reason == "configuration" { // A new event with a valid new config is legitimate.
            #expect(admittedGenerations(model) == [4])
        } else {
            #expect(admittedGenerations(model).isEmpty)
        }
    }

    @Test func pendingJournalKeepsLatestDisplayEventUntilRecoveryCompletes() async throws {
        let journal = PendingLayoutTransition(requestID: "local", scopeKind: .local, phase: .precommit,
            sourceLayoutNames: [], targetLayoutNames: ["main"], sourceSelectedSet: nil, targetSet: nil,
            definitionDigest: "old", topologyDigest: "old")
        let state = RuntimeState(pendingLayoutTransition: journal,
            activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 1)])
        let monitor = ManualArrangeOperationMonitor()
        let (model, _, directory) = try fixture(state: state, configText: yaml, monitor: monitor)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        model.startArrangeOperationMonitoring(interval: .milliseconds(10))
        model.handleDisplayChange(); model.handleDisplayChange()
        for _ in 0..<3 { monitor.tick(); try await drainWork(model) }
        #expect(admittedGenerations(model).isEmpty)
        #expect(model.engine.operationCoordinator.status().pendingTransition?.requestID == "local")
        _ = try await model.engine.recoverLayoutTransition(requestID: "recover")
        monitor.tick()
        try await drainWork(model)
        #expect(admittedGenerations(model) == [2])
    }

    @Test(arguments: ["missing", "invalid", "invalidReload"])
    func savedManagementOffersRestoreWithUnavailableConfig(mode: String) async throws {
        var hidden = SlotEntry.makeEntry(layoutName: "main", spaceID: 1,
            definition: WindowDefinition(match: WindowMatchRule(bundleID: "Editor"), slot: 1))
        hidden.visibilityState = .hiddenOffscreen
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 1)], slots: [hidden])
        let (model, _, directory) = try fixture(state: state, configText: mode == "missing" ? nil : mode == "invalid" ? "layouts: invalid" : yaml)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        if mode == "invalidReload" {
            try Data("layouts: invalid".utf8).write(to: directory.appendingPathComponent("config.yml"))
            #expect(!model.configManager.reload(trigger: "test"))
            #expect(model.configManager.configIfLoaded() != nil) // keep-last-valid is not a valid reload.
        }
        model.handleConfigChange()
        #expect(await eventually { model.runtimeState.slots.count == 1 })
        #expect(model.shouldOfferWindowRecovery)
    }

    @Test func manualFrameChangeAndLayoutRemovalOfferRestoreButOrdinaryVisibilityDoesNot() async throws {
        let initial = """
        layouts:
          main:
            spaces:
              - spaceID: 1
                windows:
                  - match: {bundleID: Editor}
                    slot: 1
                    launch: false
                    frame: {x: 0, y: 0, width: 500, height: 600}
        layoutSets:
          home:
            layouts: [main]
        """
        let config = ShitsuraeConfig(layouts: ["main": LayoutDefinition(spaces: [SpaceDefinition(spaceID: 1,
            windows: [WindowDefinition(match: WindowMatchRule(bundleID: "Editor"), slot: 1, launch: false,
                frame: FrameDefinition(x: .pt(0), y: .pt(0), width: .pt(500), height: .pt(600)))])])],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main"])])
        let state = RuntimeState(activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 1,
            appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "main", config: config))])
        let (model, _, directory) = try fixture(state: state, configText: initial)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        model.handleConfigChange()
        #expect(await eventually { model.runtimeState.activeWorkspaces.count == 1 })
        #expect(!model.shouldOfferWindowRecovery)
        let changed = initial.replacingOccurrences(of: "width: 500", with: "width: 800")
        try Data(changed.utf8).write(to: directory.appendingPathComponent("config.yml"))
        #expect(model.configManager.reload(trigger: "test"))
        model.handleConfigChange()
        #expect(model.shouldOfferWindowRecovery)
        #expect(await model.router.diagnostics().state.needsReapply)
        try Data(yaml.replacingOccurrences(of: "main", with: "other").utf8).write(to: directory.appendingPathComponent("config.yml"))
        #expect(model.configManager.reload(trigger: "test"))
        model.handleConfigChange()
        #expect(model.shouldOfferWindowRecovery)
    }

    @Test func validSelectedSetOrdinaryVisibilityPendingDoesNotOfferRestoreInAppModel() async throws {
        let config = ShitsuraeConfig(layouts: ["main": LayoutDefinition(spaces: [SpaceDefinition(spaceID: 1, windows: [])])],
            layoutSets: ["home": LayoutSetDefinition(layouts: ["main"])])
        let state = RuntimeState(selectedLayoutSet: SelectedLayoutSet(name: "home", memberNames: ["main"],
            definitionDigest: ConfigDigest.layoutSet(name: "home", config: config)),
            activeWorkspaces: [ActiveWorkspace(displayID: "primary", layoutName: "main", spaceID: 1,
                appliedDefinitionDigest: ConfigDigest.workspace(layoutName: "main", config: config))],
            pendingVisibilityConvergences: [PendingVisibilityConvergence(requestID: "visibility", startedAt: "now", displayID: "primary", layoutName: "main", targetSpaceID: 1)])
        let (model, _, directory) = try fixture(state: state, configText: yaml)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        model.handleConfigChange()
        #expect(await eventually { model.runtimeState.pendingVisibilityConvergences.count == 1 })
        #expect(!model.shouldOfferWindowRecovery)
        #expect(await model.router.diagnostics().state.needsReapply == false)
    }

    @Test func productionStatusProbeDefaultsMatchSystemProbe() async throws {
        let (model, _, directory) = try fixture(configText: yaml, useLiveStatusProbes: true)
        defer { model.stopArrangeOperationMonitoring(); try? FileManager.default.removeItem(at: directory) }
        let accessibility = SystemProbe.accessibilityGranted()
        let screenRecording = SystemProbe.screenRecordingGranted()
        let displays = SystemProbe.displays()
        model.refreshStatus()
        try await drainWork(model)
        #expect(model.accessibilityGranted == accessibility)
        #expect(model.screenRecordingGranted == screenRecording)
        #expect(model.displays == displays)
        let diagnostics = try #require(model.diagnostics)
        #expect(diagnostics.permissions.accessibility == accessibility)
        #expect(diagnostics.permissions.screenRecording == screenRecording)
        #expect(diagnostics.displays == displays.map(DisplaySummaryJSON.init(display:)))
        #expect(model.runtimeState == (await model.engine.currentState))
    }
}
