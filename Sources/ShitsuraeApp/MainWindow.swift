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
        .onAppear { model.refreshStatus() }
    }
}

// MARK: - Arrange

struct ArrangeView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedLayout: String?
    @State private var selectedSpaceID: Int?

    private var currentLayout: LayoutDefinition? {
        guard let name = selectedLayout else { return nil }
        return model.configManager.configIfLoaded()?.config.layouts[name]
    }

    private var spaceIDs: [Int] {
        currentLayout?.spaces.map(\.spaceID) ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Arrange")
                    .font(.title2).bold()

                if !model.configErrors.isEmpty {
                    ConfigErrorBox(errors: model.configErrors)
                    Button("Open Config Directory") { model.openConfigDirectory() }
                } else if model.layouts.isEmpty {
                    Text("No layouts defined. Add YAML files to the config directory.")
                        .foregroundStyle(.secondary)
                    Button("Open Config Directory") { model.openConfigDirectory() }
                } else {
                    statusCard

                    // Pickers hug their content (.fixedSize) so captions stay
                    // aligned with them. The apply button sits trailing on the
                    // same row; layoutPriority keeps it intact on narrow
                    // windows (the Spacer collapses first, the button never
                    // gets clipped).
                    HStack(alignment: .bottom, spacing: 20) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Layout").font(.caption).foregroundStyle(.secondary)
                            Picker("Layout", selection: $selectedLayout) {
                                Text("Select…").tag(nil as String?)
                                ForEach(model.layouts, id: \.self) { name in
                                    Text(name).tag(name as String?)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Space").font(.caption).foregroundStyle(.secondary)
                            Picker("Space", selection: $selectedSpaceID) {
                                Text("All Workspaces").tag(nil as Int?)
                                ForEach(spaceIDs, id: \.self) { id in
                                    Text("Space \(id)").tag(id as Int?)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Spacer(minLength: 16)

                        actionButtons
                            .layoutPriority(1)
                    }

                    if case let .failed(label, message) = model.actionStatus {
                        Label("\(label): \(message)", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    if let layout = currentLayout {
                        layoutPreview(layout)
                    }
                }
            }
            .padding(20)
        }
        .onAppear {
            if selectedLayout == nil {
                selectedLayout = model.activeLayoutName ?? model.layouts.first
            }
        }
        .onChange(of: model.layouts) { _, newValue in
            if let selected = selectedLayout, !newValue.contains(selected) {
                selectedLayout = nil
                selectedSpaceID = nil
            }
        }
        .onChange(of: selectedLayout) { _, _ in
            if let selectedSpaceID, !spaceIDs.contains(selectedSpaceID) {
                self.selectedSpaceID = nil
            }
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Virtual Workspaces", systemImage: "square.3.layers.3d")
                    .font(.headline)

                HStack(spacing: 10) {
                    badge(label: "Active Layout", value: model.activeLayoutName ?? "—")
                    badge(
                        label: "Active Space",
                        value: model.activeSpaceID.map { "Space \($0)" } ?? "—"
                    )
                    if model.diagnostics?.state.recoveryRequired == true {
                        badge(label: "Recovery", value: "required", tint: .orange)
                    }
                }

                if model.activeLayoutName == nil {
                    Text("Select a layout and press Apply All — windows are launched, placed and tracked from scratch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !model.availableSpaceIDs.isEmpty {
                    HStack(spacing: 6) {
                        Text("Switch:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(model.availableSpaceIDs, id: \.self) { spaceID in
                            Button("\(spaceID)") { model.switchSpace(to: spaceID) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(spaceID == model.activeSpaceID || model.actionStatus.isRunning)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
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

    @ViewBuilder
    private var actionButtons: some View {
        arrangeButton(
            title: selectedSpaceID == nil ? "Apply All" : "Apply Space \(selectedSpaceID!)",
            systemImage: "play.fill",
            action: "arrange",
            prominent: true
        ) {
            guard let layout = selectedLayout else { return }
            model.applyLayout(layout, spaceID: selectedSpaceID)
        }
        .help("Launch, place and track windows, then re-hide inactive workspaces")
    }

    @ViewBuilder
    private func arrangeButton(
        title: String,
        systemImage: String,
        action: String,
        prominent: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        let button = Button(action: perform) {
            HStack(spacing: 6) {
                statusIcon(action: action, defaultSystemImage: systemImage, onProminent: prominent)
                Text(title)
            }
        }
        .disabled(selectedLayout == nil || model.actionStatus.isRunning)

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func statusIcon(action: String, defaultSystemImage: String, onProminent: Bool = false) -> some View {
        // Status colors sit on the tinted prominent background, where the
        // usual green/red would vanish — use white there instead.
        switch model.actionStatus {
        case let .running(label) where label.hasPrefix(action):
            ProgressView().controlSize(.small)
        case let .success(label) where label.hasPrefix(action):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(onProminent ? Color.white : Color.green)
        case let .failed(label, _) where label.hasPrefix(action):
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(onProminent ? Color.white : Color.red)
        default:
            Image(systemName: defaultSystemImage)
        }
    }

    private func layoutPreview(_ layout: LayoutDefinition) -> some View {
        let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: model.configManager.configIfLoaded()?.config,
            displays: model.displays
        )

        return VStack(alignment: .leading, spacing: 10) {
            Label("Preview", systemImage: "rectangle.on.rectangle")
                .font(.headline)

            ForEach(Array(layout.spaces.enumerated()), id: \.offset) { _, space in
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Space \(space.spaceID)").font(.subheadline).bold()
                            if space.spaceID == model.activeSpaceID,
                               selectedLayout == model.activeLayoutName
                            {
                                Text("active")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.green.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.green)
                            }
                            if let display = space.display {
                                displayBadge(display)
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
                resolveProportionalRect(frame: win.frame, display: display).map {
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
                            row("Active layout", diagnostics.state.activeLayoutName ?? "—")
                            row(
                                "Active spaces",
                                diagnostics.state.activeSpaces
                                    .map { "space \($0.spaceID) @ \($0.displayID.prefix(8))…" }
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

func formatFrame(_ frame: FrameDefinition) -> String {
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
