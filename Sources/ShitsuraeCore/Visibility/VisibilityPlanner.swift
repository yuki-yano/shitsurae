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
/// - hide horizontally beyond the complete multi-display arrangement
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
        guard WindowEligibility.isManageableForVirtualWorkspace(window) else {
            return nil
        }
        let workingEntry = entry.bound(to: window)

        switch transition {
        case .show:
            guard let visibleFrame = resolveVisibleFrame(
                entry: workingEntry,
                window: window,
                layout: layout,
                hostDisplay: hostDisplay,
                displays: displays
            ) else {
                return nil
            }

            var desired = workingEntry
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
            guard !window.minimized else {
                // Already invisible to the user; leave it alone.
                // Refresh the exact binding without claiming Shitsurae hid a
                // window the user deliberately minimized.
                let desired = entry.bound(to: window)
                return VisibilityPlan(
                    entryID: entry.id,
                    window: window,
                    originalEntry: entry,
                    desiredEntry: desired,
                    mutation: .none,
                    restoreFromMinimized: false,
                    action: "unchanged"
                )
            }

            let hiddenFrame = resolveHiddenFrame(
                entry: workingEntry,
                window: window,
                hostDisplay: hostDisplay,
                displays: displays
            )

            var desired = workingEntry
            // Keep the last truly-visible frame: if the window is already
            // hidden, the current frame is the parking spot, not a real one.
            // A native-fullscreen frame is equally unsuitable: it describes
            // the display, not the windowed frame macOS should restore later.
            desired.lastVisibleFrame = workingEntry.visibilityState == .hiddenOffscreen || window.isFullscreen
                ? workingEntry.lastVisibleFrame
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

        // A native-fullscreen frame describes the display, not a restorable
        // windowed geometry. If neither persisted nor layout geometry exists,
        // stay unresolved until the app leaves fullscreen instead of storing
        // the display rectangle as lastVisibleFrame.
        guard !window.isFullscreen else {
            return nil
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

        let basis = hostDisplay.visibleFrame
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
        let basis = hostDisplay.visibleFrame
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

    /// - Precondition: `displays` is non-empty and contains `hostDisplay`.
    public static func resolveHiddenFrame(
        entry: SlotEntry,
        window: WindowSnapshot,
        hostDisplay: DisplayInfo,
        displays: [DisplayInfo]
    ) -> ResolvedFrame {
        precondition(
            displays.contains(where: { $0.id == hostDisplay.id }),
            "hidden-window planning requires a display list containing the host display"
        )
        let width = max(1, window.frame.width)
        let height = max(1, window.frame.height)
        let targetDisplay = resolveTargetDisplay(entry: entry, window: window, displays: displays) ?? hostDisplay
        let referenceFrame = entry.lastVisibleFrame ?? window.frame
        // AppKit keeps a titled window reachable when it is parked beyond a
        // vertical edge, so top/bottom requests can be clamped by roughly one
        // title-bar height. Horizontal parking is accepted, but it must use
        // the outer edge of the complete arrangement to avoid another display.
        let arrangementFrames = displays.map(\.frame)
        let arrangementMinX = arrangementFrames.map(\.minX).min()!
        let arrangementMaxX = arrangementFrames.map(\.maxX).max()!
        let leftEdgeDisplays = displays.filter { $0.frame.minX == arrangementMinX }
        let rightEdgeDisplays = displays.filter { $0.frame.maxX == arrangementMaxX }
        let candidates = [
            ResolvedFrame(
                x: arrangementMinX - width + 1,
                y: horizontalParkingY(
                    edgeDisplays: leftEdgeDisplays,
                    preferredDisplayID: targetDisplay.id,
                    referenceY: referenceFrame.y,
                    windowHeight: height
                ),
                width: width,
                height: height
            ),
            ResolvedFrame(
                x: arrangementMaxX - 1,
                y: horizontalParkingY(
                    edgeDisplays: rightEdgeDisplays,
                    preferredDisplayID: targetDisplay.id,
                    referenceY: referenceFrame.y,
                    windowHeight: height
                ),
                width: width,
                height: height
            ),
        ]

        // Prefer the side with the least display overlap, then the shorter
        // move from the current physical frame, which keeps repeated hides on
        // the already-parked side. The reference frame above only chooses an
        // anchor Y near the eventual restore location. Fixed array order makes
        // a complete tie stable.
        return candidates.enumerated().min { lhs, rhs in
            let lhsArea = displayIntersectionArea(frame: lhs.element, displays: displays)
            let rhsArea = displayIntersectionArea(frame: rhs.element, displays: displays)
            if lhsArea != rhsArea {
                return lhsArea < rhsArea
            }
            let lhsTravel = squaredDistance(from: window.frame, to: lhs.element)
            let rhsTravel = squaredDistance(from: window.frame, to: rhs.element)
            if lhsTravel != rhsTravel {
                return lhsTravel < rhsTravel
            }
            return lhs.offset < rhs.offset
        }!.element
    }

    private static func horizontalParkingY(
        edgeDisplays: [DisplayInfo],
        preferredDisplayID: String,
        referenceY: CGFloat,
        windowHeight: CGFloat
    ) -> CGFloat {
        precondition(!edgeDisplays.isEmpty)
        return edgeDisplays.map { display in
            let minY = display.visibleFrame.minY
            let maxY = max(minY, display.visibleFrame.maxY - windowHeight)
            let y = min(max(referenceY, minY), maxY)
            return (
                y: y,
                travel: abs(y - referenceY),
                preferredRank: display.id == preferredDisplayID ? 0 : 1,
                displayID: display.id
            )
        }.min { lhs, rhs in
            if lhs.travel != rhs.travel {
                return lhs.travel < rhs.travel
            }
            if lhs.preferredRank != rhs.preferredRank {
                return lhs.preferredRank < rhs.preferredRank
            }
            return lhs.displayID < rhs.displayID
        }!.y
    }

    private static func squaredDistance(from source: ResolvedFrame, to destination: ResolvedFrame) -> CGFloat {
        let deltaX = destination.x - source.x
        let deltaY = destination.y - source.y
        return deltaX * deltaX + deltaY * deltaY
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

    // MARK: - Geometry helpers

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
        let overlaps = displays.compactMap { display -> CGRect? in
            let overlap = windowRect.intersection(display.frame)
            return overlap.isNull || overlap.isEmpty ? nil : overlap
        }
        guard !overlaps.isEmpty else { return false }
        return overlaps.allSatisfy { $0.width <= 1 || $0.height <= 1 }
    }

    private static func displayIntersectionArea(
        frame: ResolvedFrame,
        displays: [DisplayInfo]
    ) -> CGFloat {
        let windowRect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        return displays.reduce(into: CGFloat.zero) { total, display in
            let overlap = windowRect.intersection(display.frame)
            guard !overlap.isNull, !overlap.isEmpty else { return }
            total += overlap.width * overlap.height
        }
    }
}
