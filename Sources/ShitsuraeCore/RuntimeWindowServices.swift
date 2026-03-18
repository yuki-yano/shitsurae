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

public struct SpaceInfo: Codable, Equatable {
    public let spaceID: Int
    public let displayID: String?
    public let isVisible: Bool
    public let isNativeFullscreen: Bool

    public init(
        spaceID: Int,
        displayID: String?,
        isVisible: Bool,
        isNativeFullscreen: Bool
    ) {
        self.spaceID = spaceID
        self.displayID = displayID
        self.isVisible = isVisible
        self.isNativeFullscreen = isNativeFullscreen
    }
}

public enum WindowInteractionResult: Equatable {
    case success
    case permissionDenied
    case failed

    public var isSuccess: Bool {
        self == .success
    }
}

public enum WindowQueryService {
    private struct ProfileDirectoryCacheKey: Hashable {
        let bundleID: String
        let pid: Int
    }

    private struct CachedProfileDirectoryResolution {
        let profileDirectory: String?
    }

    private final class ProfileDirectoryCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [ProfileDirectoryCacheKey: CachedProfileDirectoryResolution] = [:]

        func value(bundleID: String, pid: Int) -> CachedProfileDirectoryResolution? {
            lock.lock()
            defer { lock.unlock() }
            return entries[ProfileDirectoryCacheKey(bundleID: bundleID, pid: pid)]
        }

        func set(_ profileDirectory: String?, bundleID: String, pid: Int) {
            lock.lock()
            entries[ProfileDirectoryCacheKey(bundleID: bundleID, pid: pid)] = CachedProfileDirectoryResolution(
                profileDirectory: profileDirectory
            )
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            entries.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }

    private final class ProfileDirectoryPrewarmState: @unchecked Sendable {
        private let lock = NSLock()
        private var isRunning = false

        func begin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isRunning else {
                return false
            }
            isRunning = true
            return true
        }

        func end() {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        func reset() {
            lock.lock()
            isRunning = false
            lock.unlock()
        }
    }

    private static let profileDirectoryCache = ProfileDirectoryCache()
    private static let profileDirectoryPrewarmState = ProfileDirectoryPrewarmState()

    public static func listWindows(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionOnScreenOnly, .excludeDesktopElements])
    }

    public static func listWindowsOnAllSpaces(displays: [DisplayInfo] = SystemProbe.displays()) -> [WindowSnapshot] {
        listWindows(displays: displays, options: [.optionAll, .excludeDesktopElements])
    }

    public static func listSpaces(displays: [DisplayInfo] = SystemProbe.displays()) -> [SpaceInfo] {
        listSpaces(
            displays: displays,
            managedDisplaySpaces: managedDisplaySpaces()
        )
    }

    public static func prewarmBrowserProfileDirectoryCache() {
        guard profileDirectoryPrewarmState.begin() else {
            return
        }
        defer { profileDirectoryPrewarmState.end() }

        guard let raw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return
        }

        prewarmBrowserProfileDirectoryCache(
            rawWindowInfo: raw,
            appResolver: { pid in
                NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
            },
            profileResolver: SystemProbe.browserProfileDirectory(bundleID:pid:)
        )
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
            } else if let cached = cachedProfileDirectory(bundleID: app.bundleID, pid: pid) {
                if let profileDirectory = cached.profileDirectory {
                    resolvedProfiles[pid] = profileDirectory
                } else {
                    unresolvedPIDs.insert(pid)
                }
                profileDirectory = cached.profileDirectory
            } else {
                let resolved = profileResolver(app.bundleID, pid)
                cacheProfileDirectory(resolved, bundleID: app.bundleID, pid: pid)
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

    static func prewarmBrowserProfileDirectoryCache(
        rawWindowInfo: [[String: Any]],
        appResolver: (Int) -> String?,
        profileResolver: (String, Int) -> String? = { _, _ in nil }
    ) {
        var resolvedPIDs = Set<Int>()

        for info in rawWindowInfo {
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 {
                continue
            }

            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }

            let pid = pidNumber.intValue
            guard resolvedPIDs.insert(pid).inserted,
                  let bundleID = appResolver(pid),
                  ChromiumProfileSupport.supports(bundleID: bundleID),
                  cachedProfileDirectory(bundleID: bundleID, pid: pid) == nil
            else {
                continue
            }

            let profileDirectory = profileResolver(bundleID, pid)
            cacheProfileDirectory(profileDirectory, bundleID: bundleID, pid: pid)
        }
    }

    static func listSpaces(
        displays: [DisplayInfo],
        managedDisplaySpaces: [[String: Any]]?
    ) -> [SpaceInfo] {
        guard let managedDisplaySpaces else {
            return []
        }

        let displayOrder = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, $0.offset) })
        var result: [(displayOrder: Int, spaceOrder: Int, info: SpaceInfo)] = []

        for displayEntry in managedDisplaySpaces {
            let displayID = displayEntry["Display Identifier"] as? String
            let currentManagedSpaceID = managedSpaceID(from: displayEntry["Current Space"] as? [String: Any])
            let spaces = (displayEntry["Spaces"] as? [[String: Any]] ?? [])
                .filter { spaceType(from: $0) == 0 }

            for (index, space) in spaces.enumerated() {
                guard let managedSpaceID = managedSpaceID(from: space) else {
                    continue
                }

                result.append(
                    (
                        displayOrder[displayID ?? ""] ?? Int.max,
                        index,
                        SpaceInfo(
                            spaceID: index + 1,
                            displayID: displayID,
                            isVisible: managedSpaceID == currentManagedSpaceID,
                            isNativeFullscreen: false
                        )
                    )
                )
            }
        }

        return result
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.spaceOrder < $1.spaceOrder
            }
            .map(\.info)
    }

    static func resetProfileDirectoryCacheForTesting() {
        profileDirectoryCache.removeAll()
        profileDirectoryPrewarmState.reset()
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

    public static func currentSpaceID(displays: [DisplayInfo] = SystemProbe.displays()) -> Int? {
        currentSpaceID(
            focusedWindow: focusedWindow(displays: displays),
            spaces: listSpaces(displays: displays)
        )
    }

    public static func currentSpaceID(focusedWindow: WindowSnapshot?, spaces: [SpaceInfo]) -> Int? {
        if let spaceID = focusedWindow?.spaceID {
            return spaceID
        }

        return spaces.first(where: \.isVisible)?.spaceID
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

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var resolvedWindowElement: AXUIElement?
        let result = withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            setWindowFrameResult(
                expectedFrame: frame,
                isTrusted: AXIsProcessTrusted(),
                runningApplication: { true },
                prepareForInteraction: {
                    prepareForTargetedWindowInteraction(running)
                },
                resolveWindowElement: {
                    resolvedWindowElement = matchingWindowElement(
                        windowID: windowID,
                        appElement: appElement,
                        windowIDResolver: { element in
                            var resolvedWindowID: CGWindowID = 0
                            guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                                return nil
                            }
                            return resolvedWindowID
                        }
                    )
                    return resolvedWindowElement != nil
                },
                applySize: {
                    guard let resolvedWindowElement else {
                        return .failure
                    }
                    var size = CGSize(width: frame.width, height: frame.height)
                    guard let sizeValue = AXValueCreate(.cgSize, &size) else {
                        return .failure
                    }
                    return AXUIElementSetAttributeValue(
                        resolvedWindowElement,
                        kAXSizeAttribute as CFString,
                        sizeValue
                    )
                },
                applyPosition: {
                    guard let resolvedWindowElement else {
                        return .failure
                    }
                    var point = CGPoint(x: frame.x, y: frame.y)
                    guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                        return .failure
                    }
                    return AXUIElementSetAttributeValue(
                        resolvedWindowElement,
                        kAXPositionAttribute as CFString,
                        pointValue
                    )
                },
                readFrame: {
                    guard let resolvedWindowElement,
                          let currentFrame = WindowQueryService.frame(of: resolvedWindowElement)
                    else {
                        return nil
                    }
                    return ResolvedFrame(
                        x: currentFrame.origin.x,
                        y: currentFrame.origin.y,
                        width: currentFrame.width,
                        height: currentFrame.height
                    )
                }
            )
        }
        return result.isSuccess
    }

    public static func setWindowPosition(windowID: UInt32, bundleID: String, position: CGPoint) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        var resolvedWindowElement: AXUIElement?
        let result = withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            setWindowPositionResult(
                expectedPosition: position,
                isTrusted: AXIsProcessTrusted(),
                runningApplication: { true },
                prepareForInteraction: {
                    prepareForTargetedWindowInteraction(running)
                },
                resolveWindowElement: {
                    resolvedWindowElement = matchingWindowElement(
                        windowID: windowID,
                        appElement: appElement,
                        windowIDResolver: { element in
                            var resolvedWindowID: CGWindowID = 0
                            guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                                return nil
                            }
                            return resolvedWindowID
                        }
                    )
                    return resolvedWindowElement != nil
                },
                applyPosition: {
                    guard let resolvedWindowElement else {
                        return .failure
                    }
                    var point = position
                    guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                        return .failure
                    }
                    return AXUIElementSetAttributeValue(
                        resolvedWindowElement,
                        kAXPositionAttribute as CFString,
                        pointValue
                    )
                },
                readPosition: {
                    guard let resolvedWindowElement,
                          let currentFrame = WindowQueryService.frame(of: resolvedWindowElement)
                    else {
                        return nil
                    }
                    return currentFrame.origin
                }
            )
        }
        return result.isSuccess
    }

    static func setWindowFrameResult(
        expectedFrame: ResolvedFrame? = nil,
        isTrusted: Bool,
        runningApplication: () -> Bool,
        prepareForInteraction: () -> Void,
        resolveWindowElement: () -> Bool,
        applySize: () -> AXError,
        applyPosition: () -> AXError,
        readFrame: (() -> ResolvedFrame?)? = nil
    ) -> WindowInteractionResult {
        guard isTrusted else {
            return .permissionDenied
        }

        guard runningApplication() else {
            return .failed
        }

        prepareForInteraction()

        guard resolveWindowElement() else {
            return .failed
        }

        let sizeBeforePosition = windowInteractionResult(for: applySize())
        guard sizeBeforePosition.isSuccess else {
            return sizeBeforePosition
        }

        let positionResult = windowInteractionResult(for: applyPosition())
        guard positionResult.isSuccess else {
            return positionResult
        }

        let finalSizeResult = windowInteractionResult(for: applySize())
        guard finalSizeResult.isSuccess else {
            return finalSizeResult
        }

        if let expectedFrame,
           let actualFrame = readFrame?(),
           !roughlySame(frame: actualFrame, expectedFrame: expectedFrame)
        {
            return .failed
        }

        return .success
    }

    static func setWindowPositionResult(
        expectedPosition: CGPoint? = nil,
        isTrusted: Bool,
        runningApplication: () -> Bool,
        prepareForInteraction: () -> Void,
        resolveWindowElement: () -> Bool,
        applyPosition: () -> AXError,
        readPosition: (() -> CGPoint?)? = nil
    ) -> WindowInteractionResult {
        guard isTrusted else {
            return .permissionDenied
        }

        guard runningApplication() else {
            return .failed
        }

        prepareForInteraction()

        guard resolveWindowElement() else {
            return .failed
        }

        let positionResult = windowInteractionResult(for: applyPosition())
        guard positionResult.isSuccess else {
            return positionResult
        }

        if let expectedPosition,
           let actualPosition = readPosition?(),
           !roughlySame(position: actualPosition, expectedPosition: expectedPosition)
        {
            return .failed
        }

        return .success
    }

    public static func setWindowMinimizedResult(windowID: UInt32, bundleID: String, minimized: Bool) -> WindowInteractionResult {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let appElement = running.map { AXUIElementCreateApplication($0.processIdentifier) }
        var resolvedWindowElement: AXUIElement?
        return setWindowMinimizedResult(
            isTrusted: AXIsProcessTrusted(),
            runningApplication: { running != nil },
            prepareForInteraction: {
                if let running {
                    prepareForTargetedWindowInteraction(running)
                }
            },
            resolveWindowElement: {
                guard let appElement else {
                    return false
                }

                resolvedWindowElement = matchingWindowElement(
                    windowID: windowID,
                    appElement: appElement,
                    windowIDResolver: { element in
                        var resolvedWindowID: CGWindowID = 0
                        guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                            return nil
                        }
                        return resolvedWindowID
                    }
                )
                return resolvedWindowElement != nil
            },
            applyMinimizedAttribute: {
                guard let resolvedWindowElement else {
                    return .failure
                }
                return AXUIElementSetAttributeValue(
                    resolvedWindowElement,
                    kAXMinimizedAttribute as CFString,
                    minimized ? kCFBooleanTrue : kCFBooleanFalse
                )
            }
        )
    }

    @discardableResult
    public static func setWindowMinimized(windowID: UInt32, bundleID: String, minimized: Bool) -> Bool {
        setWindowMinimizedResult(windowID: windowID, bundleID: bundleID, minimized: minimized).isSuccess
    }

    public static func focusWindowResult(windowID: UInt32, bundleID: String) -> WindowInteractionResult {
        guard AXIsProcessTrusted() else {
            return .permissionDenied
        }

        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .failed
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
            return .failed
        }

        return focusWindowElementResult(
            appElement: appElement,
            windowElement: windowElement,
            pid: running.processIdentifier
        )
    }

    @discardableResult
    public static func focusWindow(windowID: UInt32, bundleID: String) -> Bool {
        focusWindowResult(windowID: windowID, bundleID: bundleID).isSuccess
    }

    @discardableResult
    public static func activate(bundleID: String, preferredWindowTitle: String? = nil) -> Bool {
        guard let running = runningApplication(bundleID: bundleID) else {
            return false
        }

        return activateRunningApplication(running, preferredWindowTitle: preferredWindowTitle)
    }

    private static func runningApplication(bundleID: String) -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }

        guard SystemProbe.launchApplication(bundleID: bundleID) else {
            return nil
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func activateRunningApplication(
        _ running: NSRunningApplication,
        preferredWindowTitle: String?
    ) -> Bool {
        _ = running.unhide()

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        if let preferredWindowTitle,
           let windowElement = preferredWindowElement(
               appElement: appElement,
               preferredWindowTitle: preferredWindowTitle
           ),
           focusWindowElement(
               appElement: appElement,
               windowElement: windowElement,
               pid: running.processIdentifier
           )
        {
            return true
        }

        return running.activate(options: bundleActivationOptions())
    }

    static func bundleActivationOptions() -> NSApplication.ActivationOptions {
        []
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
        pid: pid_t
    ) -> Bool {
        focusWindowElementResult(
            appElement: appElement,
            windowElement: windowElement,
            pid: pid
        ).isSuccess
    }

    private static func focusWindowElementResult(
        appElement: AXUIElement,
        windowElement: AXUIElement,
        pid: pid_t
    ) -> WindowInteractionResult {
        var resolvedWindowID: CGWindowID = 0
        guard AXUIElementGetWindowID(windowElement, &resolvedWindowID) == .success else {
            return .failed
        }

        return applyTargetedWindowFocusResult(
            pid: pid,
            windowID: UInt32(resolvedWindowID),
            promoteWindow: promoteWindowToFront,
            applyAccessibilityFocus: {
                let focusedResult = windowInteractionResult(
                    for: AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
                )
                let mainResult = windowInteractionResult(
                    for: AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, windowElement)
                )
                let windowFocusedResult = windowInteractionResult(
                    for: AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                )
                return mergeWindowInteractionResults([focusedResult, mainResult, windowFocusedResult])
            },
            raiseWindow: {
                windowInteractionResult(for: AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString))
            }
        )
    }

    static func applyTargetedWindowFocus(
        pid: pid_t,
        windowID: UInt32,
        promoteWindow: (pid_t, UInt32) -> Bool,
        applyAccessibilityFocus: () -> Void,
        raiseWindow: () -> Void
    ) -> Bool {
        guard promoteWindow(pid, windowID) else {
            return false
        }

        applyAccessibilityFocus()
        raiseWindow()
        return true
    }

    static func applyTargetedWindowFocusResult(
        pid: pid_t,
        windowID: UInt32,
        promoteWindow: (pid_t, UInt32) -> Bool,
        applyAccessibilityFocus: () -> WindowInteractionResult,
        raiseWindow: () -> WindowInteractionResult
    ) -> WindowInteractionResult {
        guard promoteWindow(pid, windowID) else {
            return .failed
        }

        let focusResult = applyAccessibilityFocus()
        guard focusResult.isSuccess else {
            return focusResult
        }

        return raiseWindow()
    }

    static func setWindowMinimizedResult(
        isTrusted: Bool,
        runningApplication: () -> Bool,
        prepareForInteraction: () -> Void,
        resolveWindowElement: () -> Bool,
        applyMinimizedAttribute: () -> AXError
    ) -> WindowInteractionResult {
        guard isTrusted else {
            return .permissionDenied
        }

        guard runningApplication() else {
            return .failed
        }

        prepareForInteraction()

        guard resolveWindowElement() else {
            return .failed
        }

        return windowInteractionResult(for: applyMinimizedAttribute())
    }

    private static func windowInteractionResult(for error: AXError) -> WindowInteractionResult {
        switch error {
        case .success:
            return .success
        case .apiDisabled:
            return .permissionDenied
        default:
            return .failed
        }
    }

    private static func mergeWindowInteractionResults(_ results: [WindowInteractionResult]) -> WindowInteractionResult {
        if results.contains(.permissionDenied) {
            return .permissionDenied
        }
        if results.allSatisfy(\.isSuccess) {
            return .success
        }
        return .failed
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

    private static func preferredWindowElement(
        appElement: AXUIElement,
        preferredWindowTitle: String
    ) -> AXUIElement? {
        let normalizedTitle = preferredWindowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            return nil
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for window in windows {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String
            else {
                continue
            }

            if title == normalizedTitle {
                return window
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
        // Use a generous tolerance for position (macOS adjusts y for the
        // menu bar — typically 25 px — and may snap x/width to integer
        // boundaries).  Size gets a tighter tolerance because rounding is
        // the only expected source of drift.
        let positionTolerance = 30.0
        let sizeTolerance = 2.0
        return abs(frame.x - expectedFrame.x) <= positionTolerance
            && abs(frame.y - expectedFrame.y) <= positionTolerance
            && abs(frame.width - expectedFrame.width) <= sizeTolerance
            && abs(frame.height - expectedFrame.height) <= sizeTolerance
    }

    static func roughlySame(position: CGPoint, expectedPosition: CGPoint) -> Bool {
        let tolerance: CGFloat = 2.0
        return abs(position.x - expectedPosition.x) <= tolerance
            && abs(position.y - expectedPosition.y) <= tolerance
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef,
              let sizeRef
        else {
            return nil
        }

        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func withTemporarilyDisabledEnhancedUserInterface(
        appElement: AXUIElement,
        body: () -> WindowInteractionResult
    ) -> WindowInteractionResult {
        let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
        var currentValue: CFTypeRef?
        let readStatus = AXUIElementCopyAttributeValue(
            appElement,
            enhancedUserInterfaceAttribute,
            &currentValue
        )
        let wasEnabled = readStatus == .success && (currentValue as? Bool) == true
        if wasEnabled {
            _ = AXUIElementSetAttributeValue(
                appElement,
                enhancedUserInterfaceAttribute,
                kCFBooleanFalse
            )
        }
        defer {
            if wasEnabled {
                _ = AXUIElementSetAttributeValue(
                    appElement,
                    enhancedUserInterfaceAttribute,
                    kCFBooleanTrue
                )
            }
        }
        return body()
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

    private static func cachedProfileDirectory(bundleID: String, pid: Int) -> CachedProfileDirectoryResolution? {
        profileDirectoryCache.value(bundleID: bundleID, pid: pid)
    }

    private static func cacheProfileDirectory(_ profileDirectory: String?, bundleID: String, pid: Int) {
        profileDirectoryCache.set(profileDirectory, bundleID: bundleID, pid: pid)
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

    private static func managedDisplaySpaces() -> [[String: Any]]? {
        guard let mainConnectionID,
              let copyManagedDisplaySpaces
        else {
            return nil
        }

        let connection = mainConnectionID()
        return copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]]
    }

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

    private static func managedSpaceID(from space: [String: Any]?) -> Int? {
        guard let space else {
            return nil
        }

        return (space["ManagedSpaceID"] as? Int)
            ?? (space["ManagedSpaceID"] as? NSNumber)?.intValue
            ?? (space["id64"] as? Int)
            ?? (space["id64"] as? NSNumber)?.intValue
    }

    private static func spaceType(from space: [String: Any]) -> Int {
        (space["type"] as? Int) ?? (space["type"] as? NSNumber)?.intValue ?? 0
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

        if shortcutID.hasPrefix("moveCurrentWindowToSpace:"), disabled.contains("moveCurrentWindowToSpace") {
            return true
        }

        if shortcutID.hasPrefix("switchVirtualSpace:"), disabled.contains("switchVirtualSpace") {
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
