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

    public func windowInventory() -> WindowInventory {
        WindowEnumerator.allWindowInventory()
    }

    public func focusedWindowObservation() -> WindowObservation {
        WindowEnumerator.focusedWindowObservation()
    }

    public func onScreenWindowIdentities() -> Set<WindowIdentity> {
        WindowEnumerator.onScreenWindowIdentities()
    }

    public func focusedWindow() -> WindowSnapshot? {
        WindowEnumerator.focusedWindow()
    }

    public func displays() -> [DisplayInfo] {
        SystemProbe.displays()
    }

    public func accessibilityGranted() -> Bool {
        SystemProbe.accessibilityGranted()
    }

    // MARK: - Frame

    @discardableResult
    public func setWindowFrame(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        frame: ResolvedFrame
    ) -> WindowGeometryMutationResult {
        guard let running = Self.runningApplication(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        ) else {
            return .notAttempted
        }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        return Self.withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            guard AXIsProcessTrusted() else {
                return .notAttempted
            }

            Self.prepareForTargetedWindowInteraction(running)

            if Self.geometryBlockedAtMutationTime(windowID: windowID, appElement: appElement) {
                return .notAttempted
            }

            guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
                return .notAttempted
            }

            var sizeSettable = DarwinBoolean(false)
            var positionSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                windowElement,
                kAXSizeAttribute as CFString,
                &sizeSettable
            ) == .success,
                sizeSettable.boolValue,
                AXUIElementIsAttributeSettable(
                    windowElement,
                    kAXPositionAttribute as CFString,
                    &positionSettable
                ) == .success,
                positionSettable.boolValue,
                let initial = Self.frame(of: windowElement)
            else {
                return .notAttempted
            }

            func applySize(_ target: CGSize) -> Bool {
                var size = target
                guard let sizeValue = AXValueCreate(.cgSize, &size) else {
                    return false
                }
                return AXUIElementSetAttributeValue(
                    windowElement,
                    kAXSizeAttribute as CFString,
                    sizeValue
                ) == .success
            }

            func applyPosition(_ target: CGPoint) -> Bool {
                var point = target
                guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                    return false
                }
                return AXUIElementSetAttributeValue(
                    windowElement,
                    kAXPositionAttribute as CFString,
                    pointValue
                ) == .success
            }

            let outcome = GeometryTransaction.applyFrame(
                initial: initial,
                requested: frame,
                setSize: applySize,
                setPosition: applyPosition,
                readFrame: { Self.frame(of: windowElement) }
            )
            return Self.mutationResult(for: outcome)
        }
    }

    @discardableResult
    public func setWindowPosition(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        position: CGPoint
    ) -> WindowGeometryMutationResult {
        guard let running = Self.runningApplication(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        ) else {
            return .notAttempted
        }

        let appElement = AXUIElementCreateApplication(running.processIdentifier)
        return Self.withTemporarilyDisabledEnhancedUserInterface(appElement: appElement) {
            guard AXIsProcessTrusted() else {
                return .notAttempted
            }

            Self.prepareForTargetedWindowInteraction(running)

            if Self.geometryBlockedAtMutationTime(windowID: windowID, appElement: appElement) {
                return .notAttempted
            }

            guard let windowElement = Self.matchingWindowElement(windowID: windowID, appElement: appElement) else {
                return .notAttempted
            }

            var positionSettable = DarwinBoolean(false)
            var sizeSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                windowElement,
                kAXPositionAttribute as CFString,
                &positionSettable
            ) == .success,
                positionSettable.boolValue,
                AXUIElementIsAttributeSettable(
                    windowElement,
                    kAXSizeAttribute as CFString,
                    &sizeSettable
                ) == .success,
                sizeSettable.boolValue,
                let initial = Self.frame(of: windowElement)
            else {
                return .notAttempted
            }

            func applyPosition(_ target: CGPoint) -> Bool {
                var point = target
                guard let pointValue = AXValueCreate(.cgPoint, &point) else {
                    return false
                }
                return AXUIElementSetAttributeValue(
                    windowElement,
                    kAXPositionAttribute as CFString,
                    pointValue
                ) == .success
            }

            func applySize(_ target: CGSize) -> Bool {
                var size = target
                guard let sizeValue = AXValueCreate(.cgSize, &size) else {
                    return false
                }
                return AXUIElementSetAttributeValue(
                    windowElement,
                    kAXSizeAttribute as CFString,
                    sizeValue
                ) == .success
            }

            let outcome = GeometryTransaction.applyPosition(
                initial: initial,
                requested: position,
                setPosition: applyPosition,
                setSize: applySize,
                readFrame: { Self.frame(of: windowElement) }
            )
            return Self.mutationResult(for: outcome)
        }
    }

    // MARK: - Minimize

    public func setWindowMinimized(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String,
        minimized: Bool
    ) -> WindowInteractionResult {
        guard AXIsProcessTrusted() else {
            return .permissionDenied
        }
        guard let running = Self.runningApplication(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        ) else {
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

    public func focusWindow(
        windowID: UInt32,
        pid: Int,
        processStartTime: UInt64,
        bundleID: String
    ) -> WindowInteractionResult {
        guard AXIsProcessTrusted() else {
            return .permissionDenied
        }
        guard let running = Self.runningApplication(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        ) else {
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
    public func activateApplication(pid: Int, processStartTime: UInt64, bundleID: String) -> Bool {
        guard let running = Self.runningApplication(
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID
        ) else {
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

    private static func runningApplication(
        pid: Int,
        processStartTime: UInt64,
        bundleID: String
    ) -> NSRunningApplication? {
        guard let running = NSRunningApplication(processIdentifier: pid_t(pid)),
              running.bundleIdentifier == bundleID,
              ProcessGenerationResolver.startTime(pid: pid) == processStartTime,
              !running.isTerminated
        else {
            return nil
        }
        return running
    }

    private static func prepareForTargetedWindowInteraction(_ running: NSRunningApplication) {
        // Avoid app-wide activation here — the targeted focus path decides
        // the z-order. Unhiding is required for AX writes to land.
        if running.isHidden {
            _ = running.unhide()
        }
    }

    /// Final fail-closed check immediately before a geometry transaction.
    /// Enumeration and mutation are necessarily separate AX operations; a
    /// Chrome confirmation sheet can appear between them.
    static func geometryBlockedAtMutationTime(windowID: UInt32, appElement: AXUIElement) -> Bool {
        func resolvedWindowID(attribute: CFString) -> UInt32? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, attribute, &ref) == .success,
                  let ref
            else {
                return nil
            }
            var resolved: CGWindowID = 0
            guard AXUIElementGetWindowID(ref as! AXUIElement, &resolved) == .success else {
                return nil
            }
            return UInt32(resolved)
        }

        let focusedWindowID = resolvedWindowID(attribute: kAXFocusedWindowAttribute as CFString)
        let mainWindowID = resolvedWindowID(attribute: kAXMainWindowAttribute as CFString)
        return geometryBlockedAtMutationTime(
            windowID: windowID,
            focusedWindowID: focusedWindowID,
            mainWindowID: mainWindowID
        )
    }

    static func geometryBlockedAtMutationTime(
        windowID: UInt32,
        focusedWindowID: UInt32?,
        mainWindowID: UInt32?
    ) -> Bool {
        guard mainWindowID == windowID else { return false }
        return focusedWindowID != mainWindowID
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

    static func withTemporarilyDisabledEnhancedUserInterface<Result>(
        appElement: AXUIElement,
        body: () -> Result
    ) -> Result {
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

    private static func mutationResult(
        for outcome: GeometryTransactionOutcome
    ) -> WindowGeometryMutationResult {
        switch outcome {
        case .applied:
            .applied
        case .rejectedAndRestored, .failedToRestore:
            .rejected
        }
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

enum GeometryTransactionOutcome: Equatable, Sendable {
    case applied
    case rejectedAndRestored
    case failedToRestore
}

/// Compensating geometry transaction shared by the live AX implementation
/// and deterministic tests. AX setters can return an error after changing the
/// physical window, so every rejected or mismatched operation restores and
/// verifies the starting frame before reporting failure.
enum GeometryTransaction {
    static func applyFrame(
        initial: CGRect,
        requested: ResolvedFrame,
        setSize: (CGSize) -> Bool,
        setPosition: (CGPoint) -> Bool,
        readFrame: () -> CGRect?
    ) -> GeometryTransactionOutcome {
        let requestedRect = CGRect(
            x: requested.x,
            y: requested.y,
            width: requested.width,
            height: requested.height
        )
        if roughlySame(initial, requestedRect) {
            return .applied
        }

        let accepted = setSize(requestedRect.size)
            && setPosition(requestedRect.origin)
            && setSize(requestedRect.size)
        if accepted, let actual = readFrame(), roughlySame(actual, requestedRect) {
            return .applied
        }

        _ = setSize(initial.size)
        _ = setPosition(initial.origin)
        _ = setSize(initial.size)
        guard let restored = readFrame(), roughlySame(restored, initial) else {
            return .failedToRestore
        }
        return .rejectedAndRestored
    }

    static func applyPosition(
        initial: CGRect,
        requested: CGPoint,
        setPosition: (CGPoint) -> Bool,
        setSize: (CGSize) -> Bool,
        readFrame: () -> CGRect?
    ) -> GeometryTransactionOutcome {
        let requestedRect = CGRect(origin: requested, size: initial.size)
        if roughlySame(initial, requestedRect) {
            return .applied
        }

        if setPosition(requested),
           let actual = readFrame(),
           roughlySame(actual, requestedRect)
        {
            return .applied
        }

        _ = setSize(initial.size)
        _ = setPosition(initial.origin)
        _ = setSize(initial.size)
        guard let restored = readFrame(), roughlySame(restored, initial) else {
            return .failedToRestore
        }
        return .rejectedAndRestored
    }

    private static func roughlySame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        roughlySame(lhs.origin, rhs.origin)
            && abs(lhs.width - rhs.width) <= 2
            && abs(lhs.height - rhs.height) <= 2
    }

    private static func roughlySame(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 2 && abs(lhs.y - rhs.y) <= 2
    }
}
