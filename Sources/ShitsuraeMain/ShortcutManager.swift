@preconcurrency import AppKit
import Carbon.HIToolbox
import Foundation
import ShitsuraeCore

private final class WeakShortcutManagerBox: @unchecked Sendable {
    weak var manager: ShortcutManager?

    init(manager: ShortcutManager) {
        self.manager = manager
    }
}

final class ShortcutManager {
    private enum CycleStateKey: Hashable {
        case native(Int)
        case virtual(layoutName: String, spaceID: Int)

        init(scope: InteractiveShortcutScope) {
            switch scope {
            case let .native(spaceID):
                self = .native(spaceID)
            case let .virtual(layoutName, spaceID):
                self = .virtual(layoutName: layoutName, spaceID: spaceID)
            }
        }
    }

    static let switcherOverlaySelectionNotification = Notification.Name("SwitcherOverlaySelectionNotification")
    static let switcherOverlaySelectionCandidateIDKey = "candidateID"

    private enum HotkeyAction {
        case focus(slot: Int)
        case moveCurrentWindowToSpace(spaceID: Int)
        case switchVirtualSpace(spaceID: Int)
        case nextWindow
        case prevWindow
        case switcher
        case switcherReverse
        case globalAction(index: Int)

        var shortcutID: String {
            switch self {
            case let .focus(slot):
                return "focusBySlot:\(slot)"
            case let .moveCurrentWindowToSpace(spaceID):
                return "moveCurrentWindowToSpace:\(spaceID)"
            case let .switchVirtualSpace(spaceID):
                return "switchVirtualSpace:\(spaceID)"
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

    private let commandService: CommandService
    private let stateStore: RuntimeStateStore
    private let configLoader = ConfigLoader()
    private let logger = ShitsuraeLogger()
    private let focusedWindowProvider: () -> WindowSnapshot?

    private var hotKeyPressedEventHandlerRef: EventHandlerRef?
    private var hotKeyReleasedEventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var actionsByHotKeyID: [UInt32: HotkeyAction] = [:]
    private var nextHotKeyID: UInt32 = 1
    private var disabledNativeSymbolicHotKeys: Set<NativeSymbolicHotKey> = []

    private var eventTapPort: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var modifierReleasePollingTimer: Timer?
    private var deferredAppActivationUntil: Date?
    private var pendingDeferredAppActivationWorkItem: DispatchWorkItem?
    private var pendingDeferredAppUnhideWorkItem: DispatchWorkItem?

    private let overlayController = SwitcherOverlayController()
    private var overlaySelectionObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var overlaySession: ShortcutOverlaySession?
    private var currentIgnoreFocusRules: IgnoreRuleSet?
    private var spaceCycleStates: [CycleStateKey: SpaceCycleState] = [:]
    private var lastActiveSpaceChangeAt: Date?
    private let activeSpaceSettleDelay: TimeInterval = 0.15
    private var lastFollowFocusSwitchAt: Date?
    private let followFocusDebounceInterval: TimeInterval = 0.5
    private var followFocusEnabled: Bool = false
    private var lastCarbonShortcutID: String?
    private var lastCarbonShortcutAt: Date?
    private let eventTapDuplicateThreshold: TimeInterval = 0.12
    private var lastEventTapOverlayAdvanceShortcutID: String?
    private var lastEventTapOverlayAdvanceAt: Date?
    private let overlayAdvanceDedupeThreshold: TimeInterval = 0.12
    private let appActivationGraceInterval: TimeInterval = 0.18
    private var loggedShortcutUnavailableHints: Set<String> = []

    private(set) var currentShortcuts = ResolvedShortcuts(from: nil)
    private var currentLoadedConfig: LoadedConfig?

    init(
        commandService: CommandService,
        stateStore: RuntimeStateStore = RuntimeStateStore(),
        focusedWindowProvider: @escaping () -> WindowSnapshot? = { WindowQueryService.focusedWindow() }
    ) {
        self.commandService = commandService
        self.stateStore = stateStore
        self.focusedWindowProvider = focusedWindowProvider
        let managerBox = WeakShortcutManagerBox(manager: self)
        overlaySelectionObserver = NotificationCenter.default.addObserver(
            forName: Self.switcherOverlaySelectionNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let candidateID = notification.userInfo?[Self.switcherOverlaySelectionCandidateIDKey] as? String else {
                return
            }
            managerBox.manager?.acceptOverlay(candidateID: candidateID)
        }
    }

    func start() {
        startWorkspaceObservers()
        reloadConfiguration()
    }

    func stop() {
        if let overlaySelectionObserver {
            NotificationCenter.default.removeObserver(overlaySelectionObserver)
            self.overlaySelectionObserver = nil
        }
        stopWorkspaceObservers()
        lastFollowFocusSwitchAt = nil
        unregisterHotkeys()
        stopEventTap()
        stopModifierReleasePolling()
        cancelDeferredWorkspaceEventHandling()
        restoreNativeSwitcherHotKeys()
        overlaySession = nil
        overlayController.hide()
        resetCycleState()
        lastActiveSpaceChangeAt = nil
        lastCarbonShortcutID = nil
        lastCarbonShortcutAt = nil
        lastEventTapOverlayAdvanceShortcutID = nil
        lastEventTapOverlayAdvanceAt = nil
        loggedShortcutUnavailableHints.removeAll()
    }

    func reloadConfiguration() {
        unregisterHotkeys()
        stopEventTap()
        stopModifierReleasePolling()
        cancelDeferredWorkspaceEventHandling()

        do {
            let loaded = try configLoader.loadFromDefaultDirectory()
            currentLoadedConfig = loaded
            currentShortcuts = loaded.config.resolvedShortcuts
            currentIgnoreFocusRules = loaded.config.ignore?.focus
            followFocusEnabled = loaded.config.resolvedFollowFocus
            overlayController.setShowsWindowThumbnails(loaded.config.overlay?.showThumbnails == true)
        } catch {
            currentLoadedConfig = nil
            currentShortcuts = ResolvedShortcuts(from: nil)
            currentIgnoreFocusRules = nil
            followFocusEnabled = false
            overlayController.setShowsWindowThumbnails(false)
        }

        scheduleBrowserProfileCachePrewarm()
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

        if isConfiguredVirtualMode {
            for spaceID in 1 ... 9 {
                if let definition = shortcuts.moveCurrentWindowToSpace[spaceID] {
                    registerHotkey(definition: definition, action: .moveCurrentWindowToSpace(spaceID: spaceID))
                }
            }

            for spaceID in 1 ... 9 {
                if let definition = shortcuts.switchVirtualSpace[spaceID] {
                    registerHotkey(definition: definition, action: .switchVirtualSpace(spaceID: spaceID))
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

    private func scheduleBrowserProfileCachePrewarm() {
        Task.detached(priority: .utility) {
            WindowQueryService.prewarmBrowserProfileDirectoryCache()
        }
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
        if shouldSuppressCarbonOverlayAdvance(for: action) {
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
            cancelOverlay()
            resetCycleState()
            _ = commandService.focus(slot: slot)
        case let .moveCurrentWindowToSpace(spaceID):
            cancelOverlay()
            resetCycleState()
            let target = focusedWindowProvider().map {
                WindowTargetSelector(windowID: $0.windowID, bundleID: nil, title: nil)
            }
            let result = commandService.windowWorkspace(target: target, spaceID: spaceID, json: true)
            logShortcutCommandResult(
                shortcutID: action.shortcutID,
                command: "window.workspace",
                result: result,
                fields: ["spaceID": spaceID]
            )
        case let .switchVirtualSpace(spaceID):
            cancelOverlay()
            resetCycleState()
            let result = commandService.spaceSwitch(spaceID: spaceID, json: true)
            logShortcutCommandResult(
                shortcutID: action.shortcutID,
                command: "space.switch",
                result: result,
                fields: ["spaceID": spaceID]
            )
        case .nextWindow:
            if currentShortcuts.cycleMode == .direct {
                cancelOverlay()
            }
            scheduleCycleFocus(forward: true, action: action)
        case .prevWindow:
            if currentShortcuts.cycleMode == .direct {
                cancelOverlay()
            }
            scheduleCycleFocus(forward: false, action: action)
        case .switcher:
            resetCycleState()
            presentOrAdvanceSwitcher(forward: true, action: action)
        case .switcherReverse:
            resetCycleState()
            presentOrAdvanceSwitcher(forward: false, action: action)
        case let .globalAction(index):
            cancelOverlay()
            resetCycleState()
            executeGlobalAction(index: index)
        }
    }

    private func dispatchRelease(action: HotkeyAction) {
        guard !isDisabled(action.shortcutID) else {
            return
        }

        switch action {
        case .nextWindow, .prevWindow, .switcher, .switcherReverse:
            handleOverlayTriggerReleased(action: action)
        case .focus, .moveCurrentWindowToSpace, .switchVirtualSpace, .globalAction:
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

    private func scheduleCycleFocus(forward: Bool, action: HotkeyAction) {
        let managerBox = WeakShortcutManagerBox(manager: self)
        DispatchQueue.main.async {
            managerBox.manager?.executeScheduledCycleFocus(forward: forward, action: action)
        }
    }

    private func executeScheduledCycleFocus(forward: Bool, action: HotkeyAction) {
        let now = Date()
        let delay = CycleFocusTiming(lastActiveSpaceChangeAt: lastActiveSpaceChangeAt)
            .dispatchDelay(now: now, activeSpaceSettleDelay: activeSpaceSettleDelay)

        guard delay > 0 else {
            cycleFocus(forward: forward, action: action)
            return
        }

        let managerBox = WeakShortcutManagerBox(manager: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            managerBox.manager?.executeScheduledCycleFocus(forward: forward, action: action)
        }
    }

    private func cycleFocus(forward: Bool, action: HotkeyAction) {
        if currentShortcuts.cycleMode == .overlay {
            presentOrAdvanceCycleOverlay(forward: forward, action: action)
            return
        }

        let candidates = buildCycleCandidatesForCurrentSpace()
        guard !candidates.isEmpty else {
            logger.log(level: "error", event: "cycle.candidates.empty")
            return
        }

        let selectedIndex = initialSwitcherSelectionIndex(candidates: candidates, forward: forward)
        let candidate = candidates[selectedIndex]
        logger.log(
            event: "cycle.select",
            fields: [
                "forward": forward,
                "selectedIndex": selectedIndex,
                "candidateID": candidate.id,
                "candidateBundleID": candidate.bundleID ?? "",
            ]
        )
        activate(candidate: candidate)
    }

    private func presentOrAdvanceCycleOverlay(forward: Bool, action: HotkeyAction) {
        if let session = overlaySession, session.kind == .cycle {
            var nextSession = session
            nextSession.advance(forward: forward, holdModifiers: holdModifiers(for: action))
            overlaySession = nextSession
            if let overlaySession {
                overlayController.show(candidates: overlaySession.candidates, selectedIndex: overlaySession.selectedIndex)
            }
            return
        }

        if overlaySession != nil {
            cancelOverlay()
        }

        let candidates = buildCycleCandidatesForCurrentSpace()
        guard !candidates.isEmpty else {
            logger.log(level: "error", event: "cycle.candidates.empty")
            return
        }

        let initialIndex = initialSwitcherSelectionIndex(candidates: candidates, forward: forward)
        overlaySession = ShortcutOverlaySession(
            kind: .cycle,
            candidates: candidates,
            selectedIndex: initialIndex,
            quickKeys: currentShortcuts.cycleQuickKeys,
            acceptKeys: currentShortcuts.cycleAcceptKeys,
            cancelKeys: currentShortcuts.cycleCancelKeys,
            holdModifiers: holdModifiers(for: action)
        )
        logger.log(
            event: "cycle.present",
            fields: [
                "candidateCount": candidates.count,
                "selectedIndex": initialIndex,
                "selectedID": candidates[initialIndex].id,
            ]
        )
        overlayController.show(candidates: candidates, selectedIndex: initialIndex)
    }

    private func presentOrAdvanceSwitcher(forward: Bool, action: HotkeyAction) {
        if let session = overlaySession, session.kind == .switcher {
            var nextSession = session
            nextSession.advance(forward: forward, holdModifiers: holdModifiers(for: action))
            overlaySession = nextSession
            if let overlaySession {
                overlayController.show(candidates: overlaySession.candidates, selectedIndex: overlaySession.selectedIndex)
            }
            return
        }

        if overlaySession != nil {
            cancelOverlay()
        }

        let candidates = buildSwitcherCandidatesForCurrentSpace()
        guard !candidates.isEmpty else {
            logger.log(level: "error", event: "switcher.candidates.empty")
            return
        }

        let initialIndex = initialSwitcherSelectionIndex(candidates: candidates, forward: forward)
        overlaySession = ShortcutOverlaySession(
            kind: .switcher,
            candidates: candidates,
            selectedIndex: initialIndex,
            quickKeys: currentShortcuts.quickKeys,
            acceptKeys: currentShortcuts.acceptKeys,
            cancelKeys: currentShortcuts.cancelKeys,
            holdModifiers: holdModifiers(for: action)
        )
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
           overlaySession != nil,
           handleOverlayKeyDown(event)
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
           overlaySession != nil,
           handleOverlayFlagsChanged(event)
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

        if isConfiguredVirtualMode {
            for spaceID in 1 ... 9 {
                if let definition = currentShortcuts.moveCurrentWindowToSpace[spaceID],
                   eventMatchesHotkey(event: event, key: definition.key, modifiers: definition.modifiers)
                {
                    return .moveCurrentWindowToSpace(spaceID: spaceID)
                }
            }

            for spaceID in 1 ... 9 {
                if let definition = currentShortcuts.switchVirtualSpace[spaceID],
                   eventMatchesHotkey(event: event, key: definition.key, modifiers: definition.modifiers)
                {
                    return .switchVirtualSpace(spaceID: spaceID)
                }
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
        case .moveCurrentWindowToSpace, .switchVirtualSpace, .switcher, .switcherReverse, .globalAction:
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
        case .moveCurrentWindowToSpace, .switchVirtualSpace, .nextWindow, .prevWindow, .switcher, .switcherReverse, .globalAction:
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

    private func handleOverlayKeyDown(_ event: CGEvent) -> Bool {
        guard var session = overlaySession else { return false }

        let key = normalizedKey(from: event)
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch session.kind {
        case .switcher:
            if key == "tab" {
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

                overlaySession = session
                recordEventTapOverlayAdvance(shortcutID: "switcher")
                overlayController.show(candidates: session.candidates, selectedIndex: session.selectedIndex)
                return true
            }
        case .cycle:
            if let action = actionForEventTap(event) {
                switch action {
                case .nextWindow, .prevWindow:
                    if isAutoRepeat {
                        return true
                    }

                    if isRecentlyHandledByCarbon(shortcutID: action.shortcutID) {
                        return true
                    }

                    let forward = if case .nextWindow = action { true } else { false }
                    session.selectedIndex = forward
                        ? (session.selectedIndex + 1) % session.candidates.count
                        : (session.selectedIndex - 1 + session.candidates.count) % session.candidates.count
                    session.holdModifiers = holdModifiers(for: action)
                    overlaySession = session
                    recordEventTapOverlayAdvance(shortcutID: action.shortcutID)
                    overlayController.show(candidates: session.candidates, selectedIndex: session.selectedIndex)
                    return true
                case .focus, .moveCurrentWindowToSpace, .switchVirtualSpace, .switcher, .switcherReverse, .globalAction:
                    break
                }
            }
        }

        if session.cancelKeys.contains(key) {
            cancelOverlay()
            return true
        }

        if session.acceptKeys.contains(key) {
            acceptOverlay()
            return true
        }

        if let quickIndex = session.candidates.firstIndex(where: { $0.quickKey == key }) {
            session.selectedIndex = quickIndex
            overlaySession = session
            acceptOverlay()
            return true
        }

        return false
    }

    private func handleOverlayFlagsChanged(_ event: CGEvent) -> Bool {
        guard let session = overlaySession else {
            return false
        }

        if !areHoldModifiersActive(session.holdModifiers, flags: event.flags) {
            acceptOverlay()
            return true
        }

        return false
    }

    private func acceptOverlay() {
        guard let session = overlaySession,
              session.candidates.indices.contains(session.selectedIndex)
        else {
            cancelOverlay()
            return
        }

        let candidate = session.candidates[session.selectedIndex]
        logger.log(
            event: session.kind == .switcher ? "switcher.accept" : "cycle.accept",
            fields: [
                "selectedIndex": session.selectedIndex,
                "selectedID": candidate.id,
                "selectedBundleID": candidate.bundleID ?? "",
            ]
        )
        overlaySession = nil
        stopModifierReleasePolling()
        overlayController.hide()
        beginAppActivationGraceWindow()
        let managerBox = WeakShortcutManagerBox(manager: self)
        DispatchQueue.main.async {
            managerBox.manager?.activate(candidate: candidate)
        }
    }

    private func acceptOverlay(candidateID: String) {
        guard let session = overlaySession,
              let selectedIndex = session.candidates.firstIndex(where: { $0.id == candidateID })
        else {
            cancelOverlay()
            return
        }

        var nextSession = session
        nextSession.selectedIndex = selectedIndex
        overlaySession = nextSession
        acceptOverlay()
    }

    private func cancelOverlay() {
        overlaySession = nil
        stopModifierReleasePolling()
        overlayController.hide()
        resetCycleState()
    }

    private func handleOverlayTriggerReleased(action: HotkeyAction) {
        guard let session = overlaySession,
              session.kind == overlayKind(for: action)
        else {
            return
        }

        guard eventTapPort == nil else {
            return
        }

        if !areHoldModifiersActive(session.holdModifiers, flags: CGEventSource.flagsState(.combinedSessionState)) {
            acceptOverlay()
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
        guard let session = overlaySession else {
            stopModifierReleasePolling()
            return
        }

        if !areHoldModifiersActive(session.holdModifiers, flags: CGEventSource.flagsState(.combinedSessionState)) {
            acceptOverlay()
        }
    }

    private func shouldSuppressCarbonOverlayAdvance(for action: HotkeyAction) -> Bool {
        switch action {
        case .nextWindow, .prevWindow, .switcher, .switcherReverse:
            guard lastEventTapOverlayAdvanceShortcutID == action.shortcutID,
                  let lastEventTapOverlayAdvanceAt
            else {
                return false
            }
            return Date().timeIntervalSince(lastEventTapOverlayAdvanceAt) <= overlayAdvanceDedupeThreshold
        case .focus, .moveCurrentWindowToSpace, .switchVirtualSpace, .globalAction:
            return false
        }
    }

    private func recordEventTapOverlayAdvance(shortcutID: String) {
        lastEventTapOverlayAdvanceShortcutID = shortcutID
        lastEventTapOverlayAdvanceAt = Date()
    }

    private func areHoldModifiersActive(_ modifiers: Set<String>, flags: CGEventFlags) -> Bool {
        for modifier in modifiers {
            switch modifier {
            case "cmd":
                if !flags.contains(.maskCommand) { return false }
            case "shift":
                if !flags.contains(.maskShift) { return false }
            case "ctrl":
                if !flags.contains(.maskControl) { return false }
            case "alt":
                if !flags.contains(.maskAlternate) { return false }
            case "fn":
                if !flags.contains(.maskSecondaryFn) { return false }
            default:
                return false
            }
        }
        return true
    }

    private func holdModifiers(for action: HotkeyAction) -> Set<String> {
        switch action {
        case .nextWindow:
            return normalizedModifiers(currentShortcuts.nextWindow.modifiers)
        case .prevWindow:
            return normalizedModifiers(currentShortcuts.prevWindow.modifiers)
        case .switcher:
            return normalizedModifiers(currentShortcuts.switcherTrigger.modifiers)
        case .switcherReverse:
            return Set(["cmd", "shift"])
        case .focus, .moveCurrentWindowToSpace, .switchVirtualSpace, .globalAction:
            return []
        }
    }

    private func overlayKind(for action: HotkeyAction) -> ShortcutOverlaySessionKind? {
        switch action {
        case .nextWindow, .prevWindow:
            return .cycle
        case .switcher, .switcherReverse:
            return .switcher
        case .focus, .moveCurrentWindowToSpace, .switchVirtualSpace, .globalAction:
            return nil
        }
    }

    private func buildCycleCandidatesForCurrentSpace() -> [SwitcherCandidate] {
        guard let context = shortcutSpaceContext(source: "cycle") else {
            return []
        }

        let cycleStateKey = CycleStateKey(scope: context.scope)
        let currentSpaceCandidates = resolvedCurrentSpaceCandidates(
            includeAllSpaces: false,
            excludedBundleIDs: currentShortcuts.cycleExcludedApps,
            quickKeys: currentShortcuts.cycleQuickKeys,
            logPrefix: "cycle"
        )
        let resolution: (candidates: [SwitcherCandidate], state: SpaceCycleState?)
        if case .virtual = context.scope,
           let currentSpaceCandidates
        {
            resolution = ShortcutCandidateOrdering.cycleCandidates(
                orderedCandidates: currentSpaceCandidates,
                currentSpaceID: context.currentSpaceID,
                quickKeys: currentShortcuts.cycleQuickKeys,
                state: spaceCycleStates[cycleStateKey]
            )
        } else {
            resolution = ShortcutCandidateOrdering.cycleCandidates(
                windows: WindowQueryService.listWindows(),
                currentSpaceID: context.currentSpaceID,
                slotEntries: context.slotEntries,
                ignoreFocusRules: currentIgnoreFocusRules,
                excludedBundleIDs: currentShortcuts.cycleExcludedApps,
                quickKeys: currentShortcuts.cycleQuickKeys,
                state: spaceCycleStates[cycleStateKey]
            )
        }

        if let state = resolution.state {
            spaceCycleStates[cycleStateKey] = state
        }

        return resolution.candidates
    }

    private func buildSwitcherCandidatesForCurrentSpace() -> [SwitcherCandidate] {
        resolvedCurrentSpaceCandidates(
            includeAllSpaces: false,
            excludedBundleIDs: currentShortcuts.switcherExcludedApps,
            quickKeys: currentShortcuts.quickKeys,
            logPrefix: "switcher"
        ) ?? []
    }

    private func resolvedCurrentSpaceCandidates(
        includeAllSpaces: Bool,
        excludedBundleIDs: Set<String>,
        quickKeys: String,
        logPrefix: String
    ) -> [SwitcherCandidate]? {
        switch commandService.switcherCandidates(
            includeAllSpacesOverride: includeAllSpaces,
            excludedBundleIDs: excludedBundleIDs,
            quickKeys: quickKeys
        ) {
        case let .success(candidates):
            return candidates
        case let .failure(result):
            logger.log(
                level: "error",
                event: "\(logPrefix).candidates.resolveFailed",
                fields: ["exitCode": Int(result.exitCode)]
            )
            return nil
        }
    }

    private func logShortcutCommandResult(
        shortcutID: String,
        command: String,
        result: CommandResult,
        fields: [String: Any] = [:]
    ) {
        var payload = fields
        payload["shortcutID"] = shortcutID
        payload["command"] = command
        payload["exitCode"] = Int(result.exitCode)
        if !result.stdout.isEmpty {
            payload["stdout"] = truncatedLogField(result.stdout)
        }
        if !result.stderr.isEmpty {
            payload["stderr"] = truncatedLogField(result.stderr)
        }
        logger.log(
            level: result.exitCode == 0 ? "info" : "error",
            event: "shortcut.command.result",
            fields: payload
        )
    }

    private func truncatedLogField(_ value: String, maxLength: Int = 1200) -> String {
        let normalized = value.replacingOccurrences(of: "\n", with: "\\n")
        guard normalized.count > maxLength else {
            return normalized
        }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: maxLength)
        return String(normalized[..<endIndex]) + "...(truncated)"
    }

    private func shortcutSpaceContext(source: String) -> InteractiveShortcutContext? {
        let resolution = resolveShortcutContext()
        switch resolution {
        case let .resolved(context):
            return context
        case let .unavailable(reason):
            logShortcutContextUnavailable(reason: reason, source: source)
            return nil
        }
    }

    private func resolveShortcutContext() -> InteractiveShortcutContextResolution {
        let state: RuntimeState
        do {
            state = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            switch error {
            case .corrupted:
                return .unavailable(reason: .stateCorrupted)
            case .readPermissionDenied:
                return .unavailable(reason: .readPermissionDenied)
            case .readFailed, .encodingFailed, .staleWriteRejected, .writePermissionDenied, .writeFailed:
                return .unavailable(reason: .uninitialized)
            }
        } catch {
            return .unavailable(reason: .uninitialized)
        }

        let readContext = RuntimeStateReadResolver.reconciledRuntimeStateForRead(
            state: state,
            loadedConfig: currentLoadedConfig
        )

        let currentSpace = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: currentLoadedConfig,
            runtimeState: readContext.state,
            focusedWindow: focusedWindowProvider(),
            spaces: WindowQueryService.listSpaces()
        )

        let nativeCurrentSpaceID: Int?
        switch currentSpace {
        case let .resolved(spaceID, kind, _):
            nativeCurrentSpaceID = kind == .native ? spaceID : nil
        case .unavailable:
            nativeCurrentSpaceID = nil
        }

        return RuntimeStateReadResolver.resolveInteractiveShortcutContextDetailed(
            loadedConfig: currentLoadedConfig,
            state: readContext.state,
            nativeCurrentSpaceID: nativeCurrentSpaceID
        )
    }

    private func logShortcutContextUnavailable(reason: CurrentSpaceUnavailableReason, source: String) {
        let hintKey = "\(source):\(shortcutUnavailableHintID(for: reason))"
        guard !loggedShortcutUnavailableHints.contains(hintKey) else {
            return
        }

        loggedShortcutUnavailableHints.insert(hintKey)
        logger.log(
            level: "info",
            event: "shortcut.context.unavailable",
            fields: [
                "source": source,
                "reason": shortcutUnavailableHintID(for: reason),
                "hint": shortcutUnavailableHintMessage(for: reason),
            ]
        )
    }

    private func shortcutUnavailableHintID(for reason: CurrentSpaceUnavailableReason) -> String {
        switch reason {
        case .uninitialized, .staleGeneration:
            return "initializeActiveSpace"
        case .stateCorrupted:
            return "reinitializeRuntimeState"
        case .readPermissionDenied:
            return "restoreStateFileReadPermission"
        }
    }

    private func shortcutUnavailableHintMessage(for reason: CurrentSpaceUnavailableReason) -> String {
        switch reason {
        case .uninitialized, .staleGeneration:
            return "Initialize Active Space"
        case .stateCorrupted:
            return "Reinitialize Runtime State"
        case .readPermissionDenied:
            return "Restore Runtime State Read Permission"
        }
    }

    private func activate(candidate: SwitcherCandidate) {
        if let windowID = candidateWindowID(from: candidate.id) {
            let result = commandService.focus(
                slot: nil,
                target: WindowTargetSelector(windowID: windowID, bundleID: nil, title: nil)
            )
            logger.log(
                event: "candidate.activate.window",
                fields: [
                    "windowID": windowID,
                    "bundleID": candidate.bundleID ?? "",
                    "activated": result.exitCode == 0,
                ]
            )
            return
        }

        if let slot = candidate.slot {
            _ = commandService.focus(slot: slot)
            logger.log(
                event: "candidate.activate.slot",
                fields: ["slot": slot]
            )
            return
        }

        if let bundleID = candidate.bundleID {
            let result = commandService.focus(
                slot: nil,
                target: WindowTargetSelector(windowID: nil, bundleID: bundleID, title: candidate.title)
            )
            logger.log(
                event: "candidate.activate.bundle",
                fields: [
                    "bundleID": bundleID,
                    "activated": result.exitCode == 0,
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

    private func initialSwitcherSelectionIndex(candidates: [SwitcherCandidate], forward: Bool) -> Int {
        SwitcherCandidateSelection.initialIndex(
            candidates: candidates,
            focusedWindowID: WindowQueryService.focusedWindow()?.windowID,
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            forward: forward
        )
    }

    private func candidateWindowID(from candidateID: String) -> UInt32? {
        SwitcherCandidateSelection.candidateWindowID(from: candidateID)
    }

    private func resetCycleState() {
        lastEventTapOverlayAdvanceShortcutID = nil
        lastEventTapOverlayAdvanceAt = nil
    }

    private func handleActiveSpaceDidChange() {
        lastActiveSpaceChangeAt = Date()
        if overlaySession?.kind == .cycle {
            cancelOverlay()
        }
        resetCycleState()
        let reconciledPendingVisibility = reconcilePendingVirtualVisibilityIfNeeded(trigger: "activeSpaceDidChange")
        logger.log(
            event: "workspace.activeSpace.changed",
            fields: ["reconciledPendingVisibility": reconciledPendingVisibility]
        )
    }

    private func handleAppActivatedForFollowFocus() {
        let delay = appActivationHandlingDelay()
        guard delay == 0 else {
            scheduleDeferredAppActivationHandling(after: delay)
            return
        }
        pendingDeferredAppActivationWorkItem = nil
        guard isConfiguredVirtualMode else {
            return
        }

        _ = reconcilePendingVirtualVisibilityIfNeeded(trigger: "appActivated")

        guard let focused = focusedWindowProvider() else {
            return
        }

        // Always update lastActivatedAt so that Cmd+Tab MRU order stays
        // in sync with OS-level window activation (Dock click, Mission
        // Control, direct click, etc.).
        commandService.touchVirtualActivation(windowID: focused.windowID)

        // Adopt untracked windows into the current workspace on each
        // activation event instead of polling with a timer.
        commandService.adoptUntrackedWindowsIntoCurrentWorkspace()

        let decision = resolveShortcutFollowFocusDecision(
            followFocusEnabled: followFocusEnabled,
            lastFollowFocusSwitchAt: lastFollowFocusSwitchAt,
            lastActiveSpaceChangeAt: lastActiveSpaceChangeAt,
            debounceInterval: followFocusDebounceInterval,
            targetSpaceID: commandService.virtualSpaceIDForWindow(focused.windowID),
            activeSpaceID: commandService.activeVirtualSpaceID()
        )
        guard case let .switchSpace(targetSpaceID) = decision else {
            return
        }

        logger.log(
            event: "followFocus.spaceSwitch",
            fields: [
                "windowID": Int(focused.windowID),
                "bundleID": focused.bundleID,
                "targetSpaceID": targetSpaceID,
            ]
        )
        lastFollowFocusSwitchAt = Date()
        let result = commandService.spaceSwitch(spaceID: targetSpaceID, json: true)
        logShortcutCommandResult(
            shortcutID: "followFocus",
            command: "space.switch",
            result: result,
            fields: ["spaceID": targetSpaceID, "trigger": "followFocus"]
        )
    }

    private func handleAppUnhiddenForVirtualVisibility() {
        let delay = appActivationHandlingDelay()
        guard delay == 0 else {
            scheduleDeferredAppUnhideHandling(after: delay)
            return
        }
        pendingDeferredAppUnhideWorkItem = nil
        _ = reconcilePendingVirtualVisibilityIfNeeded(trigger: "appUnhidden")
    }

    private func beginAppActivationGraceWindow(now: Date = Date()) {
        deferredAppActivationUntil = now.addingTimeInterval(appActivationGraceInterval)
    }

    private func appActivationHandlingDelay(now: Date = Date()) -> TimeInterval {
        let delay = InteractiveActivationTiming(
            deferredUntil: deferredAppActivationUntil
        ).handlingDelay(now: now)
        if delay == 0 {
            deferredAppActivationUntil = nil
        }
        return delay
    }

    private func scheduleDeferredAppActivationHandling(after delay: TimeInterval) {
        pendingDeferredAppActivationWorkItem?.cancel()
        let managerBox = WeakShortcutManagerBox(manager: self)
        let workItem = DispatchWorkItem {
            managerBox.manager?.handleAppActivatedForFollowFocus()
        }
        pendingDeferredAppActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleDeferredAppUnhideHandling(after delay: TimeInterval) {
        pendingDeferredAppUnhideWorkItem?.cancel()
        let managerBox = WeakShortcutManagerBox(manager: self)
        let workItem = DispatchWorkItem {
            managerBox.manager?.handleAppUnhiddenForVirtualVisibility()
        }
        pendingDeferredAppUnhideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelDeferredWorkspaceEventHandling() {
        pendingDeferredAppActivationWorkItem?.cancel()
        pendingDeferredAppActivationWorkItem = nil
        pendingDeferredAppUnhideWorkItem?.cancel()
        pendingDeferredAppUnhideWorkItem = nil
        deferredAppActivationUntil = nil
    }

    private func shouldRegisterSwitcherReverseHotkey(trigger: HotkeyDefinition) -> Bool {
        canonicalHotkeyKey(trigger.key) == "tab" && normalizedModifiers(trigger.modifiers) == ["cmd"]
    }

    private var isConfiguredVirtualMode: Bool {
        currentLoadedConfig?.config.resolvedSpaceInterpretationMode == .virtual
    }

    @discardableResult
    private func reconcilePendingVirtualVisibilityIfNeeded(trigger: String) -> Bool {
        guard isConfiguredVirtualMode else {
            return false
        }

        let reconciled = commandService.reconcilePendingVirtualVisibilityIfNeeded()
        if reconciled {
            logger.log(
                event: "virtual.visibility.reconciledOnWorkspaceEvent",
                fields: ["trigger": trigger]
            )
        }
        return reconciled
    }

    private func syncNativeSwitcherHotKeys() {
        let desired = nativeHotKeysToDisable(shortcuts: currentShortcuts)
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

    private func nativeHotKeysToDisable(shortcuts: ResolvedShortcuts) -> Set<NativeSymbolicHotKey> {
        var result: Set<NativeSymbolicHotKey> = []
        let key = canonicalHotkeyKey(shortcuts.switcherTrigger.key)
        let modifiers = normalizedModifiers(shortcuts.switcherTrigger.modifiers)

        if key == "tab", modifiers == ["cmd"] {
            result.formUnion(SymbolicHotKeyController.commandTabGroup)
        }

        if key == "tab", modifiers == ["cmd", "shift"] {
            result.insert(.commandShiftTab)
        }

        if key == "grave", modifiers == ["cmd"] {
            result.insert(.commandKeyAboveTab)
        }

        if isConfiguredVirtualMode {
            result.formUnion(SymbolicHotKeyController.desktopSwitchGroup)
        }

        return result
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

    private func startWorkspaceObservers() {
        guard activeSpaceObserver == nil else {
            return
        }

        let managerBox = WeakShortcutManagerBox(manager: self)
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            managerBox.manager?.handleActiveSpaceDidChange()
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            managerBox.manager?.handleAppActivatedForFollowFocus()
        }
        appUnhideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            managerBox.manager?.handleAppUnhiddenForVirtualVisibility()
        }
    }

    private func stopWorkspaceObservers() {
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
            self.activeSpaceObserver = nil
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
        if let appUnhideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appUnhideObserver)
            self.appUnhideObserver = nil
        }
    }

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
