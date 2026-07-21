import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Enumerates on-screen windows.
///
/// Primary enumeration uses CGWindowListCopyWindowInfo (fast, includes
/// off-screen windows with `.optionAll`). The minimized state is not available
/// from CGWindowList, so it is filled in with one AX batch query per process
/// (`kAXWindowsAttribute` → `kAXMinimizedAttribute`). The same query records
/// which CG window IDs are backed by real AX windows. v1 hardcoded
/// `minimized: false`, which broke visibility planning for manually minimized
/// windows — never reintroduce that.
public enum WindowEnumerator {
    public static let sharedProfileCache = ProfileCache()

    /// Windows on the active (visible) portion of the desktop.
    public static func listWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        inventory(displays: displays, options: [.optionOnScreenOnly, .excludeDesktopElements]).windows
    }

    /// Every window including off-screen (hidden by Shitsurae) and minimized.
    public static func listAllWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        allWindowInventory(displays: displays).windows
    }

    public static func allWindowInventory(
        displays: [DisplayInfo] = SystemProbe.displays()
    ) -> WindowInventory {
        inventory(displays: displays, options: [.optionAll, .excludeDesktopElements])
    }

    public static func onScreenWindowIdentities() -> Set<WindowIdentity> {
        let ownersBefore = processOwners()
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        let rawPIDs = Set(raw.compactMap {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
        })
        let ownersAfter = processOwners(pids: rawPIDs)
        let stableOwners = ownersAfter.filter { pid, owner in
            ownersBefore[pid]?.identity == owner.identity
        }
        return Set(raw.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue,
                  let owner = stableOwners[pid]
            else {
                return nil
            }
            return WindowIdentity(
                pid: pid,
                processStartTime: owner.identity.processStartTime,
                windowID: id,
                bundleID: owner.identity.bundleID
            )
        })
    }

    public static func focusedWindow(displays: [DisplayInfo] = SystemProbe.displays()) -> WindowSnapshot? {
        let observation = focusedWindowObservation(displays: displays)
        guard let identity = observation.focusedIdentity else { return nil }
        return observation.inventory.windows.first { $0.identity == identity }
    }

    public static func focusedWindowObservation(
        displays: [DisplayInfo] = SystemProbe.displays()
    ) -> WindowObservation {
        guard let appBefore = NSWorkspace.shared.frontmostApplication,
              let bundleID = appBefore.bundleIdentifier,
              let processStartTime = ProcessGenerationResolver.startTime(pid: Int(appBefore.processIdentifier))
        else {
            return WindowObservation(
                inventory: allWindowInventory(displays: displays),
                focusedIdentity: nil,
                mainIdentity: nil
            )
        }
        let inventory = allWindowInventory(displays: displays)
        let focusedWindowID = windowID(
            pid: appBefore.processIdentifier,
            attribute: kAXFocusedWindowAttribute as CFString
        )
        let mainWindowID = windowID(
            pid: appBefore.processIdentifier,
            attribute: kAXMainWindowAttribute as CFString
        )
        guard let appAfter = NSWorkspace.shared.frontmostApplication,
              appAfter.processIdentifier == appBefore.processIdentifier,
              appAfter.bundleIdentifier == bundleID,
              ProcessGenerationResolver.startTime(pid: Int(appAfter.processIdentifier)) == processStartTime
        else {
            return WindowObservation(inventory: inventory, focusedIdentity: nil, mainIdentity: nil)
        }
        func identity(windowID: UInt32?) -> WindowIdentity? {
            windowID.map {
                WindowIdentity(
                    pid: Int(appBefore.processIdentifier),
                    processStartTime: processStartTime,
                    windowID: $0,
                    bundleID: bundleID
                )
            }
        }
        return WindowObservation(
            inventory: inventory,
            // Preserve AX's exact identities even when the inventory was
            // captured just before a new sheet appeared. Consumers can then
            // fail closed instead of treating the older main as mutable.
            focusedIdentity: identity(windowID: focusedWindowID),
            mainIdentity: identity(windowID: mainWindowID)
        )
    }

    // MARK: - Internals

    private static func inventory(
        displays: [DisplayInfo],
        options: CGWindowListOption
    ) -> WindowInventory {
        let ownersBefore = processOwners()
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return .unavailable
        }

        let rawPIDs = Set(raw.compactMap {
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
        })
        let ownersAfter = processOwners(pids: rawPIDs)
        let stableOwners = ownersAfter.filter { pid, owner in
            ownersBefore[pid]?.identity == owner.identity
        }
        let liveWindowHandles = rawWindowHandles(
            rawWindowInfo: raw,
            processStartTimesByPID: stableOwners.mapValues(\.identity.processStartTime)
        )
        return .available(buildSnapshots(
            rawWindowInfo: raw,
            displays: displays,
            appResolver: { pid in
                stableOwners[pid].map {
                    (
                        bundleID: $0.identity.bundleID,
                        isHidden: $0.isHidden,
                        processStartTime: $0.identity.processStartTime
                    )
                }
            },
            profileResolver: { bundleID, pid, processStartTime in
                sharedProfileCache.profileDirectory(
                    bundleID: bundleID,
                    pid: pid,
                    processStartTime: processStartTime,
                    resolver: SystemProbe.browserProfileDirectory(bundleID:pid:)
                )
            },
            windowAXInfoResolver: windowAXInfo(expectedBundlesByPID:)
        ), liveWindowHandles: liveWindowHandles)
    }

    struct ProcessOwnerIdentity: Equatable, Hashable, Sendable {
        let bundleID: String
        let processStartTime: UInt64
    }

    private struct ProcessOwner: Equatable {
        let identity: ProcessOwnerIdentity
        let isHidden: Bool
    }

    private static func processOwners(pids: Set<Int>? = nil) -> [Int: ProcessOwner] {
        let applications = pids.map {
            $0.compactMap { NSRunningApplication(processIdentifier: pid_t($0)) }
        } ?? NSWorkspace.shared.runningApplications
        return Dictionary(applications.compactMap { app in
            let pid = Int(app.processIdentifier)
            guard !app.isTerminated,
                  let bundleID = app.bundleIdentifier,
                  let processStartTime = ProcessGenerationResolver.startTime(pid: pid)
            else {
                return nil
            }
            return (pid, ProcessOwner(
                identity: ProcessOwnerIdentity(
                    bundleID: bundleID,
                    processStartTime: processStartTime
                ),
                isHidden: app.isHidden
            ))
        }, uniquingKeysWith: { current, _ in current })
    }

    static func rawWindowHandles(
        rawWindowInfo: [[String: Any]],
        processStartTimesByPID: [Int: UInt64] = [:]
    ) -> Set<WindowHandle> {
        Set(rawWindowInfo.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.intValue
            else {
                return nil
            }
            return WindowHandle(
                pid: pid,
                processStartTime: processStartTimesByPID[pid],
                windowID: id
            )
        })
    }

    /// Per-window AX attributes not available from CGWindowList and the IDs
    /// actually exposed by the owning process's AX window list. Attribute
    /// dictionaries contain only successful observations; missing values are
    /// deliberately preserved as unknown rather than defaulted.
    struct WindowAXInfo {
        /// A window ID absent from this set is "not AX-visible", which covers
        /// CG-only surfaces, AX query failures, and windows the process does
        /// not currently report (other native Space, some minimized states).
        /// Consumers must treat absence as non-authoritative — see
        /// `WindowSnapshot.isAXBacked`.
        let axBackedWindowIDs: Set<WindowIdentity>
        let minimized: Set<WindowIdentity>
        let roles: [WindowIdentity: String]
        let subroles: [WindowIdentity: String]
        let modals: [WindowIdentity: Bool]
        let focusedWindowIdentities: Set<WindowIdentity>
        let mainWindowIdentities: Set<WindowIdentity>

        init(
            axBackedWindowIDs: Set<WindowIdentity>,
            minimized: Set<WindowIdentity> = [],
            roles: [WindowIdentity: String] = [:],
            subroles: [WindowIdentity: String] = [:],
            modals: [WindowIdentity: Bool] = [:],
            focusedWindowIdentities: Set<WindowIdentity> = [],
            mainWindowIdentities: Set<WindowIdentity> = []
        ) {
            self.axBackedWindowIDs = axBackedWindowIDs
            self.minimized = minimized
            self.roles = roles
            self.subroles = subroles
            self.modals = modals
            self.focusedWindowIdentities = focusedWindowIdentities
            self.mainWindowIdentities = mainWindowIdentities
        }
    }

    /// Pure assembly — injectable resolvers keep this unit-testable.
    static func buildSnapshots(
        rawWindowInfo: [[String: Any]],
        displays: [DisplayInfo],
        appResolver: (Int) -> (bundleID: String, isHidden: Bool, processStartTime: UInt64)?,
        profileResolver: (String, Int, UInt64) -> String? = { _, _, _ in nil },
        windowAXInfoResolver: ([Int: ProcessOwnerIdentity]) -> WindowAXInfo
    ) -> [WindowSnapshot] {
        struct PendingWindow {
            let windowID: UInt32
            let bundleID: String
            let pid: Int
            let processStartTime: UInt64
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
                let resolved = profileResolver(app.bundleID, pid, app.processStartTime)
                resolvedProfiles[pid] = resolved
                profileDirectory = resolved
            }

            pending.append(
                PendingWindow(
                    windowID: windowID,
                    bundleID: app.bundleID,
                    pid: pid,
                    processStartTime: app.processStartTime,
                    title: (info[kCGWindowName as String] as? String) ?? "",
                    isHidden: app.isHidden,
                    rect: rect,
                    display: resolveDisplay(for: rect, displays: displays),
                    profileDirectory: profileDirectory,
                    frontIndex: index
                )
            )
        }

        let expectedBundlesByPID = Dictionary(grouping: pending, by: \.pid).compactMapValues { windows in
            let owners = Set(windows.map {
                ProcessOwnerIdentity(
                    bundleID: $0.bundleID,
                    processStartTime: $0.processStartTime
                )
            })
            return owners.count == 1 ? owners.first : nil
        }
        let axInfo = windowAXInfoResolver(expectedBundlesByPID)

        let snapshots = pending
            .map { window in
                let axIdentity = WindowIdentity(
                    pid: window.pid,
                    processStartTime: window.processStartTime,
                    windowID: window.windowID,
                    bundleID: window.bundleID
                )
                return WindowSnapshot(
                    windowID: window.windowID,
                    bundleID: window.bundleID,
                    pid: window.pid,
                    processStartTime: window.processStartTime,
                    title: window.title,
                    role: axInfo.roles[axIdentity],
                    subrole: axInfo.subroles[axIdentity],
                    modal: axInfo.modals[axIdentity],
                    geometryBlocked: false,
                    isAXBacked: axInfo.axBackedWindowIDs.contains(axIdentity),
                    minimized: axInfo.minimized.contains(axIdentity),
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

        let snapshotsByIdentity = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.identity, $0) })
        let blockedMainIdentities: Set<WindowIdentity> = Set(
            axInfo.mainWindowIdentities.compactMap { mainIdentity -> WindowIdentity? in
                guard let focusedIdentity = axInfo.focusedWindowIdentities.first(where: {
                    $0.pid == mainIdentity.pid
                        && $0.processStartTime == mainIdentity.processStartTime
                        && $0.bundleID == mainIdentity.bundleID
                }), focusedIdentity != mainIdentity else {
                    return nil
                }
                guard let focusedWindow = snapshotsByIdentity[focusedIdentity] else {
                    // AX proves another window has focus, but CG did not yield
                    // enough data to classify it. Fail closed for the exact main.
                    return mainIdentity
                }
                return WindowEligibility.classification(of: focusedWindow) == .manageable
                    ? nil
                    : mainIdentity
            }
        )
        return snapshots.map {
            blockedMainIdentities.contains($0.identity) ? $0.withGeometryBlocked(true) : $0
        }
    }

    /// One AX query per pid, reading minimized, role, subrole, and modal for
    /// every window. Folding them into one pass avoids repeated process AX
    /// enumeration while retaining per-attribute observation failures.
    static func windowAXInfo(expectedBundlesByPID: [Int: ProcessOwnerIdentity]) -> WindowAXInfo {
        guard AXIsProcessTrusted() else {
            // No AX trust: nothing is confirmed AX-backed, nothing manageable.
            return WindowAXInfo(axBackedWindowIDs: [])
        }

        var axBackedWindowIDs = Set<WindowIdentity>()
        var minimized = Set<WindowIdentity>()
        var roles: [WindowIdentity: String] = [:]
        var subroles: [WindowIdentity: String] = [:]
        var modals: [WindowIdentity: Bool] = [:]
        var focusedWindowIdentities = Set<WindowIdentity>()
        var mainWindowIdentities = Set<WindowIdentity>()

        for (pid, expectedOwner) in expectedBundlesByPID {
            guard let ownerBefore = NSRunningApplication(processIdentifier: pid_t(pid)),
                  !ownerBefore.isTerminated,
                  ownerBefore.bundleIdentifier == expectedOwner.bundleID,
                  ProcessGenerationResolver.startTime(pid: pid) == expectedOwner.processStartTime
            else {
                continue
            }
            let appElement = AXUIElementCreateApplication(pid_t(pid))

            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windowElements = windowsRef as? [AXUIElement]
            else {
                // A failed query is not "this process has no AX windows":
                // busy processes (Chrome under automation) time out here.
                // The windows simply stay non-AX-backed for this pass, which
                // consumers must treat as non-authoritative.
                continue
            }

            var processBacked = Set<WindowIdentity>()
            var processMinimized = Set<WindowIdentity>()
            var processRoles: [WindowIdentity: String] = [:]
            var processSubroles: [WindowIdentity: String] = [:]
            var processModals: [WindowIdentity: Bool] = [:]
            for element in windowElements {
                var windowID: CGWindowID = 0
                guard AXUIElementGetWindowID(element, &windowID) == .success else {
                    continue
                }
                let identity = WindowIdentity(
                    pid: pid,
                    processStartTime: expectedOwner.processStartTime,
                    windowID: UInt32(windowID),
                    bundleID: expectedOwner.bundleID
                )
                processBacked.insert(identity)

                var minimizedRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
                   (minimizedRef as? Bool) == true
                {
                    processMinimized.insert(identity)
                }

                var roleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
                   let role = roleRef as? String
                {
                    processRoles[identity] = role
                }

                var subroleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
                   let subrole = subroleRef as? String
                {
                    processSubroles[identity] = subrole
                }

                var modalRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXModalAttribute as CFString, &modalRef) == .success,
                   let modal = modalRef as? Bool
                {
                    processModals[identity] = modal
                }
            }

            func processWindowIdentity(attribute: CFString) -> WindowIdentity? {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appElement, attribute, &ref) == .success,
                      let resolved = ref,
                      let element = checkedAXUIElement(resolved)
                else {
                    return nil
                }
                var resolvedWindowID: CGWindowID = 0
                guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                    return nil
                }
                return WindowIdentity(
                    pid: pid,
                    processStartTime: expectedOwner.processStartTime,
                    windowID: UInt32(resolvedWindowID),
                    bundleID: expectedOwner.bundleID
                )
            }
            let processFocusedIdentity = processWindowIdentity(
                attribute: kAXFocusedWindowAttribute as CFString
            )
            let processMainIdentity = processWindowIdentity(
                attribute: kAXMainWindowAttribute as CFString
            )

            guard let ownerAfter = NSRunningApplication(processIdentifier: pid_t(pid)),
                  !ownerAfter.isTerminated,
                  ownerAfter.bundleIdentifier == expectedOwner.bundleID,
                  ProcessGenerationResolver.startTime(pid: pid) == expectedOwner.processStartTime
            else {
                continue
            }
            axBackedWindowIDs.formUnion(processBacked)
            minimized.formUnion(processMinimized)
            roles.merge(processRoles, uniquingKeysWith: { current, _ in current })
            subroles.merge(processSubroles, uniquingKeysWith: { current, _ in current })
            modals.merge(processModals, uniquingKeysWith: { current, _ in current })
            if let processFocusedIdentity {
                focusedWindowIdentities.insert(processFocusedIdentity)
            }
            if let processMainIdentity {
                mainWindowIdentities.insert(processMainIdentity)
            }
        }

        return WindowAXInfo(
            axBackedWindowIDs: axBackedWindowIDs,
            minimized: minimized,
            roles: roles,
            subroles: subroles,
            modals: modals,
            focusedWindowIdentities: focusedWindowIdentities,
            mainWindowIdentities: mainWindowIdentities
        )
    }

    static func resolveFocusedWindow(
        frontmostPID: Int,
        frontmostProcessStartTime: UInt64,
        frontmostBundleID: String,
        focusedWindowID: UInt32?,
        windows: [WindowSnapshot],
        requireExactFocusedWindow: Bool = false
    ) -> WindowSnapshot? {
        if let focusedWindowID {
            let exact = windows.first(where: {
               $0.pid == frontmostPID
                   && $0.processStartTime == frontmostProcessStartTime
                   && $0.bundleID == frontmostBundleID
                   && $0.windowID == focusedWindowID
           })
            if exact != nil || requireExactFocusedWindow {
                return exact
            }
        } else if requireExactFocusedWindow {
            return nil
        }

        // AX can temporarily omit the focused window ID, but the foreground
        // process identity is still authoritative. Never fall back to a
        // same-bundle sibling process: Chrome DevTools routinely runs one.
        return windows.first(where: {
            $0.pid == frontmostPID
                && $0.processStartTime == frontmostProcessStartTime
                && $0.bundleID == frontmostBundleID
        })
    }

    static func windowID(pid: pid_t, attribute: CFString) -> UInt32? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute, &ref) == .success,
              let resolved = ref,
              let element = checkedAXUIElement(resolved)
        else {
            return nil
        }

        var resolvedWindowID: CGWindowID = 0
        guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
            return nil
        }
        return UInt32(resolvedWindowID)
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
