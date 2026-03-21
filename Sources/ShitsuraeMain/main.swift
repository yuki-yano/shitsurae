import AppKit
import ApplicationServices
import Darwin
import Foundation
import ServiceManagement
import ShitsuraeCore
import SwiftUI

private func executeRemoteCommand(_ request: AgentCommandRequest) -> CommandResult {
    AgentXPCClient().execute(
        request.withConfigDirectoryPath(ConfigPathResolver.configDirectoryURL().path)
    )
}

private let menuBarIconImage: NSImage = {
    let image = NSImage(size: NSSize(width: 22, height: 22))

    for fileName in ["menu-22.png", "menu-44.png"] {
        guard let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(fileName) else {
            continue
        }
        guard let data = try? Data(contentsOf: resourceURL),
              let representation = NSBitmapImageRep(data: data)
        else {
            continue
        }
        image.addRepresentation(representation)
    }

    precondition(!image.representations.isEmpty, "Missing menu bar icon resources in app bundle")
    image.isTemplate = true
    return image
}()

// MARK: - Active Window Geometry Observer

/// Observes move/resize/focus-change of the frontmost app's windows via AXObserver.
private final class ActiveWindowGeometryObserver {
    private var observer: AXObserver?
    private var observedWindowElement: AXUIElement?
    private var observedAppElement: AXUIElement?
    private var observedPID: pid_t = 0
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        detach()
    }

    /// Reattach to the frontmost app's focused window. Always call on app switch.
    func reattach() {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            detach()
            return
        }
        let pid = frontmost.processIdentifier
        detach()

        var axObserver: AXObserver?
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &axObserver) == .success,
              let axObserver
        else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)

        for notification in Self.appNotifications() {
            AXObserverAddNotification(axObserver, appElement, notification, ctx)
        }

        // Attach move/resize/destroyed notifications to the current focused window.
        if let windowElement = Self.focusedWindow(of: appElement) {
            for notification in Self.windowNotifications() {
                AXObserverAddNotification(axObserver, windowElement, notification, ctx)
            }
            observedWindowElement = windowElement
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)

        self.observer = axObserver
        self.observedAppElement = appElement
        self.observedPID = pid
    }

    fileprivate func handleNotification(_ notification: String) {
        if notification == kAXFocusedWindowChangedNotification as String
            || notification == kAXMainWindowChangedNotification as String
            || notification == kAXUIElementDestroyedNotification as String
        {
            reattachWindowObservers()
        }
        onChange()
    }

    // MARK: - Private

    /// Swap move/resize observers to the newly focused window (keeping the same AXObserver).
    private func reattachWindowObservers() {
        guard let observer, let appElement = observedAppElement else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        if let old = observedWindowElement {
            for notification in Self.windowNotifications() {
                AXObserverRemoveNotification(observer, old, notification)
            }
            observedWindowElement = nil
        }

        if let windowElement = Self.focusedWindow(of: appElement) {
            for notification in Self.windowNotifications() {
                AXObserverAddNotification(observer, windowElement, notification, ctx)
            }
            observedWindowElement = windowElement
        }
    }

    private func detach() {
        if let observer {
            if let win = observedWindowElement {
                for notification in Self.windowNotifications() {
                    AXObserverRemoveNotification(observer, win, notification)
                }
            }
            if let app = observedAppElement {
                for notification in Self.appNotifications() {
                    AXObserverRemoveNotification(observer, app, notification)
                }
            }
        }
        observer = nil
        observedWindowElement = nil
        observedAppElement = nil
        observedPID = 0
    }

    private static func focusedWindow(of appElement: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &ref) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (ref as! AXUIElement)
    }

    private static func appNotifications() -> [CFString] {
        [
            kAXFocusedWindowChangedNotification as CFString,
            kAXMainWindowChangedNotification as CFString,
            kAXWindowCreatedNotification as CFString,
            kAXApplicationHiddenNotification as CFString,
            kAXApplicationShownNotification as CFString,
        ]
    }

    private static func windowNotifications() -> [CFString] {
        [
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
        ]
    }
}

private func axObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let obj = Unmanaged<ActiveWindowGeometryObserver>.fromOpaque(refcon).takeUnretainedValue()
    obj.handleNotification(notification as String)
}

// MARK: - App

struct ShitsuraeMenuBarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarActionsView(model: model) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Open Shitsurae") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Preferences…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Button("Open Config Directory") {
                model.openConfigDirectory()
            }

            Divider()

            Button("Quit") {
                model.quit()
            }
        } label: {
            Image(nsImage: menuBarIconImage)
        }
        .menuBarExtraStyle(.menu)

        Window("Shitsurae", id: "main") {
            AppContentView(model: model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 780, height: 520)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Shitsurae") {
                    model.quit()
                }
                .keyboardShortcut("q")
            }
        }

        Settings {
            AppContentView(model: model)
                .frame(minWidth: 780, minHeight: 520)
        }
    }
}

// MARK: - Sidebar Item

private enum SidebarItem: Hashable {
    case arrange
    case layout(String)
    case general
    case shortcuts
    case permissions
    case windowStatus
    case diagnostics
}

// MARK: - ArrangeStatus

private enum ArrangeStatus: Equatable {
    case idle
    case running(ArrangeTrigger)
    case success(ArrangeTrigger)
    case failed(ArrangeTrigger)
}

private enum ArrangeTrigger: Equatable {
    case apply
    case stateOnly
}

// MARK: - AppModel

@MainActor
private final class AppModel: ObservableObject {
    @Published var layouts: [String] = []
    @Published var config: ShitsuraeConfig?
    @Published var configError: String?
    @Published var diagnosticsText = "{}"
    @Published var diagnosticsSnapshot: DiagnosticsJSON?
    @Published var currentSpaceSnapshot: SpaceCurrentJSON?
    @Published var guiVirtualSpaceStatus = GUIVirtualSpaceStatus(
        mode: .native,
        activeLayoutName: nil,
        activeVirtualSpaceID: nil,
        activeLayoutSpaceIDs: [],
        blockReason: nil,
        preferredRecoverySpaceID: nil,
        canForceClearPendingState: false,
    )
    @Published var arrangeStatus: ArrangeStatus = .idle
    @Published var runtimeStateSnapshot: RuntimeState?

    let commandService: CommandService
    private let shortcutManager: ShortcutManager
    private let launchAtLoginController = LaunchAtLoginController()
    private var appliedLaunchAtLogin: Bool?
    private var shutdownPerformed = false
    private var activeSpaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var windowGeometryObserver: ActiveWindowGeometryObserver?

    init() {
        commandService = CommandService(enableAutoReloadMonitor: true)
        commandService.clearRuntimeState()
        shortcutManager = ShortcutManager(commandService: commandService)
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.shutdownIfNeeded()
            }
        }
        ensureAgentRunning()
        commandService.onAutoReload = { [weak self] _ in
            Task { @MainActor in
                self?.reloadConfig()
                self?.refreshDiagnostics()
                self?.shortcutManager.reloadConfiguration()
            }
        }
        startWorkspaceObservers()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shortcutManager.start()
            self.reloadConfig()
            self.refreshDiagnostics()
        }
    }

    func reloadConfig() {
        do {
            let loaded = try ConfigLoader().loadFromDefaultDirectory()
            applyLaunchAtLoginIfNeeded(config: loaded.config)
            config = loaded.config
            configError = nil
            layouts = loaded.config.layouts.keys.sorted()
        } catch let error as ConfigLoadError {
            config = nil
            configError = error.errorDescription ?? "Failed to load config."
            layouts = []
        } catch {
            config = nil
            configError = error.localizedDescription
            layouts = []
        }
    }

    func apply(layout: String, spaceID: Int? = nil, stateOnly: Bool = false) {
        let trigger: ArrangeTrigger = stateOnly ? .stateOnly : .apply
        arrangeStatus = .running(trigger)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = executeRemoteCommand(
                AgentCommandRequest(
                    command: .arrange,
                    json: false,
                    dryRun: false,
                    verbose: false,
                    layoutName: layout,
                    spaceID: spaceID,
                    stateOnly: stateOnly
                )
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.arrangeStatus = result.exitCode == 0 ? .success(trigger) : .failed(trigger)
                self.refreshDiagnostics()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.arrangeStatus == .success(trigger) || self.arrangeStatus == .failed(trigger) {
                        self.arrangeStatus = .idle
                    }
                }
            }
        }
    }

    func switchVirtualSpace(spaceID: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = executeRemoteCommand(
                AgentCommandRequest(
                    command: .spaceSwitch,
                    json: false,
                    spaceID: spaceID
                )
            )
            DispatchQueue.main.async {
                self?.refreshDiagnostics()
            }
        }
    }

    func forceClearPendingState() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = executeRemoteCommand(
                AgentCommandRequest(
                    command: .spaceRecover,
                    json: false,
                    forceClearPending: true,
                    confirm: true
                )
            )
            DispatchQueue.main.async {
                self?.refreshDiagnostics()
            }
        }
    }

    func refreshDiagnostics() {
        let diagnosticsResult = commandService.diagnostics(json: true)
        diagnosticsText = diagnosticsResult.stdout.isEmpty ? "{}" : diagnosticsResult.stdout
        diagnosticsSnapshot = decodeJSON(DiagnosticsJSON.self, from: diagnosticsResult.stdout)

        let spaceCurrentResult = commandService.spaceCurrent(json: true)
        currentSpaceSnapshot = decodeJSON(SpaceCurrentJSON.self, from: spaceCurrentResult.stdout)
        guiVirtualSpaceStatus = GUIVirtualSpaceStatusResolver.resolve(
            config: config,
            diagnostics: diagnosticsSnapshot,
            spaceCurrentResult: spaceCurrentResult
        )

        refreshWindowStatus()
    }

    func refreshWindowStatus() {
        let runtimeState = RuntimeStateStore().load()
        runtimeStateSnapshot = WindowStatusResolver.resolveLive(
            state: runtimeState,
            windows: WindowQueryService.listWindowsOnAllSpaces()
        )
    }

    func openConfigDirectory() {
        let url = ConfigPathResolver.configDirectoryURL()
        NSWorkspace.shared.open(url)
    }

    func quit() {
        shutdownIfNeeded()
        NSApplication.shared.terminate(nil)
    }

    private func ensureAgentRunning() {
        Task.detached(priority: .utility) {
            _ = AgentXPCClient().execute(AgentCommandRequest(command: .diagnostics, json: true))
        }
    }

    private func terminateAgentProcess() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(AgentXPCConstants.launchAgentLabel)"
        runProcess(executable: "/bin/launchctl", arguments: ["bootout", service])
        runProcess(executable: "/usr/bin/pkill", arguments: ["-x", "ShitsuraeAgent"])
    }

    private func applyLaunchAtLoginIfNeeded(config: ShitsuraeConfig) {
        guard let launchAtLogin = config.app?.launchAtLogin,
              appliedLaunchAtLogin != launchAtLogin
        else {
            return
        }

        do {
            try launchAtLoginController.setEnabled(launchAtLogin)
            appliedLaunchAtLogin = launchAtLogin
        } catch {
            NSLog("Failed to apply launchAtLogin=%@ setting: %@", String(launchAtLogin), error.localizedDescription)
        }
    }

    private func startWorkspaceObservers() {
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDiagnostics()
                self?.refreshWindowStatus()
            }
        }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDiagnostics()
                self?.refreshWindowStatus()
                self?.windowGeometryObserver?.reattach()
            }
        }

        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindowStatus()
            }
        }

        appHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindowStatus()
            }
        }

        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshWindowStatus()
            }
        }

        windowGeometryObserver = ActiveWindowGeometryObserver { [weak self] in
            Task { @MainActor in
                self?.refreshWindowStatus()
            }
        }
        windowGeometryObserver?.reattach()
    }

    private func shutdownIfNeeded() {
        guard !shutdownPerformed else { return }
        shutdownPerformed = true
        shortcutManager.stop()
        windowGeometryObserver = nil
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        let restoreResult = commandService.restoreVirtualWorkspaceWindowsForShutdown()
        if restoreResult.exitCode != 0 {
            NSLog("Failed to restore virtual workspace windows before shutdown: %@", restoreResult.stderr)
        }
        terminateAgentProcess()
    }

    private func runProcess(executable: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String) -> T? {
        guard !text.isEmpty else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: Data(text.utf8))
    }
}

private struct LaunchAtLoginController {
    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch (enabled, service.status) {
        case (true, .enabled), (false, .notRegistered):
            return
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
    }
}

// MARK: - Menu Bar Actions

private struct MenuBarActionsView: View {
    @ObservedObject var model: AppModel
    let openMainWindow: () -> Void

    private var isVirtualMode: Bool {
        model.guiVirtualSpaceStatus.isVirtualMode
    }

    private var nativeCurrentSpaceID: Int? {
        guard model.currentSpaceSnapshot?.space.kind == .native else {
            return nil
        }
        return model.currentSpaceSnapshot?.space.spaceID
    }

    var body: some View {
        Group {
            if model.layouts.isEmpty {
                Text("No layouts")
            } else if isVirtualMode {
                virtualMenu
            } else {
                nativeMenus
            }
        }
    }

    @ViewBuilder
    private var nativeMenus: some View {
        ForEach(model.layouts, id: \.self) { layout in
            Menu(layout) {
                Button("Apply All") {
                    model.apply(layout: layout)
                }

                Button("Apply Current Space") {
                    model.apply(layout: layout, spaceID: nativeCurrentSpaceID)
                }
                .disabled(nativeCurrentSpaceID == nil)
            }
        }
    }

    private var virtualMenuTitle: String {
        if let layout = model.guiVirtualSpaceStatus.activeLayoutName {
            return "Virtual Spaces: \(layout)"
        }
        return "Virtual Spaces"
    }

    @ViewBuilder
    private var virtualMenu: some View {
        Menu(virtualMenuTitle) {
            if model.guiVirtualSpaceStatus.canSwitchFromMenuBar {
                ForEach(model.guiVirtualSpaceStatus.activeLayoutSpaceIDs, id: \.self) { spaceID in
                    Button {
                        model.switchVirtualSpace(spaceID: spaceID)
                    } label: {
                        if model.guiVirtualSpaceStatus.activeVirtualSpaceID == spaceID {
                            Text("Space \(spaceID) (Current)")
                        } else {
                            Text("Switch to Space \(spaceID)")
                        }
                    }
                    .disabled(model.guiVirtualSpaceStatus.activeVirtualSpaceID == spaceID)
                }

                Divider()
                Button("Open Arrange View") {
                    openMainWindow()
                }
            } else {
                Text(virtualMenuStatusTitle)
                Text(virtualMenuStatusMessage)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Open Arrange View") {
                    openMainWindow()
                }
            }
        }
    }

    private var virtualMenuStatusTitle: String {
        switch model.guiVirtualSpaceStatus.blockReason {
        case .busy:
            return "Switch In Progress"
        case .recoveryRequiresLiveArrange:
            return "Recovery Requires Live Arrange"
        case .runtimeStateCorrupted:
            return "Runtime State Corrupted"
        case .runtimeStateReadPermissionDenied:
            return "Runtime State Unreadable"
        case .unavailable, nil:
            return "Initialize Active Space"
        }
    }

    private var virtualMenuStatusMessage: String {
        switch model.guiVirtualSpaceStatus.blockReason {
        case .busy:
            return "Wait for the current switch to finish, then retry."
        case .recoveryRequiresLiveArrange:
            return "State-only bootstrap is blocked. Run a live arrange for the recovery target first."
        case .runtimeStateCorrupted:
            return "Use diagnostics and recovery guidance before switching."
        case .runtimeStateReadPermissionDenied:
            return "Repair runtime-state.json permissions before switching."
        case .unavailable, nil:
            return "Open Arrange View to initialize active space."
        }
    }
}

// MARK: - Shared Content View

private struct AppContentView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SidebarItem? = .arrange

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Actions") {
                    Label("Arrange", systemImage: "play.rectangle")
                        .tag(SidebarItem.arrange)
                }

                if !model.layouts.isEmpty {
                    Section("Layouts") {
                        ForEach(model.layouts, id: \.self) { name in
                            Label(name, systemImage: "square.grid.2x2")
                                .tag(SidebarItem.layout(name))
                        }
                    }
                }

                Section("Status") {
                    Label("Window Status", systemImage: "macwindow.on.rectangle")
                        .tag(SidebarItem.windowStatus)
                }

                Section("Settings") {
                    Label("General", systemImage: "gearshape")
                        .tag(SidebarItem.general)
                    Label("Shortcuts", systemImage: "keyboard")
                        .tag(SidebarItem.shortcuts)
                }

                Section("System") {
                    Label("Permissions", systemImage: "checkmark.shield")
                        .tag(SidebarItem.permissions)
                    Label("Diagnostics", systemImage: "stethoscope")
                        .tag(SidebarItem.diagnostics)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 200)

            Divider()

            Group {
                switch selection {
                case .arrange:
                    ArrangeView(model: model)
                case let .layout(name):
                    if let layout = model.config?.layouts[name] {
                        LayoutDetailView(name: name, layout: layout)
                    } else {
                        ContentUnavailableView("Layout not found", systemImage: "exclamationmark.triangle")
                    }
                case .general:
                    GeneralSettingsView(config: model.config)
                case .shortcuts:
                    ShortcutsView(config: model.config)
                case .permissions:
                    PermissionsView()
                case .windowStatus:
                    WindowStatusView(model: model)
                case .diagnostics:
                    DiagnosticsView(diagnostics: model.diagnosticsSnapshot, text: model.diagnosticsText)
                case nil:
                    ContentUnavailableView("Select an item", systemImage: "sidebar.left")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Arrange View

private struct ArrangeView: View {
    @ObservedObject var model: AppModel
    @State private var selectedLayout: String?
    @State private var selectedSpaceID: Int?

    private var guiStatus: GUIVirtualSpaceStatus {
        model.guiVirtualSpaceStatus
    }

    private var isVirtualMode: Bool {
        guiStatus.isVirtualMode
    }

    private var currentLayout: LayoutDefinition? {
        guard let name = selectedLayout else { return nil }
        return model.config?.layouts[name]
    }

    private var spaceIDs: [Int] {
        currentLayout?.spaces.map(\.spaceID) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Arrange")
                    .font(.title2).bold()

                if let error = model.configError {
                    GroupBox {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                if isVirtualMode {
                    virtualModeStatusCard
                }

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Layout").font(.caption).foregroundStyle(.secondary)
                        Picker("Layout", selection: $selectedLayout) {
                            Text("Select…").tag(nil as String?)
                            ForEach(model.layouts, id: \.self) { name in
                                Text(name).tag(name as String?)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 180)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Space").font(.caption).foregroundStyle(.secondary)
                        Picker("Space", selection: $selectedSpaceID) {
                            if isVirtualMode {
                                Text("All Workspaces").tag(nil as Int?)
                            } else {
                                Text("All Spaces").tag(nil as Int?)
                            }
                            ForEach(spaceIDs, id: \.self) { id in
                                Text("Space \(id)").tag(id as Int?)
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 140)
                    }

                    actionButtons
                }

                if let layout = currentLayout {
                    layoutPreview(layout)
                }
            }
            .padding(20)
        }
        .onChange(of: model.layouts) { _, newValue in
            if let sel = selectedLayout, !newValue.contains(sel) {
                selectedLayout = nil
            }
            syncSelectedSpaceSelection()
        }
        .onChange(of: selectedLayout) { _, _ in
            syncSelectedSpaceSelection()
        }
        .onChange(of: model.guiVirtualSpaceStatus) { _, _ in
            syncSelectedSpaceSelection()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            if isVirtualMode {
                arrangeButton(
                    title: selectedSpaceID == nil ? "Apply All Workspaces" : "Apply Selected Space",
                    systemImage: "play.fill",
                    trigger: .apply,
                    stateOnly: false
                )
                .help(selectedSpaceID == nil
                    ? "Resolve and track every virtual workspace window, then apply each workspace frame while keeping the current workspace active"
                    : "Run the live apply step for the selected virtual space")
                arrangeButton(
                    title: selectedSpaceID == nil ? "Initialize All Workspaces" : "Initialize Active Space",
                    systemImage: "square.stack.3d.down.right",
                    trigger: .stateOnly,
                    stateOnly: true
                )
                .help(selectedSpaceID == nil
                    ? "Update runtime state for every virtual workspace without moving windows"
                    : "Step 2 of virtual bootstrap: `arrange <layout> --state-only --space <id>` without moving windows")
            } else {
                arrangeButton(title: "Apply", systemImage: "play.fill", trigger: .apply, stateOnly: false)
                arrangeButton(title: "State Only", systemImage: "square.stack.3d.down.right", trigger: .stateOnly, stateOnly: true)
                    .help("Update runtime state without moving or resizing windows")
            }
            if isVirtualMode, guiStatus.canRecoverWithLiveArrange {
                Button("Recover With Live Arrange") {
                    guard let layout = guiStatus.activeLayoutName ?? selectedLayout,
                          let recoverySpaceID = guiStatus.preferredRecoverySpaceID
                    else {
                        return
                    }
                    model.apply(layout: layout, spaceID: recoverySpaceID, stateOnly: false)
                }
                .buttonStyle(.bordered)
                .disabled(isArrangeRunning)
                .help("Run `arrange <layout> --space <id>` for the preferred recovery space to reconcile workspace visibility")
            }
            if isVirtualMode, guiStatus.canForceClearPendingState {
                Button("Force Clear Pending State") {
                    model.forceClearPendingState()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isArrangeRunning)
                .help("Last resort. Clears pending recovery state only; after success, run `arrange --dry-run --json` and then `arrange <layout> --space <id>`")
            }
        }
    }

    @ViewBuilder
    private func arrangeButton(
        title: String,
        systemImage: String,
        trigger: ArrangeTrigger,
        stateOnly: Bool
    ) -> some View {
        let button = Button {
            guard let layout = selectedLayout else { return }
            model.apply(layout: layout, spaceID: selectedSpaceID, stateOnly: stateOnly)
        } label: {
            HStack(spacing: 6) {
                statusIcon(for: trigger, defaultSystemImage: systemImage)
                Text(title)
            }
        }

        button.buttonStyle(.bordered)
            .disabled(selectedLayout == nil || isArrangeRunning || !buttonIsEnabled(stateOnly: stateOnly))
    }

    @ViewBuilder
    private func statusIcon(for trigger: ArrangeTrigger, defaultSystemImage: String) -> some View {
        switch model.arrangeStatus {
        case let .running(statusTrigger) where statusTrigger == trigger:
            ProgressView().controlSize(.small)
        case let .success(statusTrigger) where statusTrigger == trigger:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(statusTrigger) where statusTrigger == trigger:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default:
            Image(systemName: defaultSystemImage)
        }
    }

    private var isArrangeRunning: Bool {
        if case .running = model.arrangeStatus {
            return true
        }
        return false
    }

    private func buttonIsEnabled(stateOnly: Bool) -> Bool {
        guard isVirtualMode else {
            return true
        }

        if stateOnly {
            return guiStatus.canInitializeActiveSpace
        }

        return guiStatus.blockReason != .busy
            && guiStatus.blockReason != .runtimeStateCorrupted
            && guiStatus.blockReason != .runtimeStateReadPermissionDenied
    }

    private var virtualModeStatusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "square.3.layers.3d", title: "Virtual Mode")

                HStack(spacing: 10) {
                    LabeledValueBadge(label: "Mode", value: guiStatus.mode.rawValue)
                    if let layout = guiStatus.activeLayoutName {
                        LabeledValueBadge(label: "Active Layout", value: layout)
                    }
                    if let activeSpaceID = guiStatus.activeVirtualSpaceID {
                        LabeledValueBadge(label: "Active Space", value: "Space \(activeSpaceID)")
                    }
                }

                Text(virtualModeGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var virtualModeGuidance: String {
        switch guiStatus.blockReason {
        case .busy:
            return "Switch In Progress. Wait for the current virtual-space mutation to finish before retrying."
        case .recoveryRequiresLiveArrange:
            if let recoverySpaceID = guiStatus.preferredRecoverySpaceID {
                return "Recovery Requires Live Arrange. `arrange <layout> --state-only --space <id>` is blocked until `arrange <layout> --space \(recoverySpaceID)` succeeds."
            }
            return "Recovery Requires Live Arrange. `arrange <layout> --state-only --space <id>` is blocked until `arrange <layout> --space <id>` succeeds."
        case .runtimeStateCorrupted:
            return "Runtime State Corrupted. Use diagnostics and the recovery runbook before mutating virtual spaces."
        case .runtimeStateReadPermissionDenied:
            return "Runtime State Unreadable. Repair runtime-state.json permissions, then retry bootstrap or live arrange."
        case .unavailable, nil:
            if guiStatus.activeLayoutName == nil {
                return "Step 1: `arrange --dry-run --json`. Step 2: initialize one workspace with `arrange <layout> --state-only --space <id>` or all workspaces with `arrange <layout> --state-only`. Step 3: `arrange <layout> --space <id>` for one workspace, or `arrange <layout>` to resolve and track every virtual workspace window."
            }
            return "Active state is initialized. Use Apply Selected Space for one workspace, or Apply All Workspaces to refresh tracking and layout frames for every virtual workspace."
        }
    }

    private func syncSelectedSpaceSelection() {
        guard isVirtualMode else {
            selectedSpaceID = nil
            return
        }

        guard selectedLayout != nil else {
            selectedSpaceID = nil
            return
        }

        if selectedSpaceID == nil {
            return
        }

        if let selectedLayout,
           selectedLayout == guiStatus.activeLayoutName,
           let activeSpaceID = guiStatus.activeVirtualSpaceID,
           spaceIDs.contains(activeSpaceID)
        {
            selectedSpaceID = activeSpaceID
            return
        }

        if let selectedSpaceID, spaceIDs.contains(selectedSpaceID) {
            return
        }

        selectedSpaceID = nil
    }

    private func layoutPreview(_ layout: LayoutDefinition) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "rectangle.on.rectangle", title: "Preview")

            ForEach(Array(layout.spaces.enumerated()), id: \.offset) { _, space in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Space \(space.spaceID)").font(.subheadline).bold()
                            if let display = space.display {
                                displayBadge(display)
                            }
                        }

                        VisualLayoutPreview(space: space, compact: true)

                        windowLegend(space.windows)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func windowLegend(_ windows: [WindowDefinition]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, win in
                HStack(spacing: 6) {
                    Circle()
                        .fill(colorForSlot(win.slot))
                        .frame(width: 8, height: 8)
                    Text("\(win.slot)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(colorForSlot(win.slot))
                    Text(win.match.bundleID)
                        .font(.system(.caption, design: .monospaced))
                    if let tm = win.match.title {
                        Text(formatTitleMatcher(tm))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatFrame(win.frame))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Layout Detail View

private struct LayoutDetailView: View {
    let name: String
    let layout: LayoutDefinition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(name)
                    .font(.title2).bold()

                HStack(spacing: 16) {
                    statBadge(
                        icon: "rectangle.split.3x1",
                        label: "Spaces",
                        value: "\(layout.spaces.count)"
                    )
                    statBadge(
                        icon: "macwindow",
                        label: "Windows",
                        value: "\(layout.spaces.reduce(0) { $0 + $1.windows.count })"
                    )
                    if let focus = layout.initialFocus {
                        statBadge(
                            icon: "target",
                            label: "Initial Focus",
                            value: "Slot \(focus.slot)"
                        )
                    }
                }

                ForEach(Array(layout.spaces.enumerated()), id: \.offset) { _, space in
                    spaceSection(space)
                }
            }
            .padding(20)
        }
    }

    private func statBadge(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3).bold()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func spaceSection(_ space: SpaceDefinition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Space \(space.spaceID)")
                    .font(.headline)
                if let display = space.display {
                    displayBadge(display)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            VStack(alignment: .leading, spacing: 8) {
                if space.windows.isEmpty {
                    Text("No windows").foregroundStyle(.secondary)
                } else {
                    VisualLayoutPreview(space: space, compact: false)

                    windowTable(space.windows)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private func windowTable(_ windows: [WindowDefinition]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("")
                Text("Slot")
                Text("Bundle ID")
                Text("Title")
                Text("Frame")
                Text("Launch")
                    .gridColumnAlignment(.center)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            Divider()
                .gridCellUnsizedAxes(.horizontal)

            ForEach(Array(windows.enumerated()), id: \.offset) { _, win in
                GridRow {
                    Circle()
                        .fill(colorForSlot(win.slot))
                        .frame(width: 8, height: 8)

                    Text("\(win.slot)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(colorForSlot(win.slot))

                    Text(win.match.bundleID)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)

                    Group {
                        if let tm = win.match.title {
                            Text(formatTitleMatcher(tm))
                        } else {
                            Text("—").foregroundStyle(.quaternary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)

                    Text(formatFrame(win.frame))
                        .font(.system(.caption, design: .monospaced))

                    Group {
                        if win.launch == true {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        } else {
                            Text("—").foregroundStyle(.quaternary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - General Settings View

private struct GeneralSettingsView: View {
    let config: ShitsuraeConfig?

    private var hasAppSettings: Bool {
        config?.app?.launchAtLogin != nil
    }

    private var hasIgnore: Bool {
        guard let ignore = config?.ignore else { return false }
        let applyApps = ignore.apply?.apps ?? []
        let applyWindows = ignore.apply?.windows ?? []
        let focusApps = ignore.focus?.apps ?? []
        let focusWindows = ignore.focus?.windows ?? []
        return !applyApps.isEmpty || !applyWindows.isEmpty || !focusApps.isEmpty || !focusWindows.isEmpty
    }

    private var hasExecutionPolicy: Bool {
        config?.executionPolicy != nil
    }

    private var hasOverlay: Bool {
        config?.overlay != nil
    }

    private var hasMonitors: Bool {
        config?.monitors != nil
    }

    private var hasAnySettings: Bool {
        hasAppSettings || hasIgnore || hasExecutionPolicy || hasOverlay || hasMonitors
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.title2).bold()

                if !hasAnySettings {
                    ContentUnavailableView(
                        "No settings configured",
                        systemImage: "gearshape",
                        description: Text("Add app, ignore, executionPolicy, overlay, or monitors to your YAML config.")
                    )
                } else {
                    if hasAppSettings {
                        appSection
                    }
                    if hasIgnore {
                        ignoreSection
                    }
                    if hasExecutionPolicy {
                        executionPolicySection
                    }
                    if hasOverlay {
                        overlaySection
                    }
                    if hasMonitors {
                        monitorsSection
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: App

    @ViewBuilder
    private var appSection: some View {
        if let launchAtLogin = config?.app?.launchAtLogin {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "power", title: "App")

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Setting")
                            Text("Value")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        Divider().gridCellUnsizedAxes(.horizontal)

                        GridRow {
                            Text("Launch at Login")
                            BooleanStatusBadge(value: launchAtLogin)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Ignore

    @ViewBuilder
    private var ignoreSection: some View {
        if let ignore = config?.ignore {
            if let apply = ignore.apply, !(apply.apps ?? []).isEmpty || !(apply.windows ?? []).isEmpty {
                ignoreRuleSetBox(context: "Apply", icon: "play.rectangle", ruleSet: apply)
            }
            if let focus = ignore.focus, !(focus.apps ?? []).isEmpty || !(focus.windows ?? []).isEmpty {
                ignoreRuleSetBox(context: "Focus", icon: "target", ruleSet: focus)
            }
        }
    }

    private func ignoreRuleSetBox(context: String, icon: String, ruleSet: IgnoreRuleSet) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "eye.slash", title: "Ignore — \(context)")

                if let apps = ruleSet.apps, !apps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apps").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(apps, id: \.self) { bundleID in
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.7))
                                Text(bundleID)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                }

                if let windows = ruleSet.windows, !windows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window Rules").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(Array(windows.enumerated()), id: \.offset) { _, rule in
                            ignoreWindowRuleRow(rule)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ignoreWindowRuleRow(_ rule: IgnoreWindowRule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.7))

            HStack(spacing: 6) {
                if let bundleID = rule.bundleID {
                    conditionPill("app", bundleID)
                }
                if let titleRegex = rule.titleRegex {
                    conditionPill("title", "/\(titleRegex)/")
                }
                if let role = rule.role {
                    conditionPill("role", role)
                }
                if let subrole = rule.subrole {
                    conditionPill("subrole", subrole)
                }
                if let minimized = rule.minimized {
                    conditionPill("minimized", minimized ? "true" : "false")
                }
                if let hidden = rule.hidden {
                    conditionPill("hidden", hidden ? "true" : "false")
                }
            }
        }
    }

    private func conditionPill(_ label: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Execution Policy

    private var executionPolicySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "arrow.triangle.swap", title: "Execution Policy")

                let policy = config?.resolvedExecutionPolicy ?? ExecutionPolicy()

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Setting")
                        Text("Value")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        Text("Default Space Move")
                        SpaceMoveMethodBadge(method: policy.spaceMoveMethod ?? .drag)
                    }
                }

                if let overrides = policy.spaceMoveMethodInApps, !overrides.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Per-App Overrides").font(.caption.bold()).foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("App")
                                Text("Method")
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)

                            ForEach(overrides.keys.sorted(), id: \.self) { bundleID in
                                if let method = overrides[bundleID] {
                                    GridRow {
                                        Text(bundleID)
                                            .font(.system(.body, design: .monospaced))
                                        SpaceMoveMethodBadge(method: method)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Overlay

    private var overlaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "rectangle.on.rectangle.angled", title: "Overlay")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Setting")
                        Text("Value")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        Text("Show Thumbnails")
                        BooleanStatusBadge(value: config?.overlay?.showThumbnails ?? false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Monitors

    private var monitorsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "display.2", title: "Monitors")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Role")
                        Text("ID")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    if let primary = config?.monitors?.primary {
                        GridRow {
                            Text("Primary")
                                .bold()
                            Text(primary.id ?? "—")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(primary.id != nil ? .primary : .quaternary)
                        }
                    }

                    if let secondary = config?.monitors?.secondary {
                        GridRow {
                            Text("Secondary")
                                .bold()
                            Text(secondary.id ?? "—")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(secondary.id != nil ? .primary : .quaternary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Helpers

}

// MARK: - Shortcuts View

private struct ShortcutsView: View {
    let config: ShitsuraeConfig?

    private var resolved: ResolvedShortcuts {
        ResolvedShortcuts(from: config?.shortcuts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shortcuts")
                    .font(.title2).bold()

                focusBySlotSection
                switchVirtualSpaceSection
                moveCurrentWindowToSpaceSection
                navigationSection
                switcherSection
                globalActionsSection
                disabledInAppsSection
            }
            .padding(20)
        }
    }

    private var focusBySlotSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "number", title: "Focus by Slot")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Slot")
                        Text("Shortcut")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(1 ... 9, id: \.self) { slot in
                        if let hotkey = resolved.focusBySlot[slot] {
                            GridRow {
                                slotLabel(slot)
                                hotkeyLabel(hotkey)
                            }
                        }
                    }
                }

                if !resolved.focusBySlotEnabledInApps.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Per-App Overrides").font(.caption.bold()).foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("App")
                                Text("Enabled")
                            }
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)

                            ForEach(resolved.focusBySlotEnabledInApps.keys.sorted(), id: \.self) { bundleID in
                                if let enabled = resolved.focusBySlotEnabledInApps[bundleID] {
                                    GridRow {
                                        Text(bundleID)
                                            .font(.system(.body, design: .monospaced))
                                        BooleanStatusBadge(value: enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var navigationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "arrow.up.arrow.down", title: "Window Navigation")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Action")
                        Text("Shortcut")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        Text("Next Window")
                        hotkeyLabel(resolved.nextWindow)
                    }
                    GridRow {
                        Text("Prev Window")
                        hotkeyLabel(resolved.prevWindow)
                    }
                    GridRow {
                        Text("Cycle Mode")
                        Text(resolved.cycleMode.rawValue)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Cycle Quick Keys")
                        Text(resolved.cycleQuickKeys)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Cycle Accept Keys")
                        Text(resolved.cycleAcceptKeys.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Cycle Cancel Keys")
                        Text(resolved.cycleCancelKeys.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if !resolved.cycleExcludedApps.isEmpty {
                    excludedAppsRow("Cycle excluded", apps: resolved.cycleExcludedApps.sorted())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var moveCurrentWindowToSpaceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "rectangle.portrait.and.arrow.right", title: "Move Current Window to Workspace")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Workspace")
                        Text("Shortcut")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(1 ... 9, id: \.self) { spaceID in
                        if let hotkey = resolved.moveCurrentWindowToSpace[spaceID] {
                            GridRow {
                                slotLabel(spaceID)
                                hotkeyLabel(hotkey)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var switchVirtualSpaceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "rectangle.2.swap", title: "Switch Virtual Workspace")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Workspace")
                        Text("Shortcut")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(1 ... 9, id: \.self) { spaceID in
                        if let hotkey = resolved.switchVirtualSpace[spaceID] {
                            GridRow {
                                slotLabel(spaceID)
                                hotkeyLabel(hotkey)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var switcherSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "rectangle.stack", title: "Switcher")

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Setting")
                        Text("Value")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        Text("Trigger")
                        hotkeyLabel(resolved.switcherTrigger)
                    }
                    GridRow {
                        Text("Scope")
                        Text("Current Space only")
                    }
                    GridRow {
                        Text("Quick Keys")
                        Text(resolved.quickKeys)
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Accept Keys")
                        Text(resolved.acceptKeys.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Cancel Keys")
                        Text(resolved.cancelKeys.joined(separator: ", "))
                            .font(.system(.body, design: .monospaced))
                    }
                }

                if !resolved.switcherExcludedApps.isEmpty {
                    excludedAppsRow("Excluded apps", apps: resolved.switcherExcludedApps.sorted())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var globalActionsSection: some View {
        if !resolved.globalActions.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "bolt.fill", title: "Global Actions")

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow {
                            Text("Shortcut")
                            Text("Action")
                            Text("Detail")
                        }
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                        Divider().gridCellUnsizedAxes(.horizontal)

                        ForEach(Array(resolved.globalActions.enumerated()), id: \.offset) { _, action in
                            GridRow {
                                hotkeyLabel(HotkeyDefinition(key: action.key, modifiers: action.modifiers))

                                Text(action.action.type.rawValue)
                                    .font(.system(.body, design: .monospaced))

                                Text(globalActionDetail(action.action))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var disabledInAppsSection: some View {
        if !resolved.disabledInApps.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(icon: "xmark.app", title: "Disabled in Apps")

                    ForEach(resolved.disabledInApps.keys.sorted(), id: \.self) { bundleID in
                        if let shortcuts = resolved.disabledInApps[bundleID] {
                            HStack(alignment: .top, spacing: 8) {
                                Text(shortBundleID(bundleID))
                                    .font(.system(.body, design: .monospaced))
                                    .bold()
                                Text(shortcuts.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func hotkeyLabel(_ hotkey: HotkeyDefinition) -> some View {
        HStack(spacing: 4) {
            ForEach(hotkey.modifiers, id: \.self) { mod in
                Text(modifierSymbol(mod))
                    .font(.system(.body))
            }
            Text(hotkey.key.uppercased())
                .font(.system(.body, design: .monospaced))
                .bold()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func slotLabel(_ slot: Int) -> some View {
        Text("\(slot)")
            .font(.system(.caption, design: .monospaced).bold())
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private func excludedAppsRow(_ label: String, apps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(apps.map { shortBundleID($0) }.joined(separator: ", "))
                .font(.system(.caption, design: .monospaced))
        }
    }

    private func modifierSymbol(_ mod: String) -> String {
        switch mod {
        case "cmd": return "\u{2318}"
        case "shift": return "\u{21E7}"
        case "ctrl": return "\u{2303}"
        case "alt": return "\u{2325}"
        case "fn": return "fn"
        default: return mod
        }
    }

    private func globalActionDetail(_ action: GlobalActionDefinition) -> String {
        if let preset = action.preset {
            return preset.rawValue
        }
        var parts: [String] = []
        if let x = action.x { parts.append("x: \(formatLength(x))") }
        if let y = action.y { parts.append("y: \(formatLength(y))") }
        if let w = action.width { parts.append("w: \(formatLength(w))") }
        if let h = action.height { parts.append("h: \(formatLength(h))") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Permissions View

private struct PermissionsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions")
                    .font(.title2).bold()

                permissionRow(
                    icon: "hand.raised.fill",
                    name: "Accessibility",
                    description: "Required to move and resize windows.",
                    granted: SystemProbe.accessibilityGranted(),
                    required: true
                )

                permissionRow(
                    icon: "rectangle.dashed.badge.record",
                    name: "Screen Recording",
                    description: "Required to read window titles and positions.",
                    granted: SystemProbe.screenRecordingGranted(),
                    required: true
                )

                permissionRow(
                    icon: "gearshape.2.fill",
                    name: "Automation",
                    description: "Used for space switching via AppleScript.",
                    granted: false,
                    required: false
                )

                Divider()

                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(20)
        }
    }

    private func permissionRow(
        icon: String, name: String, description: String,
        granted: Bool, required: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.body).bold()
                    Text(required ? "Required" : "Optional")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            required ? Color.red.opacity(0.15) : Color.gray.opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(required ? .red : .secondary)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(granted ? "Granted" : "Not Granted")
                .font(.callout)
                .foregroundStyle(granted ? .green : .orange)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Window Status View

private struct WindowStatusView: View {
    @ObservedObject var model: AppModel

    private var state: RuntimeState? {
        model.runtimeStateSnapshot
    }

    private var slotsBySpace: [SlotSpaceGroup] {
        state?.slotsBySpace() ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Window Status")
                        .font(.title2).bold()
                    Spacer()
                    Button {
                        model.refreshWindowStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh window status")
                }

                if let state {
                    runtimeSummary(state)

                    if state.slots.isEmpty {
                        ContentUnavailableView(
                            "No tracked windows",
                            systemImage: "macwindow",
                            description: Text("Run Arrange to start tracking window positions.")
                        )
                    } else {
                        ForEach(slotsBySpace, id: \.spaceID) { group in
                            spaceSection(spaceID: group.spaceID, slots: group.slots)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No runtime state",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Runtime state is not yet available.")
                    )
                }
            }
            .padding(20)
        }
    }

    private func runtimeSummary(_ state: RuntimeState) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(icon: "info.circle", title: "Runtime State")

                HStack(spacing: 10) {
                    LabeledValueBadge(label: "Mode", value: state.stateMode.rawValue)
                    if let layout = state.activeLayoutName {
                        LabeledValueBadge(label: "Active Layout", value: layout)
                    }
                    if let spaceID = state.activeVirtualSpaceID {
                        LabeledValueBadge(label: "Active Space", value: "Space \(spaceID)")
                    }
                    LabeledValueBadge(label: "Tracked Windows", value: "\(state.slots.count)")
                    LabeledValueBadge(label: "Revision", value: "\(state.revision)")
                }

                Text("Updated: \(state.updatedAt)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func spaceSection(spaceID: Int, slots: [SlotEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(spaceID == 0 ? "Unassigned" : "Space \(spaceID)")
                    .font(.headline)
                Text("\(slots.count) windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activeSpaceID = state?.activeVirtualSpaceID, activeSpaceID == spaceID {
                    Text("Active")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            VStack(alignment: .leading, spacing: 0) {
                WindowPositionPreview(slots: slots)
                    .padding(.vertical, 8)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        Text("Slot")
                        Text("App")
                        Text("Title")
                        Text("Frame")
                    }
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(Array(slots.enumerated()), id: \.offset) { _, entry in
                        GridRow {
                            Circle()
                                .fill(colorForSlot(entry.slot))
                                .frame(width: 8, height: 8)

                            Text("\(entry.slot)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(colorForSlot(entry.slot))

                            VStack(alignment: .leading, spacing: 1) {
                                Text(shortBundleID(entry.bundleID))
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                if let wid = entry.windowID {
                                    Text("wid:\(wid)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Text(entry.lastKnownTitle ?? "—")
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(entry.lastKnownTitle != nil ? .primary : .quaternary)

                            frameCell(entry)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func frameCell(_ entry: SlotEntry) -> some View {
        let frame = entry.lastVisibleFrame
        if let frame {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Int(frame.x)), \(Int(frame.y))")
                    .font(.system(.caption, design: .monospaced))
                Text("\(Int(frame.width)) \u{00D7} \(Int(frame.height))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
    }

}

// MARK: - Window Position Preview

private struct WindowPositionPreview: View {
    let slots: [SlotEntry]

    private var displayBounds: CGRect {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return screen
    }

    private var slotsWithFrames: [(entry: SlotEntry, frame: ResolvedFrame)] {
        slots.compactMap { entry in
            guard let frame = entry.lastVisibleFrame else { return nil }
            return (entry: entry, frame: frame)
        }
    }

    private var previewBounds: CGRect {
        guard !slotsWithFrames.isEmpty else {
            return CGRect(origin: .zero, size: CGSize(width: displayBounds.width, height: displayBounds.height))
        }
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for item in slotsWithFrames {
            let f = item.frame
            minX = min(minX, f.x)
            minY = min(minY, f.y)
            maxX = max(maxX, f.x + f.width)
            maxY = max(maxY, f.y + f.height)
        }
        minX = min(minX, 0)
        minY = min(minY, 0)
        maxX = max(maxX, displayBounds.width)
        maxY = max(maxY, displayBounds.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var body: some View {
        let bounds = previewBounds
        let aspectRatio = bounds.height / bounds.width

        GeometryReader { geo in
            let previewWidth = geo.size.width
            let previewHeight = previewWidth * aspectRatio

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )

                ForEach(Array(slotsWithFrames.enumerated()), id: \.offset) { _, item in
                    let color = colorForSlot(item.entry.slot)
                    let isHidden = item.entry.visibilityState == .hiddenOffscreen
                    let f = item.frame
                    let nx = (f.x - bounds.origin.x) / bounds.width
                    let ny = (f.y - bounds.origin.y) / bounds.height
                    let nw = f.width / bounds.width
                    let nh = f.height / bounds.height
                    let gap: CGFloat = 1.5

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(isHidden ? 0.05 : 0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(
                                    color.opacity(isHidden ? 0.2 : 0.5),
                                    style: isHidden ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
                                )
                        )
                        .overlay {
                            VStack(spacing: 1) {
                                Text("\(item.entry.slot)")
                                    .font(.system(.caption2, design: .rounded, weight: .bold))
                                    .foregroundStyle(color.opacity(isHidden ? 0.5 : 1))
                                Text(shortBundleID(item.entry.bundleID))
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary.opacity(isHidden ? 0.5 : 1))
                                    .lineLimit(1)
                            }
                        }
                        .frame(
                            width: max(0, previewWidth * nw - gap * 2),
                            height: max(0, previewHeight * nh - gap * 2)
                        )
                        .position(
                            x: previewWidth * (nx + nw / 2),
                            y: previewHeight * (ny + nh / 2)
                        )
                }
            }
            .frame(height: previewHeight)
        }
        .aspectRatio(1 / aspectRatio, contentMode: .fit)
        .frame(maxWidth: 400)
    }
}

// MARK: - Visual Layout Preview

private struct VisualLayoutPreview: View {
    let space: SpaceDefinition
    let compact: Bool

    private var displayAspectRatio: CGFloat {
        let screen = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        return screen.height / screen.width
    }

    var body: some View {
        GeometryReader { geo in
            let previewWidth = geo.size.width
            let previewHeight = previewWidth * displayAspectRatio
            let rects = space.windows.map { win in
                (win: win, rect: resolveProportionalRect(frame: win.frame))
            }

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )

                ForEach(Array(rects.enumerated()), id: \.offset) { _, item in
                    let color = colorForSlot(item.win.slot)
                    let r = item.rect
                    let gap: CGFloat = 1.5

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(color.opacity(0.5), lineWidth: 1)
                        )
                        .overlay {
                            VStack(spacing: 2) {
                                Text("\(item.win.slot)")
                                    .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .bold))
                                    .foregroundStyle(color)
                                Text(shortBundleID(item.win.match.bundleID))
                                    .font(.system(size: compact ? 8 : 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(
                            width: max(0, previewWidth * r.width - gap * 2),
                            height: max(0, previewHeight * r.height - gap * 2)
                        )
                        .position(
                            x: previewWidth * (r.x + r.width / 2),
                            y: previewHeight * (r.y + r.height / 2)
                        )
                }
            }
            .frame(height: previewHeight)
        }
        .aspectRatio(1 / displayAspectRatio, contentMode: .fit)
        .frame(maxWidth: compact ? 280 : 400)
    }
}

// MARK: - Helpers

private let slotColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .yellow, .indigo, .mint]

private func colorForSlot(_ slot: Int) -> Color {
    guard slot >= 1, slot <= slotColors.count else { return .gray }
    return slotColors[slot - 1]
}

private func shortBundleID(_ bundleID: String) -> String {
    bundleID.split(separator: ".").last.map(String.init) ?? bundleID
}

private struct ProportionalRect {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private func lengthToProportion(_ value: LengthValue, referenceDimension: Double) -> Double {
    guard let parsed = try? LengthParser.parse(value) else { return 0 }
    switch parsed.unit {
    case .percent:
        return parsed.value / 100.0
    case .ratio:
        return parsed.value
    case .pt:
        return referenceDimension > 0 ? parsed.value / referenceDimension : 0
    case .px:
        let points = parsed.value / 2.0
        return referenceDimension > 0 ? points / referenceDimension : 0
    }
}

private func resolveProportionalRect(frame: FrameDefinition) -> ProportionalRect {
    let refWidth: Double = 1440
    let refHeight: Double = 900
    return ProportionalRect(
        x: lengthToProportion(frame.x, referenceDimension: refWidth),
        y: lengthToProportion(frame.y, referenceDimension: refHeight),
        width: lengthToProportion(frame.width, referenceDimension: refWidth),
        height: lengthToProportion(frame.height, referenceDimension: refHeight)
    )
}

private func displayBadge(_ display: DisplayDefinition) -> some View {
    Group {
        if let monitor = display.monitor {
            Text(monitor.rawValue)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        } else if let id = display.id {
            Text(id.prefix(8) + "…")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.blue.opacity(0.15), in: Capsule())
                .foregroundStyle(.blue)
        }
    }
}

private func formatLength(_ value: LengthValue) -> String {
    switch value {
    case let .pt(v):
        if v == v.rounded() {
            return "\(Int(v))"
        }
        return String(format: "%.1f", v)
    case let .expression(s):
        return s
    }
}

private func formatFrame(_ frame: FrameDefinition) -> String {
    let x = formatLength(frame.x)
    let y = formatLength(frame.y)
    let w = formatLength(frame.width)
    let h = formatLength(frame.height)
    return "\(x), \(y)  \(w) \u{00D7} \(h)"
}

private func formatTitleMatcher(_ matcher: TitleMatcher) -> String {
    if let eq = matcher.equals {
        return "title = \"\(eq)\""
    }
    if let c = matcher.contains {
        return "title ~ \"\(c)\""
    }
    if let r = matcher.regex {
        return "title \u{2248} /\(r)/"
    }
    return ""
}

// MARK: - Entry Point

ShitsuraeMenuBarApp.main()
