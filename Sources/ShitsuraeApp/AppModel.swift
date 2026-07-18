import AppKit
import Combine
import Foundation
import ServiceManagement
import ShitsuraeCore

/// Application root object: owns the engine actor, config manager, command
/// server and hotkey manager, and bridges OS notifications into engine calls.
enum EngineActionUrgency: Sendable {
    case normal
    case interactive

    var taskPriority: TaskPriority? {
        switch self {
        case .normal:
            nil
        case .interactive:
            .high
        }
    }

    var activityOptions: ProcessInfo.ActivityOptions? {
        switch self {
        case .normal:
            nil
        case .interactive:
            [.userInitiated, .latencyCritical]
        }
    }
}

@MainActor
final class FocusEventCoordinator {
    private let gate: FocusEventGate
    private(set) var latestSequence: UInt64 = 0

    init(gate: FocusEventGate = FocusEventGate()) {
        self.gate = gate
    }

    func accept(_ sequence: UInt64) -> Bool {
        guard sequence > latestSequence, gate.accept(sequence) else { return false }
        latestSequence = sequence
        return true
    }

    /// AX observers can deliver queued notifications after their application
    /// has moved to the background. Such an event must not supersede the
    /// activation retry of the application that is actually frontmost.
    func acceptWindowEvent(_ sequence: UInt64, isCurrentFrontmost: Bool) -> Bool {
        guard isCurrentFrontmost else { return false }
        return accept(sequence)
    }

    func isCurrent(_ sequence: UInt64) -> Bool {
        sequence == latestSequence && gate.isCurrent(sequence)
    }

    func invalidate(with sequence: UInt64) {
        latestSequence = max(latestSequence, sequence)
        gate.invalidate(with: sequence)
    }
}

struct RunningApplicationIdentity: Equatable {
    let pid: Int
    let bundleID: String
    let launchDate: Date?

    init(pid: Int, bundleID: String, launchDate: Date?) {
        self.pid = pid
        self.bundleID = bundleID
        self.launchDate = launchDate
    }

    init?(application: NSRunningApplication) {
        guard let bundleID = application.bundleIdentifier else { return nil }
        self.init(
            pid: Int(application.processIdentifier),
            bundleID: bundleID,
            launchDate: application.launchDate
        )
    }
}

struct FrontmostApplicationTracker {
    private struct DisplacedApplication {
        let identity: RunningApplicationIdentity
        let displacedAt: Date
    }

    private(set) var current: RunningApplicationIdentity?
    private var displaced: DisplacedApplication?
    let terminationCoalescingWindow: TimeInterval

    init(terminationCoalescingWindow: TimeInterval = 0.5) {
        self.terminationCoalescingWindow = terminationCoalescingWindow
    }

    mutating func reset(to identity: RunningApplicationIdentity?) {
        current = identity
        displaced = nil
    }

    @discardableResult
    mutating func recordActivation(
        _ identity: RunningApplicationIdentity,
        now: Date
    ) -> RunningApplicationIdentity? {
        guard current != identity else { return nil }
        let previous = current
        displaced = previous.map { DisplacedApplication(identity: $0, displacedAt: now) }
        current = identity
        return previous
    }

    /// Accepts either notification order used by AppKit: termination before
    /// replacement activation, or replacement activation immediately before
    /// termination.
    mutating func consumeFrontmostTermination(
        _ identity: RunningApplicationIdentity,
        now: Date
    ) -> Bool {
        if current == identity {
            current = nil
            return true
        }

        guard let displaced,
              displaced.identity == identity,
              now.timeIntervalSince(displaced.displacedAt) <= terminationCoalescingWindow
        else {
            return false
        }
        self.displaced = nil
        return true
    }
}

@MainActor
final class AppModel: ObservableObject {
    let logger = ShitsuraeLogger()
    let configManager: ConfigManager
    let engine: VirtualSpaceEngine
    let router: CommandRouter
    private let windowEventMonitor = AXWindowEventMonitor()
    private var server: CommandServer?
    private(set) var hotkeyManager: HotkeyManager?

    @Published var layouts: [String] = []
    @Published var activeLayoutName: String?
    @Published var activeSpaceID: Int?
    @Published var availableSpaceIDs: [Int] = []
    @Published var selectedSpaceID: Int = 1
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var displays: [DisplayInfo] = []
    @Published var configErrors: [ValidateErrorItem] = []
    @Published var diagnostics: DiagnosticsJSON?
    @Published private(set) var workspaceState: WorkspaceStateSnapshot?
    @Published var lastActionMessage: String?
    @Published var actionStatus: ActionStatus = .idle

    enum ActionStatus: Equatable {
        case idle
        case running(String)
        case success(String)
        case failed(String, String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Grace window after our own programmatic activation: OS activation
    /// notifications arrive late and must not re-trigger follow-focus.
    private var lastInteractiveActivationAt: Date?
    private var lastFollowFocusSwitchAt: Date?
    private var lastActiveSpaceChangeAt: Date?
    private var frontmostWindowBelongsToActiveWorkspace = true {
        didSet {
            syncHotkeyFastPathPolicy()
        }
    }
    private let followFocusPolicy = FollowFocusPolicy()
    private let focusEventGate: FocusEventGate
    private let focusEventCoordinator: FocusEventCoordinator
    private let interactiveActivationGrace: TimeInterval = 0.18
    private static let activationFocusRetryDelayNanoseconds: UInt64 = 40_000_000
    private static let terminationFollowFocusDelayNanoseconds: UInt64 = 100_000_000
    private var frontmostApplicationTracker = FrontmostApplicationTracker()

    private var observers: [NSObjectProtocol] = []
    private var shutdownInProgress = false
    private var shutdownCompletions: [() -> Void] = []
    private var workspaceStateRefreshSequence: UInt64 = 0

    init() {
        let focusEventGate = FocusEventGate()
        self.focusEventGate = focusEventGate
        focusEventCoordinator = FocusEventCoordinator(gate: focusEventGate)
        configManager = ConfigManager(logger: logger)
        do {
            engine = try VirtualSpaceEngine(
                store: RuntimeStateStore(),
                control: LiveWindowControl(),
                logger: logger,
                focusEventGate: focusEventGate
            )
        } catch {
            logger.error(
                event: "app.runtimeStateLoadFailed",
                fields: ["error": String(describing: error)]
            )
            fatalError("Unable to load runtime state safely: \(error)")
        }
        router = CommandRouter(engine: engine, configManager: configManager, logger: logger)
    }

    func start() {
        accessibilityGranted = SystemProbe.accessibilityGranted()
        screenRecordingGranted = SystemProbe.screenRecordingGranted()
        frontmostApplicationTracker.reset(
            to: NSWorkspace.shared.frontmostApplication.flatMap(RunningApplicationIdentity.init)
        )

        configManager.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleConfigChange()
            }
        }

        let server = CommandServer(router: router, logger: logger)
        guard server.start() else {
            logger.error(event: "app.serverStartFailed", fields: ["reason": "another instance is already serving"])
            configManager.stop()
            NSApp.terminate(nil)
            return
        }
        self.server = server

        let hotkeyManager = HotkeyManager(model: self)
        hotkeyManager.start()
        self.hotkeyManager = hotkeyManager

        installNotificationObservers()
        windowEventMonitor.start { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleWindowEvent(event)
            }
        }
        handleConfigChange()
        refreshStatus()
    }

    func shutdown(completion: @escaping () -> Void) {
        shutdownCompletions.append(completion)
        guard !shutdownInProgress else { return }
        shutdownInProgress = true

        let config = configManager.configIfLoaded()
        hotkeyManager?.stop()
        windowEventMonitor.stop()
        server?.stop()
        configManager.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        // Leave no window stranded offscreen while Shitsurae isn't running,
        // then discard the runtime state — but only when every hidden window
        // was actually restored. A failed restore keeps the state so the
        // next session can still find and recover the parked windows.
        let engine = engine
        let logger = logger
        Task {
            var restored = false
            if let config {
                restored = await engine.restoreAllForShutdown(config: config)
            }
            if restored {
                await engine.clearRuntimeState()
            } else {
                logger.log(
                    level: "warn",
                    event: "app.shutdown.restoreIncomplete",
                    fields: ["keptState": true]
                )
            }
            let completions = shutdownCompletions
            shutdownCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    // MARK: - Config

    private func handleConfigChange() {
        let loaded = configManager.configIfLoaded()
        layouts = loaded.map { $0.config.layouts.keys.sorted() } ?? []
        configErrors = configManager.configErrors()
        hotkeyManager?.reload(shortcuts: loaded?.config.resolvedShortcuts)
        applyLaunchAtLogin(loaded?.config.app?.launchAtLogin)
        refreshStatus()
    }

    private func applyLaunchAtLogin(_ enabled: Bool?) {
        guard let enabled else { return }
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.log(level: "warn", event: "app.launchAtLogin", fields: ["error": String(describing: error)])
        }
    }

    // MARK: - Status

    func refreshStatus() {
        accessibilityGranted = SystemProbe.accessibilityGranted()
        screenRecordingGranted = SystemProbe.screenRecordingGranted()
        displays = SystemProbe.displays()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await engine.currentState
            activeLayoutName = state.activeLayoutName
            activeSpaceID = state.primaryActiveSpaceID
            if let layoutName = state.activeLayoutName,
               let layout = configManager.configIfLoaded()?.config.layouts[layoutName]
            {
                availableSpaceIDs = layout.spaces.map(\.spaceID).sorted()
            } else if let first = layouts.first,
                      let layout = configManager.configIfLoaded()?.config.layouts[first]
            {
                availableSpaceIDs = layout.spaces.map(\.spaceID).sorted()
            } else {
                availableSpaceIDs = []
            }
            if let activeSpaceID, availableSpaceIDs.contains(activeSpaceID) {
                selectedSpaceID = activeSpaceID
            }
            diagnostics = await router.diagnostics()
            await refreshWorkspaceState()
        }
    }

    func refreshWorkspaceState() async {
        workspaceStateRefreshSequence &+= 1
        let sequence = workspaceStateRefreshSequence
        let config = configManager.configIfLoaded()
        let snapshot = await engine.workspaceStateSnapshot(config: config)
        guard sequence == workspaceStateRefreshSequence else { return }
        if workspaceState != snapshot {
            workspaceState = snapshot
        }
    }

    /// Keeps live window flags current only while the read-only status screen
    /// is mounted. SwiftUI cancels this task when the user navigates away.
    func monitorWorkspaceState() async {
        while !Task.isCancelled {
            await refreshWorkspaceState()
            do {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            } catch {
                return
            }
        }
    }

    // MARK: - Actions

    func applyLayout(_ name: String, spaceID: Int?) {
        runEngineAction("arrange \(name)", urgency: .interactive) { engine, config in
            let result = try await engine.arrange(layoutName: name, spaceID: spaceID, config: config)
            if result.result == "failed" {
                let detail = result.hardErrors.map(\.message).joined(separator: "; ")
                let message = [result.subcode, detail.isEmpty ? nil : detail]
                    .compactMap { $0 }
                    .joined(separator: ": ")
                throw VirtualSpaceEngineError.stateError(
                    message.isEmpty ? "arrange failed" : message
                )
            }
        }
    }

    func switchSpace(to spaceID: Int) {
        // Mark before the switch: the engine focuses the target window
        // mid-switch and the OS activation notification must not re-trigger
        // follow-focus.
        markInteractiveActivation()
        runEngineAction("switch to space \(spaceID)", urgency: .interactive) { [weak self] engine, config in
            let outcome = try await engine.switchSpace(to: spaceID, config: config)
            await MainActor.run {
                self?.markInteractiveActivation()
                self?.lastActiveSpaceChangeAt = Date()
                self?.frontmostWindowBelongsToActiveWorkspace = outcome.focusedWindowID != nil || !outcome.didChangeSpace
            }
            if let message = SpaceSwitchCompletion.incompleteMessage(
                converged: outcome.converged,
                unresolvedSlotCount: outcome.unresolvedSlots.count
            ) {
                throw VirtualSpaceEngineError.stateError(message)
            }
        }
    }

    func moveCurrentWindowToSpace(_ spaceID: Int) {
        runEngineAction("move window to space \(spaceID)", urgency: .interactive) { engine, config in
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(),
                toSpaceID: spaceID,
                config: config
            )
        }
    }

    func focusSlot(_ slot: Int) {
        markInteractiveActivation()
        runEngineAction("focus slot \(slot)", urgency: .interactive) { [weak self] engine, config in
            _ = try await engine.focusSlot(slot, config: config)
            await MainActor.run {
                self?.markInteractiveActivation()
                self?.frontmostWindowBelongsToActiveWorkspace = true
            }
        }
    }

    func focusWindow(identity: WindowIdentity) {
        markInteractiveActivation()
        runEngineAction("focus window \(identity.windowID)", urgency: .interactive) { [weak self] engine, config in
            let result = try await engine.focusWindow(identity: identity, config: config)
            await MainActor.run {
                self?.markInteractiveActivation()
                if result.didSwitchSpace {
                    self?.lastActiveSpaceChangeAt = Date()
                }
                self?.frontmostWindowBelongsToActiveWorkspace = true
            }
        }
    }

    func snapFocusedWindow(_ preset: SnapPreset) {
        runEngineAction("snap \(preset.rawValue)", urgency: .interactive) { engine, _ in
            _ = try await engine.snapWindow(selector: WindowTargetSelector(), preset: preset)
        }
    }

    func performGlobalAction(_ action: GlobalActionDefinition) {
        switch action.type {
        case .snap:
            if let preset = action.preset {
                snapFocusedWindow(preset)
            }
        case .move, .resize, .moveResize:
            runEngineAction("globalAction \(action.type.rawValue)", urgency: .interactive) { engine, config in
                _ = try await engine.setWindowFrame(
                    selector: WindowTargetSelector(),
                    x: action.x,
                    y: action.y,
                    width: action.width,
                    height: action.height,
                    config: config
                )
            }
        }
    }

    func cycleWindow(forward: Bool) {
        runEngineAction("cycle", urgency: .interactive) { [weak self] engine, config in
            let shortcuts = config.config.resolvedShortcuts
            let candidates = try await engine.cycleCandidates(
                config: config,
                excludedApps: shortcuts.cycleExcludedApps
            )
            guard !candidates.isEmpty else { return }

            let focusedIdentity = await engine.resolveTargetWindow(selector: WindowTargetSelector())?.identity
            let currentIndex = candidates.firstIndex(where: { $0.identity == focusedIdentity }) ?? -1
            let nextIndex: Int
            if currentIndex < 0 {
                nextIndex = 0
            } else if forward {
                nextIndex = (currentIndex + 1) % candidates.count
            } else {
                nextIndex = (currentIndex - 1 + candidates.count) % candidates.count
            }

            _ = try await engine.focusWindow(identity: candidates[nextIndex].identity, config: config)
            await MainActor.run {
                self?.markInteractiveActivation()
                self?.frontmostWindowBelongsToActiveWorkspace = true
            }
        }
    }

    func openConfigDirectory() {
        let url = ConfigPathResolver.configDirectoryURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func markInteractiveActivation() {
        lastInteractiveActivationAt = Date()
        let sequence = AXWindowEventMonitor.nextSequence()
        focusEventCoordinator.invalidate(with: sequence)
        invalidateEngineFocusEvents(upTo: sequence)
    }

    func frontmostBelongsToActiveWorkspaceForShortcutPolicy() -> Bool {
        frontmostWindowBelongsToActiveWorkspace
    }

    func handleFastPathActionStarted(_ label: String) {
        markInteractiveActivation()
        actionStatus = .running(label)
    }

    func handleFastPathSwitchFinished(label: String, result: HotkeyFastPathExecutionResult) {
        switch result {
        case let .success(outcome):
            markInteractiveActivation()
            lastActionMessage = "\(label): ok"
            actionStatus = .success(label)
            lastActiveSpaceChangeAt = Date()
            frontmostWindowBelongsToActiveWorkspace = outcome.focusedWindowID != nil || !outcome.didChangeSpace
            refreshStatus()

        case let .partial(outcome, message):
            markInteractiveActivation()
            lastActionMessage = "\(label): \(message)"
            actionStatus = .failed(label, message)
            lastActiveSpaceChangeAt = Date()
            frontmostWindowBelongsToActiveWorkspace = outcome.focusedWindowID != nil || !outcome.didChangeSpace
            refreshStatus()

        case let .failure(message):
            lastActionMessage = "\(label): \(message)"
            actionStatus = .failed(label, message)
            refreshStatus()
        }
    }

    private func syncHotkeyFastPathPolicy(frontmostBundleID: String? = nil) {
        hotkeyManager?.updateFastPathPolicy(
            frontmostBundleID: frontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            frontmostBelongsToActiveWorkspace: frontmostWindowBelongsToActiveWorkspace
        )
    }

    private func runEngineAction(
        _ label: String,
        urgency: EngineActionUrgency = .normal,
        _ body: @escaping @Sendable (VirtualSpaceEngine, LoadedConfig) async throws -> Void
    ) {
        if case .interactive = urgency {
            markInteractiveActivation()
        }
        guard let config = configManager.configIfLoaded() else {
            lastActionMessage = "config not loaded"
            actionStatus = .failed(label, "config not loaded")
            return
        }
        let engine = engine
        let activityOptions = urgency.activityOptions
        actionStatus = .running(label)
        Task(priority: urgency.taskPriority) {
            let activity = activityOptions.map {
                ProcessInfo.processInfo.beginActivity(
                    options: $0,
                    reason: "Shitsurae \(label)"
                )
            }
            defer {
                if let activity {
                    ProcessInfo.processInfo.endActivity(activity)
                }
            }

            do {
                try await body(engine, config)
                await MainActor.run {
                    self.lastActionMessage = "\(label): ok"
                    self.actionStatus = .success(label)
                    self.refreshStatus()
                }
            } catch {
                let message = (error as? VirtualSpaceEngineError).map {
                    CommandRouter.mapEngineError($0).message
                } ?? String(describing: error)
                self.logger.log(level: "warn", event: "app.action.failed", fields: ["label": label, "error": message])
                await MainActor.run {
                    self.lastActionMessage = "\(label): \(message)"
                    self.actionStatus = .failed(label, message)
                    self.refreshStatus()
                }
            }
        }
    }

    // MARK: - OS notifications

    private func installNotificationObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        observers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Extract the Sendable bits before hopping to the actor.
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier
                else {
                    return
                }
                let sequence = AXWindowEventMonitor.nextSequence()
                Task { @MainActor [weak self] in
                    self?.handleAppActivated(application: app, bundleID: bundleID, sequence: sequence)
                }
            }
        )

        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
                    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let bundleID = app.bundleIdentifier
                    else {
                        return
                    }
                    // Stale pids must re-resolve their Chromium profile.
                    WindowEnumerator.sharedProfileCache.invalidate(bundleID: bundleID)
                    Task { @MainActor [weak self] in
                        if name == NSWorkspace.didLaunchApplicationNotification {
                            self?.windowEventMonitor.register(application: app)
                        } else {
                            self?.handleAppTerminated(application: app, bundleID: bundleID)
                        }
                    }
                }
            )
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleDisplayChange()
                }
            }
        )
    }

    private func handleAppActivated(
        application: NSRunningApplication,
        bundleID: String,
        sequence: UInt64
    ) {
        guard !application.isTerminated,
              application.bundleIdentifier == bundleID,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == application.processIdentifier,
              frontmost.bundleIdentifier == bundleID,
              frontmost.launchDate == application.launchDate
        else {
            return
        }

        recordFrontmostActivation(application)
        guard !bundleID.hasPrefix("com.yuki-yano.shitsurae"),
              bundleID != Bundle.main.bundleIdentifier,
              let processStartTime = ProcessGenerationResolver.startTime(
                  pid: Int(application.processIdentifier)
              )
        else {
            return
        }

        syncHotkeyFastPathPolicy(frontmostBundleID: bundleID)
        windowEventMonitor.register(application: application)
        guard focusEventCoordinator.accept(sequence) else { return }
        sampleActivatedWindowFocus(
            application: application,
            bundleID: bundleID,
            expectedProcessStartTime: processStartTime,
            sequence: sequence,
            retriesRemaining: 1
        )
    }

    private func sampleActivatedWindowFocus(
        application: NSRunningApplication,
        bundleID: String,
        expectedProcessStartTime: UInt64,
        sequence: UInt64,
        retriesRemaining: Int
    ) {
        guard focusEventCoordinator.isCurrent(sequence) else { return }
        let pid = Int(application.processIdentifier)
        guard !application.isTerminated,
              application.bundleIdentifier == bundleID,
              ProcessGenerationResolver.startTime(pid: pid) == expectedProcessStartTime,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == application.processIdentifier,
              frontmost.bundleIdentifier == bundleID,
              frontmost.launchDate == application.launchDate
        else {
            invalidateEngineFocusEvents(upTo: sequence)
            return
        }

        if let windowID = windowEventMonitor.focusedWindowID(application: application) {
            handleFocusedWindowChanged(
                sequence: sequence,
                bundleID: bundleID,
                pid: pid,
                processStartTime: expectedProcessStartTime,
                windowID: windowID
            )
            return
        }

        guard retriesRemaining > 0 else {
            invalidateEngineFocusEvents(upTo: sequence)
            return
        }

        // Chrome can publish its activation before kAXFocusedWindowAttribute
        // is populated, and no later notification is guaranteed when focus
        // inside Chrome did not change. Retry once while the exact process is
        // still frontmost; a newer source sequence invalidates this work.
        Task { @MainActor [weak self, weak application] in
            try? await Task.sleep(nanoseconds: Self.activationFocusRetryDelayNanoseconds)
            guard let self, let application else { return }
            self.sampleActivatedWindowFocus(
                application: application,
                bundleID: bundleID,
                expectedProcessStartTime: expectedProcessStartTime,
                sequence: sequence,
                retriesRemaining: retriesRemaining - 1
            )
        }
    }

    private func handleWindowEvent(_ event: AXWindowEventMonitor.Event) {
        switch event {
        case let .focusedWindowChanged(sequence, bundleID, pid, processStartTime, windowID):
            // Gate before sequence acceptance. A delayed event from a
            // background Chrome helper/process must not cancel the one-shot
            // activation retry for the exact process that is frontmost.
            guard let application = NSRunningApplication(processIdentifier: pid),
                  !application.isTerminated,
                  application.bundleIdentifier == bundleID,
                  ProcessGenerationResolver.startTime(pid: Int(pid)) == processStartTime,
                  let frontmost = NSWorkspace.shared.frontmostApplication,
                  !frontmost.isTerminated,
                  frontmost.processIdentifier == pid,
                  frontmost.bundleIdentifier == bundleID,
                  frontmost.launchDate == application.launchDate,
                  focusEventCoordinator.acceptWindowEvent(sequence, isCurrentFrontmost: true)
            else {
                return
            }
            recordFrontmostActivation(application)
            guard let windowID else {
                sampleActivatedWindowFocus(
                    application: application,
                    bundleID: bundleID,
                    expectedProcessStartTime: processStartTime,
                    sequence: sequence,
                    retriesRemaining: 1
                )
                return
            }
            handleFocusedWindowChanged(
                sequence: sequence,
                bundleID: bundleID,
                pid: Int(pid),
                processStartTime: processStartTime,
                windowID: windowID
            )
        }
    }

    private func handleFocusedWindowChanged(
        sequence: UInt64,
        bundleID: String,
        pid: Int,
        processStartTime: UInt64,
        windowID: UInt32
    ) {
        if let lastInteractive = lastInteractiveActivationAt,
           Date().timeIntervalSince(lastInteractive) < interactiveActivationGrace
        {
            return
        }

        guard let config = configManager.configIfLoaded() else { return }
        let followFocusEnabled = config.config.resolvedFollowFocus
        let engine = engine

        Task { [weak self] in
            // One engine call = one live snapshot: target resolution, the
            // global assignment, MRU/binding updates and adoption all happen
            // inside processFocusEvent. Nothing below re-runs them.
            guard let outcome = await engine.processFocusEvent(
                sequence: sequence,
                windowID: windowID,
                pid: pid,
                processStartTime: processStartTime,
                bundleID: bundleID,
                config: config
            ) else {
                await MainActor.run { [weak self] in
                    guard self?.focusEventCoordinator.isCurrent(sequence) == true else { return }
                    self?.frontmostWindowBelongsToActiveWorkspace = false
                }
                return
            }

            guard self?.focusEventCoordinator.isCurrent(sequence) == true else { return }

            let decision = await MainActor.run { [weak self] in
                guard let self else { return FollowFocusPolicy.Decision.markActivated }
                self.frontmostWindowBelongsToActiveWorkspace = FollowFocusPolicy
                    .frontmostBelongsToActiveWorkspace(
                        targetSpaceID: outcome.spaceID,
                        activeSpaceID: outcome.activeSpaceID
                    )
                return self.followFocusPolicy.decisionForFocusedWindow(
                    targetSpaceID: outcome.spaceID,
                    activeSpaceID: outcome.activeSpaceID,
                    followFocusEnabled: followFocusEnabled,
                    lastFollowFocusSwitchAt: self.lastFollowFocusSwitchAt,
                    lastActiveSpaceChangeAt: self.lastActiveSpaceChangeAt,
                    now: Date()
                )
            }

            switch decision {
            case .adoptIntoActiveWorkspace, .markActivated:
                // Adoption (or its rejection by a focus ignore rule) already
                // happened inside processFocusEvent on the same snapshot;
                // there is nothing left to apply for these decisions.
                return

            case let .switchSpace(targetSpaceID):
                // AppKit may activate a previously used application just
                // before publishing that the current one terminated. Briefly
                // coalesce cross-workspace focus so the termination handler
                // can replace it with an in-workspace MRU target.
                try? await Task.sleep(nanoseconds: Self.terminationFollowFocusDelayNanoseconds)
                guard self?.focusEventCoordinator.isCurrent(sequence) == true else { return }
                let switchOutcome = try? await engine.switchSpaceForFocusEvent(
                    sequence: sequence,
                    identity: outcome.identity,
                    to: targetSpaceID,
                    config: config
                )
                await MainActor.run {
                    guard self?.focusEventCoordinator.isCurrent(sequence) == true,
                          let switchOutcome
                    else {
                        return
                    }
                    let now = Date()
                    self?.lastFollowFocusSwitchAt = now
                    self?.lastActiveSpaceChangeAt = now
                    self?.frontmostWindowBelongsToActiveWorkspace = switchOutcome.focusedWindowID != nil
                    self?.refreshStatus()
                }
            }
        }
    }

    private func handleAppTerminated(
        application: NSRunningApplication,
        bundleID: String
    ) {
        windowEventMonitor.unregister(application: application)
        let identity = RunningApplicationIdentity(
            pid: Int(application.processIdentifier),
            bundleID: bundleID,
            launchDate: application.launchDate
        )
        guard frontmostApplicationTracker.consumeFrontmostTermination(identity, now: Date())
        else {
            return
        }
        restoreFocusAfterFrontmostTermination(identity)
    }

    private func recordFrontmostActivation(_ application: NSRunningApplication) {
        guard let identity = RunningApplicationIdentity(application: application),
              let displaced = frontmostApplicationTracker.recordActivation(identity, now: Date()),
              !isApplicationStillRunning(displaced),
              frontmostApplicationTracker.consumeFrontmostTermination(displaced, now: Date())
        else {
            return
        }
        restoreFocusAfterFrontmostTermination(displaced)
    }

    private func isApplicationStillRunning(_ identity: RunningApplicationIdentity) -> Bool {
        guard let application = NSRunningApplication(
            processIdentifier: pid_t(identity.pid)
        ), !application.isTerminated,
           let runningIdentity = RunningApplicationIdentity(application: application)
        else {
            return false
        }
        return runningIdentity == identity
    }

    private func restoreFocusAfterFrontmostTermination(
        _ identity: RunningApplicationIdentity
    ) {
        guard let config = configManager.configIfLoaded() else { return }

        // Supersede any activation/focus event emitted for AppKit's automatic
        // replacement before it can trigger follow-focus.
        markInteractiveActivation()
        let engine = engine
        Task { [weak self] in
            do {
                let focusedIdentity = try await engine.focusPreferredWindowInActiveWorkspace(
                    excludingPID: identity.pid,
                    bundleID: identity.bundleID,
                    config: config
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.frontmostWindowBelongsToActiveWorkspace = focusedIdentity != nil
                    self.syncHotkeyFastPathPolicy(
                        frontmostBundleID: focusedIdentity?.bundleID
                    )
                }
            } catch {
                self?.logger.log(
                    level: "warn",
                    event: "app.terminationFocusRestoreFailed",
                    fields: [
                        "pid": identity.pid,
                        "bundleID": identity.bundleID,
                        "error": String(describing: error),
                    ]
                )
                await MainActor.run { [weak self] in
                    self?.frontmostWindowBelongsToActiveWorkspace = false
                }
            }
        }
    }

    private func invalidateEngineFocusEvents(upTo sequence: UInt64) {
        let engine = engine
        Task {
            await engine.invalidateFocusEvents(upTo: sequence)
        }
    }

    private func handleDisplayChange() {
        guard let config = configManager.configIfLoaded() else { return }
        let engine = engine
        Task { [weak self] in
            if let activeSpaceID = await engine.activeSpaceID() {
                _ = try? await engine.switchSpace(to: activeSpaceID, config: config, reconcile: true)
            }
            await MainActor.run { self?.refreshStatus() }
        }
    }
}
