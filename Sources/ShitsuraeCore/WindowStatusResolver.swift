import CoreGraphics
import Foundation

public enum WindowStatusResolver {
    public static func resolveLive(
        state: RuntimeState,
        windows: [WindowSnapshot],
        displays: [DisplayInfo] = SystemProbe.displays()
    ) -> RuntimeState {
        state.with(slots: state.slots.compactMap { resolve(entry: $0, windows: windows, displays: displays) })
    }

    public static func resolve(
        state: RuntimeState,
        windows: [WindowSnapshot],
        displays: [DisplayInfo] = SystemProbe.displays()
    ) -> RuntimeState {
        state.with(slots: state.slots.compactMap { resolve(entry: $0, windows: windows, displays: displays) ?? $0 })
    }

    private static func resolve(
        entry: SlotEntry,
        windows: [WindowSnapshot],
        displays: [DisplayInfo]
    ) -> SlotEntry? {
        guard let window = resolveWindow(for: entry, windows: windows) else {
            return nil
        }

        let visibilityState = resolveVisibilityState(entry: entry, window: window, displays: displays)
        let lastVisibleFrame = visibilityState == .visible ? window.frame : entry.lastVisibleFrame
        let lastHiddenFrame = visibilityState == .hiddenOffscreen ? window.frame : entry.lastHiddenFrame

        return SlotEntry(
            layoutName: entry.layoutName,
            slot: entry.slot,
            layoutOriginSpaceID: entry.layoutOriginSpaceID,
            layoutOriginSlot: entry.layoutOriginSlot,
            source: entry.source,
            bundleID: window.bundleID,
            definitionFingerprint: entry.definitionFingerprint,
            pid: window.pid,
            titleMatchKind: entry.titleMatchKind,
            titleMatchValue: entry.titleMatchValue,
            excludeTitleRegex: entry.excludeTitleRegex,
            role: entry.role ?? window.role,
            subrole: entry.subrole ?? window.subrole,
            matchIndex: entry.matchIndex,
            lastKnownTitle: window.title,
            profile: entry.profile ?? window.profileDirectory,
            spaceID: entry.spaceID,
            nativeSpaceID: window.spaceID ?? entry.nativeSpaceID,
            displayID: window.displayID ?? entry.displayID,
            windowID: window.windowID,
            lastVisibleFrame: lastVisibleFrame,
            lastHiddenFrame: lastHiddenFrame,
            visibilityState: visibilityState,
            lastActivatedAt: entry.lastActivatedAt
        )
    }

    private static func resolveWindow(for entry: SlotEntry, windows: [WindowSnapshot]) -> WindowSnapshot? {
        if let windowID = entry.windowID,
           let exact = windows.first(where: { $0.windowID == windowID })
        {
            return exact
        }

        return WindowMatchEngine.select(rule: persistedMatchRule(for: entry), candidates: windows)
    }

    private static func persistedMatchRule(for entry: SlotEntry) -> WindowMatchRule {
        WindowMatchRule(
            bundleID: entry.bundleID,
            title: persistedTitleMatcher(for: entry),
            role: entry.role,
            subrole: entry.subrole,
            profile: entry.profile,
            excludeTitleRegex: entry.excludeTitleRegex,
            index: entry.matchIndex
        )
    }

    private static func persistedTitleMatcher(for entry: SlotEntry) -> TitleMatcher? {
        guard let value = entry.titleMatchValue else {
            return nil
        }

        switch entry.titleMatchKind {
        case .none:
            return nil
        case .equals:
            return TitleMatcher(equals: value, contains: nil, regex: nil)
        case .contains:
            return TitleMatcher(equals: nil, contains: value, regex: nil)
        case .regex:
            return TitleMatcher(equals: nil, contains: nil, regex: value)
        }
    }

    private static func resolveVisibilityState(
        entry: SlotEntry,
        window: WindowSnapshot,
        displays: [DisplayInfo]
    ) -> VirtualWindowVisibilityState {
        if window.minimized || window.hidden {
            return .hiddenOffscreen
        }

        if let lastHiddenFrame = entry.lastHiddenFrame,
           approximatelyEquals(lastHiddenFrame, window.frame)
        {
            return .hiddenOffscreen
        }

        if isVirtualHiddenWindowFrame(frame: window.frame, displays: displays) {
            return .hiddenOffscreen
        }
        return .visible
    }

    private static func approximatelyEquals(_ lhs: ResolvedFrame, _ rhs: ResolvedFrame, tolerance: Double = 1) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance
            && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}
