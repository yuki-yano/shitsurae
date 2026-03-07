import AppKit
import Darwin
import Foundation
import ShitsuraeCore
import SwiftUI

// MARK: - App

struct ShitsuraeMenuBarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            let currentSpaceID = WindowQueryService.focusedWindow()?.spaceID
            if model.layouts.isEmpty {
                Text("No layouts")
            } else {
                ForEach(model.layouts, id: \.self) { layout in
                    Menu(layout) {
                        Button("Apply All") {
                            model.apply(layout: layout)
                        }

                        Button("Apply Current Space") {
                            model.apply(layout: layout, spaceID: currentSpaceID)
                        }
                        .disabled(currentSpaceID == nil)
                    }
                }
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
            Image(systemName: "rectangle.3.group")
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
    case diagnostics
}

// MARK: - ArrangeStatus

private enum ArrangeStatus: Equatable {
    case idle
    case running
    case success
    case failed
}

// MARK: - AppModel

@MainActor
private final class AppModel: ObservableObject {
    @Published var layouts: [String] = []
    @Published var config: ShitsuraeConfig?
    @Published var configError: String?
    @Published var diagnosticsText = "{}"
    @Published var arrangeStatus: ArrangeStatus = .idle

    let commandService: CommandService
    private let shortcutManager: ShortcutManager
    private var shutdownPerformed = false

    init() {
        commandService = CommandService(enableAutoReloadMonitor: true)
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
            config = loaded.config
            configError = nil
            layouts = loaded.config.layouts.keys.sorted()
        } catch {
            config = nil
            configError = error.localizedDescription
            layouts = []
        }
    }

    func apply(layout: String, spaceID: Int? = nil) {
        arrangeStatus = .running
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RemoteCommandService().arrange(
                layoutName: layout, spaceID: spaceID,
                dryRun: false, verbose: false, json: false
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.arrangeStatus = result.exitCode == 0 ? .success : .failed
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.arrangeStatus == .success || self.arrangeStatus == .failed {
                        self.arrangeStatus = .idle
                    }
                }
            }
        }
    }

    func refreshDiagnostics() {
        let result = commandService.diagnostics(json: true)
        diagnosticsText = result.stdout.isEmpty ? "{}" : result.stdout
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
            _ = AgentXPCClient().execute(
                AgentCommandRequest(
                    command: .diagnostics,
                    json: true,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
                    x: nil,
                    y: nil,
                    width: nil,
                    height: nil
                )
            )
        }
    }

    private func terminateAgentProcess() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(AgentXPCConstants.launchAgentLabel)"
        runProcess(executable: "/bin/launchctl", arguments: ["bootout", service])
        runProcess(executable: "/usr/bin/pkill", arguments: ["-x", "ShitsuraeAgent"])
    }

    private func shutdownIfNeeded() {
        guard !shutdownPerformed else { return }
        shutdownPerformed = true
        shortcutManager.stop()
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
                case .diagnostics:
                    DiagnosticsView(text: model.diagnosticsText)
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

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Layout").font(.caption).foregroundStyle(.secondary)
                        Picker("Layout", selection: $selectedLayout) {
                            Text("Select…").tag(nil as String?)
                            ForEach(model.layouts, id: \.self) { name in
                                Text(name).tag(name as String?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Space").font(.caption).foregroundStyle(.secondary)
                        Picker("Space", selection: $selectedSpaceID) {
                            Text("All Spaces").tag(nil as Int?)
                            ForEach(spaceIDs, id: \.self) { id in
                                Text("Space \(id)").tag(id as Int?)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                    applyButton
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
        }
        .onChange(of: selectedLayout) { _, _ in
            selectedSpaceID = nil
        }
    }

    @ViewBuilder
    private var applyButton: some View {
        Button {
            guard let layout = selectedLayout else { return }
            model.apply(layout: layout, spaceID: selectedSpaceID)
        } label: {
            HStack(spacing: 6) {
                switch model.arrangeStatus {
                case .idle:
                    Image(systemName: "play.fill")
                case .running:
                    ProgressView().controlSize(.small)
                case .success:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                Text("Apply")
            }
        }
        .disabled(selectedLayout == nil || model.arrangeStatus == .running)
        .padding(.top, 16)
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
        hasIgnore || hasExecutionPolicy || hasOverlay || hasMonitors
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
                        description: Text("Add ignore, executionPolicy, overlay, or monitors to your YAML config.")
                    )
                } else {
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
                        methodBadge(policy.spaceMoveMethod ?? .drag)
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
                                        methodBadge(method)
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

    private func methodBadge(_ method: SpaceMoveMethod) -> some View {
        Text(method.rawValue)
            .font(.system(.caption, design: .monospaced).bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                method == .drag ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(method == .drag ? .blue : .orange)
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
                        generalBoolBadge(config?.overlay?.showThumbnails ?? false)
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

    private func generalBoolBadge(_ value: Bool) -> some View {
        Text(value ? "ON" : "OFF")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                value ? Color.green.opacity(0.15) : Color.gray.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(value ? .green : .secondary)
    }
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
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(colorForSlot(slot))
                                        .frame(width: 8, height: 8)
                                    Text("\(slot)")
                                        .foregroundStyle(colorForSlot(slot))
                                }
                                .font(.system(.body, design: .monospaced))

                                hotkeyLabel(hotkey)
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
                }

                if !resolved.cycleExcludedApps.isEmpty {
                    excludedAppsRow("Cycle excluded", apps: resolved.cycleExcludedApps.sorted())
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
                        Text("Include All Spaces")
                        boolBadge(resolved.includeAllSpaces)
                    }
                    GridRow {
                        Text("Prioritize Current Space")
                        boolBadge(resolved.prioritizeCurrentSpace)
                    }
                    GridRow {
                        Text("Accept on Modifier Release")
                        boolBadge(resolved.acceptOnModifierRelease)
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

    private func boolBadge(_ value: Bool) -> some View {
        Text(value ? "ON" : "OFF")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                value ? Color.green.opacity(0.15) : Color.gray.opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(value ? .green : .secondary)
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

// MARK: - Diagnostics View

private struct DiagnosticsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.headline)
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
