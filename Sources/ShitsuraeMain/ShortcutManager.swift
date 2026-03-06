@preconcurrency import AppKit
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit
import ShitsuraeCore
import SwiftUI

private final class WeakShortcutManagerBox: @unchecked Sendable {
    weak var manager: ShortcutManager?

    init(manager: ShortcutManager) {
        self.manager = manager
    }
}

final class ShortcutManager {
    fileprivate static let switcherOverlaySelectionNotification = Notification.Name("SwitcherOverlaySelectionNotification")
    fileprivate static let switcherOverlaySelectionCandidateIDKey = "candidateID"

    private enum HotkeyAction {
        case focus(slot: Int)
        case nextWindow
        case prevWindow
        case switcher
        case switcherReverse
        case globalAction(index: Int)

        var shortcutID: String {
            switch self {
            case let .focus(slot):
                return "focusBySlot:\(slot)"
            case .nextWindow:
                return "nextWindow"
            case .prevWindow:
                return "prevWindow"
            case .switcher:
                return "switcher"
            case .switcherReverse:
                return "switcher"
            case let .globalAction(index):
                return "globalAction:\(index)"
            }
        }
    }

    private struct SwitcherSession {
        let shortcuts: ResolvedShortcuts
        var candidates: [SwitcherCandidate]
        var selectedIndex: Int
    }

    private let commandService: CommandService
    private let configLoader = ConfigLoader()
    private let logger = ShitsuraeLogger()

    private var hotKeyPressedEventHandlerRef: EventHandlerRef?
    private var hotKeyReleasedEventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionsByHotKeyID: [UInt32: HotkeyAction] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var disabledNativeSymbolicHotKeys: Set<NativeSymbolicHotKey> = []

    private var eventTapPort: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var modifierReleasePollingTimer: Timer?

    private let overlayController = SwitcherOverlayController()
    private var overlaySelectionObserver: NSObjectProtocol?
    private var switcherSession: SwitcherSession?
    private var cycleIndex: Int = -1
    private var cycleCandidates: [SwitcherCandidate] = []
    private var lastCycleAt: Date?
    private let cycleSessionTimeout: TimeInterval = 1.5
    private var lastCarbonShortcutID: String?
    private var lastCarbonShortcutAt: Date?
    private let eventTapDuplicateThreshold: TimeInterval = 0.12
    private var lastEventTapSwitcherAdvanceAt: Date?
    private let switcherAdvanceDedupeThreshold: TimeInterval = 0.12

    private(set) var currentShortcuts = ResolvedShortcuts(from: nil)

    init(commandService: CommandService) {
        self.commandService = commandService
        let managerBox = WeakShortcutManagerBox(manager: self)
        overlaySelectionObserver = NotificationCenter.default.addObserver(
            forName: Self.switcherOverlaySelectionNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let candidateID = notification.userInfo?[Self.switcherOverlaySelectionCandidateIDKey] as? String else {
                return
            }
            managerBox.manager?.acceptSwitcher(candidateID: candidateID)
        }
    }

    func start() {
        reloadConfiguration()
    }

    func stop() {
        if let overlaySelectionObserver {
            NotificationCenter.default.removeObserver(overlaySelectionObserver)
            self.overlaySelectionObserver = nil
        }
        unregisterHotkeys()
        stopEventTap()
        stopModifierReleasePolling()
        restoreNativeSwitcherHotKeys()
        switcherSession = nil
        overlayController.hide()
        resetCycleState()
        lastCarbonShortcutID = nil
        lastCarbonShortcutAt = nil
        lastEventTapSwitcherAdvanceAt = nil
    }

    func reloadConfiguration() {
        unregisterHotkeys()
        stopEventTap()
        stopModifierReleasePolling()

        do {
            let loaded = try configLoader.loadFromDefaultDirectory()
            currentShortcuts = loaded.config.resolvedShortcuts
        } catch {
            currentShortcuts = ResolvedShortcuts(from: nil)
        }

        syncNativeSwitcherHotKeys()
        startEventTap()
        installHotkeyHandlersIfNeeded()
        registerHotkeys(shortcuts: currentShortcuts)
        detectExternalConflicts()
        let accessibilityGranted = SystemProbe.accessibilityGranted()
        logger.log(
            event: "shortcut.resolved",
            fields: [
                "nextWindowKey": canonicalHotkeyKey(currentShortcuts.nextWindow.key),
                "nextWindowModifiers": currentShortcuts.nextWindow.modifiers,
                "prevWindowKey": canonicalHotkeyKey(currentShortcuts.prevWindow.key),
                "prevWindowModifiers": currentShortcuts.prevWindow.modifiers,
                "switcherKey": canonicalHotkeyKey(currentShortcuts.switcherTrigger.key),
                "switcherModifiers": currentShortcuts.switcherTrigger.modifiers,
            ]
        )
        logger.log(
            event: "shortcut.reload",
            fields: [
                "registeredCount": actionsByHotKeyID.count,
                "eventTapEnabled": eventTapPort != nil,
                "accessibilityGranted": accessibilityGranted,
            ]
        )
        if !accessibilityGranted {
            logger.log(
                level: "error",
                event: "shortcut.permission.missing",
                fields: [
                    "accessibilityGranted": accessibilityGranted,
                ]
            )
        }
    }

    private func detectExternalConflicts() {
        detectSkhdConflict(for: currentShortcuts.nextWindow, shortcutID: "nextWindow")
        detectSkhdConflict(for: currentShortcuts.prevWindow, shortcutID: "prevWindow")
    }

    private func detectSkhdConflict(for definition: HotkeyDefinition, shortcutID: String) {
        guard isProcessRunning(named: "skhd") else {
            return
        }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let candidatePaths = [
            "\(home)/.skhdrc",
            "\(home)/.config/skhd/skhdrc",
        ]

        let expectedKey = canonicalHotkeyKey(definition.key)
        let expectedModifiers = Set(definition.modifiers.map { $0.lowercased() })

        for path in candidatePaths {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }
            if skhdConfig(content, containsShortcutWithKey: expectedKey, modifiers: expectedModifiers) {
                logger.log(
                    level: "warn",
                    event: "shortcut.conflict.detected",
                    fields: [
                        "shortcutID": shortcutID,
                        "key": expectedKey,
                        "modifiers": definition.modifiers,
                        "conflictSource": "skhd",
                        "configPath": path,
                    ]
                )
                return
            }
        }
    }

    private func isProcessRunning(named processName: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", processName]
        process.standardInput = nil
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func skhdConfig(_ content: String, containsShortcutWithKey key: String, modifiers: Set<String>) -> Bool {
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hashIndex = line.firstIndex(of: "#") {
                line = String(line[..<hashIndex])
            }
            line = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if line.isEmpty {
                continue
            }

            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let binding = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let parts = binding
                .split(separator: "-", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            guard let keyPart = parts.last, !keyPart.isEmpty else {
                continue
            }

            let modPart = parts.dropLast().joined(separator: "-")
            let parsedModifiers = Set(
                modPart
                    .split(separator: "+")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )

            if keyPart == key, parsedModifiers == modifiers {
                return true
            }
        }
        return false
    }

    private func installHotkeyHandlersIfNeeded() {
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        if hotKeyPressedEventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyPressed)
            )
            InstallEventHandler(
                GetEventDispatcherTarget(),
                appHotKeyPressedHandler,
                1,
                &eventType,
                userData,
                &hotKeyPressedEventHandlerRef
            )
        }

        if hotKeyReleasedEventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: OSType(kEventHotKeyReleased)
            )
            InstallEventHandler(
                GetEventDispatcherTarget(),
                appHotKeyReleasedHandler,
                1,
                &eventType,
                userData,
                &hotKeyReleasedEventHandlerRef
            )
        }
    }

    private func registerHotkeys(shortcuts: ResolvedShortcuts) {
        if eventTapPort == nil {
            for slot in 1 ... 9 {
                if let definition = shortcuts.focusBySlot[slot] {
                    registerHotkey(definition: definition, action: .focus(slot: slot))
                }
            }
        }

        registerHotkey(definition: shortcuts.nextWindow, action: .nextWindow)
        registerHotkey(definition: shortcuts.prevWindow, action: .prevWindow)
        registerHotkey(definition: shortcuts.switcherTrigger, action: .switcher)
        if shouldRegisterSwitcherReverseHotkey(trigger: shortcuts.switcherTrigger) {
            registerHotkey(key: "tab", modifiers: ["cmd", "shift"], action: .switcherReverse)
        }

        for (index, action) in shortcuts.globalActions.enumerated() {
            registerHotkey(
                key: action.key,
                modifiers: action.modifiers,
                action: .globalAction(index: index + 1)
            )
        }
    }

    private func registerHotkey(definition: HotkeyDefinition, action: HotkeyAction) {
        registerHotkey(key: definition.key, modifiers: definition.modifiers, action: action)
    }

    private func registerHotkey(key: String, modifiers: [String], action: HotkeyAction) {
        guard let keyCode = keyCode(for: key) else {
            return
        }

        let carbonMods = carbonModifiers(modifiers)
        let hotKeyID = EventHotKeyID(signature: 0x53485254, id: nextHotKeyID)
        nextHotKeyID += 1

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            logger.log(
                level: "error",
                event: "shortcut.register.failed",
                fields: [
                    "key": key,
                    "modifiers": modifiers,
                    "status": status,
                    "shortcutID": action.shortcutID,
                ]
            )
            return
        }

        hotKeyRefs.append(ref)
        actionsByHotKeyID[hotKeyID.id] = action
        logger.log(
            event: "shortcut.registered",
            fields: [
                "shortcutID": action.shortcutID,
                "key": canonicalHotkeyKey(key),
                "modifiers": modifiers,
            ]
        )
    }

    private func unregisterHotkeys() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs = []
        actionsByHotKeyID = [:]
        nextHotKeyID = 1

        if let eventHandlerRef = hotKeyPressedEventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            hotKeyPressedEventHandlerRef = nil
        }
        if let eventHandlerRef = hotKeyReleasedEventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            hotKeyReleasedEventHandlerRef = nil
        }
    }

    private func startEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: appEventTapCallback,
            userInfo: userInfo
        )

        guard let port else {
            EventTapRuntimeStatusStore.shared.set(EventTapStatus(enabled: false, reason: "eventTapUnavailable"))
            logger.log(
                level: "error",
                event: "eventTap.unavailable",
                fields: ["reason": "eventTapUnavailable"]
            )
            return
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            EventTapRuntimeStatusStore.shared.set(EventTapStatus(enabled: false, reason: "eventTapUnavailable"))
            logger.log(
                level: "error",
                event: "eventTap.unavailable",
                fields: ["reason": "eventTapUnavailable"]
            )
            return
        }

        eventTapPort = port
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        EventTapRuntimeStatusStore.shared.set(EventTapStatus(enabled: true, reason: nil))
        logger.log(event: "eventTap.enabled")
    }

    private func stopEventTap() {
        if let source = eventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapRunLoopSource = nil
        }

        if let port = eventTapPort {
            CFMachPortInvalidate(port)
            eventTapPort = nil
        }

        EventTapRuntimeStatusStore.shared.set(EventTapStatus(enabled: false, reason: "eventTapStopped"))
    }

    fileprivate func handleHotkeyPressed(event: EventRef?) -> OSStatus {
        guard let action = hotkeyAction(from: event) else {
            logger.log(level: "error", event: "shortcut.pressed.unknown")
            return noErr
        }
        if shouldSuppressCarbonSwitcherAdvance(for: action) {
            logger.log(
                event: "shortcut.pressed.suppressed",
                fields: [
                    "shortcutID": action.shortcutID,
                    "source": "carbon",
                    "reason": "eventTapAlreadyAdvanced",
                ]
            )
            return noErr
        }
        lastCarbonShortcutID = action.shortcutID
        lastCarbonShortcutAt = Date()
        logger.log(event: "shortcut.pressed", fields: ["shortcutID": action.shortcutID])
        dispatch(action: action)
        return noErr
    }

    fileprivate func handleHotkeyReleased(event: EventRef?) -> OSStatus {
        guard let action = hotkeyAction(from: event) else {
            logger.log(level: "error", event: "shortcut.released.unknown")
            return noErr
        }
        logger.log(event: "shortcut.released", fields: ["shortcutID": action.shortcutID])
        dispatchRelease(action: action)
        return noErr
    }

    private func hotkeyAction(from event: EventRef?) -> HotkeyAction? {
        guard let event else { return nil }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else {
            return nil
        }
        return actionsByHotKeyID[hotKeyID.id]
    }

    private func dispatch(action: HotkeyAction) {
        guard !isDisabled(action.shortcutID) else {
            return
        }

        switch action {
        case let .focus(slot):
            resetCycleState()
            _ = commandService.focus(slot: slot)
        case .nextWindow:
            cycleFocus(forward: true)
        case .prevWindow:
            cycleFocus(forward: false)
        case .switcher:
            resetCycleState()
            presentOrAdvanceSwitcher(forward: true)
        case .switcherReverse:
            resetCycleState()
            presentOrAdvanceSwitcher(forward: false)
        case let .globalAction(index):
            resetCycleState()
            executeGlobalAction(index: index)
        }
    }

    private func dispatchRelease(action: HotkeyAction) {
        guard !isDisabled(action.shortcutID) else {
            return
        }

        switch action {
        case .switcher, .switcherReverse:
            handleSwitcherTriggerReleased()
        case .focus, .nextWindow, .prevWindow, .globalAction:
            return
        }
    }

    private func isDisabled(_ shortcutID: String) -> Bool {
        guard let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return PolicyEngine.isShortcutDisabled(
            frontmostBundleID: frontmostBundleID,
            shortcutID: shortcutID,
            disabledInApps: currentShortcuts.disabledInApps,
            focusBySlotEnabledInApps: currentShortcuts.focusBySlotEnabledInApps
        )
    }

    private func cycleFocus(forward: Bool) {
        let now = Date()

        if shouldRefreshCycleCandidates(now: now) {
            cycleCandidates = fetchSwitcherCandidates(
                includeAllSpaces: currentShortcuts.includeAllSpaces,
                excludedBundleIDs: currentShortcuts.cycleExcludedApps
            )
            cycleIndex = -1
        }

        let candidates = cycleCandidates
        guard !candidates.isEmpty else {
            logger.log(level: "error", event: "cycle.candidates.empty")
            return
        }

        if cycleIndex < 0 || cycleIndex >= candidates.count {
            cycleIndex = initialSelectionIndex(candidates: candidates, forward: forward)
        } else {
            cycleIndex = forward
                ? (cycleIndex + 1) % candidates.count
                : (cycleIndex - 1 + candidates.count) % candidates.count
        }

        let candidate = candidates[cycleIndex]
        logger.log(
            event: "cycle.select",
            fields: [
                "forward": forward,
                "selectedIndex": cycleIndex,
                "candidateID": candidate.id,
                "candidateBundleID": candidate.bundleID ?? "",
            ]
        )
        lastCycleAt = now
        activate(candidate: candidate)
    }

    private func presentOrAdvanceSwitcher(forward: Bool) {
        if var session = switcherSession {
            guard !session.candidates.isEmpty else { return }
            session.selectedIndex = forward
                ? (session.selectedIndex + 1) % session.candidates.count
                : (session.selectedIndex - 1 + session.candidates.count) % session.candidates.count
            switcherSession = session
            overlayController.show(candidates: session.candidates, selectedIndex: session.selectedIndex)
            return
        }

        let candidates = fetchSwitcherCandidates(
            includeAllSpaces: currentShortcuts.includeAllSpaces,
            excludedBundleIDs: currentShortcuts.switcherExcludedApps
        )
        guard !candidates.isEmpty else {
            logger.log(level: "error", event: "switcher.candidates.empty")
            return
        }

        let initialIndex = initialSwitcherSelectionIndex(candidates: candidates, forward: forward)
        let session = SwitcherSession(
            shortcuts: currentShortcuts,
            candidates: candidates,
            selectedIndex: initialIndex
        )
        switcherSession = session
        logger.log(
            event: "switcher.present",
            fields: [
                "candidateCount": candidates.count,
                "selectedIndex": initialIndex,
                "selectedID": candidates[initialIndex].id,
            ]
        )
        overlayController.show(candidates: candidates, selectedIndex: initialIndex)
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
            if let eventTapPort {
                CGEvent.tapEnable(tap: eventTapPort, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown,
           switcherSession != nil,
           handleSwitcherKeyDown(event)
        {
            return nil
        }

        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
           let action = actionForEventTap(event),
           shouldDispatchFromEventTap(action: action)
        {
            guard shouldConsumeEventTap(action: action) else {
                return Unmanaged.passRetained(event)
            }
            logger.log(
                event: "shortcut.pressed",
                fields: [
                    "shortcutID": action.shortcutID,
                    "source": "eventTap",
                ]
            )
            dispatch(action: action)
            return nil
        }

        if type == .flagsChanged,
           switcherSession != nil,
           handleSwitcherFlagsChanged(event)
        {
            return nil
        }

        return Unmanaged.passRetained(event)
    }

    private func actionForEventTap(_ event: CGEvent) -> HotkeyAction? {
        for slot in 1 ... 9 {
            if let definition = currentShortcuts.focusBySlot[slot],
               eventMatchesHotkey(event: event, key: definition.key, modifiers: definition.modifiers)
            {
                return .focus(slot: slot)
            }
        }

        if eventMatchesHotkey(
            event: event,
            key: currentShortcuts.nextWindow.key,
            modifiers: currentShortcuts.nextWindow.modifiers
        ) {
            return .nextWindow
        }

        if eventMatchesHotkey(
            event: event,
            key: currentShortcuts.prevWindow.key,
            modifiers: currentShortcuts.prevWindow.modifiers
        ) {
            return .prevWindow
        }

        if eventMatchesHotkey(
            event: event,
            key: currentShortcuts.switcherTrigger.key,
            modifiers: currentShortcuts.switcherTrigger.modifiers
        ) {
            return .switcher
        }

        if shouldRegisterSwitcherReverseHotkey(trigger: currentShortcuts.switcherTrigger),
           eventMatchesHotkey(event: event, key: "tab", modifiers: ["cmd", "shift"])
        {
            return .switcherReverse
        }

        for (index, action) in currentShortcuts.globalActions.enumerated() {
            if eventMatchesHotkey(event: event, key: action.key, modifiers: action.modifiers) {
                return .globalAction(index: index + 1)
            }
        }

        return nil
    }

    private func shouldDispatchFromEventTap(action: HotkeyAction) -> Bool {
        switch action {
        case .focus:
            return true
        case .nextWindow, .prevWindow:
            return !isRecentlyHandledByCarbon(shortcutID: action.shortcutID)
        case .switcher, .switcherReverse, .globalAction:
            return actionsByHotKeyID.isEmpty
        }
    }

    private func shouldConsumeEventTap(action: HotkeyAction) -> Bool {
        if isDisabled(action.shortcutID) {
            return false
        }

        switch action {
        case let .focus(slot):
            return commandService.shouldHandleFocusShortcut(slot: slot)
        case .nextWindow, .prevWindow, .switcher, .switcherReverse, .globalAction:
            return true
        }
    }

    private func isRecentlyHandledByCarbon(shortcutID: String) -> Bool {
        guard lastCarbonShortcutID == shortcutID,
              let lastCarbonShortcutAt
        else {
            return false
        }
        return Date().timeIntervalSince(lastCarbonShortcutAt) <= eventTapDuplicateThreshold
    }

    private func handleSwitcherKeyDown(_ event: CGEvent) -> Bool {
        guard var session = switcherSession else { return false }

        let key = normalizedKey(from: event)
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if key == "tab" {
            // Avoid accidental initial reordering caused by key-repeat after opening the switcher.
            if isAutoRepeat {
                return true
            }

            if isRecentlyHandledByCarbon(shortcutID: "switcher") {
                return true
            }

            if flags.contains(.maskShift) {
                session.selectedIndex = (session.selectedIndex - 1 + session.candidates.count) % session.candidates.count
            } else {
                session.selectedIndex = (session.selectedIndex + 1) % session.candidates.count
            }

            switcherSession = session
            lastEventTapSwitcherAdvanceAt = Date()
            overlayController.show(candidates: session.candidates, selectedIndex: session.selectedIndex)
            return true
        }

        if session.shortcuts.cancelKeys.contains(key) {
            cancelSwitcher()
            return true
        }

        if session.shortcuts.acceptKeys.contains(key) {
            acceptSwitcher()
            return true
        }

        if let quickIndex = session.candidates.firstIndex(where: { $0.quickKey == key }) {
            session.selectedIndex = quickIndex
            switcherSession = session
            acceptSwitcher()
            return true
        }

        return false
    }

    private func handleSwitcherFlagsChanged(_ event: CGEvent) -> Bool {
        guard let session = switcherSession,
              session.shortcuts.acceptOnModifierRelease
        else {
            return false
        }

        if !isSwitcherHoldModifierActive(flags: event.flags) {
            acceptSwitcher()
            return true
        }

        return false
    }

    private func acceptSwitcher() {
        guard let session = switcherSession,
              session.candidates.indices.contains(session.selectedIndex)
        else {
            cancelSwitcher()
            return
        }

        let candidate = session.candidates[session.selectedIndex]
        logger.log(
            event: "switcher.accept",
            fields: [
                "selectedIndex": session.selectedIndex,
                "selectedID": candidate.id,
                "selectedBundleID": candidate.bundleID ?? "",
            ]
        )
        activate(candidate: candidate)
        switcherSession = nil
        stopModifierReleasePolling()
        overlayController.hide()
    }

    private func acceptSwitcher(candidateID: String) {
        guard let session = switcherSession,
              let selectedIndex = session.candidates.firstIndex(where: { $0.id == candidateID })
        else {
            cancelSwitcher()
            return
        }

        switcherSession = SwitcherSession(
            shortcuts: session.shortcuts,
            candidates: session.candidates,
            selectedIndex: selectedIndex
        )
        acceptSwitcher()
    }

    private func cancelSwitcher() {
        switcherSession = nil
        stopModifierReleasePolling()
        overlayController.hide()
        resetCycleState()
    }

    private func handleSwitcherTriggerReleased() {
        guard switcherSession != nil,
              currentShortcuts.acceptOnModifierRelease
        else {
            return
        }

        guard eventTapPort == nil else {
            return
        }

        if !isSwitcherHoldModifierActive(flags: CGEventSource.flagsState(.combinedSessionState)) {
            acceptSwitcher()
            return
        }

        startModifierReleasePolling()
    }

    private func startModifierReleasePolling() {
        guard modifierReleasePollingTimer == nil else {
            return
        }

        let managerBox = WeakShortcutManagerBox(manager: self)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            managerBox.manager?.pollModifierRelease()
        }
        RunLoop.main.add(timer, forMode: .common)
        modifierReleasePollingTimer = timer
    }

    private func stopModifierReleasePolling() {
        modifierReleasePollingTimer?.invalidate()
        modifierReleasePollingTimer = nil
    }

    private func pollModifierRelease() {
        guard switcherSession != nil else {
            stopModifierReleasePolling()
            return
        }

        if !isSwitcherHoldModifierActive(flags: CGEventSource.flagsState(.combinedSessionState)) {
            acceptSwitcher()
        }
    }

    private func shouldSuppressCarbonSwitcherAdvance(for action: HotkeyAction) -> Bool {
        switch action {
        case .switcher, .switcherReverse:
            guard let lastEventTapSwitcherAdvanceAt else {
                return false
            }
            return Date().timeIntervalSince(lastEventTapSwitcherAdvanceAt) <= switcherAdvanceDedupeThreshold
        case .focus, .nextWindow, .prevWindow, .globalAction:
            return false
        }
    }

    private func isSwitcherHoldModifierActive(flags: CGEventFlags) -> Bool {
        guard let holdModifier = switcherHoldModifier else {
            return false
        }

        switch holdModifier {
        case "cmd":
            return flags.contains(.maskCommand)
        case "shift":
            return flags.contains(.maskShift)
        case "ctrl":
            return flags.contains(.maskControl)
        case "alt":
            return flags.contains(.maskAlternate)
        case "fn":
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    private var switcherHoldModifier: String? {
        let modifiers = normalizedModifiers(currentShortcuts.switcherTrigger.modifiers)
        if modifiers.contains("cmd") { return "cmd" }
        if modifiers.contains("alt") { return "alt" }
        if modifiers.contains("ctrl") { return "ctrl" }
        if modifiers.contains("shift") { return "shift" }
        if modifiers.contains("fn") { return "fn" }
        return nil
    }

    private func fetchSwitcherCandidates(includeAllSpaces: Bool?, excludedBundleIDs: Set<String>) -> [SwitcherCandidate] {
        let result = commandService.switcherList(json: true, includeAllSpacesOverride: includeAllSpaces)
        guard result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SwitcherListJSON.self, from: data)
        else {
            return []
        }
        return ShortcutCandidateFilter.filter(
            candidates: payload.candidates,
            excludedBundleIDs: excludedBundleIDs,
            quickKeys: currentShortcuts.quickKeys
        )
    }

    private func activate(candidate: SwitcherCandidate) {
        if let slot = candidate.slot {
            _ = commandService.focus(slot: slot)
            logger.log(
                event: "candidate.activate.slot",
                fields: ["slot": slot]
            )
            return
        }

        if let bundleID = candidate.bundleID {
            let activated = WindowQueryService.activate(
                bundleID: bundleID,
                preferredWindowTitle: candidate.title
            )
            logger.log(
                event: "candidate.activate.bundle",
                fields: [
                    "bundleID": bundleID,
                    "activated": activated,
                ]
            )
        }
    }

    private func executeGlobalAction(index: Int) {
        guard currentShortcuts.globalActions.indices.contains(index - 1) else {
            return
        }

        let action = currentShortcuts.globalActions[index - 1].action
        switch action.type {
        case .move:
            if let x = action.x, let y = action.y {
                _ = commandService.windowMove(x: x, y: y)
            }
        case .resize:
            if let w = action.width, let h = action.height {
                _ = commandService.windowResize(width: w, height: h)
            }
        case .moveResize:
            if let x = action.x, let y = action.y, let w = action.width, let h = action.height {
                _ = commandService.windowSet(x: x, y: y, width: w, height: h)
            }
        case .snap:
            guard let preset = action.preset else { return }
            if preset == .center {
                centerCurrentWindow()
                return
            }
            let frame = snapFrame(for: preset)
            _ = commandService.windowSet(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        }
    }

    private func snapFrame(for preset: SnapPreset) -> (x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) {
        switch preset {
        case .leftHalf:
            return (.expression("0%"), .expression("0%"), .expression("50%"), .expression("100%"))
        case .rightHalf:
            return (.expression("50%"), .expression("0%"), .expression("50%"), .expression("100%"))
        case .topHalf:
            return (.expression("0%"), .expression("0%"), .expression("100%"), .expression("50%"))
        case .bottomHalf:
            return (.expression("0%"), .expression("50%"), .expression("100%"), .expression("50%"))
        case .leftThird:
            return (.expression("0%"), .expression("0%"), .expression("33.3333%"), .expression("100%"))
        case .centerThird:
            return (.expression("33.3333%"), .expression("0%"), .expression("33.3333%"), .expression("100%"))
        case .rightThird:
            return (.expression("66.6667%"), .expression("0%"), .expression("33.3333%"), .expression("100%"))
        case .maximize:
            return (.expression("0%"), .expression("0%"), .expression("100%"), .expression("100%"))
        case .center:
            return (.expression("0%"), .expression("0%"), .expression("100%"), .expression("100%"))
        }
    }

    private func centerCurrentWindow() {
        guard let window = WindowQueryService.focusedWindow() else {
            return
        }

        let displays = SystemProbe.displays()
        guard let display = resolveDisplay(frame: window.frame, displays: displays) ?? displays.first else {
            return
        }

        let basis = display.visibleFrame

        let relativeX = (basis.width - window.frame.width) / 2.0
        let relativeY = (basis.height - window.frame.height) / 2.0
        _ = commandService.windowMove(x: .pt(relativeX), y: .pt(relativeY))
    }

    private func shouldRefreshCycleCandidates(now: Date) -> Bool {
        if cycleCandidates.isEmpty {
            return true
        }

        guard let lastCycleAt else {
            return true
        }

        return now.timeIntervalSince(lastCycleAt) > cycleSessionTimeout
    }

    private func initialSelectionIndex(candidates: [SwitcherCandidate], forward: Bool) -> Int {
        guard let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return forward ? 0 : candidates.count - 1
        }

        if forward {
            return candidates.firstIndex(where: { $0.bundleID != frontmostBundleID }) ?? 0
        }

        return candidates.lastIndex(where: { $0.bundleID != frontmostBundleID }) ?? (candidates.count - 1)
    }

    private func initialSwitcherSelectionIndex(candidates: [SwitcherCandidate], forward: Bool) -> Int {
        guard !candidates.isEmpty else {
            return 0
        }
        guard candidates.count > 1 else {
            return 0
        }

        if let focusedWindow = WindowQueryService.focusedWindow(),
           let firstCandidate = candidates.first,
           candidateWindowID(from: firstCandidate.id) == focusedWindow.windowID
        {
            return forward ? 1 : (candidates.count - 1)
        }

        if let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           candidates.first?.bundleID == frontmostBundleID
        {
            return forward ? 1 : (candidates.count - 1)
        }

        return initialSelectionIndex(candidates: candidates, forward: forward)
    }

    private func candidateWindowID(from candidateID: String) -> UInt32? {
        let parts = candidateID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "window",
              let rawID = UInt32(parts[1])
        else {
            return nil
        }
        return rawID
    }

    private func resetCycleState() {
        cycleIndex = -1
        cycleCandidates = []
        lastCycleAt = nil
    }

    private func shouldRegisterSwitcherReverseHotkey(trigger: HotkeyDefinition) -> Bool {
        canonicalHotkeyKey(trigger.key) == "tab" && normalizedModifiers(trigger.modifiers) == ["cmd"]
    }

    private func syncNativeSwitcherHotKeys() {
        let desired = nativeHotKeysToDisable(trigger: currentShortcuts.switcherTrigger)
        let toEnable = disabledNativeSymbolicHotKeys.subtracting(desired)
        if !toEnable.isEmpty {
            _ = SymbolicHotKeyController.setEnabled(true, hotKeys: Array(toEnable))
        }

        let toDisable = desired.subtracting(disabledNativeSymbolicHotKeys)
        if !toDisable.isEmpty {
            _ = SymbolicHotKeyController.setEnabled(false, hotKeys: Array(toDisable))
        }

        disabledNativeSymbolicHotKeys = desired
    }

    private func restoreNativeSwitcherHotKeys() {
        guard !disabledNativeSymbolicHotKeys.isEmpty else {
            return
        }

        _ = SymbolicHotKeyController.setEnabled(true, hotKeys: Array(disabledNativeSymbolicHotKeys))
        disabledNativeSymbolicHotKeys = []
    }

    private func nativeHotKeysToDisable(trigger: HotkeyDefinition) -> Set<NativeSymbolicHotKey> {
        let key = canonicalHotkeyKey(trigger.key)
        let modifiers = normalizedModifiers(trigger.modifiers)

        if key == "tab", modifiers == ["cmd"] {
            return Set(SymbolicHotKeyController.commandTabGroup)
        }

        if key == "tab", modifiers == ["cmd", "shift"] {
            return [.commandShiftTab]
        }

        if key == "grave", modifiers == ["cmd"] {
            return [.commandKeyAboveTab]
        }

        return []
    }

    private func normalizedModifiers(_ modifiers: [String]) -> Set<String> {
        Set(modifiers.map { $0.lowercased() })
    }

    private func resolveDisplay(frame: ResolvedFrame, displays: [DisplayInfo]) -> DisplayInfo? {
        guard !displays.isEmpty else {
            return nil
        }

        let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
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

}

private func eventMatchesHotkey(event: CGEvent, key: String, modifiers: [String]) -> Bool {
    guard let expectedKeyCode = keyCode(for: key) else {
        return false
    }

    let actualKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    guard actualKeyCode == expectedKeyCode else {
        return false
    }

    let expected = Set(modifiers.map { $0.lowercased() })
    return eventModifierSet(flags: event.flags) == expected
}

private func eventModifierSet(flags: CGEventFlags) -> Set<String> {
    var result = Set<String>()
    if flags.contains(.maskCommand) {
        result.insert("cmd")
    }
    if flags.contains(.maskShift) {
        result.insert("shift")
    }
    if flags.contains(.maskControl) {
        result.insert("ctrl")
    }
    if flags.contains(.maskAlternate) {
        result.insert("alt")
    }
    if flags.contains(.maskSecondaryFn) {
        result.insert("fn")
    }
    return result
}

private func appHotKeyPressedHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotkeyPressed(event: event)
}

private func appHotKeyReleasedHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<ShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    return manager.handleHotkeyReleased(event: event)
}

private func appEventTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<ShortcutManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEventTap(type: type, event: event)
}

private func canonicalHotkeyKey(_ key: String) -> String {
    switch key.lowercased() {
    case "`", "grave", "backtick":
        return "grave"
    default:
        return key.lowercased()
    }
}

private func keyCode(for key: String) -> Int? {
    switch canonicalHotkeyKey(key) {
    case "a": return Int(kVK_ANSI_A)
    case "b": return Int(kVK_ANSI_B)
    case "c": return Int(kVK_ANSI_C)
    case "d": return Int(kVK_ANSI_D)
    case "e": return Int(kVK_ANSI_E)
    case "f": return Int(kVK_ANSI_F)
    case "g": return Int(kVK_ANSI_G)
    case "h": return Int(kVK_ANSI_H)
    case "i": return Int(kVK_ANSI_I)
    case "j": return Int(kVK_ANSI_J)
    case "k": return Int(kVK_ANSI_K)
    case "l": return Int(kVK_ANSI_L)
    case "m": return Int(kVK_ANSI_M)
    case "n": return Int(kVK_ANSI_N)
    case "o": return Int(kVK_ANSI_O)
    case "p": return Int(kVK_ANSI_P)
    case "q": return Int(kVK_ANSI_Q)
    case "r": return Int(kVK_ANSI_R)
    case "s": return Int(kVK_ANSI_S)
    case "t": return Int(kVK_ANSI_T)
    case "u": return Int(kVK_ANSI_U)
    case "v": return Int(kVK_ANSI_V)
    case "w": return Int(kVK_ANSI_W)
    case "x": return Int(kVK_ANSI_X)
    case "y": return Int(kVK_ANSI_Y)
    case "z": return Int(kVK_ANSI_Z)
    case "0": return Int(kVK_ANSI_0)
    case "1": return Int(kVK_ANSI_1)
    case "2": return Int(kVK_ANSI_2)
    case "3": return Int(kVK_ANSI_3)
    case "4": return Int(kVK_ANSI_4)
    case "5": return Int(kVK_ANSI_5)
    case "6": return Int(kVK_ANSI_6)
    case "7": return Int(kVK_ANSI_7)
    case "8": return Int(kVK_ANSI_8)
    case "9": return Int(kVK_ANSI_9)
    case "grave": return Int(kVK_ANSI_Grave)
    case "tab": return Int(kVK_Tab)
    case "enter": return Int(kVK_Return)
    case "esc": return Int(kVK_Escape)
    case "space": return Int(kVK_Space)
    case "left": return Int(kVK_LeftArrow)
    case "right": return Int(kVK_RightArrow)
    case "up": return Int(kVK_UpArrow)
    case "down": return Int(kVK_DownArrow)
    case "home": return Int(kVK_Home)
    case "end": return Int(kVK_End)
    case "pageup": return Int(kVK_PageUp)
    case "pagedown": return Int(kVK_PageDown)
    case "f1": return Int(kVK_F1)
    case "f2": return Int(kVK_F2)
    case "f3": return Int(kVK_F3)
    case "f4": return Int(kVK_F4)
    case "f5": return Int(kVK_F5)
    case "f6": return Int(kVK_F6)
    case "f7": return Int(kVK_F7)
    case "f8": return Int(kVK_F8)
    case "f9": return Int(kVK_F9)
    case "f10": return Int(kVK_F10)
    case "f11": return Int(kVK_F11)
    case "f12": return Int(kVK_F12)
    case "f13": return Int(kVK_F13)
    case "f14": return Int(kVK_F14)
    case "f15": return Int(kVK_F15)
    case "f16": return Int(kVK_F16)
    case "f17": return Int(kVK_F17)
    case "f18": return Int(kVK_F18)
    case "f19": return Int(kVK_F19)
    case "f20": return Int(kVK_F20)
    default: return nil
    }
}

private func carbonModifiers(_ modifiers: [String]) -> UInt32 {
    var result: UInt32 = 0
    for modifier in modifiers {
        switch modifier.lowercased() {
        case "cmd":
            result |= UInt32(cmdKey)
        case "shift":
            result |= UInt32(shiftKey)
        case "ctrl":
            result |= UInt32(controlKey)
        case "alt":
            result |= UInt32(optionKey)
        case "fn":
            result |= UInt32(kEventKeyModifierFnMask)
        default:
            continue
        }
    }
    return result
}

private func normalizedKey(from event: CGEvent) -> String {
    if let special = specialKey(for: event) {
        return special
    }

    var chars = [UniChar](repeating: 0, count: 4)
    var length: Int = 0
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return "" }
    return String(utf16CodeUnits: chars, count: length).lowercased()
}

private func specialKey(for event: CGEvent) -> String? {
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    switch keyCode {
    case Int(kVK_ANSI_Grave):
        return "grave"
    case Int(kVK_Tab):
        return "tab"
    case Int(kVK_Return):
        return "enter"
    case Int(kVK_Escape):
        return "esc"
    case Int(kVK_Space):
        return "space"
    case Int(kVK_LeftArrow):
        return "left"
    case Int(kVK_RightArrow):
        return "right"
    case Int(kVK_UpArrow):
        return "up"
    case Int(kVK_DownArrow):
        return "down"
    case Int(kVK_Home):
        return "home"
    case Int(kVK_End):
        return "end"
    case Int(kVK_PageUp):
        return "pageup"
    case Int(kVK_PageDown):
        return "pagedown"
    case Int(kVK_F1):
        return "f1"
    case Int(kVK_F2):
        return "f2"
    case Int(kVK_F3):
        return "f3"
    case Int(kVK_F4):
        return "f4"
    case Int(kVK_F5):
        return "f5"
    case Int(kVK_F6):
        return "f6"
    case Int(kVK_F7):
        return "f7"
    case Int(kVK_F8):
        return "f8"
    case Int(kVK_F9):
        return "f9"
    case Int(kVK_F10):
        return "f10"
    case Int(kVK_F11):
        return "f11"
    case Int(kVK_F12):
        return "f12"
    case Int(kVK_F13):
        return "f13"
    case Int(kVK_F14):
        return "f14"
    case Int(kVK_F15):
        return "f15"
    case Int(kVK_F16):
        return "f16"
    case Int(kVK_F17):
        return "f17"
    case Int(kVK_F18):
        return "f18"
    case Int(kVK_F19):
        return "f19"
    case Int(kVK_F20):
        return "f20"
    default:
        return nil
    }
}

private final class WeakSwitcherOverlayControllerBox: @unchecked Sendable {
    weak var controller: SwitcherOverlayController?

    init(controller: SwitcherOverlayController) {
        self.controller = controller
    }
}

private struct SwitcherOverlayComponents: @unchecked Sendable {
    let panel: NSPanel
    let viewModel: SwitcherOverlayViewModel
}

private final class SwitcherOverlayController {
    private let panel: NSPanel
    private let viewModel: SwitcherOverlayViewModel
    private var iconCache: [String: NSImage] = [:]
    private var previewCache: [String: NSImage] = [:]
    private var pendingPreviewIDs: Set<String> = []
    private var previewCaptureMaxPixels: CGFloat = 0

    init() {
        let components: SwitcherOverlayComponents
        if Thread.isMainThread {
            components = MainActor.assumeIsolated {
                Self.makeComponentsOnMain()
            }
        } else {
            var tmp: SwitcherOverlayComponents?
            DispatchQueue.main.sync {
                tmp = MainActor.assumeIsolated {
                    Self.makeComponentsOnMain()
                }
            }
            guard let built = tmp else {
                fatalError("Failed to initialize switcher overlay")
            }
            components = built
        }

        self.panel = components.panel
        self.viewModel = components.viewModel
    }

    func show(candidates: [SwitcherCandidate], selectedIndex: Int) {
        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                managerBox.controller?.showOnMain(candidates: candidates, selectedIndex: selectedIndex)
            }
            return
        }

        let snapshot = candidates
        DispatchQueue.main.async {
            guard let controller = managerBox.controller else {
                return
            }
            MainActor.assumeIsolated {
                controller.showOnMain(candidates: snapshot, selectedIndex: selectedIndex)
            }
        }
    }

    func hide() {
        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                managerBox.controller?.hideOnMain()
            }
            return
        }

        DispatchQueue.main.async {
            guard let controller = managerBox.controller else {
                return
            }
            MainActor.assumeIsolated {
                controller.hideOnMain()
            }
        }
    }

    @MainActor
    private func showOnMain(candidates: [SwitcherCandidate], selectedIndex: Int) {
        let isInitialPresentation = !panel.isVisible
        let shouldAnimateSelection = panel.isVisible
        let displayFrame = panelDisplayFrame()
        let metrics = makeMetrics(
            candidateCount: candidates.count,
            displayFrame: displayFrame
        )

        self.viewModel.set(
            candidates: candidates,
            selectedIndex: selectedIndex,
            previews: self.previewCache,
            icons: self.iconCache,
            metrics: metrics,
            shouldAnimateSelection: shouldAnimateSelection
        )
        self.updatePanelFrame(
            metrics: metrics,
            displayFrame: displayFrame,
            forceReposition: !self.panel.isVisible
        )

        if !self.panel.isVisible {
            self.panel.orderFrontRegardless()
        }

        self.prefetchAssets(
            for: candidates,
            metrics: metrics,
            forceRefreshVisiblePreviews: isInitialPresentation
        )
    }

    @MainActor
    private func hideOnMain() {
        panel.orderOut(nil)
        viewModel.resetPresentationState()
    }

    @MainActor
    private func prefetchAssets(
        for candidates: [SwitcherCandidate],
        metrics: SwitcherOverlayMetrics,
        forceRefreshVisiblePreviews: Bool
    ) {
        self.prefetchIcons(for: candidates)
        self.prefetchWindowPreviews(
            for: candidates,
            maxPixels: desiredPreviewCapturePixels(for: metrics),
            forceRefreshVisiblePreviews: forceRefreshVisiblePreviews
        )
    }

    @MainActor
    private func prefetchIcons(for candidates: [SwitcherCandidate]) {
        var iconAdded = false
        for candidate in candidates where self.iconCache[candidate.id] == nil {
            guard let icon = makeIcon(for: candidate) else {
                continue
            }
            self.iconCache[candidate.id] = icon
            iconAdded = true
        }
        if iconAdded {
            self.viewModel.setIcons(iconCache, for: Set(candidates.map(\.id)))
        }

        trimCacheIfNeeded()
    }

    @MainActor
    private func prefetchWindowPreviews(
        for candidates: [SwitcherCandidate],
        maxPixels: CGFloat,
        forceRefreshVisiblePreviews: Bool
    ) {
        let effectiveMaxPixels = min(
            SwitcherOverlayLayout.thumbnailMaxPixels,
            max(SwitcherOverlayLayout.minPreviewCapturePixels, maxPixels)
        )
        if effectiveMaxPixels > previewCaptureMaxPixels + 32 {
            previewCaptureMaxPixels = effectiveMaxPixels
            previewCache.removeAll(keepingCapacity: true)
            pendingPreviewIDs.removeAll(keepingCapacity: true)
        } else if previewCaptureMaxPixels <= 0 {
            previewCaptureMaxPixels = effectiveMaxPixels
        }

        let jobs = SwitcherPreviewCapturePlanner.plannedJobs(
            candidates: candidates,
            cachedPreviewIDs: Set(self.previewCache.keys),
            pendingPreviewIDs: self.pendingPreviewIDs,
            forceRefreshVisiblePreviews: forceRefreshVisiblePreviews
        ).reduce(into: [String: CGWindowID]()) { partialResult, item in
            partialResult[item.key] = CGWindowID(item.value)
        }

        guard !jobs.isEmpty else {
            return
        }

        for candidateID in jobs.keys {
            self.pendingPreviewIDs.insert(candidateID)
        }

        let managerBox = WeakSwitcherOverlayControllerBox(controller: self)
        let requestedMaxPixels = effectiveMaxPixels
        Task.detached(priority: .userInitiated) {
            let previews = await SwitcherOverlayController.captureWindowPreviews(
                jobs: jobs,
                maxPixels: requestedMaxPixels
            )
            await MainActor.run {
                guard let controller = managerBox.controller else {
                    return
                }

                for candidateID in jobs.keys {
                    controller.pendingPreviewIDs.remove(candidateID)
                }

                if requestedMaxPixels + 1 < controller.previewCaptureMaxPixels {
                    return
                }

                if !previews.isEmpty {
                    for (candidateID, image) in previews {
                        controller.previewCache[candidateID] = image
                    }
                    controller.viewModel.setPreviews(controller.previewCache, for: Set(jobs.keys))
                }
            }
        }
    }

    private static func captureWindowPreviews(
        jobs: [String: CGWindowID],
        maxPixels: CGFloat
    ) async -> [String: NSImage] {
        guard !jobs.isEmpty else {
            return [:]
        }

        guard let shareableContent = try? await SCShareableContent.current else {
            return [:]
        }

        let windowsByID = Dictionary(uniqueKeysWithValues: shareableContent.windows.map { ($0.windowID, $0) })
        var results: [String: NSImage] = [:]
        for (candidateID, windowID) in jobs {
            guard let window = windowsByID[windowID],
                  let image = await captureWindowPreview(window: window, maxPixels: maxPixels)
            else {
                continue
            }
            results[candidateID] = image
        }
        return results
    }

    private static func captureWindowPreview(window: SCWindow, maxPixels: CGFloat) async -> NSImage? {
        let frame = window.frame
        let maxDimension = max(frame.width, frame.height)
        guard maxDimension > 0 else {
            return nil
        }

        let scale = min(1.0, maxPixels / maxDimension)
        let config = SCStreamConfiguration()
        config.width = Int(max(1, (frame.width * scale).rounded()))
        config.height = Int(max(1, (frame.height * scale).rounded()))
        config.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    @MainActor
    private func desiredPreviewCapturePixels(for metrics: SwitcherOverlayMetrics) -> CGFloat {
        let scale = panel.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        let base = max(metrics.cardWidth, metrics.previewHeight)
        let desired = ceil(base * scale * 3.0)
        return min(
            SwitcherOverlayLayout.thumbnailMaxPixels,
            max(SwitcherOverlayLayout.minPreviewCapturePixels, desired)
        )
    }

    @MainActor
    private func makeIcon(for candidate: SwitcherCandidate) -> NSImage? {
        guard let bundleID = candidate.bundleID else {
            return nil
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let icon = running.icon
        {
            return icon
        }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    @MainActor
    private func trimCacheIfNeeded() {
        if previewCache.count > SwitcherOverlayLayout.cacheLimit {
            previewCache.removeAll(keepingCapacity: true)
            pendingPreviewIDs.removeAll(keepingCapacity: true)
        }
        if iconCache.count > SwitcherOverlayLayout.cacheLimit {
            iconCache.removeAll(keepingCapacity: true)
        }
    }

    @MainActor
    private func updatePanelFrame(
        metrics: SwitcherOverlayMetrics,
        displayFrame: NSRect,
        forceReposition: Bool
    ) {
        let targetWidth = metrics.panelWidth
        let targetHeight = metrics.panelHeight
        let currentFrame = panel.frame
        if !forceReposition,
           abs(currentFrame.width - targetWidth) < 0.5,
           abs(currentFrame.height - targetHeight) < 0.5
        {
            return
        }

        let newFrame = NSRect(
            x: round(displayFrame.midX - targetWidth / 2),
            y: round(displayFrame.midY - targetHeight / 2),
            width: targetWidth,
            height: targetHeight
        )
        panel.setFrame(newFrame, display: true)
    }

    @MainActor
    private func makeMetrics(candidateCount: Int, displayFrame: NSRect) -> SwitcherOverlayMetrics {
        let effectiveCount = max(candidateCount, SwitcherOverlayLayout.minLayoutCards)
        let visibleCards = min(effectiveCount, SwitcherOverlayLayout.maxVisibleCards)

        let widthLimit = max(620, floor(displayFrame.width - 24))
        let heightLimit = max(210, floor(displayFrame.height - 24))

        let preferredWidth = min(
            widthLimit,
            max(
                SwitcherOverlayLayout.minPanelWidth,
                floor(displayFrame.width * SwitcherOverlayLayout.panelWidthRatio)
            )
        )
        let preferredHeight = min(
            heightLimit,
            max(
                SwitcherOverlayLayout.minPanelHeight,
                floor(displayFrame.height * SwitcherOverlayLayout.panelHeightRatio)
            )
        )

        let panelPadding = min(
            SwitcherOverlayLayout.maxPanelPadding,
            max(
                SwitcherOverlayLayout.minPanelPadding,
                floor(min(preferredWidth, preferredHeight) * 0.06)
            )
        )
        let horizontalPadding = panelPadding
        let verticalPadding = panelPadding
        let cardSpacing = max(12, floor(preferredWidth * 0.012))
        let desiredCardWidth = min(
            SwitcherOverlayLayout.maxCardWidth,
            max(
                SwitcherOverlayLayout.minCardWidth,
                floor(displayFrame.width * SwitcherOverlayLayout.cardWidthRatio)
            )
        )
        let desiredCardHeight = min(
            SwitcherOverlayLayout.maxCardHeight,
            max(
                SwitcherOverlayLayout.minCardHeight,
                floor(desiredCardWidth * SwitcherOverlayLayout.cardHeightRatio)
            )
        )
        let desiredPanelWidth = horizontalPadding * 2
            + CGFloat(visibleCards) * desiredCardWidth
            + CGFloat(max(visibleCards - 1, 0)) * cardSpacing
        let panelWidth = min(
            preferredWidth,
            max(SwitcherOverlayLayout.minPanelWidth, desiredPanelWidth)
        )
        let desiredPanelHeight = verticalPadding * 2 + desiredCardHeight
        let panelHeight = min(
            heightLimit,
            min(preferredHeight, max(SwitcherOverlayLayout.minPanelHeight, desiredPanelHeight))
        )

        let cardWidthRaw = (panelWidth
            - horizontalPadding * 2
            - CGFloat(max(visibleCards - 1, 0)) * cardSpacing
        ) / CGFloat(visibleCards)
        let cardWidth = min(
            SwitcherOverlayLayout.maxCardWidth,
            max(SwitcherOverlayLayout.minCardWidth, floor(cardWidthRaw))
        )
        let cardHeight = min(
            SwitcherOverlayLayout.maxCardHeight,
            max(SwitcherOverlayLayout.minCardHeight, floor(panelHeight - verticalPadding * 2))
        )
        let previewHeight = max(92, min(cardHeight - 48, floor(cardHeight * 0.60)))

        return SwitcherOverlayMetrics(
            panelWidth: panelWidth,
            panelHeight: panelHeight,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            cardSpacing: cardSpacing,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            previewHeight: previewHeight,
            maxVisibleCards: SwitcherOverlayLayout.maxVisibleCards
        )
    }

    @MainActor
    private func panelDisplayFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        if let matchingScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return matchingScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
    }

    @MainActor
    private static func makeComponentsOnMain() -> SwitcherOverlayComponents {
        let viewModel = SwitcherOverlayViewModel()
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SwitcherOverlayLayout.initialPanelWidth,
                height: SwitcherOverlayLayout.initialPanelHeight
            ),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        let hostingView = NSHostingView(rootView: SwitcherOverlayView(viewModel: viewModel))

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        hostingView.frame = NSRect(
            origin: .zero,
            size: panel.contentRect(forFrameRect: panel.frame).size
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        return SwitcherOverlayComponents(panel: panel, viewModel: viewModel)
    }

}

private enum SwitcherOverlayLayout {
    static let maxVisibleCards = 6
    static let minLayoutCards = 1
    static let panelWidthRatio: CGFloat = 0.72
    static let panelHeightRatio: CGFloat = 0.31
    static let minPanelWidth: CGFloat = 420
    static let minPanelHeight: CGFloat = 196
    static let minCardWidth: CGFloat = 176
    static let maxCardWidth: CGFloat = 330
    static let minCardHeight: CGFloat = 142
    static let maxCardHeight: CGFloat = 240
    static let cardHeightRatio: CGFloat = 0.74
    static let cardWidthRatio: CGFloat = 0.136
    static let minPanelPadding: CGFloat = 16
    static let maxPanelPadding: CGFloat = 20
    static let initialPanelWidth: CGFloat = 820
    static let initialPanelHeight: CGFloat = 256
    static let thumbnailMaxPixels: CGFloat = 2_048
    static let minPreviewCapturePixels: CGFloat = 960
    static let cacheLimit = 160
}

private struct SwitcherOverlayMetrics {
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cardSpacing: CGFloat
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let previewHeight: CGFloat
    let maxVisibleCards: Int

    static let initial = SwitcherOverlayMetrics(
        panelWidth: SwitcherOverlayLayout.initialPanelWidth,
        panelHeight: SwitcherOverlayLayout.initialPanelHeight,
        horizontalPadding: 18,
        verticalPadding: 18,
        cardSpacing: 10,
        cardWidth: 236,
        cardHeight: 174,
        previewHeight: 104,
        maxVisibleCards: SwitcherOverlayLayout.maxVisibleCards
    )
}

private final class SwitcherOverlayViewModel: ObservableObject {
    @Published private(set) var candidates: [SwitcherCandidate] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var previewsByID: [String: NSImage] = [:]
    @Published private(set) var iconsByID: [String: NSImage] = [:]
    @Published private(set) var metrics = SwitcherOverlayMetrics.initial
    @Published private(set) var shouldAnimateSelection = false

    func set(
        candidates: [SwitcherCandidate],
        selectedIndex: Int,
        previews: [String: NSImage],
        icons: [String: NSImage],
        metrics: SwitcherOverlayMetrics,
        shouldAnimateSelection: Bool
    ) {
        self.shouldAnimateSelection = shouldAnimateSelection
        self.candidates = candidates
        self.selectedIndex = selectedIndex
        self.metrics = metrics
        let ids = Set(candidates.map(\.id))
        previewsByID = previews.filter { ids.contains($0.key) }
        iconsByID = icons.filter { ids.contains($0.key) }
    }

    func resetPresentationState() {
        shouldAnimateSelection = false
        candidates = []
        selectedIndex = 0
    }

    func setPreviews(_ previews: [String: NSImage], for candidateIDs: Set<String>) {
        previewsByID = previews.filter { candidateIDs.contains($0.key) }
    }

    func setIcons(_ icons: [String: NSImage], for candidateIDs: Set<String>) {
        iconsByID = icons.filter { candidateIDs.contains($0.key) }
    }

    func select(candidateID: String) {
        NotificationCenter.default.post(
            name: ShortcutManager.switcherOverlaySelectionNotification,
            object: nil,
            userInfo: [ShortcutManager.switcherOverlaySelectionCandidateIDKey: candidateID]
        )
    }
}

private struct SwitcherOverlayView: View {
    @ObservedObject var viewModel: SwitcherOverlayViewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(red: 0.18, green: 0.20, blue: 0.24).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1.2)
                )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: viewModel.metrics.cardSpacing) {
                    ForEach(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
                        SwitcherCandidateCardView(
                            candidate: candidate,
                            isSelected: index == viewModel.selectedIndex,
                            preview: viewModel.previewsByID[candidate.id],
                            icon: viewModel.iconsByID[candidate.id],
                            metrics: viewModel.metrics,
                            onSelect: { viewModel.select(candidateID: candidate.id) }
                        )
                    }
                }
                .padding(.horizontal, viewModel.metrics.horizontalPadding)
                .padding(.vertical, viewModel.metrics.verticalPadding)
            }
            .scrollDisabled(viewModel.candidates.count <= viewModel.metrics.maxVisibleCards)
        }
        .clipShape(.rect(cornerRadius: 22))
        .padding(0.5)
        .animation(
            viewModel.shouldAnimateSelection ? .snappy(duration: 0.18) : nil,
            value: viewModel.selectedIndex
        )
    }
}

private struct SwitcherCandidateCardView: View {
    let candidate: SwitcherCandidate
    let isSelected: Bool
    let preview: NSImage?
    let icon: NSImage?
    let metrics: SwitcherOverlayMetrics
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 7 : 10) {
            headerRow
            bundleRow
            windowLikePreview
            .frame(height: metrics.previewHeight)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1.1)
            )
        }
        .padding(compactLayout ? 10 : 14)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .topLeading)
        .background(Color.white.opacity(isSelected ? 0.34 : 0.2))
        .clipShape(.rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.22),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .scaleEffect(isSelected ? 1.028 : 1.0)
        .shadow(
            color: Color.black.opacity(isSelected ? 0.24 : 0.13),
            radius: isSelected ? 16 : 9,
            y: isSelected ? 6 : 3
        )
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.title)")
    }

    private var compactLayout: Bool {
        metrics.cardWidth < 220
    }

    private var headerRow: some View {
        HStack(spacing: compactLayout ? 6 : 8) {
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "rectangle.on.rectangle")
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: compactLayout ? 18 : 20, height: compactLayout ? 18 : 20)

            Text(candidate.title)
                .font(.system(size: compactLayout ? 14 : 17, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let quickKey = candidate.quickKey {
                Text(quickKey.uppercased())
                    .font(.system(size: compactLayout ? 10 : 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, compactLayout ? 5 : 7)
                    .padding(.vertical, compactLayout ? 2 : 3)
                    .background(Color.white.opacity(0.14))
                    .clipShape(.rect(cornerRadius: 6))
            }
        }
        .foregroundStyle(Color.white)
    }

    private var bundleRow: some View {
        Group {
            if let bundleID = candidate.bundleID {
                Text(bundleID)
                    .font(.system(size: compactLayout ? 11 : 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: compactLayout ? 11 : 12, weight: .regular))
            }
        }
    }

    private var windowLikePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: compactLayout ? 4 : 5) {
                Circle()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)
                Circle()
                    .fill(Color.yellow.opacity(0.82))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)
                Circle()
                    .fill(Color.green.opacity(0.82))
                    .frame(width: compactLayout ? 5 : 6, height: compactLayout ? 5 : 6)

                Spacer(minLength: 0)

                Text(candidate.source == .window ? "Window" : "Session")
                    .font(.system(size: compactLayout ? 8 : 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, compactLayout ? 7 : 8)
                .frame(height: compactLayout ? 19 : 21)
                .background(Color.white.opacity(0.18))

            ZStack {
                if let preview {
                    Color.black.opacity(0.1)
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                } else {
                    LinearGradient(
                        colors: [Color.white.opacity(0.2), Color.black.opacity(0.14)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    Group {
                        if let icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .padding(compactLayout ? 16 : 24)
                                .opacity(0.56)
                        } else {
                            Image(systemName: "macwindow")
                                .font(.system(size: compactLayout ? 26 : 34))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                    }
                }
            }
        }
    }
}
