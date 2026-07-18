import CoreGraphics
import ShitsuraeCore
import SwiftUI

struct WorkspaceStatePreviewLayout: Equatable {
    struct Display: Equatable, Identifiable {
        let id: String
        let normalizedFrame: CGRect
        let normalizedVisibleFrame: CGRect?
        let isPrimary: Bool
    }

    struct Window: Equatable, Identifiable {
        let id: String
        let normalizedFrame: CGRect
        let slot: Int
        let bundleID: String
        let frameSource: WorkspaceWindowPreviewFrameSource
        let actualVisibility: WorkspaceWindowActualVisibility?
        let isBound: Bool
        let isFocused: Bool
        let isFullscreen: Bool
    }

    let aspectRatio: CGFloat
    let displays: [Display]
    let windows: [Window]
    let unavailableWindowCount: Int

    init?(displays displayInfos: [DisplayInfo], windows trackedWindows: [WorkspaceTrackedWindowState]) {
        let usableDisplays = displayInfos.filter {
            $0.frame.width > 0 && $0.frame.height > 0
        }
        guard let canvasBounds = Self.canvasBounds(for: usableDisplays.map(\.frame)) else {
            return nil
        }

        aspectRatio = canvasBounds.width / canvasBounds.height
        displays = usableDisplays.compactMap { display in
            guard let normalizedFrame = Self.normalizedFrame(display.frame, within: canvasBounds) else {
                return nil
            }
            return Display(
                id: display.id,
                normalizedFrame: normalizedFrame,
                normalizedVisibleFrame: Self.normalizedFrame(
                    display.visibleFrame,
                    within: canvasBounds
                ),
                isPrimary: display.isPrimary
            )
        }

        let positionedWindows = trackedWindows.compactMap { window -> Window? in
            guard let frame = window.previewFrame,
                  let frameSource = window.previewFrameSource,
                  let normalizedFrame = Self.normalizedFrame(
                      CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
                      within: canvasBounds
                  )
            else {
                return nil
            }
            return Window(
                id: window.id,
                normalizedFrame: normalizedFrame,
                slot: window.slot,
                bundleID: window.bundleID,
                frameSource: frameSource,
                actualVisibility: window.liveWindow?.actualVisibility,
                isBound: window.bindingState == .bound,
                isFocused: window.liveWindow?.isFocused == true,
                isFullscreen: window.liveWindow?.isFullscreen == true
            )
        }
        windows = positionedWindows.sorted { lhs, rhs in
            if lhs.isFocused != rhs.isFocused { return !lhs.isFocused }
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            return lhs.id < rhs.id
        }
        unavailableWindowCount = trackedWindows.count - positionedWindows.count
    }

    static func canvasBounds(for displayFrames: [CGRect]) -> CGRect? {
        guard let first = displayFrames.first,
              first.width > 0,
              first.height > 0
        else {
            return nil
        }
        let bounds = displayFrames.dropFirst().reduce(first) { partial, frame in
            partial.union(frame)
        }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    static func normalizedFrame(_ frame: CGRect, within bounds: CGRect) -> CGRect? {
        let clipped = frame.intersection(bounds)
        guard !clipped.isNull,
              !clipped.isEmpty,
              bounds.width > 0,
              bounds.height > 0
        else {
            return nil
        }
        return CGRect(
            x: (clipped.minX - bounds.minX) / bounds.width,
            y: (clipped.minY - bounds.minY) / bounds.height,
            width: clipped.width / bounds.width,
            height: clipped.height / bounds.height
        )
    }
}

struct WorkspaceStatePreview: View {
    let spaceID: Int
    let layout: WorkspaceStatePreviewLayout?

    init(workspace: WorkspaceStateGroup, displays: [DisplayInfo]) {
        spaceID = workspace.spaceID
        layout = WorkspaceStatePreviewLayout(displays: displays, windows: workspace.windows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("Placement", systemImage: "rectangle.on.rectangle")
                    .font(.subheadline.bold())
                Spacer()
                WorkspaceStatePreviewLegend()
            }

            if let layout {
                Canvas { context, size in
                    drawDisplays(layout.displays, context: &context, size: size)
                    drawWindows(layout.windows, context: &context, size: size)
                }
                .aspectRatio(layout.aspectRatio, contentMode: .fit)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(.black.opacity(0.025), in: .rect(cornerRadius: 6))
                .accessibilityHidden(true)

                if layout.unavailableWindowCount > 0 {
                    Label(
                        "\(layout.unavailableWindowCount) windows do not have a known visible position",
                        systemImage: "questionmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "Display geometry unavailable",
                    systemImage: "display.trianglebadge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Space \(spaceID) placement preview")
    }

    private func drawDisplays(
        _ displays: [WorkspaceStatePreviewLayout.Display],
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for display in displays {
            let frame = projected(display.normalizedFrame, size: size).insetBy(dx: 1, dy: 1)
            let displayPath = Path(roundedRect: frame, cornerRadius: 5)
            context.fill(displayPath, with: .color(.secondary.opacity(0.055)))
            context.stroke(
                displayPath,
                with: .color(.secondary.opacity(0.35)),
                lineWidth: display.isPrimary ? 1.5 : 1
            )
            if let normalizedVisibleFrame = display.normalizedVisibleFrame {
                let visibleFrame = projected(normalizedVisibleFrame, size: size)
                context.stroke(
                    Path(roundedRect: visibleFrame, cornerRadius: 3),
                    with: .color(.secondary.opacity(0.12)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
            }

            let label = Text(display.isPrimary ? "Primary" : shortDisplayID(display.id))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            context.draw(
                label,
                at: CGPoint(x: frame.minX + 6, y: frame.minY + 5),
                anchor: .topLeading
            )
        }
    }

    private func drawWindows(
        _ windows: [WorkspaceStatePreviewLayout.Window],
        context: inout GraphicsContext,
        size: CGSize
    ) {
        for window in windows {
            let projectedFrame = projected(window.normalizedFrame, size: size)
            let frame = projectedFrame.insetBy(dx: 2, dy: 2)
            guard frame.width > 1, frame.height > 1 else { continue }

            let slotColor = colorForSlot(window.slot)
            let borderColor = window.isBound ? slotColor : Color.orange
            let usesRestoredPosition = window.frameSource == .lastVisibleFrame
            let path = Path(roundedRect: frame, cornerRadius: 4)
            context.fill(
                path,
                with: .color(slotColor.opacity(usesRestoredPosition ? 0.09 : 0.2))
            )
            context.stroke(
                path,
                with: .color(borderColor.opacity(window.isBound ? 0.7 : 0.9)),
                style: StrokeStyle(
                    lineWidth: window.isFocused ? 2.5 : 1.25,
                    dash: usesRestoredPosition || !window.isBound ? [5, 3] : []
                )
            )

            if window.isFocused {
                context.stroke(
                    Path(roundedRect: frame.insetBy(dx: -2, dy: -2), cornerRadius: 5),
                    with: .color(.blue.opacity(0.65)),
                    lineWidth: 1.5
                )
            }

            guard frame.width >= 30, frame.height >= 18 else { continue }
            let marker = windowMarker(window)
            let label = Text(marker)
                .font(.system(size: min(11, max(8, frame.height * 0.16)), weight: .bold, design: .rounded))
                .foregroundStyle(borderColor)
            var clippedContext = context
            clippedContext.clip(to: path)
            clippedContext.draw(
                label,
                at: CGPoint(x: frame.midX, y: frame.midY),
                anchor: .center
            )
        }
    }

    private func projected(_ normalizedFrame: CGRect, size: CGSize) -> CGRect {
        let inset: CGFloat = 6
        let drawingWidth = max(0, size.width - inset * 2)
        let drawingHeight = max(0, size.height - inset * 2)
        return CGRect(
            x: inset + normalizedFrame.minX * drawingWidth,
            y: inset + normalizedFrame.minY * drawingHeight,
            width: normalizedFrame.width * drawingWidth,
            height: normalizedFrame.height * drawingHeight
        )
    }

    private func windowMarker(_ window: WorkspaceStatePreviewLayout.Window) -> String {
        let slot = window.slot > 0 ? "\(window.slot)" : "A"
        let state: String
        if !window.isBound {
            state = "?"
        } else if window.actualVisibility == .minimized {
            state = "−"
        } else if window.isFullscreen {
            state = "⛶"
        } else if window.frameSource == .lastVisibleFrame {
            state = "↩"
        } else {
            state = ""
        }
        return "\(slot) \(shortBundleID(window.bundleID))\(state.isEmpty ? "" : " \(state)")"
    }
}

private struct WorkspaceStatePreviewLegend: View {
    var body: some View {
        HStack(spacing: 9) {
            key(label: "Current", tint: .secondary, dashed: false)
            key(label: "Restore", tint: .secondary, dashed: true)
            key(label: "Missing", tint: .orange, dashed: true)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func key(label: String, tint: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 2] : [])
                )
                .frame(width: 14, height: 9)
            Text(label)
        }
    }
}
