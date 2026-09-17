import AppKit
import SwiftUI
import ShitsuraeCore

// Main window UI, structured like v1: a sidebar with Arrange, one item per
// layout (with visual previews), settings and system sections.

enum SidebarItem: Hashable {
    case arrange
    case workspaceState
    case layout(String)
    case general
    case shortcuts
    case permissions
    case diagnostics
}

struct DisplayLayoutChoice: Identifiable, Equatable {
    let displayID: String
    let isPrimary: Bool
    let monitorAlias: String?
    let layoutNames: [String]
    let activeLayoutName: String?

    var id: String { displayID }
    var title: String {
        monitorAlias.map { "\($0) Display" }
            ?? (isPrimary ? "Primary Display" : "Display \(displayID.prefix(8))…")
    }
}

struct DisplayLayoutSelection: Identifiable, Equatable {
    let displayID: String
    let displayTitle: String
    let layoutName: String
    let spaceID: Int?

    var id: String { displayID }
}

func selectedDisplayLayouts(
    choices: [DisplayLayoutChoice],
    selectionByDisplayID: [String: String],
    spaceByDisplayID: [String: Int]
) -> [DisplayLayoutSelection] {
    choices.compactMap { choice in
        guard let layoutName = selectionByDisplayID[choice.displayID] else {
            return nil
        }
        return DisplayLayoutSelection(
            displayID: choice.displayID,
            displayTitle: choice.title,
            layoutName: layoutName,
            spaceID: spaceByDisplayID[choice.displayID]
        )
    }
}

struct MainWindowView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .arrange

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Actions") {
                    Label("Arrange", systemImage: "play.rectangle")
                        .tag(SidebarItem.arrange)
                    Label("Workspace State", systemImage: "rectangle.3.group")
                        .tag(SidebarItem.workspaceState)
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch selection {
                case .arrange, nil:
                    ArrangeView()
                case .workspaceState:
                    WorkspaceStateSection()
                case let .layout(name):
                    if let layout = model.configManager.configIfLoaded()?.config.layouts[name] {
                        LayoutDetailView(name: name, layout: layout)
                    } else {
                        ContentUnavailableView("Layout not found", systemImage: "exclamationmark.triangle")
                    }
                case .general:
                    GeneralSection()
                case .shortcuts:
                    ShortcutsSection()
                case .permissions:
                    PermissionsSection()
                case .diagnostics:
                    DiagnosticsSection()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 560)
        .disabled(!model.startupStatus.isReady)
        .overlay {
            if !model.startupStatus.isReady {
                StartupLoadingView(status: model.startupStatus)
            }
        }
        .onAppear { model.refreshStatus() }
    }
}

private struct StartupLoadingView: View {
    let status: AppStartupStatus

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)

            VStack(spacing: 5) {
                Text("Getting Shitsurae ready…")
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            progressView
                .frame(width: 240)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private var detail: String {
        switch status {
        case .preparing:
            "Preparing services"
        case let .monitoringApplications(completed, total):
            "Monitoring running applications \(completed) of \(total)"
        case .ready:
            "Ready"
        }
    }

    @ViewBuilder
    private var progressView: some View {
        switch status {
        case .preparing:
            ProgressView()
        case let .monitoringApplications(completed, total) where total > 0:
            ProgressView(value: Double(completed), total: Double(total))
        case .monitoringApplications, .ready:
            ProgressView()
        }
    }
}

// MARK: - Arrange

struct ArrangeView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectionByDisplayID: [String: String] = [:]
    @State private var spaceByDisplayID: [String: Int] = [:]
    @State private var selectedLayoutSetName: String?

    private var operationRunning: Bool {
        model.actionStatus.isRunning || model.arrangeStatus.active != nil
    }

    private var selectedLayoutSet: LayoutSetPresentation? {
        model.layoutSetPresentations.first { $0.name == selectedLayoutSetName }
    }

    private var spaceIDsByLayout: [String: [Int]] {
        guard let config = model.configManager.configIfLoaded()?.config else { return [:] }
        return config.layouts.mapValues { layout in
            layout.spaces.map(\.spaceID).sorted()
        }
    }

    private var displayLayoutChoices: [DisplayLayoutChoice] {
        guard let config = model.configManager.configIfLoaded()?.config else { return [] }
        let activeByDisplayID = Dictionary(
            uniqueKeysWithValues: (model.diagnostics?.state.activeWorkspaces ?? []).map {
                ($0.displayID, $0.layoutName)
            }
        )
        return model.displays
            .sorted {
                if $0.isPrimary != $1.isPrimary { return $0.isPrimary }
                return $0.id < $1.id
            }
            .compactMap { display in
                let candidates = model.layouts.filter { name in
                    guard let layout = config.layouts[name] else { return false }
                    return DisplayResolver.hostDisplay(
                        layout: layout,
                        config: config,
                        displays: model.displays
                    )?.id == display.id
                }
                guard !candidates.isEmpty else { return nil }
                return DisplayLayoutChoice(
                    displayID: display.id,
                    isPrimary: display.isPrimary,
                    monitorAlias: DisplayResolver.alias(
                        for: display.id,
                        config: config,
                        displays: model.displays
                    ),
                    layoutNames: candidates,
                    activeLayoutName: activeByDisplayID[display.id]
                )
            }
    }

    private var previewSelections: [DisplayLayoutSelection] {
        selectedDisplayLayouts(
            choices: displayLayoutChoices,
            selectionByDisplayID: selectionByDisplayID,
            spaceByDisplayID: spaceByDisplayID
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Arrange")
                    .font(.title2).bold()

                statusCard

                if model.shouldOfferWindowRecovery {
                    recoverySection
                }

                if !model.configErrors.isEmpty {
                    ConfigErrorBox(errors: model.configErrors)
                    Button("Open Config Directory") { model.openConfigDirectory() }
                } else if model.layouts.isEmpty {
                    Text("No layouts defined. Add YAML files to the config directory.")
                        .foregroundStyle(.secondary)
                    Button("Open Config Directory") { model.openConfigDirectory() }
                } else {
                    layoutSetSection
                    DisplayArrangeSection(
                        choices: displayLayoutChoices,
                        spaceIDsByLayout: spaceIDsByLayout,
                        isRunning: operationRunning,
                        selectionByDisplayID: $selectionByDisplayID,
                        spaceByDisplayID: $spaceByDisplayID,
                        onApplyLayout: { layoutName, spaceID in
                            model.applyLayoutFromMainWindow(layoutName, spaceID: spaceID)
                        },
                        onApplyDisplaySet: model.applyLayoutsFromMainWindow
                    )

                    if case let .failed(label, message) = model.actionStatus {
                        Label("\(label): \(message)", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    if case let .partial(label, message) = model.actionStatus {
                        Label("\(label): \(message)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }

                    if !previewSelections.isEmpty {
                        displaySetPreview(previewSelections)
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: synchronizeLayoutSetSelection)
        .onChange(of: model.layoutSetPresentations) {
            synchronizeLayoutSetSelection()
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Virtual Workspaces", systemImage: "square.3.layers.3d")
                    .font(.headline)

                HStack(spacing: 10) {
                    badge(
                        label: "Layout Set",
                        value: model.runtimeState.selectedLayoutSet?.name ?? "Manual"
                    )
                    badge(
                        label: "Active Space",
                        value: model.activeSpaceID.map { "Space \($0)" } ?? "—"
                    )
                    if model.arrangeStatus.pendingTransition != nil || model.diagnostics?.state.needsReapply == true {
                        badge(label: "Recovery", value: "required", tint: .orange)
                    }
                }

                if let active = model.arrangeStatus.active {
                    Label(
                        "\(active.operation.displayLabel): \(active.phase.displayLabel) · \(active.elapsedMS) ms",
                        systemImage: "hourglass"
                    )
                    .font(.caption)
                    if let reason = active.waitingReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if active.deadlineExceeded {
                        Text("The deadline was exceeded; the current system call may still be in flight.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let outcome = model.arrangeStatus.lastOutcome {
                    Text("Last: \(outcome.operation.displayLabel) · \(outcome.result) · exit \(outcome.exitCode)")
                        .font(.caption)
                        .foregroundStyle(outcome.exitCode == 0 ? Color.secondary : Color.orange)
                    if let detail = outcome.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.arrangeStatus.pendingTransition != nil {
                    Text("Some windows may still be hidden or misplaced. Restore them before applying again.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Restore Managed Windows") { model.recoverLayoutsFromMainWindow() }
                        .disabled(operationRunning)
                }

                if model.activeLayoutName == nil {
                    Text("Choose a display layout and press Apply — windows are launched, placed and tracked from scratch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let workspaces = model.diagnostics?.state.activeWorkspaces ?? []
                ForEach(workspaces, id: \.layoutName) { workspace in
                    WorkspaceSpaceControls(
                        workspace: workspace,
                        isPrimary: model.displays.first(where: { $0.id == workspace.displayID })?.isPrimary == true,
                        monitorAlias: DisplayResolver.alias(
                            for: workspace.displayID,
                            config: model.configManager.configIfLoaded()?.config,
                            displays: model.displays
                        ),
                        spaceIDs: model.configManager.configIfLoaded()?.config.layouts[workspace.layoutName]?
                            .spaces.map(\.spaceID).sorted() ?? [],
                        isRunning: operationRunning,
                        onSwitch: { spaceID in
                            model.switchSpace(
                                layoutName: workspace.layoutName,
                                to: spaceID,
                                focusPolicy: workspace.displayID == model.displays.first(where: \.isPrimary)?.id
                                    ? .target
                                    : .preserve
                            )
                        }
                    )
                    if workspace.layoutName != workspaces.last?.layoutName {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var recoverySection: some View {
        GroupBox("Restore") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restore managed windows to the current primary display and stop managing the affected scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Restore Windows and Stop Managing", systemImage: "arrow.uturn.backward.circle") {
                    model.recoverLayoutsFromMainWindow()
                }
                .buttonStyle(.borderedProminent)
                .disabled(operationRunning)
                .accessibilityHint("Restores reachable windows and removes their workspace management state")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var layoutSetSection: some View {
        GroupBox("Layout Sets") {
            VStack(alignment: .leading, spacing: 10) {
                if model.layoutSetPresentations.isEmpty {
                    Text("No layout sets are defined. Add layoutSets to the YAML config; individual display layouts remain available below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Config Directory") { model.openConfigDirectory() }
                } else {
                    Picker("Layout Set", selection: $selectedLayoutSetName) {
                        ForEach(model.layoutSetPresentations) { item in
                            Text(item.name).tag(item.name as String?)
                        }
                    }
                    .accessibilityLabel("Layout Set")
                    .accessibilityHint("Selects a layout set without applying it")

                    if let item = selectedLayoutSet {
                        ForEach(item.members) { member in
                            HStack {
                                Text(member.layoutName).font(.subheadline.bold())
                                Text(member.managementState).font(.caption)
                                Text(member.resolvedDisplayID.map(shortDisplayID) ?? "display unavailable")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(member.issue == nil ? Color.secondary : Color.orange)
                                Spacer()
                                Text("\(member.spaceCount) spaces · target \(member.targetSpaceID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            if let displayID = member.resolvedDisplayID,
                               let layout = model.configManager.configIfLoaded()?.config.layouts[member.layoutName]
                            {
                                layoutPreview(
                                    selection: DisplayLayoutSelection(
                                        displayID: displayID,
                                        displayTitle: shortDisplayID(displayID),
                                        layoutName: member.layoutName,
                                        spaceID: member.targetSpaceID
                                    ),
                                    layout: layout
                                )
                            }
                        }
                        Text("\(item.releasedCount) currently managed windows may be shown on the primary display and released from management. Windows claimed by the new set are transferred instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reason = item.blockingReason {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if item.needsReapply {
                            Label("Needs Reapply", systemImage: "arrow.clockwise")
                                .font(.caption.bold())
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Spacer()
                            Button("Apply Layout Set", systemImage: "rectangle.3.group") {
                                model.applyLayoutSetFromMainWindow(item.name)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!item.canApply || operationRunning)
                            .accessibilityHint("Replaces the complete managed layout scope with this set")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func synchronizeLayoutSetSelection() {
        let presentations = model.layoutSetPresentations
        guard !presentations.isEmpty else {
            selectedLayoutSetName = nil
            return
        }
        if let selectedLayoutSetName,
           presentations.contains(where: { $0.name == selectedLayoutSetName })
        {
            return
        }
        if let applied = model.runtimeState.selectedLayoutSet?.name,
           presentations.contains(where: { $0.name == applied })
        {
            selectedLayoutSetName = applied
        } else {
            selectedLayoutSetName = presentations[0].name
        }
    }

    private func badge(label: String, value: String, tint: Color = .accentColor) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    private func displaySetPreview(_ selections: [DisplayLayoutSelection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Preview", systemImage: "rectangle.on.rectangle")
                .font(.headline)

            ForEach(selections) { selection in
                if let layout = model.configManager.configIfLoaded()?
                    .config.layouts[selection.layoutName]
                {
                    layoutPreview(selection: selection, layout: layout)
                }
            }
        }
    }

    private func layoutPreview(
        selection: DisplayLayoutSelection,
        layout: LayoutDefinition
    ) -> some View {
        let hostDisplay = model.displays.first { $0.id == selection.displayID }
        let spaces = selection.spaceID.map { selectedSpaceID in
            layout.spaces.filter { $0.spaceID == selectedSpaceID }
        } ?? layout.spaces

        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(selection.displayTitle, systemImage: "display")
                        .font(.subheadline.bold())
                    Text(selection.layoutName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let display = layout.display {
                        displayBadge(display)
                    }
                }

                ForEach(spaces, id: \.spaceID) { space in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Space \(space.spaceID)").font(.subheadline).bold()
                            if space.spaceID == activeSpaceID(for: selection.layoutName) {
                                Text("active")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                        }

                        VisualLayoutPreview(
                            space: space,
                            display: hostDisplay,
                            compact: true
                        )

                        windowLegend(space.windows)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if space.spaceID != spaces.last?.spaceID {
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func activeSpaceID(for layoutName: String) -> Int? {
        return model.diagnostics?.state.activeWorkspaces
            .first(where: { $0.layoutName == layoutName })?
            .spaceID
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
                    if let matcher = win.match.title {
                        Text(formatTitleMatcher(matcher))
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

private struct DisplayArrangeSection: View {
    let choices: [DisplayLayoutChoice]
    let spaceIDsByLayout: [String: [Int]]
    let isRunning: Bool
    @Binding var selectionByDisplayID: [String: String]
    @Binding var spaceByDisplayID: [String: Int]
    let onApplyLayout: (String, Int?) -> Void
    let onApplyDisplaySet: ([String]) -> Void

    private var selectedLayouts: [String] {
        choices.compactMap { selectionByDisplayID[$0.displayID] }
    }

    var body: some View {
        GroupBox("Individual Displays") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(choices) { choice in
                    DisplayArrangeRow(
                        choice: choice,
                        spaceIDs: spaceIDs(for: choice),
                        selectedLayout: selectionBinding(for: choice),
                        selectedSpaceID: spaceBinding(for: choice),
                        isRunning: isRunning,
                        onApply: {
                            applyLayout(for: choice)
                        }
                    )
                }

                HStack {
                    Text("Applies only the selected displays. Use a Layout Set above to replace the complete managed configuration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply Selected Displays", systemImage: "rectangle.2.swap") {
                        onApplyDisplaySet(selectedLayouts)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedLayouts.count < 2 || isRunning)
                    .accessibilityHint("Applies selected display layouts as a local batch without choosing a layout set")
                }
            }
            .padding(4)
        }
        .onAppear(perform: synchronizeSelections)
        .onChange(of: choices) {
            synchronizeSelections()
        }
    }

    private func selectionBinding(for choice: DisplayLayoutChoice) -> Binding<String?> {
        Binding(
            get: { selectionByDisplayID[choice.displayID] },
            set: { newValue in
                selectionByDisplayID[choice.displayID] = newValue
                if let newValue {
                    if let selectedSpaceID = spaceByDisplayID[choice.displayID],
                       !(spaceIDsByLayout[newValue] ?? []).contains(selectedSpaceID)
                    {
                        spaceByDisplayID[choice.displayID] = nil
                    }
                } else {
                    spaceByDisplayID[choice.displayID] = nil
                }
            }
        )
    }

    private func spaceBinding(for choice: DisplayLayoutChoice) -> Binding<Int?> {
        Binding(
            get: { spaceByDisplayID[choice.displayID] },
            set: { spaceByDisplayID[choice.displayID] = $0 }
        )
    }

    private func spaceIDs(for choice: DisplayLayoutChoice) -> [Int] {
        guard let layoutName = selectionByDisplayID[choice.displayID] else { return [] }
        return spaceIDsByLayout[layoutName] ?? []
    }

    private func applyLayout(for choice: DisplayLayoutChoice) {
        guard let layoutName = selectionByDisplayID[choice.displayID] else { return }
        onApplyLayout(layoutName, spaceByDisplayID[choice.displayID])
    }

    private func synchronizeSelections() {
        var updated: [String: String] = [:]
        for choice in choices {
            if let current = selectionByDisplayID[choice.displayID],
               choice.layoutNames.contains(current)
            {
                updated[choice.displayID] = current
            } else if let active = choice.activeLayoutName,
                      choice.layoutNames.contains(active)
            {
                updated[choice.displayID] = active
            } else if choice.layoutNames.count == 1 {
                updated[choice.displayID] = choice.layoutNames[0]
            }
        }
        if updated != selectionByDisplayID {
            selectionByDisplayID = updated
        }

        let validDisplayIDs = Set(updated.keys)
        let validSpaces = spaceByDisplayID.filter { displayID, spaceID in
            guard validDisplayIDs.contains(displayID),
                  let layoutName = updated[displayID]
            else {
                return false
            }
            return (spaceIDsByLayout[layoutName] ?? []).contains(spaceID)
        }
        if validSpaces != spaceByDisplayID {
            spaceByDisplayID = validSpaces
        }
    }
}

private struct DisplayArrangeRow: View {
    let choice: DisplayLayoutChoice
    let spaceIDs: [Int]
    @Binding var selectedLayout: String?
    @Binding var selectedSpaceID: Int?
    let isRunning: Bool
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(
                choice.title,
                systemImage: choice.isPrimary ? "display" : "rectangle.on.rectangle"
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Layout", selection: $selectedLayout) {
                Text("Do not apply").tag(nil as String?)
                ForEach(choice.layoutNames, id: \.self) { layoutName in
                    Text(layoutName).tag(layoutName as String?)
                }
            }
            .frame(width: 150)

            Picker("Space", selection: $selectedSpaceID) {
                Text("All Workspaces").tag(nil as Int?)
                ForEach(spaceIDs, id: \.self) { spaceID in
                    Text("Space \(spaceID)").tag(spaceID as Int?)
                }
            }
            .frame(width: 150)
            .disabled(selectedLayout == nil)

            Button("Apply", systemImage: "play.fill", action: onApply)
                .buttonStyle(.bordered)
                .disabled(selectedLayout == nil || isRunning)
                .help("Apply this display’s selected layout or space")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(choice.title)
    }
}

private struct WorkspaceSpaceControls: View {
    let workspace: WorkspaceSummaryJSON
    let isPrimary: Bool
    let monitorAlias: String?
    let spaceIDs: [Int]
    let isRunning: Bool
    let onSwitch: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(workspace.layoutName)
                        .font(.subheadline.bold())
                    Text(monitorAlias ?? (isPrimary ? "primary" : "unbound"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if workspace.dormant {
                        Text("dormant")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(workspace.displayID)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            ForEach(spaceIDs, id: \.self) { spaceID in
                Button("\(spaceID)") {
                    onSwitch(spaceID)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(spaceID == workspace.spaceID || workspace.dormant || isRunning)
                .accessibilityLabel(
                    "Switch \(workspace.layoutName) to space \(spaceID)"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(workspace.layoutName) workspace")
    }
}

// MARK: - Layout detail

struct LayoutDetailView: View {
    @EnvironmentObject var model: AppModel

    let name: String
    let layout: LayoutDefinition

    private var hostDisplay: DisplayInfo? {
        DisplayResolver.hostDisplay(
            layout: layout,
            config: model.configManager.configIfLoaded()?.config,
            displays: model.displays
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(name)
                        .font(.title2).bold()
                    if let display = layout.display {
                        displayBadge(display)
                    }
                }

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            VStack(alignment: .leading, spacing: 8) {
                if space.windows.isEmpty {
                    Text("No windows").foregroundStyle(.secondary)
                } else {
                    VisualLayoutPreview(
                        space: space,
                        display: hostDisplay,
                        compact: false
                    )

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
                        if let matcher = win.match.title {
                            Text(formatTitleMatcher(matcher))
                        } else if let profile = win.match.profile {
                            Text("profile = \(profile)")
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

// MARK: - Visual layout preview (proportional window rectangles)

struct VisualLayoutPreview: View {
    let space: SpaceDefinition
    let display: DisplayInfo?
    let compact: Bool

    @ViewBuilder
    var body: some View {
        if let display, display.visibleFrame.width > 0, display.visibleFrame.height > 0 {
            preview(display: display)
        } else {
            Label("Display unavailable", systemImage: "display.trianglebadge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func preview(display: DisplayInfo) -> some View {
        let displayAspectRatio = display.visibleFrame.height / display.visibleFrame.width

        return GeometryReader { geo in
            let previewWidth = geo.size.width
            let previewHeight = previewWidth * displayAspectRatio
            let rects = space.windows.compactMap { win in
                win.frame.flatMap { frame in
                    resolveProportionalRect(frame: frame, display: display)
                }.map {
                    (win: win, rect: $0)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.black.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    )

                ForEach(Array(rects.enumerated()), id: \.offset) { _, item in
                    previewItem(
                        item: item,
                        previewWidth: previewWidth,
                        previewHeight: previewHeight
                    )
                }
            }
            .frame(height: previewHeight)
        }
        .aspectRatio(1 / displayAspectRatio, contentMode: .fit)
        .frame(maxWidth: compact ? 280 : 400)
    }

    @ViewBuilder
    private func previewItem(
        item: (win: WindowDefinition, rect: ProportionalRect),
        previewWidth: CGFloat,
        previewHeight: CGFloat
    ) -> some View {
        let gap: CGFloat = 1.5

        previewTile(win: item.win)
            .frame(
                width: max(0, previewWidth * item.rect.width - gap * 2),
                height: max(0, previewHeight * item.rect.height - gap * 2)
            )
            .position(
                x: previewWidth * (item.rect.x + item.rect.width / 2),
                y: previewHeight * (item.rect.y + item.rect.height / 2)
            )
    }

    @ViewBuilder
    private func previewTile(win: WindowDefinition) -> some View {
        let color = colorForSlot(win.slot)

        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(color.opacity(0.5), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 2) {
                    Text("\(win.slot)")
                        .font(.system(compact ? .caption2 : .caption, design: .rounded, weight: .bold))
                        .foregroundStyle(color)
                    Text(shortBundleID(win.match.bundleID))
                        .font(.system(size: compact ? 8 : 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
    }
}

// MARK: - Config error box

struct ConfigErrorBox: View {
    let errors: [ValidateErrorItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label("Config could not be loaded", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(error.message)
                            .font(.callout)
                            .textSelection(.enabled)
                        Text(error.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

// MARK: - Settings / system sections

struct GeneralSection: View {
    @EnvironmentObject var model: AppModel

    private var config: ShitsuraeConfig? {
        model.configManager.configIfLoaded()?.config
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.bold())

                if !model.configErrors.isEmpty {
                    ConfigErrorBox(errors: model.configErrors)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(icon: "app.badge", title: "App")

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("Launch at Login")
                                BooleanStatusBadge(value: config?.app?.launchAtLogin == true)
                            }
                            GridRow {
                                Text("Follow Focus")
                                BooleanStatusBadge(value: config?.resolvedFollowFocus == true)
                            }
                            GridRow {
                                Text("Switcher Thumbnails")
                                BooleanStatusBadge(value: config?.overlay?.showThumbnails ?? true)
                            }
                            GridRow {
                                Text("Config Directory")
                                Button("Open in Finder") { model.openConfigDirectory() }
                                    .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let ignore = config?.ignore {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionHeader(icon: "eye.slash", title: "Ignore Rules")

                            ignoreRuleSet("Apply", ruleSet: ignore.apply)
                            ignoreRuleSet("Focus", ruleSet: ignore.focus)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func ignoreRuleSet(_ label: String, ruleSet: IgnoreRuleSet?) -> some View {
        if let ruleSet {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption.bold()).foregroundStyle(.secondary)
                if let apps = ruleSet.apps, !apps.isEmpty {
                    Text(apps.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                }
                if let windows = ruleSet.windows, !windows.isEmpty {
                    ForEach(Array(windows.enumerated()), id: \.offset) { _, rule in
                        Text(ignoreWindowRuleSummary(rule))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func ignoreWindowRuleSummary(_ rule: IgnoreWindowRule) -> String {
        var parts: [String] = []
        if let bundleID = rule.bundleID { parts.append(bundleID) }
        if let titleRegex = rule.titleRegex { parts.append("title ≈ /\(titleRegex)/") }
        if let role = rule.role { parts.append("role=\(role)") }
        if let subrole = rule.subrole { parts.append("subrole=\(subrole)") }
        if let minimized = rule.minimized { parts.append("minimized=\(minimized)") }
        if let hidden = rule.hidden { parts.append("hidden=\(hidden)") }
        return parts.joined(separator: "  ")
    }
}

struct ShortcutsSection: View {
    @EnvironmentObject var model: AppModel

    private var resolved: ResolvedShortcuts {
        ResolvedShortcuts(from: model.configManager.configIfLoaded()?.config.shortcuts)
    }

    private struct SpaceShortcutRow: Identifiable {
        let id: String
        let hotkey: HotkeyDefinition
        let targets: String
    }

    private var spaceShortcutRows: [SpaceShortcutRow] {
        let groups = Dictionary(grouping: resolved.switchVirtualSpace) { shortcut in
            let modifiers = Set(shortcut.hotkey.modifiers.map { $0.lowercased() })
                .sorted()
                .joined(separator: "+")
            return "\(modifiers)|\(shortcut.hotkey.key.lowercased())"
        }
        return groups.map { chord, shortcuts in
            let ordered = shortcuts.sorted {
                if ($0.monitor ?? "primary") != ($1.monitor ?? "primary") {
                    return ($0.monitor ?? "primary") < ($1.monitor ?? "primary")
                }
                return $0.spaceID < $1.spaceID
            }
            let targets = ordered.map {
                let focus = $0.focus == .preserve ? " preserve" : ""
                return "\($0.monitor ?? "primary") / \($0.spaceID)\(focus)"
            }.joined(separator: ", ")
            return SpaceShortcutRow(
                id: chord,
                hotkey: ordered[0].hotkey,
                targets: targets
            )
        }.sorted { $0.id < $1.id }
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
                            ForEach(resolved.focusBySlotEnabledInApps.keys.sorted(), id: \.self) { bundleID in
                                if let enabled = resolved.focusBySlotEnabledInApps[bundleID] {
                                    GridRow {
                                        Text(bundleID)
                                            .font(.system(.caption, design: .monospaced))
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

                    ForEach(spaceShortcutRows) { row in
                        GridRow {
                            Text(row.targets)
                            hotkeyLabel(row.hotkey)
                        }
                    }
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
                        Text("Accept on Modifier Release")
                        BooleanStatusBadge(value: true)
                    }
                    GridRow {
                        Text("Quick Keys")
                        Text(resolved.quickKeys)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
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
        HStack(spacing: 6) {
            Circle()
                .fill(colorForSlot(slot))
                .frame(width: 8, height: 8)
            Text("\(slot)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(colorForSlot(slot))
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

struct PermissionsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions").font(.title2.bold())

                permissionRow(
                    "Accessibility",
                    granted: model.accessibilityGranted,
                    required: true,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                permissionRow(
                    "Screen Recording",
                    granted: model.screenRecordingGranted,
                    required: false,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )

                Button("Refresh") { model.refreshStatus() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ name: String, granted: Bool, required: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : (required ? .red : .orange))
            Text(name).frame(width: 160, alignment: .leading)
            Text(required ? "required" : "optional (switcher thumbnails)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !granted {
                Button("Open Settings") {
                    if let url = URL(string: pane) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Diagnostics").font(.title2.bold())

                if let diagnostics = model.diagnostics {
                    GroupBox("State") {
                        VStack(alignment: .leading, spacing: 2) {
                            row(
                                "Active workspaces",
                                diagnostics.state.activeWorkspaces.isEmpty
                                    ? "—"
                                    : diagnostics.state.activeWorkspaces
                                    .map { workspace in
                                        let dormant = workspace.dormant ? " (dormant)" : ""
                                        return "\(workspace.layoutName) space \(workspace.spaceID) @ \(workspace.displayID.prefix(8))…\(dormant)"
                                    }
                                    .joined(separator: ", ")
                            )
                            row("Tracked slots", "\(diagnostics.state.slotCount)")
                            row("Hidden windows", "\(diagnostics.state.hiddenCount)")
                            row("Recovery required", diagnostics.state.recoveryRequired ? "YES" : "no")
                            row("Revision", "\(diagnostics.state.revision)")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    if !diagnostics.state.pendingUnresolvedSlots.isEmpty {
                        GroupBox("Unresolved slots") {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(diagnostics.state.pendingUnresolvedSlots.enumerated()), id: \.offset) { _, slot in
                                    Text("space \(slot.spaceID) slot \(slot.slot): \(slot.reason)")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Text("Re-applying the layout (or switching workspaces) reconciles these automatically.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                        }
                    }

                    GroupBox("Config files") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(diagnostics.configFiles.enumerated()), id: \.offset) { _, file in
                                HStack {
                                    Image(systemName: file.loaded ? "checkmark.circle" : "xmark.circle")
                                        .foregroundStyle(file.loaded ? .green : .red)
                                    Text(file.path).font(.caption)
                                    if let message = file.message {
                                        Text(message).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                } else {
                    Text("Loading…").foregroundStyle(.secondary)
                }

                Button("Refresh") { model.refreshStatus() }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).frame(width: 160, alignment: .leading)
            Text(value).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared helpers (ported from v1)

let slotColors: [Color] = [.blue, .orange, .green, .purple, .pink, .cyan, .yellow, .indigo, .mint]

func colorForSlot(_ slot: Int) -> Color {
    guard slot >= 1, slot <= slotColors.count else { return .gray }
    return slotColors[slot - 1]
}

func shortBundleID(_ bundleID: String) -> String {
    bundleID.split(separator: ".").last.map(String.init) ?? bundleID
}

struct ProportionalRect: Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func resolveProportionalRect(
    frame: FrameDefinition,
    display: DisplayInfo
) -> ProportionalRect? {
    let basis = display.visibleFrame
    guard basis.width > 0, basis.height > 0,
          let resolved = try? LengthParser.resolveFrame(
              frame,
              basis: basis,
              scale: display.scale
          )
    else {
        return nil
    }

    return ProportionalRect(
        x: (resolved.x - basis.minX) / basis.width,
        y: (resolved.y - basis.minY) / basis.height,
        width: resolved.width / basis.width,
        height: resolved.height / basis.height
    )
}

func displayBadge(_ display: DisplayDefinition) -> some View {
    Group {
        if let monitor = display.monitor {
            Text(monitor)
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

func formatLength(_ value: LengthValue) -> String {
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

func formatFrame(_ frame: FrameDefinition?) -> String {
    guard let frame else {
        return "Preserve current frame"
    }
    let x = formatLength(frame.x)
    let y = formatLength(frame.y)
    let w = formatLength(frame.width)
    let h = formatLength(frame.height)
    return "\(x), \(y)  \(w) \u{00D7} \(h)"
}

func formatTitleMatcher(_ matcher: TitleMatcher) -> String {
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
