import CoreGraphics
import Foundation

public enum VisibilityTransition: Sendable {
    case show
    case hide
}

public enum VisibilityMutation: Equatable, Sendable {
    case none
    case frame(ResolvedFrame)
    case position(CGPoint)
}

public enum HideCorner: Sendable {
    case bottomLeft
    case bottomRight
}

/// A planned show/hide for one bound window.
public struct VisibilityPlan: Equatable, Sendable {
    public let entryID: String
    public let window: WindowSnapshot
    /// Entry state before the mutation (for rollback on failure).
    public let originalEntry: SlotEntry
    /// Entry state after the mutation succeeds and converges.
    public let desiredEntry: SlotEntry
    public let mutation: VisibilityMutation
    /// v2: show plans unminimize first when the window is minimized. v1
    /// hardcoded false here, which made minimized windows unrecoverable.
    public let restoreFromMinimized: Bool
    public let action: String
}

/// Pure visibility planning: which frame to show at, where to park hidden
/// windows. All geometry knowledge ported from v1 (proven in production):
/// - hide = move 1px outside the display edge (never minimize / NSApp.hide)
/// - hide corner auto-selected from the multi-display arrangement
/// - coordinates normalized into the CG (top-left origin) space
public enum VisibilityPlanner {
    public static func plan(
        entry: SlotEntry,
        window: WindowSnapshot,
        transition: VisibilityTransition,
        layout: LayoutDefinition,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> VisibilityPlan? {
        switch transition {
        case .show:
            guard let visibleFrame = resolveVisibleFrame(
                entry: entry,
                window: window,
                layout: layout,
                hostDisplay: hostDisplay,
                displays: displays
            ) else {
                return nil
            }

            var desired = entry.bound(to: window)
            desired.lastVisibleFrame = visibleFrame
            desired.visibilityState = .visible

            return VisibilityPlan(
                entryID: entry.id,
                window: window,
                originalEntry: entry,
                desiredEntry: desired,
                mutation: .frame(visibleFrame),
                restoreFromMinimized: window.minimized,
                action: "shown"
            )

        case .hide:
            guard !window.minimized, !window.isFullscreen else {
                // Already invisible to the user; leave it alone.
                return VisibilityPlan(
                    entryID: entry.id,
                    window: window,
                    originalEntry: entry,
                    desiredEntry: entry,
                    mutation: .none,
                    restoreFromMinimized: false,
                    action: "unchanged"
                )
            }

            let hiddenFrame = resolveHiddenFrame(
                entry: entry,
                window: window,
                hostDisplay: hostDisplay,
                displays: displays
            )

            var desired = entry.bound(to: window)
            // Keep the last truly-visible frame: if the window is already
            // hidden, the current frame is the parking spot, not a real one.
            desired.lastVisibleFrame = entry.visibilityState == .hiddenOffscreen
                ? entry.lastVisibleFrame
                : window.frame
            desired.lastHiddenFrame = hiddenFrame
            desired.visibilityState = .hiddenOffscreen

            return VisibilityPlan(
                entryID: entry.id,
                window: window,
                originalEntry: entry,
                desiredEntry: desired,
                mutation: .position(CGPoint(x: hiddenFrame.x, y: hiddenFrame.y)),
                restoreFromMinimized: false,
                action: "hiddenOffscreen"
            )
        }
    }

    // MARK: - Visible frame

    public static func resolveVisibleFrame(
        entry: SlotEntry,
        window: WindowSnapshot,
        layout: LayoutDefinition,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> ResolvedFrame? {
        if let frame = entry.lastVisibleFrame,
           isWithinVisibleArea(frame: frame, hostDisplay: hostDisplay, displays: displays),
           !isHiddenWindowFrame(frame: frame, displays: displays)
        {
            return frame
        }

        if let layoutFrame = resolvedLayoutFrame(
            entry: entry,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        ) {
            return layoutFrame
        }

        if isWithinVisibleArea(frame: window.frame, hostDisplay: hostDisplay, displays: displays),
           !isHiddenWindowFrame(frame: window.frame, displays: displays)
        {
            return window.frame
        }

        return clampedRecoveryFrame(
            entry: entry,
            window: window,
            hostDisplay: hostDisplay,
            displays: displays
        )
    }

    /// The frame the layout definition assigns to this entry — only while the
    /// entry still lives on its layout-defined space.
    static func resolvedLayoutFrame(
        entry: SlotEntry,
        layout: LayoutDefinition,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> ResolvedFrame? {
        guard let layoutSpaceID = entry.layoutSpaceID,
              entry.spaceID == layoutSpaceID,
              let space = layout.spaces.first(where: { $0.spaceID == layoutSpaceID }),
              let definition = space.windows.first(where: { $0.slot == entry.slot })
        else {
            return nil
        }

        let basis = coordinateRect(hostDisplay.visibleFrame, displays: displays)
        return try? LengthParser.resolveFrame(
            definition.frame,
            basis: basis,
            scale: hostDisplay.scale
        )
    }

    /// Last-resort show frame: source frame clamped into the host display.
    static func clampedRecoveryFrame(
        entry: SlotEntry,
        window: WindowSnapshot,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> ResolvedFrame {
        let basis = coordinateRect(hostDisplay.visibleFrame, displays: displays)
        let source = entry.lastVisibleFrame ?? window.frame
        let width = min(max(1, source.width), basis.width)
        let height = min(max(1, source.height), basis.height)
        let maxX = max(basis.minX, basis.maxX - width)
        let maxY = max(basis.minY, basis.maxY - height)
        let x = min(max(source.x, basis.minX), maxX)
        let y = min(max(source.y, basis.minY), maxY)
        return ResolvedFrame(x: x, y: y, width: width, height: height)
    }

    // MARK: - Hidden frame

    public static func resolveHiddenFrame(
        entry: SlotEntry,
        window: WindowSnapshot,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> ResolvedFrame {
        let width = max(1, window.frame.width)
        let height = max(1, window.frame.height)
        let targetDisplay = resolveTargetDisplay(entry: entry, window: window, displays: displays) ?? hostDisplay
        let targetVisibleFrame = coordinateRect(targetDisplay.visibleFrame, displays: displays)
        let corner = optimalHideCorner(for: targetDisplay, displays: displays)
        let x: Double
        switch corner {
        case .bottomLeft:
            x = targetVisibleFrame.minX - width + 1
        case .bottomRight:
            x = targetVisibleFrame.maxX - 1
        }
        let referenceFrame = entry.lastVisibleFrame ?? window.frame
        let minY = targetVisibleFrame.minY
        let maxY = max(minY, targetVisibleFrame.maxY - height)
        let y = min(max(referenceFrame.y, minY), maxY)
        return ResolvedFrame(x: x, y: y, width: width, height: height)
    }

    static func resolveTargetDisplay(
        entry: SlotEntry,
        window: WindowSnapshot,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        if let displayID = entry.displayID ?? window.displayID,
           let matched = displays.first(where: { $0.id == displayID })
        {
            return matched
        }
        return WindowEnumerator.resolveDisplay(
            for: CGRect(
                x: window.frame.x,
                y: window.frame.y,
                width: window.frame.width,
                height: window.frame.height
            ),
            displays: displays
        )
    }

    /// Chooses the hide corner whose probe points overlap other displays the
    /// least, so the parked window can't bleed into a neighboring screen.
    /// The 1px outside margin is intentional — do not change.
    public static func optimalHideCorner(for display: DisplayInfo, displays: [DisplayInfo]) -> HideCorner {
        let normalizedDisplayFrame = coordinateRect(display.frame, displays: displays)
        let normalizedDisplayFrames = displays.map { coordinateRect($0.frame, displays: displays) }
        let xOffset = normalizedDisplayFrame.width * 0.1
        let yOffset = normalizedDisplayFrame.height * 0.1

        let bottomRightPrimary = CGPoint(x: normalizedDisplayFrame.maxX + 2, y: normalizedDisplayFrame.maxY - yOffset)
        let bottomRightSecondary = CGPoint(x: normalizedDisplayFrame.maxX - xOffset, y: normalizedDisplayFrame.maxY + 2)
        let bottomRightCritical = CGPoint(x: normalizedDisplayFrame.maxX + 2, y: normalizedDisplayFrame.maxY + 2)

        let bottomLeftPrimary = CGPoint(x: normalizedDisplayFrame.minX - 2, y: normalizedDisplayFrame.maxY - yOffset)
        let bottomLeftSecondary = CGPoint(x: normalizedDisplayFrame.minX + xOffset, y: normalizedDisplayFrame.maxY + 2)
        let bottomLeftCritical = CGPoint(x: normalizedDisplayFrame.minX - 2, y: normalizedDisplayFrame.maxY + 2)

        func containmentScore(for points: [CGPoint]) -> Int {
            normalizedDisplayFrames.reduce(into: 0) { total, candidate in
                total += candidate.contains(points[0]) ? 1 : 0
                total += candidate.contains(points[1]) ? 1 : 0
                total += candidate.contains(points[2]) ? 10 : 0
            }
        }

        let leftScore = containmentScore(for: [bottomLeftPrimary, bottomLeftSecondary, bottomLeftCritical])
        let rightScore = containmentScore(for: [bottomRightPrimary, bottomRightSecondary, bottomRightCritical])
        return leftScore < rightScore ? .bottomLeft : .bottomRight
    }

    // MARK: - Geometry helpers

    /// Converts an AppKit (bottom-left origin) rect into the CG (top-left
    /// origin) coordinate space AX and CGWindowList use.
    public static func coordinateRect(_ rect: CGRect, displays: [DisplayInfo]) -> CGRect {
        let mainDisplayHeight = displays.first(where: \.isPrimary)?.frame.height
            ?? displays.map { $0.frame.height }.max()
            ?? rect.height
        return CGRect(
            x: rect.minX,
            y: mainDisplayHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func isHiddenWindowFrame(frame: ResolvedFrame, displays: [DisplayInfo]) -> Bool {
        isOffscreenFrame(frame: frame, displays: displays)
            || isEdgePinnedHiddenFrame(frame: frame, displays: displays)
    }

    static func isWithinVisibleArea(frame: ResolvedFrame, hostDisplay: DisplayInfo, displays: [DisplayInfo]) -> Bool {
        for display in displays {
            let displayRight = display.frame.origin.x + display.frame.width
            let displayBottom = display.frame.origin.y + display.frame.height
            if frame.x < displayRight,
               frame.x + frame.width > display.frame.origin.x,
               frame.y < displayBottom,
               frame.y + frame.height > display.frame.origin.y
            {
                return true
            }
        }
        if displays.isEmpty {
            return frame.x < hostDisplay.frame.width && frame.y < hostDisplay.frame.height
        }
        return false
    }

    private static func isOffscreenFrame(frame: ResolvedFrame, displays: [DisplayInfo]) -> Bool {
        let windowRect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard !displays.isEmpty else {
            return false
        }
        return displays.allSatisfy { !windowRect.intersects($0.frame) }
    }

    private static func isEdgePinnedHiddenFrame(frame: ResolvedFrame, displays: [DisplayInfo]) -> Bool {
        let windowRect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)

        return displays.contains { display in
            let overlap = windowRect.intersection(display.frame)
            guard !overlap.isNull else {
                return false
            }

            return overlap.width <= 1 || overlap.height <= 1
        }
    }
}
