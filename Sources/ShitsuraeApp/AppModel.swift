import AppKit
import Combine
import Foundation
import ServiceManagement
import ShitsuraeCore

/// Application root object: owns the engine actor, config manager, command
/// server and hotkey manager, and bridges OS notifications into engine calls.
@MainActor
final class AppModel: ObservableObject {
    let logger = ShitsuraeLogger()
    let configManager: ConfigManager
    let engine: VirtualSpaceEngine
    let router: CommandRouter
    private var server: CommandServer?
    private(set) var hotkeyManager: HotkeyManager?

    @Published var layouts: [String] = []
    @Published var activeLayoutName: String?
    @Published var activeSpaceID: Int?
    @Published var availableSpaceIDs: [Int] = []
    @Published var selectedSpaceID: Int = 1
    @Published var accessibilityGranted = false
    @Published var screenRecordingGranted = false
    @Published var configErrors: [ValidateErrorItem] = []
    @Published var diagnostics: DiagnosticsJSON?
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
    private let followFocusDebounce: TimeInterval = 0.5
    private let interactiveActivationGrace: TimeInterval = 0.18

    private var observers: [NSObjectProtocol] = []

    init() {
        configManager = ConfigManager(logger: logger)
        engine = VirtualSpaceEngine(
            store: RuntimeStateStore(),
            control: LiveWindowControl(),
            logger: logger
        )
        router = CommandRouter(engine: engine, configManager: configManager, logger: logger)
    }

    func start() {
        accessibilityGranted = SystemProbe.accessibilityGranted()
        screenRecordingGranted = SystemProbe.screenRecordingGranted()

        configManager.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleConfigChange()
            }
        }

        let server = CommandServer(router: router, logger: logger)
        server.start()
        self.server = server

        let hotkeyManager = HotkeyManager(model: self)
        hotkeyManager.start()
        self.hotkeyManager = hotkeyManager

        installNotificationObservers()
        handleConfigChange()
        refreshStatus()
    }

    func shutdown() {
        hotkeyManager?.stop()
        server?.stop()
        configManager.stop()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        // Leave no window stranded offscreen while Shitsurae isn't running,
        // then discard the runtime state entirely — every session starts
        // fresh from an apply.
        let engine = engine
        let config = configManager.configIfLoaded()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if let config {
                await engine.restoreAllForShutdown(config: config)
            }
            await engine.clearRuntimeState()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
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

        Task { @MainActor in
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
        }
    }

    // MARK: - Actions

    func applyLayout(_ name: String, spaceID: Int?) {
        runEngineAction("arrange \(name)") { engine, config in
            _ = try await engine.arrange(layoutName: name, spaceID: spaceID, config: config)
        }
    }

    func switchSpace(to spaceID: Int) {
        // Mark before the switch: the engine focuses the target window
        // mid-switch and the OS activation notification must not re-trigger
        // follow-focus.
        markInteractiveActivation()
        runEngineAction("switch to space \(spaceID)") { [weak self] engine, config in
            _ = try await engine.switchSpace(to: spaceID, config: config)
            await MainActor.run {
                self?.markInteractiveActivation()
                self?.lastActiveSpaceChangeAt = Date()
            }
        }
    }

    func moveCurrentWindowToSpace(_ spaceID: Int) {
        runEngineAction("move window to space \(spaceID)") { engine, config in
            _ = try await engine.windowWorkspace(
                selector: WindowTargetSelector(),
                toSpaceID: spaceID,
                config: config
            )
        }
    }

    func focusSlot(_ slot: Int) {
        markInteractiveActivation()
        runEngineAction("focus slot \(slot)") { [weak self] engine, config in
            _ = try await engine.focusSlot(slot, config: config)
            await MainActor.run { self?.markInteractiveActivation() }
        }
    }

    func focusWindow(windowID: UInt32) {
        markInteractiveActivation()
        runEngineAction("focus window \(windowID)") { [weak self] engine, config in
            _ = try await engine.focusWindow(
                selector: WindowTargetSelector(windowID: windowID),
                config: config
            )
            await MainActor.run { self?.markInteractiveActivation() }
        }
    }

    func snapFocusedWindow(_ preset: SnapPreset) {
        runEngineAction("snap \(preset.rawValue)") { engine, _ in
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
            runEngineAction("globalAction \(action.type.rawValue)") { engine, config in
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
        runEngineAction("cycle") { [weak self] engine, config in
            let shortcuts = config.config.resolvedShortcuts
            let candidates = try await engine.cycleCandidates(
                config: config,
                excludedApps: shortcuts.cycleExcludedApps
            )
            guard !candidates.isEmpty else { return }

            let focusedWindowID = await engine.resolveTargetWindow(selector: WindowTargetSelector())?.windowID
            let currentIndex = candidates.firstIndex(where: { $0.windowID == focusedWindowID }) ?? -1
            let nextIndex: Int
            if currentIndex < 0 {
                nextIndex = 0
            } else if forward {
                nextIndex = (currentIndex + 1) % candidates.count
            } else {
                nextIndex = (currentIndex - 1 + candidates.count) % candidates.count
            }

            guard let windowID = candidates[nextIndex].windowID else { return }
            _ = try await engine.focusWindow(
                selector: WindowTargetSelector(windowID: windowID),
                config: config
            )
            await MainActor.run { self?.markInteractiveActivation() }
        }
    }

    func openConfigDirectory() {
        let url = ConfigPathResolver.configDirectoryURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func markInteractiveActivation() {
        lastInteractiveActivationAt = Date()
    }

    private func runEngineAction(
        _ label: String,
        _ body: @escaping @Sendable (VirtualSpaceEngine, LoadedConfig) async throws -> Void
    ) {
        guard let config = configManager.configIfLoaded() else {
            lastActionMessage = "config not loaded"
            actionStatus = .failed(label, "config not loaded")
            return
        }
        let engine = engine
        actionStatus = .running(label)
        Task {
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
                let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                guard let bundleID else { return }
                Task { @MainActor [weak self] in
                    self?.handleAppActivated(bundleID: bundleID)
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

    private func handleAppActivated(bundleID: String) {
        guard !bundleID.hasPrefix("com.yuki-yano.shitsurae"),
              bundleID != Bundle.main.bundleIdentifier
        else {
            return
        }

        if let lastInteractive = lastInteractiveActivationAt,
           Date().timeIntervalSince(lastInteractive) < interactiveActivationGrace
        {
            return
        }

        guard let config = configManager.configIfLoaded() else { return }
        let followFocusEnabled = config.config.resolvedFollowFocus
        let engine = engine
        let debounce = followFocusDebounce
        let lastSwitch = lastFollowFocusSwitchAt
        let lastChange = lastActiveSpaceChangeAt

        Task { [weak self] in
            guard let window = await engine.resolveTargetWindow(selector: WindowTargetSelector()),
                  window.bundleID == bundleID
            else {
                return
            }

            // OS-level MRU tracking: every activation path updates recency.
            await engine.markActivated(window: window)

            let targetSpaceID = await engine.spaceID(forWindowID: window.windowID)
            let activeSpaceID = await engine.activeSpaceID()

            var shouldSwitch = followFocusEnabled
            if let lastSwitch, Date().timeIntervalSince(lastSwitch) < debounce {
                shouldSwitch = false
            }
            if let lastChange, Date().timeIntervalSince(lastChange) < debounce {
                shouldSwitch = false
            }
            guard shouldSwitch,
                  let targetSpaceID,
                  targetSpaceID != activeSpaceID
            else {
                return
            }

            _ = try? await engine.switchSpace(to: targetSpaceID, config: config)
            await MainActor.run {
                self?.lastFollowFocusSwitchAt = Date()
                self?.lastActiveSpaceChangeAt = Date()
                self?.refreshStatus()
            }
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
