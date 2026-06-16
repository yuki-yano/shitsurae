import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ShitsuraeCore

/// Global hotkey handling, CGEventTap only (v2 dropped v1's Carbon +
/// event-tap dual registration and its dedup timestamps). Accessibility
/// permission is a hard requirement of the app, so the tap is always
/// available when the app works at all.
@MainActor
final class HotkeyManager {
    private weak var model: AppModel?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var shortcuts: ResolvedShortcuts?
    private var overlay: SwitcherOverlayController?
    private var session: OverlaySession?
    /// Monotonic id distinguishing concurrent session loads.
    private var sessionGeneration = 0
    /// Set when the trigger is released while candidates are still loading;
    /// the loader turns it into an instant switch (quick-tap).
    private var pendingQuickAccept: Int?
    private var commandTabDisabled = false

    struct OverlaySession {
        enum Kind {
            case switcher
            case cycle
        }

        let kind: Kind
        var candidates: [SwitcherCandidate]
        var selectedIndex: Int
        let quickKeys: String
        let acceptKeys: [String]
        let cancelKeys: [String]
        /// Modifiers held by the trigger; releasing them all accepts.
        let holdModifiers: Set<String>
    }

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        // The tap source is added to the main run loop, so the callback runs
        // on the main thread; assumeIsolated bridges into the actor. The
        // closure returns Bool (Sendable) because CGEvent isn't.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated {
                manager.handle(type: type, event: event)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            model?.logger.error(event: "hotkey.tapCreateFailed")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        restoreNativeSwitcherHotKeys()
        overlay?.hide()
    }

    func reload(shortcuts: ResolvedShortcuts?) {
        self.shortcuts = shortcuts

        // Own Cmd+Tab only when our switcher can actually run: the trigger
        // is Cmd+Tab AND the event tap exists. Without the tap (e.g. missing
        // Accessibility permission) disabling the system hotkey would leave
        // the user with no working Cmd+Tab at all.
        let triggerIsCommandTab = shortcuts.map {
            $0.switcherTrigger.key.lowercased() == "tab"
                && Set($0.switcherTrigger.modifiers.map { $0.lowercased() }) == ["cmd"]
        } ?? false
        let shouldOwnCommandTab = triggerIsCommandTab && eventTap != nil

        if shouldOwnCommandTab, !commandTabDisabled {
            SymbolicHotKeyController.setEnabled(false, hotKeys: SymbolicHotKeyController.commandTabGroup)
            commandTabDisabled = true
        } else if !shouldOwnCommandTab, commandTabDisabled {
            restoreNativeSwitcherHotKeys()
        }
    }

    func restoreNativeSwitcherHotKeys() {
        if commandTabDisabled {
            SymbolicHotKeyController.setEnabled(true, hotKeys: SymbolicHotKeyController.commandTabGroup)
            commandTabDisabled = false
        }
    }

    // MARK: - Event handling

    /// Returns true when the event was consumed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return false
        }

        if session != nil {
            return handleOverlayEvent(type: type, event: event)
        }

        guard type == .keyDown, let shortcuts else {
            return false
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        func disabled(_ shortcutID: String) -> Bool {
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: frontmostBundleID,
                shortcutID: shortcutID,
                disabledInApps: shortcuts.disabledInApps,
                focusBySlotEnabledInApps: shortcuts.focusBySlotEnabledInApps
            )
        }

        // Switcher trigger
        if eventMatchesHotkey(event: event, key: shortcuts.switcherTrigger.key, modifiers: shortcuts.switcherTrigger.modifiers),
           !disabled("switcher")
        {
            openSwitcher(shortcuts: shortcuts)
            return true
        }

        // Cycle next/prev
        if eventMatchesHotkey(event: event, key: shortcuts.nextWindow.key, modifiers: shortcuts.nextWindow.modifiers),
           !disabled("nextWindow")
        {
            cycle(forward: true, shortcuts: shortcuts, trigger: shortcuts.nextWindow)
            return true
        }
        if eventMatchesHotkey(event: event, key: shortcuts.prevWindow.key, modifiers: shortcuts.prevWindow.modifiers),
           !disabled("prevWindow")
        {
            cycle(forward: false, shortcuts: shortcuts, trigger: shortcuts.prevWindow)
            return true
        }

        // Slot focus / workspace switch / move-to-workspace
        for slot in 1 ... 9 {
            if let hotkey = shortcuts.focusBySlot[slot],
               eventMatchesHotkey(event: event, key: hotkey.key, modifiers: hotkey.modifiers),
               !disabled("focusBySlot:\(slot)")
            {
                model?.focusSlot(slot)
                return true
            }
            if let hotkey = shortcuts.switchVirtualSpace[slot],
               eventMatchesHotkey(event: event, key: hotkey.key, modifiers: hotkey.modifiers),
               !disabled("switchVirtualSpace:\(slot)")
            {
                model?.switchSpace(to: slot)
                return true
            }
            if let hotkey = shortcuts.moveCurrentWindowToSpace[slot],
               eventMatchesHotkey(event: event, key: hotkey.key, modifiers: hotkey.modifiers),
               !disabled("moveCurrentWindowToSpace:\(slot)")
            {
                model?.moveCurrentWindowToSpace(slot)
                return true
            }
        }

        // Global actions (snap etc.)
        for (index, action) in shortcuts.globalActions.enumerated() {
            if eventMatchesHotkey(event: event, key: action.key, modifiers: action.modifiers),
               !disabled("globalAction:\(index + 1)")
            {
                model?.performGlobalAction(action.action)
                return true
            }
        }

        return false
    }

    // MARK: - Overlay sessions

    /// Sessions start *synchronously* on the trigger key so the modifier
    /// release is never lost while candidates load. Releasing before the
    /// candidates arrive turns the press into a quick-tap: switch to the
    /// previous window without ever showing the overlay.
    private func openSwitcher(shortcuts: ResolvedShortcuts) {
        guard let model, let config = model.configManager.configIfLoaded() else {
            return
        }

        let engine = model.engine
        let holdModifiers = Set(shortcuts.switcherTrigger.modifiers.map { $0.lowercased() })

        sessionGeneration += 1
        let generation = sessionGeneration
        session = OverlaySession(
            kind: .switcher,
            candidates: [],
            selectedIndex: 0,
            quickKeys: shortcuts.quickKeys,
            acceptKeys: shortcuts.acceptKeys,
            cancelKeys: shortcuts.cancelKeys,
            holdModifiers: holdModifiers
        )

        Task { @MainActor in
            // v1 behavior: the switcher targets the active workspace only.
            let candidates = (try? await engine.switcherCandidates(
                includeAllSpaces: false,
                config: config,
                excludedApps: shortcuts.switcherExcludedApps
            )) ?? []

            guard self.sessionGeneration == generation else {
                return // superseded by a newer session
            }

            // Released while loading -> quick-tap: jump to the previous window.
            if self.pendingQuickAccept == generation {
                self.pendingQuickAccept = nil
                if !candidates.isEmpty {
                    let index = candidates.count > 1 ? 1 : 0
                    if let windowID = candidates[index].windowID {
                        self.model?.focusWindow(windowID: windowID)
                    }
                }
                return
            }

            guard var session = self.session, session.kind == .switcher else {
                return
            }
            guard !candidates.isEmpty else {
                self.cancelSession()
                return
            }

            // MRU order: index 1 (the previous window) starts selected, so
            // one trigger press + release = back to the previous window.
            session.candidates = candidates
            session.selectedIndex = candidates.count > 1 ? 1 : 0
            self.session = session
            self.showOverlay(showThumbnails: config.config.overlay?.showThumbnails)
        }
    }

    private func cycle(forward: Bool, shortcuts: ResolvedShortcuts, trigger: HotkeyDefinition) {
        guard shortcuts.cycleMode == .overlay else {
            model?.cycleWindow(forward: forward)
            return
        }

        guard let model, let config = model.configManager.configIfLoaded() else {
            return
        }
        let engine = model.engine
        // Release detection must track the hotkey that actually fired —
        // prevWindow may use different modifiers than nextWindow.
        let holdModifiers = Set(trigger.modifiers.map { $0.lowercased() })

        sessionGeneration += 1
        let generation = sessionGeneration
        session = OverlaySession(
            kind: .cycle,
            candidates: [],
            selectedIndex: 0,
            quickKeys: shortcuts.cycleQuickKeys,
            acceptKeys: shortcuts.cycleAcceptKeys,
            cancelKeys: shortcuts.cycleCancelKeys,
            holdModifiers: holdModifiers
        )

        Task { @MainActor in
            let candidates = (try? await engine.cycleCandidates(
                config: config,
                excludedApps: shortcuts.cycleExcludedApps
            )) ?? []

            guard self.sessionGeneration == generation else {
                return
            }

            // Released while loading -> behave like a direct cycle step.
            if self.pendingQuickAccept == generation {
                self.pendingQuickAccept = nil
                self.model?.cycleWindow(forward: forward)
                return
            }

            guard var session = self.session, session.kind == .cycle else {
                return
            }
            guard !candidates.isEmpty else {
                self.cancelSession()
                return
            }

            let focusedWindowID = await engine.resolveTargetWindow(selector: WindowTargetSelector())?.windowID
            let currentIndex = candidates.firstIndex(where: { $0.windowID == focusedWindowID }) ?? 0
            let startIndex = forward
                ? (currentIndex + 1) % candidates.count
                : (currentIndex - 1 + candidates.count) % candidates.count

            session.candidates = candidates
            session.selectedIndex = startIndex
            self.session = session
            self.showOverlay(showThumbnails: config.config.overlay?.showThumbnails)
        }
    }

    private func handleOverlayEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard var session else {
            return false
        }

        if type == .flagsChanged {
            let held = eventModifierSet(flags: event.flags)
            if session.holdModifiers.isDisjoint(with: held) == false {
                return true // some trigger modifiers still held
            }
            // All trigger modifiers released → accept.
            acceptSession()
            return true
        }

        guard type == .keyDown else {
            return false
        }

        let key = normalizedKey(from: event)
        let modifiers = eventModifierSet(flags: event.flags)

        if session.cancelKeys.contains(key) {
            cancelSession()
            return true
        }
        if session.acceptKeys.contains(key) {
            acceptSession()
            return true
        }

        // Quick keys: select and accept in one stroke.
        if key.count == 1,
           let index = session.quickKeys.lowercased().firstIndex(of: Character(key))
        {
            let position = session.quickKeys.lowercased().distance(from: session.quickKeys.startIndex, to: index)
            if position < session.candidates.count {
                session.selectedIndex = position
                self.session = session
                acceptSession()
                return true
            }
        }

        // Tab / Shift+Tab and trigger keys advance the selection.
        if let advanceForward = overlayAdvanceForward(event: event, key: key, modifiers: modifiers, session: session) {
            session.advance(forward: advanceForward)
            self.session = session
            overlay?.update(session: session)
            return true
        }

        return true // swallow everything else while the overlay is up
    }

    private func overlayAdvanceForward(
        event: CGEvent,
        key: String,
        modifiers: Set<String>,
        session: OverlaySession
    ) -> Bool? {
        switch session.kind {
        case .switcher:
            guard key == "tab" || isTriggerRepeat(event: event) else {
                return nil
            }
            return !modifiers.contains("shift")
        case .cycle:
            let eventKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if let advanceForward = Self.cycleOverlayAdvanceForward(forKeyCode: eventKeyCode, shortcuts: shortcuts) {
                return advanceForward
            }
            guard key == "tab" else {
                return nil
            }
            return !modifiers.contains("shift")
        }
    }

    nonisolated static func cycleOverlayAdvanceForward(
        forKeyCode eventKeyCode: Int,
        shortcuts: ResolvedShortcuts?
    ) -> Bool? {
        guard let shortcuts else {
            return nil
        }
        if keyCode(for: shortcuts.nextWindow.key) == eventKeyCode {
            return true
        }
        if keyCode(for: shortcuts.prevWindow.key) == eventKeyCode {
            return false
        }
        return nil
    }

    private func isTriggerRepeat(event: CGEvent) -> Bool {
        guard let shortcuts, let session else { return false }
        switch session.kind {
        case .switcher:
            let trigger = shortcuts.switcherTrigger
            return keyCode(for: trigger.key) == Int(event.getIntegerValueField(.keyboardEventKeycode))
        case .cycle:
            let next = shortcuts.nextWindow
            let prev = shortcuts.prevWindow
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return keyCode(for: next.key) == code || keyCode(for: prev.key) == code
        }
    }

    private func showOverlay(showThumbnails: Bool?) {
        if overlay == nil {
            overlay = SwitcherOverlayController { [weak self] index in
                guard var session = self?.session else { return }
                session.selectedIndex = index
                self?.session = session
                self?.acceptSession()
            }
        }
        guard let session else { return }
        overlay?.show(session: session, showThumbnails: showThumbnails ?? true)
    }

    private func acceptSession() {
        guard let session else { return }
        self.session = nil
        overlay?.hide()

        // Candidates still loading: remember the release; the loader
        // completes it as a quick-tap switch.
        if session.candidates.isEmpty {
            pendingQuickAccept = sessionGeneration
            return
        }

        guard session.candidates.indices.contains(session.selectedIndex),
              let windowID = session.candidates[session.selectedIndex].windowID
        else {
            return
        }
        model?.focusWindow(windowID: windowID)
    }

    private func cancelSession() {
        session = nil
        pendingQuickAccept = nil
        overlay?.hide()
    }
}

extension HotkeyManager.OverlaySession {
    mutating func advance(forward: Bool) {
        guard !candidates.isEmpty else { return }
        selectedIndex = forward
            ? (selectedIndex + 1) % candidates.count
            : (selectedIndex - 1 + candidates.count) % candidates.count
    }
}

// MARK: - Event helpers (ported from v1)

func eventMatchesHotkey(event: CGEvent, key: String, modifiers: [String]) -> Bool {
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

func eventModifierSet(flags: CGEventFlags) -> Set<String> {
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

func normalizedKey(from event: CGEvent) -> String {
    let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if let key = overlayCommandKeyName(forKeyCode: code) {
        return key
    }

    var chars = [UniChar](repeating: 0, count: 4)
    var length = 0
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return "" }
    return String(utf16CodeUnits: chars, count: length).lowercased()
}
