import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("GetProcessForPID")
@discardableResult
private func LegacyGetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

private enum SLPSMode: UInt32 {
    case userGenerated = 0x200
}

private typealias CSetFrontProcessWithOptionsFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    CGWindowID,
    UInt32
) -> CGError

private typealias CPostEventRecordToFn = @convention(c) (
    UnsafeMutablePointer<ProcessSerialNumber>,
    UnsafeMutablePointer<UInt8>
) -> CGError

typealias SetFrontProcessWithOptionsCall = (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
typealias PostEventRecordToCall = (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

private enum SkyLightSymbols {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

    static func setFrontProcessWithOptions() -> SetFrontProcessWithOptionsCall? {
        guard let function = resolve("_SLPSSetFrontProcessWithOptions", as: CSetFrontProcessWithOptionsFn.self) else {
            return nil
        }

        return { psn, windowID, mode in
            function(psn, windowID, mode)
        }
    }

    static func postEventRecordTo() -> PostEventRecordToCall? {
        guard let function = resolve("SLPSPostEventRecordTo", as: CPostEventRecordToFn.self) else {
            return nil
        }

        return { psn, bytes in
            function(psn, bytes)
        }
    }

    private static func resolve<T>(_ symbol: String, as _: T.Type) -> T? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let raw = dlsym(handle, symbol)
        else {
            return nil
        }

        return unsafeBitCast(raw, to: T.self)
    }
}

public struct WindowSnapshot: Codable, Equatable {
    public let windowID: UInt32
    public let bundleID: String
    public let pid: Int
    public let title: String
    public let role: String
    public let subrole: String?
    public let minimized: Bool
    public let hidden: Bool
    public let frame: ResolvedFrame
    public let spaceID: Int?
    public let displayID: String?
    public let profileDirectory: String?
    public let isFullscreen: Bool
    public let frontIndex: Int

    public init(
        windowID: UInt32,
        bundleID: String,
        pid: Int,
        title: String,
        role: String,
        subrole: String?,
        minimized: Bool,
        hidden: Bool,
        frame: ResolvedFrame,
        spaceID: Int?,
        displayID: String?,
        profileDirectory: String? = nil,
        isFullscreen: Bool,
        frontIndex: Int
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.pid = pid
        self.title = title
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
        self.hidden = hidden
        self.frame = frame
        self.spaceID = spaceID
        self.displayID = displayID
        self.profileDirectory = profileDirectory
        self.isFullscreen = isFullscreen
        self.frontIndex = frontIndex
    }
}

public enum WindowQueryService {
    public static func listWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    public static func listWindowsOnAllSpaces(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionAll, .excludeDesktopElements])
    }

    private static func listWindows(
        displays: [DisplayInfo],
        options: CGWindowListOption
    ) -> [WindowSnapshot] {
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return listWindows(
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
            profileResolver: SystemProbe.browserProfileDirectory(bundleID:pid:),
            spaceResolver: resolvedSpaceID(for:displayID:)
        )
    }

    static func listWindows(
        rawWindowInfo: [[String: Any]],
        displays: [DisplayInfo],
        appResolver: (Int) -> (bundleID: String, isHidden: Bool)?,
        profileResolver: (String, Int) -> String? = { _, _ in nil },
        spaceResolver: (UInt32, String?) -> Int? = { _, _ in nil }
    ) -> [WindowSnapshot] {
        var windows: [WindowSnapshot] = []
        var resolvedProfiles: [Int: String] = [:]
        var unresolvedPIDs = Set<Int>()
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

            guard let app = appResolver(pid)
            else {
                continue
            }

            var rect = CGRect.zero
            if let bounds = info[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(bounds, &rect)
            }

            if rect.width <= 0 || rect.height <= 0 {
                continue
            }

            let mappedDisplay = resolveDisplay(for: rect, displays: displays)
            let title = (info[kCGWindowName as String] as? String) ?? ""
            let spaceID = (info["kCGWindowWorkspace"] as? Int) ?? spaceResolver(windowID, mappedDisplay?.id)
            let isFullscreen = mappedDisplay.map { roughlySame(rect: rect, displayFrame: $0.frame) } ?? false
            let profileDirectory: String?
            if let cached = resolvedProfiles[pid] {
                profileDirectory = cached
            } else if unresolvedPIDs.contains(pid) {
                profileDirectory = nil
            } else {
                let resolved = profileResolver(app.bundleID, pid)
                if let resolved {
                    resolvedProfiles[pid] = resolved
                } else {
                    unresolvedPIDs.insert(pid)
                }
                profileDirectory = resolved
            }

            windows.append(
                WindowSnapshot(
                    windowID: windowID,
                    bundleID: app.bundleID,
                    pid: pid,
                    title: title,
                    role: "AXWindow",
                    subrole: nil,
                    minimized: false,
                    hidden: app.isHidden,
                    frame: ResolvedFrame(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
                    spaceID: spaceID,
                    displayID: mappedDisplay?.id,
                    profileDirectory: profileDirectory,
                    isFullscreen: isFullscreen,
                    frontIndex: index
                )
            )
        }

        return windows.sorted { lhs, rhs in
            if lhs.frontIndex != rhs.frontIndex { return lhs.frontIndex < rhs.frontIndex }
            return lhs.windowID < rhs.windowID
        }
    }

    public static func focusedWindow(displays: [DisplayInfo] = SystemProbe.displays()) -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier
        else {
            return nil
        }

        let windows = listWindows(displays: displays)
        return resolveFocusedWindow(
            frontmostPID: Int(app.processIdentifier),
            frontmostBundleID: bundleID,
            focusedWindowID: frontmostWindowID(pid: app.processIdentifier),
            windows: windows
        )
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

    private static func frontmostWindowID(pid: pid_t) -> UInt32? {
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

    @discardableResult
    public static func setFocusedWindowFrame(_ frame: ResolvedFrame) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let appElement = AXUIElementCreateApplication(frontmost.processIdentifier)

        var focusedWindowRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindowRef)
        guard focusedResult == .success,
              let focused = focusedWindowRef
        else {
            return false
        }

        let windowElement = focused as! AXUIElement

        var point = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)

        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let setPosition = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, pointValue)
        let setSize = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)

        return setPosition == .success && setSize == .success
    }

    @discardableResult
    public static func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        prepareForTargetedWindowInteraction(running)
        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        guard let windowElement = matchingWindowElement(
            windowID: windowID,
            appElement: appElement,
            windowIDResolver: { element in
                var resolvedWindowID: CGWindowID = 0
                guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                    return nil
                }
                return resolvedWindowID
            }
        ) else {
            return false
        }

        guard focusWindowElement(
            appElement: appElement,
            windowElement: windowElement,
            pid: running.processIdentifier,
            bundleID: bundleID
        ) else {
            return false
        }

        var point = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)

        guard let pointValue = AXValueCreate(.cgPoint, &point),
              let sizeValue = AXValueCreate(.cgSize, &size)
        else {
            return false
        }

        let setPosition = AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, pointValue)
        let setSize = AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        return setPosition == .success && setSize == .success
    }

    @discardableResult
    public static func focusWindow(windowID: UInt32, bundleID: String) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        prepareForTargetedWindowInteraction(running)

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        guard let windowElement = matchingWindowElement(
            windowID: windowID,
            appElement: appElement,
            windowIDResolver: { element in
                var resolvedWindowID: CGWindowID = 0
                guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                    return nil
                }
                return resolvedWindowID
            }
        ) else {
            return false
        }

        return focusWindowElement(
            appElement: appElement,
            windowElement: windowElement,
            pid: running.processIdentifier,
            bundleID: bundleID
        )
    }

    @discardableResult
    public static func activate(bundleID: String, preferredWindowTitle: String? = nil) -> Bool {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            _ = running.unhide()
            _ = running.activate(options: bundleActivationOptions())
            if waitForFrontmost(pid: running.processIdentifier, bundleID: bundleID) {
                return true
            }

            if activateViaAccessibility(
                pid: running.processIdentifier,
                preferredWindowTitle: preferredWindowTitle,
                bundleID: bundleID
            ), waitForFrontmost(pid: running.processIdentifier, bundleID: bundleID)
            {
                return true
            }

            return false
        }

        guard SystemProbe.launchApplication(bundleID: bundleID) else {
            return false
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            _ = running.unhide()
            _ = running.activate(options: bundleActivationOptions())
            if waitForFrontmost(pid: running.processIdentifier, bundleID: bundleID) {
                return true
            }

            if activateViaAccessibility(
                pid: running.processIdentifier,
                preferredWindowTitle: preferredWindowTitle,
                bundleID: bundleID
            ), waitForFrontmost(pid: running.processIdentifier, bundleID: bundleID)
            {
                return true
            }
        }

        return false
    }

    @discardableResult
    private static func activateViaAccessibility(pid: pid_t, preferredWindowTitle: String?, bundleID: String?) -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              !windows.isEmpty
        else {
            return false
        }

        let targetWindow = pickTargetWindow(windows: windows, preferredWindowTitle: preferredWindowTitle)

        _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        guard waitForFrontmost(pid: pid, bundleID: bundleID) else {
            return false
        }

        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, targetWindow)
        _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, targetWindow)
        _ = AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)

        return waitForFrontmost(pid: pid, bundleID: bundleID)
    }

    static func bundleActivationOptions() -> NSApplication.ActivationOptions {
        [.activateAllWindows]
    }

    private static func prepareForTargetedWindowInteraction(_ running: NSRunningApplication) {
        prepareForTargetedWindowInteraction(isHidden: running.isHidden) {
            _ = running.unhide()
        }
    }

    static func prepareForTargetedWindowInteraction(isHidden: Bool, unhide: () -> Void) {
        // Avoid app-wide activation here. The precise window focus path below should decide the z-order.
        if isHidden {
            unhide()
        }
    }

    @discardableResult
    private static func focusWindowElement(
        appElement: AXUIElement,
        windowElement: AXUIElement,
        pid: pid_t,
        bundleID: String?
    ) -> Bool {
        var resolvedWindowID: CGWindowID = 0
        guard AXUIElementGetWindowID(windowElement, &resolvedWindowID) == .success else {
            return false
        }

        return performWindowFocusTransition(
            setFrontmost: {
                if !promoteWindowToFront(pid: pid, windowID: UInt32(resolvedWindowID)) {
                    _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
            },
            waitForFrontmost: {
                waitForFrontmost(pid: pid, bundleID: bundleID)
            },
            applyWindowFocus: {
                _ = AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
                _ = AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, windowElement)
                _ = AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
            },
            waitForTargetWindow: {
                waitForFocusedWindow(
                    appElement: appElement,
                    targetWindowID: UInt32(resolvedWindowID),
                    pid: pid,
                    bundleID: bundleID
                )
            }
        )
    }

    static func performWindowFocusTransition(
        setFrontmost: () -> Void,
        waitForFrontmost: () -> Bool,
        applyWindowFocus: () -> Void,
        waitForTargetWindow: () -> Bool,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        maxAttempts: Int = 3,
        settleDelay: TimeInterval = 0.05
    ) -> Bool {
        setFrontmost()

        guard waitForFrontmost() else {
            return false
        }

        for attempt in 0 ..< maxAttempts {
            applyWindowFocus()
            if waitForTargetWindow() {
                return true
            }

            if attempt + 1 < maxAttempts {
                sleep(0.01)
            }
        }

        if settleDelay > 0 {
            sleep(settleDelay)
        }

        return waitForTargetWindow()
    }

    private static func getProcessSerialNumber(pid: pid_t, psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus {
        LegacyGetProcessForPID(pid, psn)
    }

    private static func promoteWindowToFront(pid: pid_t, windowID: UInt32) -> Bool {
        promoteWindowToFront(
            pid: pid,
            windowID: windowID,
            getProcessForPID: getProcessSerialNumber,
            setFrontProcessWithOptions: SkyLightSymbols.setFrontProcessWithOptions(),
            postEventRecordTo: SkyLightSymbols.postEventRecordTo()
        )
    }

    static func promoteWindowToFront(
        pid: pid_t,
        windowID: UInt32,
        getProcessForPID: (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus,
        setFrontProcessWithOptions: SetFrontProcessWithOptionsCall?,
        postEventRecordTo: PostEventRecordToCall?
    ) -> Bool {
        guard let setFrontProcessWithOptions,
              let postEventRecordTo
        else {
            return false
        }

        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr,
              setFrontProcessWithOptions(&psn, CGWindowID(windowID), SLPSMode.userGenerated.rawValue) == .success
        else {
            return false
        }

        return makeKeyWindow(psn: &psn, windowID: windowID, postEventRecordTo: postEventRecordTo)
    }

    static func makeKeyWindow(
        psn: inout ProcessSerialNumber,
        windowID: UInt32,
        postEventRecordTo: PostEventRecordToCall
    ) -> Bool {
        for eventType in [UInt8(0x01), UInt8(0x02)] {
            var bytes = makeKeyWindowEventBytes(windowID: windowID, eventType: eventType)
            let status = bytes.withUnsafeMutableBufferPointer { buffer in
                postEventRecordTo(&psn, buffer.baseAddress!)
            }
            if status != .success {
                return false
            }
        }

        return true
    }

    static func makeKeyWindowEventBytes(windowID: UInt32, eventType: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = eventType
        bytes[0x3a] = 0x10

        for index in 0x20 ..< 0x30 {
            bytes[index] = 0xff
        }

        var littleEndianWindowID = windowID.littleEndian
        withUnsafeBytes(of: &littleEndianWindowID) { rawBuffer in
            for (offset, byte) in rawBuffer.enumerated() {
                bytes[0x3c + offset] = byte
            }
        }

        return bytes
    }

    private static func waitForFrontmost(pid: pid_t, bundleID: String?) -> Bool {
        for _ in 0 ..< 5 {
            if frontmostMatches(pid: pid, bundleID: bundleID) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return frontmostMatches(pid: pid, bundleID: bundleID)
    }

    private static func frontmostMatches(pid: pid_t, bundleID: String?) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        if frontmost.processIdentifier == pid {
            return true
        }
        if let bundleID, frontmost.bundleIdentifier == bundleID {
            return true
        }
        return false
    }

    private static func waitForFocusedWindow(
        appElement: AXUIElement,
        targetWindowID: UInt32,
        pid: pid_t,
        bundleID: String?
    ) -> Bool {
        for _ in 0 ..< 5 {
            if frontmostMatches(pid: pid, bundleID: bundleID),
               focusedWindowMatches(appElement: appElement, targetWindowID: targetWindowID)
            {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return frontmostMatches(pid: pid, bundleID: bundleID)
            && focusedWindowMatches(appElement: appElement, targetWindowID: targetWindowID)
    }

    static func focusedWindowMatches(
        appElement: AXUIElement,
        targetWindowID: UInt32,
        attributeValueResolver: (AXUIElement, CFString) -> AXUIElement? = { element, attribute in
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success,
                  let resolved = ref
            else {
                return nil
            }
            return (resolved as! AXUIElement)
        },
        windowIDResolver: (AXUIElement) -> CGWindowID? = { element in
            var resolvedWindowID: CGWindowID = 0
            guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                return nil
            }
            return resolvedWindowID
        }
    ) -> Bool {
        for attribute in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            guard let window = attributeValueResolver(appElement, attribute),
                  let windowID = windowIDResolver(window)
            else {
                continue
            }

            if UInt32(windowID) == targetWindowID {
                return true
            }
        }

        return false
    }

    private static func pickTargetWindow(windows: [AXUIElement], preferredWindowTitle: String?) -> AXUIElement {
        guard let preferredWindowTitle,
              !preferredWindowTitle.isEmpty
        else {
            return windows[0]
        }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String
            else {
                continue
            }
            if title == preferredWindowTitle {
                return window
            }
        }
        return windows[0]
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

    static func matchingWindowElement(
        windowID: UInt32,
        appElement: AXUIElement,
        windowIDResolver: (AXUIElement) -> CGWindowID?
    ) -> AXUIElement? {
        var candidates: [AXUIElement] = []

        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement]
        {
            candidates.append(contentsOf: windows)
        }

        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, attribute as CFString, &ref) == .success,
               let ref
            {
                let element = ref as! AXUIElement
                guard !candidates.contains(where: { CFEqual($0, element) }) else {
                    continue
                }
                candidates.append(element)
            }
        }

        return candidates.first(where: { windowIDResolver($0) == windowID })
    }

    private typealias MainConnectionIDFn = @convention(c) () -> UInt32
    private typealias CopySpacesForWindowsFn = @convention(c) (UInt32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (UInt32) -> Unmanaged<CFArray>?

    private static let mainConnectionID: MainConnectionIDFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSMainConnectionID")
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: MainConnectionIDFn.self)
    }()

    private static let copySpacesForWindows: CopySpacesForWindowsFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSCopySpacesForWindows")
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopySpacesForWindows")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: CopySpacesForWindowsFn.self)
    }()

    private static let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSCopyManagedDisplaySpaces")
            ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCopyManagedDisplaySpaces")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: CopyManagedDisplaySpacesFn.self)
    }()

    private static func resolvedSpaceID(for windowID: UInt32, displayID: String?) -> Int? {
        guard let mainConnectionID,
              let copySpacesForWindows,
              let copyManagedDisplaySpaces
        else {
            return nil
        }

        let connection = mainConnectionID()
        let windows = [NSNumber(value: windowID)] as CFArray
        guard let spaces = copySpacesForWindows(connection, 0x7, windows)?.takeRetainedValue() as? [NSNumber],
              let managedSpaceID = spaces.first?.intValue,
              let managedDisplaySpaces = copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
        else {
            return nil
        }

        let normalSpaces: [[String: Any]]
        if let displayID {
            normalSpaces = managedDisplaySpaces
                .filter { ($0["Display Identifier"] as? String) == displayID }
                .flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 } }
        } else {
            normalSpaces = managedDisplaySpaces
                .flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 0 } }
        }

        for (index, space) in normalSpaces.enumerated() {
            let candidate = (space["ManagedSpaceID"] as? Int)
                ?? (space["ManagedSpaceID"] as? NSNumber)?.intValue
                ?? (space["id64"] as? Int)
                ?? (space["id64"] as? NSNumber)?.intValue
            if candidate == managedSpaceID {
                return index + 1
            }
        }

        return nil
    }
}

public enum WindowMatchEngine {
    public static func select(rule: WindowMatchRule, candidates: [WindowSnapshot]) -> WindowSnapshot? {
        var filtered = candidates.filter { $0.bundleID == rule.bundleID }

        if let matcher = rule.title {
            filtered = filtered.filter { window in
                if let equals = matcher.equals {
                    return window.title == equals
                }
                if let contains = matcher.contains {
                    return window.title.contains(contains)
                }
                if let regex = matcher.regex {
                    return window.title.range(of: regex, options: .regularExpression) != nil
                }
                return true
            }
        }

        if let role = rule.role {
            filtered = filtered.filter { $0.role == role }
        }

        if let subrole = rule.subrole {
            filtered = filtered.filter { $0.subrole == subrole }
        }

        if let profile = rule.profile {
            filtered = filtered.filter { $0.profileDirectory == profile }
        }

        if let excludeRegex = rule.excludeTitleRegex {
            filtered = filtered.filter { $0.title.range(of: excludeRegex, options: .regularExpression) == nil }
        }

        filtered.sort { lhs, rhs in
            let leftHasSpace = lhs.spaceID != nil
            let rightHasSpace = rhs.spaceID != nil
            if leftHasSpace != rightHasSpace {
                return leftHasSpace
            }

            let leftHasTitle = !lhs.title.isEmpty
            let rightHasTitle = !rhs.title.isEmpty
            if leftHasTitle != rightHasTitle {
                return leftHasTitle
            }

            let leftArea = lhs.frame.width * lhs.frame.height
            let rightArea = rhs.frame.width * rhs.frame.height
            if leftArea != rightArea {
                return leftArea > rightArea
            }

            if lhs.frontIndex != rhs.frontIndex { return lhs.frontIndex < rhs.frontIndex }
            return lhs.windowID < rhs.windowID
        }

        if let index = rule.index {
            let zeroBased = index - 1
            guard zeroBased >= 0, zeroBased < filtered.count else {
                return nil
            }
            return filtered[zeroBased]
        }

        return filtered.first
    }
}

public enum PolicyEngine {
    public static func matchesIgnoreRule(window: WindowSnapshot, rules: IgnoreRuleSet?) -> Bool {
        if rules?.apps?.contains(window.bundleID) == true {
            return true
        }

        guard let windowRules = rules?.windows else {
            return false
        }

        return windowRules.contains { matches(window: window, rule: $0) }
    }

    public static func matchesIgnoreRule(windowDefinition: WindowDefinition, rules: IgnoreRuleSet?) -> Bool {
        if rules?.apps?.contains(windowDefinition.match.bundleID) == true {
            return true
        }

        guard let windowRules = rules?.windows else {
            return false
        }

        let pseudo = WindowSnapshot(
            windowID: 0,
            bundleID: windowDefinition.match.bundleID,
            pid: 0,
            title: windowDefinition.match.title?.equals ?? windowDefinition.match.title?.contains ?? windowDefinition.match.title?.regex ?? "",
            role: windowDefinition.match.role ?? "AXWindow",
            subrole: windowDefinition.match.subrole,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: nil,
            displayID: nil,
            isFullscreen: false,
            frontIndex: 0
        )
        return windowRules.contains { matches(window: pseudo, rule: $0) }
    }

    public static func isShortcutDisabled(
        frontmostBundleID: String?,
        shortcutID: String,
        disabledInApps: [String: [String]],
        focusBySlotEnabledInApps: [String: Bool] = [:]
    ) -> Bool {
        guard let frontmostBundleID else {
            return false
        }

        if shortcutID.hasPrefix("focusBySlot:"),
           let enabled = focusBySlotEnabledInApps[frontmostBundleID]
        {
            return !enabled
        }

        guard let disabled = disabledInApps[frontmostBundleID] else {
            return false
        }

        if disabled.contains(shortcutID) {
            return true
        }

        if shortcutID.hasPrefix("focusBySlot:"), disabled.contains("focusBySlot") {
            return true
        }

        return false
    }

    private static func matches(window: WindowSnapshot, rule: IgnoreWindowRule) -> Bool {
        if let bundleID = rule.bundleID, window.bundleID != bundleID {
            return false
        }

        if let titleRegex = rule.titleRegex,
           window.title.range(of: titleRegex, options: .regularExpression) == nil
        {
            return false
        }

        if let role = rule.role, window.role != role {
            return false
        }

        if let subrole = rule.subrole, window.subrole != subrole {
            return false
        }

        if let minimized = rule.minimized, window.minimized != minimized {
            return false
        }

        if let hidden = rule.hidden, window.hidden != hidden {
            return false
        }

        return true
    }
}
