import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Enumerates on-screen windows.
///
/// Primary enumeration uses CGWindowListCopyWindowInfo (fast, includes
/// off-screen windows with `.optionAll`). The minimized state is not available
/// from CGWindowList, so it is filled in with one AX batch query per process
/// (kAXWindowsAttribute → kAXMinimizedAttribute). v1 hardcoded
/// `minimized: false`, which broke visibility planning for manually minimized
/// windows — never reintroduce that.
public enum WindowEnumerator {
    public static let sharedProfileCache = ProfileCache()

    /// Windows on the active (visible) portion of the desktop.
    public static func listWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    /// Every window including off-screen (hidden by Shitsurae) and minimized.
    public static func listAllWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionAll, .excludeDesktopElements])
    }

    public static func focusedWindow(displays: [DisplayInfo] = SystemProbe.displays()) -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }

        let windows = listAllWindows(displays: displays)
        return resolveFocusedWindow(
            frontmostPID: Int(app.processIdentifier),
            frontmostBundleID: bundleID,
            focusedWindowID: frontmostWindowID(pid: app.processIdentifier),
            windows: windows
        )
    }

    // MARK: - Internals

    private static func listWindows(
        displays: [DisplayInfo],
        options: CGWindowListOption
    ) -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return buildSnapshots(
            rawWindowInfo: raw,
            displays: displays,
            appResolver: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
                      let bundleID = app.bundleIdentifier
                else {
                    return nil
                }
                return (bundleID: bundleID, isHidden: app.isHidden)
            },
            profileResolver: { bundleID, pid in
                sharedProfileCache.profileDirectory(
                    bundleID: bundleID,
                    pid: pid,
                    resolver: SystemProbe.browserProfileDirectory(bundleID:pid:)
                )
            },
            windowAXInfoResolver: windowAXInfo(pids:)
        )
    }

    /// Per-window AX attributes not available from CGWindowList: the minimized
    /// flag and the window subrole (used to keep dialogs/popups unmanaged).
    struct WindowAXInfo {
        let minimized: Set<UInt32>
        let subroles: [UInt32: String]

        init(minimized: Set<UInt32> = [], subroles: [UInt32: String] = [:]) {
            self.minimized = minimized
            self.subroles = subroles
        }
    }

    /// Pure assembly — injectable resolvers keep this unit-testable.
    static func buildSnapshots(
        rawWindowInfo: [[String: Any]],
        displays: [DisplayInfo],
        appResolver: (Int) -> (bundleID: String, isHidden: Bool)?,
        profileResolver: (String, Int) -> String? = { _, _ in nil },
        windowAXInfoResolver: (Set<Int>) -> WindowAXInfo = { _ in WindowAXInfo() }
    ) -> [WindowSnapshot] {
        struct PendingWindow {
            let windowID: UInt32
            let bundleID: String
            let pid: Int
            let title: String
            let isHidden: Bool
            let rect: CGRect
            let display: DisplayInfo?
            let profileDirectory: String?
            let frontIndex: Int
        }

        var pending: [PendingWindow] = []
        var resolvedProfiles: [Int: String?] = [:]

        for (index, info) in rawWindowInfo.enumerated() {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                continue
            }

            guard let idNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber
            else {
                continue
            }

            let windowID = idNumber.uint32Value
            let pid = pidNumber.intValue

            guard let app = appResolver(pid) else {
                continue
            }

            var rect = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(bounds, &rect)
            }

            if rect.width <= 0 || rect.height <= 0 {
                continue
            }

            let profileDirectory: String?
            if let memoized = resolvedProfiles[pid] {
                profileDirectory = memoized
            } else {
                let resolved = profileResolver(app.bundleID, pid)
                resolvedProfiles[pid] = resolved
                profileDirectory = resolved
            }

            pending.append(
                PendingWindow(
                    windowID: windowID,
                    bundleID: app.bundleID,
                    pid: pid,
                    title: (info[kCGWindowName as String] as? String) ?? "",
                    isHidden: app.isHidden,
                    rect: rect,
                    display: resolveDisplay(for: rect, displays: displays),
                    profileDirectory: profileDirectory,
                    frontIndex: index
                )
            )
        }

        let axInfo = windowAXInfoResolver(Set(pending.map(\.pid)))

        return pending
            .map { window in
                WindowSnapshot(
                    windowID: window.windowID,
                    bundleID: window.bundleID,
                    pid: window.pid,
                    title: window.title,
                    subrole: axInfo.subroles[window.windowID],
                    minimized: axInfo.minimized.contains(window.windowID),
                    hidden: window.isHidden,
                    frame: ResolvedFrame(
                        x: window.rect.origin.x,
                        y: window.rect.origin.y,
                        width: window.rect.width,
                        height: window.rect.height
                    ),
                    displayID: window.display?.id,
                    profileDirectory: window.profileDirectory,
                    isFullscreen: window.display.map { roughlySame(rect: window.rect, displayFrame: $0.frame) } ?? false,
                    frontIndex: window.frontIndex
                )
            }
            .sorted { lhs, rhs in
                if lhs.frontIndex != rhs.frontIndex { return lhs.frontIndex < rhs.frontIndex }
                return lhs.windowID < rhs.windowID
            }
    }

    /// One AX query per pid, reading both the minimized flag and the subrole
    /// for every window (neither is available from CGWindowList). Folding both
    /// into a single pass avoids a second per-process AX round trip.
    static func windowAXInfo(pids: Set<Int>) -> WindowAXInfo {
        guard AXIsProcessTrusted() else {
            return WindowAXInfo()
        }

        var minimized = Set<UInt32>()
        var subroles: [UInt32: String] = [:]

        for pid in pids {
            let appElement = AXUIElementCreateApplication(pid_t(pid))

            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windowElements = windowsRef as? [AXUIElement]
            else {
                continue
            }

            for element in windowElements {
                var windowID: CGWindowID = 0
                guard AXUIElementGetWindowID(element, &windowID) == .success else {
                    continue
                }
                let id = UInt32(windowID)

                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   (minimizedRef as? Bool) == true
                {
                    minimized.insert(id)
                }

                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String
                {
                    subroles[id] = subrole
                }
            }
        }

        return WindowAXInfo(minimized: minimized, subroles: subroles)
    }

    static func resolveFocusedWindow(
        frontmostPID: Int,
        frontmostBundleID: String,
        focusedWindowID: UInt32?,
        windows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        if let focusedWindowID,
           let exact = windows.first(where: { $0.windowID == focusedWindowID })
        {
            return exact
        }

        if let exact = windows.first(where: { $0.pid == frontmostPID }) {
            return exact
        }

        return windows.first(where: { $0.bundleID == frontmostBundleID })
    }

    static func frontmostWindowID(pid: pid_t) -> UInt32? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attribute, &ref) == .success,
                  let resolved = ref
            else {
                continue
            }

            var windowID: CGWindowID = 0
            if AXUIElementGetWindowID((resolved as! AXUIElement), &windowID) == .success {
                return UInt32(windowID)
            }
        }

        return nil
    }

    static func resolveDisplay(for rect: CGRect, displays: [DisplayInfo]) -> DisplayInfo? {
        if displays.isEmpty {
            return nil
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let containing = displays.first(where: { $0.frame.contains(center) }) {
            return containing
        }

        var best: (display: DisplayInfo, area: CGFloat)?
        for display in displays {
            let intersection = rect.intersection(display.frame)
            if intersection.isNull || intersection.isEmpty {
                continue
            }

            let area = intersection.width * intersection.height
            if let current = best {
                if area > current.area || (area == current.area && display.id < current.display.id) {
                    best = (display, area)
                }
            } else {
                best = (display, area)
            }
        }

        return best?.display ?? displays.sorted(by: { $0.id < $1.id }).first
    }

    static func roughlySame(rect: CGRect, displayFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 2.0
        return abs(rect.origin.x - displayFrame.origin.x) <= tolerance
            && abs(rect.origin.y - displayFrame.origin.y) <= tolerance
            && abs(rect.width - displayFrame.width) <= tolerance
            && abs(rect.height - displayFrame.height) <= tolerance
    }

    static func roughlySame(frame: ResolvedFrame, expectedFrame: ResolvedFrame) -> Bool {
        // Generous position tolerance: macOS adjusts y for the menu bar
        // (typically 25 px) and may snap x/width to integer boundaries.
        // Size gets a tighter tolerance because rounding is the only
        // expected source of drift.
        let positionTolerance = 30.0
        let sizeTolerance = 2.0
        return abs(frame.x - expectedFrame.x) <= positionTolerance
            && abs(frame.y - expectedFrame.y) <= positionTolerance
            && abs(frame.width - expectedFrame.width) <= sizeTolerance
            && abs(frame.height - expectedFrame.height) <= sizeTolerance
    }

    static func roughlySame(position: CGPoint, expectedPosition: CGPoint) -> Bool {
        let tolerance: CGFloat = 2
        return abs(position.x - expectedPosition.x) <= tolerance
            && abs(position.y - expectedPosition.y) <= tolerance
    }
}
