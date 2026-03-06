import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Darwin

public protocol WindowSpaceSwitching {
    func moveWindow(windowID: UInt32, targetSpaceID: Int) -> Bool
}

public protocol SpaceShortcutSwitching {
    func switchToSpace(targetSpaceID: Int) -> Bool
}

public protocol DisplayRelayWindowSpaceSwitching {
    func moveWindow(
        windowID: UInt32,
        bundleID: String,
        targetDisplayID: String?,
        targetSpaceID: Int,
        spacesMode: SpacesMode
    ) -> Bool
}

struct WindowSpaceDragAttempt: Equatable {
    let startPoint: CGPoint
    let holdPoint: CGPoint
}

enum WindowSpaceDragPlanner {
    static func dragAttempts(
        fallbackFrame: ResolvedFrame,
        titleBarHandleFrames: [CGRect]
    ) -> [WindowSpaceDragAttempt] {
        var attempts: [WindowSpaceDragAttempt] = []

        for handleFrame in titleBarHandleFrames {
            let startPoint = CGPoint(
                x: handleFrame.midX,
                y: fallbackFrame.y + abs(fallbackFrame.y - handleFrame.minY) / 2.0
            )
            attempts.append(WindowSpaceDragAttempt(
                startPoint: startPoint,
                holdPoint: holdPoint(for: startPoint, fallbackFrame: fallbackFrame)
            ))
        }

        let topInsets = fallbackTopInsets(for: fallbackFrame)
        let anchorXs = fallbackAnchorXs(for: fallbackFrame)
        for topInset in topInsets {
            for anchorX in anchorXs {
                let startPoint = CGPoint(x: anchorX, y: fallbackFrame.y + topInset)
                attempts.append(WindowSpaceDragAttempt(
                    startPoint: startPoint,
                    holdPoint: holdPoint(for: startPoint, fallbackFrame: fallbackFrame)
                ))
            }
        }

        return uniqueAttempts(attempts)
    }

    private static func fallbackTopInsets(for frame: ResolvedFrame) -> [CGFloat] {
        let candidates: [CGFloat] = [8, 14, 22, 30, 40]
        let maxInset = max(8, min(48, frame.height * 0.08))
        let filtered = candidates.filter { $0 <= maxInset }
        return filtered.isEmpty ? [8] : filtered
    }

    private static func fallbackAnchorXs(for frame: ResolvedFrame) -> [CGFloat] {
        [
            frame.x + min(60, max(10, frame.width / 10)),
            frame.x + (frame.width / 2.0),
            frame.x + max(frame.width - 60, frame.width * 0.85),
        ]
    }

    private static func holdPoint(for startPoint: CGPoint, fallbackFrame: ResolvedFrame) -> CGPoint {
        let dragDistance = min(max(18, fallbackFrame.height * 0.02), max(18, fallbackFrame.height - 20))
        return CGPoint(
            x: startPoint.x,
            y: min(startPoint.y + dragDistance, fallbackFrame.y + fallbackFrame.height - 10)
        )
    }

    private static func uniqueAttempts(_ attempts: [WindowSpaceDragAttempt]) -> [WindowSpaceDragAttempt] {
        var unique: [WindowSpaceDragAttempt] = []
        for attempt in attempts where !unique.contains(where: { existing in
            abs(existing.startPoint.x - attempt.startPoint.x) < 1 &&
            abs(existing.startPoint.y - attempt.startPoint.y) < 1 &&
            abs(existing.holdPoint.x - attempt.holdPoint.x) < 1 &&
            abs(existing.holdPoint.y - attempt.holdPoint.y) < 1
        }) {
            unique.append(attempt)
        }
        return unique
    }
}

public final class AppleScriptSpaceShortcutSwitcher: SpaceShortcutSwitching {
    private typealias GetSymbolicHotKeyValueFn = @convention(c) (
        UInt16,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt16>,
        UnsafeMutablePointer<UInt64>
    ) -> Int32
    private typealias IsSymbolicHotKeyEnabledFn = @convention(c) (UInt16) -> Bool
    private typealias SetSymbolicHotKeyEnabledFn = @convention(c) (UInt16, Bool) -> Int32

    private struct SpaceSwitchHotKey {
        let id: UInt16
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }
    private let commandRunner: (String, [String]) -> Int32
    private let getSymbolicHotKeyValue: GetSymbolicHotKeyValueFn?
    private let isSymbolicHotKeyEnabled: IsSymbolicHotKeyEnabledFn?
    private let setSymbolicHotKeyEnabled: SetSymbolicHotKeyEnabledFn?

    public init(
        commandRunner: @escaping (String, [String]) -> Int32 = { executable, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = nil
            process.standardOutput = Pipe()
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        },
        symbolResolver: @escaping (String) -> UnsafeMutableRawPointer? = {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), $0)
        }
    ) {
        self.commandRunner = commandRunner

        if let symbol = symbolResolver("CGSGetSymbolicHotKeyValue") {
            self.getSymbolicHotKeyValue = unsafeBitCast(symbol, to: GetSymbolicHotKeyValueFn.self)
        } else {
            self.getSymbolicHotKeyValue = nil
        }

        if let symbol = symbolResolver("CGSIsSymbolicHotKeyEnabled") {
            self.isSymbolicHotKeyEnabled = unsafeBitCast(symbol, to: IsSymbolicHotKeyEnabledFn.self)
        } else {
            self.isSymbolicHotKeyEnabled = nil
        }

        if let symbol = symbolResolver("CGSSetSymbolicHotKeyEnabled") {
            self.setSymbolicHotKeyEnabled = unsafeBitCast(symbol, to: SetSymbolicHotKeyEnabledFn.self)
        } else {
            self.setSymbolicHotKeyEnabled = nil
        }
    }

    public func switchToSpace(targetSpaceID: Int) -> Bool {
        guard let hotKey = hotKey(for: targetSpaceID) else {
            return false
        }

        let wasEnabled = isSymbolicHotKeyEnabled?(hotKey.id) ?? true
        if !wasEnabled {
            _ = setSymbolicHotKeyEnabled?(hotKey.id, true)
        }
        defer {
            if !wasEnabled {
                _ = setSymbolicHotKeyEnabled?(hotKey.id, false)
            }
        }

        return triggerSpaceSwitch(using: hotKey)
    }

    private func hotKey(for targetSpaceID: Int) -> SpaceSwitchHotKey? {
        guard (1 ... 16).contains(targetSpaceID),
              let getSymbolicHotKeyValue
        else {
            return nil
        }

        let hotKeyID = UInt16(118 + targetSpaceID - 1)
        var keyCode: UInt16 = 0
        var flags: UInt64 = 0
        let status = getSymbolicHotKeyValue(hotKeyID, nil, &keyCode, &flags)
        guard status == 0 else {
            return nil
        }

        return SpaceSwitchHotKey(
            id: hotKeyID,
            keyCode: CGKeyCode(keyCode),
            flags: CGEventFlags(rawValue: flags)
        )
    }

    private func triggerSpaceSwitch(using hotKey: SpaceSwitchHotKey) -> Bool {
        let modifiers = appleScriptModifiers(from: hotKey.flags)
        let command: String
        if modifiers.isEmpty {
            command = "tell application \"System Events\" to key code \(hotKey.keyCode)"
        } else {
            command = "tell application \"System Events\" to key code \(hotKey.keyCode) using {\(modifiers.joined(separator: ", "))}"
        }

        return commandRunner("/usr/bin/osascript", ["-e", command]) == 0
    }

    private func appleScriptModifiers(from flags: CGEventFlags) -> [String] {
        var modifiers: [String] = []
        if flags.contains(.maskControl) { modifiers.append("control down") }
        if flags.contains(.maskShift) { modifiers.append("shift down") }
        if flags.contains(.maskAlternate) { modifiers.append("option down") }
        if flags.contains(.maskCommand) { modifiers.append("command down") }
        return modifiers
    }
}

public final class DisplayRelayWindowSpaceSwitcher: DisplayRelayWindowSpaceSwitching {
    private let windowProvider: () -> [WindowSnapshot]
    private let displayProvider: () -> [DisplayInfo]
    private let frameSetter: (UInt32, String, ResolvedFrame) -> Bool
    private let spaceShortcutSwitcher: SpaceShortcutSwitching
    private let sleep: (TimeInterval) -> Void

    public init(
        windowProvider: @escaping () -> [WindowSnapshot] = { WindowQueryService.listWindowsOnAllSpaces() },
        displayProvider: @escaping () -> [DisplayInfo] = { SystemProbe.displays() },
        frameSetter: @escaping (UInt32, String, ResolvedFrame) -> Bool = { windowID, bundleID, frame in
            WindowQueryService.setWindowFrame(windowID: windowID, bundleID: bundleID, frame: frame)
        },
        spaceShortcutSwitcher: SpaceShortcutSwitching = AppleScriptSpaceShortcutSwitcher(),
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.windowProvider = windowProvider
        self.displayProvider = displayProvider
        self.frameSetter = frameSetter
        self.spaceShortcutSwitcher = spaceShortcutSwitcher
        self.sleep = sleep
    }

    public func moveWindow(
        windowID: UInt32,
        bundleID: String,
        targetDisplayID: String?,
        targetSpaceID: Int,
        spacesMode: SpacesMode
    ) -> Bool {
        guard spacesMode == .perDisplay else {
            return false
        }

        let displays = displayProvider()
        guard displays.count >= 2,
              let snapshot = windowProvider().first(where: { $0.windowID == windowID }),
              let currentDisplayID = snapshot.displayID,
              let targetDisplay = resolveTargetDisplay(targetDisplayID: targetDisplayID, displays: displays),
              let relayDisplay = resolveRelayDisplay(
                currentDisplayID: currentDisplayID,
                targetDisplayID: targetDisplay.id,
                displays: displays
              )
        else {
            return false
        }

        let referenceFrame = snapshot.frame
        if currentDisplayID == targetDisplay.id {
            let relayFrame = temporaryFrame(for: referenceFrame, on: relayDisplay)
            guard frameSetter(windowID, bundleID, relayFrame),
                  waitForWindow(windowID: windowID, targetDisplayID: relayDisplay.id, targetSpaceID: nil)
            else {
                return false
            }
        }

        guard spaceShortcutSwitcher.switchToSpace(targetSpaceID: targetSpaceID) else {
            return false
        }
        sleep(0.5)

        let targetFrame = temporaryFrame(for: referenceFrame, on: targetDisplay)
        guard frameSetter(windowID, bundleID, targetFrame),
              waitForWindow(windowID: windowID, targetDisplayID: targetDisplay.id, targetSpaceID: targetSpaceID)
        else {
            return false
        }

        return true
    }

    private func resolveTargetDisplay(targetDisplayID: String?, displays: [DisplayInfo]) -> DisplayInfo? {
        if let targetDisplayID {
            return displays.first(where: { $0.id == targetDisplayID })
        }

        return displays.first(where: \.isPrimary) ?? displays.sorted(by: { $0.id < $1.id }).first
    }

    private func resolveRelayDisplay(
        currentDisplayID: String,
        targetDisplayID: String,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        if currentDisplayID != targetDisplayID,
           let currentDisplay = displays.first(where: { $0.id == currentDisplayID })
        {
            return currentDisplay
        }

        return displays
            .filter { $0.id != targetDisplayID }
            .sorted(by: { $0.id < $1.id })
            .first
    }

    private func temporaryFrame(for frame: ResolvedFrame, on display: DisplayInfo) -> ResolvedFrame {
        let basis = display.visibleFrame.insetBy(dx: 40, dy: 40)
        let width = min(frame.width, max(400.0, Double(basis.width)))
        let height = min(frame.height, max(300.0, Double(basis.height)))

        return ResolvedFrame(
            x: Double(basis.minX),
            y: Double(basis.minY),
            width: width,
            height: height
        )
    }

    private func waitForWindow(windowID: UInt32, targetDisplayID: String, targetSpaceID: Int?) -> Bool {
        for _ in 0 ..< 20 {
            if matches(windowID: windowID, targetDisplayID: targetDisplayID, targetSpaceID: targetSpaceID) {
                return true
            }
            sleep(0.1)
        }

        return matches(windowID: windowID, targetDisplayID: targetDisplayID, targetSpaceID: targetSpaceID)
    }

    private func matches(windowID: UInt32, targetDisplayID: String, targetSpaceID: Int?) -> Bool {
        guard let snapshot = windowProvider().first(where: { $0.windowID == windowID }),
              snapshot.displayID == targetDisplayID
        else {
            return false
        }

        if let targetSpaceID {
            return snapshot.spaceID == targetSpaceID
        }

        return true
    }
}

public final class SimulatedWindowSpaceSwitcher: WindowSpaceSwitching {
    private struct TargetWindow {
        let pid: pid_t
        let appElement: AXUIElement
        let windowElement: AXUIElement
        let dragAttempts: [WindowSpaceDragAttempt]
    }

    private let windowProvider: () -> [WindowSnapshot]
    private let sleep: (TimeInterval) -> Void
    private let eventPoster: (CGEvent) -> Void
    private let spaceShortcutSwitcher: SpaceShortcutSwitching

    public init(
        windowProvider: @escaping () -> [WindowSnapshot] = { WindowQueryService.listWindowsOnAllSpaces() },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        spaceShortcutSwitcher: SpaceShortcutSwitching = AppleScriptSpaceShortcutSwitcher()
    ) {
        self.windowProvider = windowProvider
        self.sleep = sleep
        self.eventPoster = eventPoster
        self.spaceShortcutSwitcher = spaceShortcutSwitcher
    }

    public func moveWindow(windowID: UInt32, targetSpaceID: Int) -> Bool {
        guard AXIsProcessTrusted(),
              let targetWindow = resolveTargetWindow(windowID: windowID)
        else {
            return false
        }

        focus(targetWindow)
        for dragAttempt in targetWindow.dragAttempts {
            dragWindow(dragAttempt, targetSpaceID: targetSpaceID)
            if waitUntilWindowMoves(windowID: windowID, targetSpaceID: targetSpaceID) {
                return true
            }
            sleep(0.2)
        }
        return false
    }

    private func resolveTargetWindow(windowID: UInt32) -> TargetWindow? {
        guard let snapshot = windowProvider().first(where: { $0.windowID == windowID }) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid_t(snapshot.pid))
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else {
            return nil
        }

        for window in windows {
            var resolvedWindowID: CGWindowID = 0
            if AXUIElementGetWindowID(window, &resolvedWindowID) == .success,
               resolvedWindowID == snapshot.windowID,
               let dragAttempts = dragAttempts(for: window, fallbackFrame: snapshot.frame),
               !dragAttempts.isEmpty
            {
                return TargetWindow(
                    pid: pid_t(snapshot.pid),
                    appElement: appElement,
                    windowElement: window,
                    dragAttempts: dragAttempts
                )
            }
        }

        return nil
    }

    private func dragAttempts(for window: AXUIElement, fallbackFrame: ResolvedFrame) -> [WindowSpaceDragAttempt]? {
        var handleFrames: [CGRect] = []

        let handleAttributes: [CFString] = [
            kAXMinimizeButtonAttribute as CFString,
            kAXCloseButtonAttribute as CFString,
            kAXZoomButtonAttribute as CFString,
            kAXToolbarButtonAttribute as CFString,
            kAXFullScreenButtonAttribute as CFString,
            kAXTitleUIElementAttribute as CFString,
            kAXProxyAttribute as CFString,
        ]

        for attribute in handleAttributes {
            if let element = element(for: attribute, in: window),
               let elementFrame = frame(for: element)
            {
                handleFrames.append(elementFrame)
            }
        }

        return WindowSpaceDragPlanner.dragAttempts(
            fallbackFrame: fallbackFrame,
            titleBarHandleFrames: handleFrames
        )
    }

    private func element(for attribute: CFString, in window: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &ref) == .success,
              let element = ref
        else {
            return nil
        }

        return (element as! AXUIElement)
    }

    private func frame(for element: AXUIElement) -> CGRect? {
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

    private func focus(_ targetWindow: TargetWindow) {
        _ = AXUIElementSetAttributeValue(targetWindow.appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(targetWindow.appElement, kAXFocusedWindowAttribute as CFString, targetWindow.windowElement)
        _ = AXUIElementSetAttributeValue(targetWindow.appElement, kAXMainWindowAttribute as CFString, targetWindow.windowElement)
        _ = AXUIElementSetAttributeValue(targetWindow.windowElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(targetWindow.windowElement, kAXRaiseAction as CFString)
        sleep(0.1)
    }

    private func dragWindow(_ attempt: WindowSpaceDragAttempt, targetSpaceID: Int) {
        let mouseMove = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: attempt.startPoint,
            mouseButton: .left
        )
        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: attempt.startPoint,
            mouseButton: .left
        )
        let mouseDragStart = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: attempt.holdPoint,
            mouseButton: .left
        )
        let mouseDragHold = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: attempt.holdPoint,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: attempt.holdPoint,
            mouseButton: .left
        )
        guard let mouseMove,
              let mouseDown,
              let mouseDragStart,
              let mouseDragHold,
              let mouseUp
        else {
            return
        }

        eventPoster(mouseMove)
        eventPoster(mouseDown)
        sleep(0.05)
        eventPoster(mouseDragStart)
        sleep(0.08)
        sleep(0.05)
        _ = spaceShortcutSwitcher.switchToSpace(targetSpaceID: targetSpaceID)
        sleep(0.35)
        eventPoster(mouseDragHold)
        sleep(0.45)
        eventPoster(mouseUp)
    }

    private func waitUntilWindowMoves(windowID: UInt32, targetSpaceID: Int) -> Bool {
        for _ in 0 ..< 20 {
            if windowProvider().first(where: { $0.windowID == windowID })?.spaceID == targetSpaceID {
                return true
            }
            sleep(0.1)
        }

        return windowProvider().first(where: { $0.windowID == windowID })?.spaceID == targetSpaceID
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func AXUIElementGetWindowID(_ element: AXUIElement, _ idOut: UnsafeMutablePointer<CGWindowID>) -> AXError
