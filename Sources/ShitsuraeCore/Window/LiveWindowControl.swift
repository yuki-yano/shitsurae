import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AX-backed WindowControl implementation. Ports the production-proven v1
/// interaction patterns:
/// - frame setting is size → position → size (some apps re-adjust position
///   after a resize; the final size write fixes the drift)
/// - AXEnhancedUserInterface is temporarily disabled around frame writes
///   (Electron apps fail frame setting otherwise)
/// - focusing a specific window goes through SkyLight
///   _SLPSSetFrontProcessWithOptions + synthesized key-window events; plain
///   AX focus cannot raise one window above its siblings
public struct LiveWindowControl: WindowControl {
    public init() {}

    public func listWindows() -> [WindowSnapshot] {
        WindowEnumerator.listWindows()
    }

    public func listAllWindows() -> [WindowSnapshot] {
        WindowEnumerator.listAllWindows()
    }

    public func onScreenWindowIDs() -> Set<UInt32> {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return Set(raw.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    public func focusedWindow() -> WindowSnapshot? {
        WindowEnumerator.focusedWindow()
    }

    public func displays() -> [DisplayInfo] {
        SystemProbe.displays()
    }

    // MARK: - Frame

    @discardableResult
    public func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        let result = Self.withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            guard AXIsProcessTrusted() else {
                return WindowInteractionResult.permissionDenied
            }

            Self.prepareForTargetedWindowInteraction(running)

            guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
                return .failed
            }

            func applySize() -> AXError {
                var size = CGSize(width: frame.width, height: frame.height)
                guard let sizeValue = AXValueCreate(.cgSize, &size) else {
                    return .failure
                }
                return AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
            }

            func applyPosition() -> AXError {
                var point = CGPoint(x: frame.x, y: frame.y)
                guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                    return .failure
                }
                return AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, pointValue)
            }

            let sizeBefore = Self.interactionResult(for: applySize())
            guard sizeBefore.isSuccess else { return sizeBefore }

            let position = Self.interactionResult(for: applyPosition())
            guard position.isSuccess else { return position }

            let sizeAfter = Self.interactionResult(for: applySize())
            guard sizeAfter.isSuccess else { return sizeAfter }

            if let actual = Self.frame(of: windowElement) {
                let actualFrame = ResolvedFrame(
                    x: actual.origin.x,
                    y: actual.origin.y,
                    width: actual.width,
                    height: actual.height
                )
                if !WindowEnumerator.roughlySame(frame: actualFrame, expectedFrame: frame) {
                    return .failed
                }
            }

            return .success
        }
        return result.isSuccess
    }

    @discardableResult
    public func setWindowPosition(windowID: UInt32, bundleID: String, position: CGPoint) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        let result = Self.withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            guard AXIsProcessTrusted() else {
                return WindowInteractionResult.permissionDenied
            }

            Self.prepareForTargetedWindowInteraction(running)

            guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
                return .failed
            }

            var point = position
            guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                return .failed
            }
            let applied = Self.interactionResult(
                for: AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, pointValue)
            )
            guard applied.isSuccess else { return applied }

            if let actual = Self.frame(of: windowElement),
               !WindowEnumerator.roughlySame(position: actual.origin, expectedPosition: position)
            {
                return .failed
            }

            return .success
        }
        return result.isSuccess
    }

    // MARK: - Minimize

    public func setWindowMinimized(windowID: UInt32, bundleID: String, minimized: Bool) -> WindowInteractionResult {
        guard AXIsProcessTrusted() else {
            return .permissionDenied
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .failed
        }

        Self.prepareForTargetedWindowInteraction(running)

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
            return .failed
        }

        return Self.interactionResult(
            for: AXUIElementSetAttributeValue(
                windowElement,
                kAXMinimizedAttribute as CFString,
                minimized ? kCFBooleanTrue : kCFBooleanFalse
            )
        )
    }

    // MARK: - Focus / activation

    public func focusWindow(windowID: UInt32, bundleID: String) -> WindowInteractionResult {
        guard AXIsProcessTrusted() else {
            return .permissionDenied
        }
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return .failed
        }

        Self.prepareForTargetedWindowInteraction(running)

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
            return .failed
        }

        guard Self.promoteWindowToFront(pid: running.processIdentifier, windowID: windowID) else {
            return .failed
        }

        let focusedResult = Self.interactionResult(
            for: AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, windowElement)
        )
        let mainResult = Self.interactionResult(
            for: AXUIElementSetAttributeValue(appElement, kAXMainWindowAttribute as CFString, windowElement)
        )
        let windowFocusedResult = Self.interactionResult(
            for: AXUIElementSetAttributeValue(windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        )
        let focusResult = Self.merge([focusedResult, mainResult, windowFocusedResult])
        guard focusResult.isSuccess else {
            return focusResult
        }

        return Self.interactionResult(
            for: AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        )
    }

    @discardableResult
    public func activateBundle(bundleID: String) -> Bool {
        guard let running = Self.runningApplication(bundleID: bundleID) else {
            return false
        }

        _ = running.unhide()
        return running.activate(options: [])
    }

    @discardableResult
    public func launchApplication(request: ApplicationLaunchRequest) -> Bool {
        SystemProbe.launchApplication(request: request)
    }

    // MARK: - Internals

    private static func runningApplication(bundleID: String) -> NSRunningApplication? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }

        guard SystemProbe.launchApplication(bundleID: bundleID) else {
            return nil
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func prepareForTargetedWindowInteraction(_ running: NSRunningApplication) {
        // Avoid app-wide activation here — the targeted focus path decides
        // the z-order. Unhiding is required for AX writes to land.
        if running.isHidden {
            _ = running.unhide()
        }
    }

    static func matchingWindowElement(windowID: UInt32, appElement: AXUIElement) -> AXUIElement? {
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

        return candidates.first { element in
            var resolvedWindowID: CGWindowID = 0
            guard AXUIElementGetWindowID(element, &resolvedWindowID) == .success else {
                return false
            }
            return resolvedWindowID == windowID
        }
    }

    static func withTemporarilyDisabledEnhancedUserInterface(
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
            _ = AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute, kCFBooleanFalse)
        }
        defer {
            if wasEnabled {
                _ = AXUIElementSetAttributeValue(appElement, enhancedUserInterfaceAttribute, kCFBooleanTrue)
            }
        }
        return body()
    }

    static func frame(of element: AXUIElement) -> CGRect? {
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

    static func promoteWindowToFront(pid: pid_t, windowID: UInt32) -> Bool {
        promoteWindowToFront(
            pid: pid,
            windowID: windowID,
            getProcessForPID: { LegacyGetProcessForPID($0, $1) },
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
        var bytes = [UInt8](repeating: 0, count: 0xF8)
        bytes[0x04] = 0xF8
        bytes[0x08] = eventType
        bytes[0x3A] = 0x10

        for index in 0x20 ..< 0x30 {
            bytes[index] = 0xFF
        }

        var littleEndianWindowID = windowID.littleEndian
        withUnsafeBytes(of: &littleEndianWindowID) { rawBuffer in
            for (offset, byte) in rawBuffer.enumerated() {
                bytes[0x3C + offset] = byte
            }
        }

        return bytes
    }

    private static func interactionResult(for error: AXError) -> WindowInteractionResult {
        switch error {
        case .success:
            return .success
        case .apiDisabled:
            return .permissionDenied
        default:
            return .failed
        }
    }

    private static func merge(_ results: [WindowInteractionResult]) -> WindowInteractionResult {
        if results.contains(.permissionDenied) {
            return .permissionDenied
        }
        if results.allSatisfy(\.isSuccess) {
            return .success
        }
        return .failed
    }
}
