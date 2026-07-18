import AppKit
import ShitsuraeCore
import SwiftUI

struct WorkspaceStateSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let snapshot = model.workspaceState {
                    WorkspaceStateSummary(snapshot: snapshot)

                    if snapshot.inventoryAvailability == .unavailable {
                        WorkspaceStateNotice(
                            title: "Live window inventory unavailable",
                            message: "Tracked membership is shown, but live binding and visibility are unknown.",
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        )
                    }

                    if snapshot.recoveryRequired {
                        WorkspaceStateNotice(
                            title: "Recovery required",
                            message: "The previous visibility operation has not fully converged.",
                            systemImage: "arrow.trianglehead.2.clockwise.rotate.90",
                            tint: .orange
                        )
                    }

                    if snapshot.layoutName == nil {
                        ContentUnavailableView(
                            "No active layout",
                            systemImage: "rectangle.3.group",
                            description: Text("Apply a layout to start tracking virtual workspaces.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else if snapshot.workspaces.isEmpty {
                        ContentUnavailableView(
                            "No virtual workspaces",
                            systemImage: "square.3.layers.3d",
                            description: Text("The active layout does not define any workspaces.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(snapshot.workspaces) { workspace in
                                WorkspaceStateCard(workspace: workspace)
                            }
                        }
                    }

                    if !snapshot.unmanagedWindows.isEmpty {
                        WorkspaceUnmanagedWindowsSection(windows: snapshot.unmanagedWindows)
                    }

                    Text("Runtime state revision \(snapshot.revision)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    ProgressView("Loading workspace state…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await model.monitorWorkspaceState()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Workspace State")
                    .font(.title2.bold())
                Text("Read-only view of virtual workspace membership and live windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
        }
    }

    private func refresh() {
        Task {
            await model.refreshWorkspaceState()
        }
    }
}

private struct WorkspaceStateSummary: View {
    let snapshot: WorkspaceStateSnapshot
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            WorkspaceStateMetric(
                systemImage: "square.grid.2x2",
                label: "Layout",
                value: snapshot.layoutName ?? "—"
            )
            WorkspaceStateMetric(
                systemImage: "square.3.layers.3d",
                label: "Workspaces",
                value: "\(snapshot.workspaces.count)"
            )
            WorkspaceStateMetric(
                systemImage: "link",
                label: "Bound",
                value: "\(snapshot.boundWindowCount) / \(snapshot.trackedWindowCount)"
            )
            WorkspaceStateMetric(
                systemImage: "rectangle.dashed",
                label: "Offscreen",
                value: "\(snapshot.hiddenWindowCount)"
            )
            WorkspaceStateMetric(
                systemImage: "questionmark.app",
                label: "Unmanaged",
                value: "\(snapshot.unmanagedWindows.count)"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workspace state summary")
    }
}

private struct WorkspaceStateMetric: View {
    let systemImage: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceStateNotice: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceStateCard: View {
    let workspace: WorkspaceStateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if workspace.windows.isEmpty {
                Text("No tracked windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(workspace.windows) { window in
                    WorkspaceTrackedWindowRow(window: window)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            Divider()
                                .opacity(window.id == workspace.windows.last?.id ? 0 : 1)
                        }
                }
            }

            if !workspace.pendingUnresolvedSlots.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(workspace.pendingUnresolvedSlots, id: \.workspaceStateID) { unresolved in
                        Label(
                            unresolved.slot == 0
                                ? unresolved.reason
                                : "Slot \(unresolved.slot): \(unresolved.reason)",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.07))
            }
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    workspace.isActive
                        ? Color.accentColor.opacity(0.55)
                        : Color.secondary.opacity(0.18)
                )
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.isActive ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                .foregroundStyle(workspace.isActive ? Color.accentColor : .secondary)
            Text("Space \(workspace.spaceID)")
                .font(.headline)
            if workspace.isActive {
                WorkspaceStatePill(label: "Active", systemImage: "circle.fill", tint: .green)
            }
            if !workspace.activeDisplayIDs.isEmpty {
                Text(workspace.activeDisplayIDs.map(shortDisplayID).joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(workspace.windows.count) windows")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            workspace.isActive
                ? Color.accentColor.opacity(0.07)
                : Color.secondary.opacity(0.05)
        )
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceTrackedWindowRow: View {
    let window: WorkspaceTrackedWindowState

    @ScaledMetric(relativeTo: .body) private var appIconSize = 28.0
    @ScaledMetric(relativeTo: .caption) private var slotSize = 25.0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(window.slot > 0 ? "\(window.slot)" : "A")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(colorForSlot(window.slot))
                .frame(width: slotSize, height: slotSize)
                .background(colorForSlot(window.slot).opacity(0.12), in: Circle())
                .help(window.slot > 0 ? "Slot \(window.slot)" : "Adopted window")

            WorkspaceApplicationIcon(bundleID: window.bundleID, size: appIconSize)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(windowTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if window.origin == .adopted {
                        WorkspaceStatePill(label: "Adopted", systemImage: "plus.circle", tint: .purple)
                    }
                    if window.liveWindow?.isFocused == true {
                        WorkspaceStatePill(label: "Focused", systemImage: "scope", tint: .blue)
                    }
                }

                HStack(spacing: 5) {
                    Text(window.bundleID)
                    if let profile = window.profile {
                        Text("• profile \(profile)")
                    }
                    if let displayID = window.displayID {
                        Text("• \(shortDisplayID(displayID))")
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !window.pendingReasons.isEmpty {
                    Text(window.pendingReasons.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 5) {
                    bindingPill
                    if let liveWindow = window.liveWindow {
                        actualVisibilityPill(liveWindow.actualVisibility)
                        if liveWindow.isFullscreen {
                            WorkspaceStatePill(label: "Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right", tint: .purple)
                        }
                        if liveWindow.isGeometryBlocked {
                            WorkspaceStatePill(label: "Protected", systemImage: "lock", tint: .orange)
                        }
                    }
                }

                HStack(spacing: 5) {
                    trackedVisibilityPill
                    if window.hasVisibilityMismatch {
                        WorkspaceStatePill(label: "Visibility drift", systemImage: "exclamationmark.triangle", tint: .orange)
                    }
                }

                if let frame = window.liveWindow?.frame {
                    Text(formatResolvedFrame(frame))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var windowTitle: String {
        let title = window.liveWindow?.title ?? window.trackedTitle
        return title.isEmpty ? shortBundleID(window.bundleID) : title
    }

    @ViewBuilder
    private var bindingPill: some View {
        switch window.bindingState {
        case .bound:
            WorkspaceStatePill(label: "Bound", systemImage: "link", tint: .green)
        case .reservedExactIdentity:
            WorkspaceStatePill(label: "Reserved", systemImage: "clock", tint: .orange)
        case .exactOnlyMissing:
            WorkspaceStatePill(label: "Closed", systemImage: "xmark.circle", tint: .red)
        case .indexOutOfBounds:
            WorkspaceStatePill(label: "Index missing", systemImage: "number", tint: .red)
        case .candidateConflict:
            WorkspaceStatePill(label: "Conflict", systemImage: "exclamationmark.triangle", tint: .red)
        case .noCandidate:
            WorkspaceStatePill(label: "Not found", systemImage: "questionmark.circle", tint: .orange)
        case .inventoryUnavailable:
            WorkspaceStatePill(label: "Unknown", systemImage: "questionmark", tint: .secondary)
        }
    }

    private var trackedVisibilityPill: some View {
        switch window.trackedVisibility {
        case .visible:
            WorkspaceStatePill(label: "Tracked visible", systemImage: "eye", tint: .secondary)
        case .hiddenOffscreen:
            WorkspaceStatePill(label: "Tracked offscreen", systemImage: "rectangle.dashed", tint: .secondary)
        }
    }

    private func actualVisibilityPill(_ visibility: WorkspaceWindowActualVisibility) -> WorkspaceStatePill {
        switch visibility {
        case .visible:
            WorkspaceStatePill(label: "Visible", systemImage: "eye.fill", tint: .green)
        case .hiddenOffscreen:
            WorkspaceStatePill(label: "Offscreen", systemImage: "rectangle.dashed", tint: .blue)
        case .minimized:
            WorkspaceStatePill(label: "Minimized", systemImage: "minus.square", tint: .orange)
        case .applicationHidden:
            WorkspaceStatePill(label: "App hidden", systemImage: "eye.slash", tint: .orange)
        }
    }
}

private struct WorkspaceUnmanagedWindowsSection: View {
    let windows: [WorkspaceUnmanagedWindowState]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unmanaged live windows", systemImage: "questionmark.app")
                .font(.headline)
            Text("Manageable windows that are not currently owned by a tracked workspace entry.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(windows) { window in
                    WorkspaceUnmanagedWindowRow(window: window)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) {
                            Divider()
                                .opacity(window.id == windows.last?.id ? 0 : 1)
                        }
                }
            }
            .background(.background)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary)
            }
        }
    }
}

private struct WorkspaceUnmanagedWindowRow: View {
    let window: WorkspaceUnmanagedWindowState

    @ScaledMetric(relativeTo: .body) private var appIconSize = 28.0

    var body: some View {
        HStack(spacing: 10) {
            WorkspaceApplicationIcon(
                bundleID: window.liveWindow.identity.bundleID,
                size: appIconSize
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(window.liveWindow.title.isEmpty
                    ? shortBundleID(window.liveWindow.identity.bundleID)
                    : window.liveWindow.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(window.liveWindow.identity.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            WorkspaceStatePill(
                label: window.reason == .unassigned ? "Not tracked" : "Binding deferred",
                systemImage: window.reason == .unassigned ? "questionmark.circle" : "clock",
                tint: .orange
            )
            Text(formatResolvedFrame(window.liveWindow.frame))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct WorkspaceApplicationIcon: View {
    let bundleID: String
    let size: Double

    var body: some View {
        Group {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "macwindow")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage? {
        WorkspaceApplicationIconProvider.shared.icon(for: bundleID)
    }
}

@MainActor
private final class WorkspaceApplicationIconProvider {
    static let shared = WorkspaceApplicationIconProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var missingBundleIDs = Set<String>()

    func icon(for bundleID: String) -> NSImage? {
        if let cached = cache.object(forKey: bundleID as NSString) {
            return cached
        }
        guard !missingBundleIDs.contains(bundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            missingBundleIDs.insert(bundleID)
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}

private struct WorkspaceStatePill: View {
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}

private func shortDisplayID(_ displayID: String) -> String {
    displayID.count > 8 ? "\(displayID.prefix(8))…" : displayID
}

private func formatResolvedFrame(_ frame: ResolvedFrame) -> String {
    String(
        format: "%.0f, %.0f  %.0f × %.0f",
        frame.x,
        frame.y,
        frame.width,
        frame.height
    )
}

private extension PendingUnresolvedSlot {
    var workspaceStateID: String {
        "\(spaceID)\u{0}\(slot)\u{0}\(reason)"
    }
}
