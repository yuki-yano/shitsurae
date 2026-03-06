import AppKit
import Darwin
import Foundation
import ShitsuraeCore
import SwiftUI

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

            Button("Preferences") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }

            Button("Diagnostics") {
                model.refreshDiagnostics()
                openWindow(id: "diagnostics")
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

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(text: model.diagnosticsText)
        }
        .defaultSize(width: 700, height: 460)

        Settings {
            PreferencesView(model: model)
        }
    }
}

@MainActor
private final class AppModel: ObservableObject {
    @Published var layouts: [String] = []
    @Published var diagnosticsText = "{}"

    private let commandService: CommandService
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
            guard let self else {
                return
            }
            self.shortcutManager.start()
            self.reloadConfig()
            self.refreshDiagnostics()
        }
    }

    func reloadConfig() {
        let result = commandService.layoutsList()
        if result.exitCode == 0 {
            let names = result.stdout
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            layouts = names
        } else {
            layouts = []
        }
    }

    func apply(layout: String, spaceID: Int? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = RemoteCommandService().arrange(layoutName: layout, spaceID: spaceID, dryRun: false, verbose: false, json: false)
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

    func validationStatusText() -> String {
        let result = commandService.validate(json: true)
        return result.exitCode == 0 ? "Config loaded" : "Config invalid"
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

        // LaunchAgent 管理外の手動起動プロセスも停止する。
        runProcess(executable: "/usr/bin/pkill", arguments: ["-x", "ShitsuraeAgent"])
    }

    private func shutdownIfNeeded() {
        guard !shutdownPerformed else {
            return
        }

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

private struct PreferencesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            PermissionsTab()
                .tabItem { Label("Permissions", systemImage: "checkmark.shield") }

            ShortcutsTab(model: model)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            DiagnosticsView(text: model.diagnosticsText)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct PermissionsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.title2)
                .bold()

            permissionRow(name: "Accessibility", granted: SystemProbe.accessibilityGranted())
            permissionRow(name: "Screen Recording", granted: SystemProbe.screenRecordingGranted())
            permissionRow(name: "Automation", granted: false)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(name: String, granted: Bool) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .foregroundStyle(granted ? .green : .orange)
        }
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts")
                .font(.title2)
                .bold()

            Text(model.validationStatusText())

            Text("Cmd+1 ... Cmd+9")
            Text("Cmd+Ctrl+J / Cmd+Ctrl+K")
            Text("Cmd+Tab")

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticsView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

ShitsuraeMenuBarApp.main()
