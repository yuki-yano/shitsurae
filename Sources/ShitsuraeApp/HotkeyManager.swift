import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ShitsuraeCore

/// Global hotkey handling, CGEventTap only (v2 dropped v1's Carbon +
/// event-tap dual registration and its dedup timestamps). Accessibility
/// permission is a hard requirement of the app, so the tap is always
/// available when the app works at all.
enum HotkeyFastPathAction: Equatable, Sendable {
    case switchSpace(Int)

    static func match(
        eventKeyCode: Int,
        modifiers: Set<String>,
        shortcuts: ResolvedShortcuts,
        frontmostBundleID: String?,
        frontmostBelongsToActiveWorkspace: Bool
    ) -> HotkeyFastPathAction? {
        for (slot, hotkey) in shortcuts.switchVirtualSpace {
            guard keyCode(for: hotkey.key) == eventKeyCode,
                  Set(hotkey.modifiers.map { $0.lowercased() }) == modifiers
            else {
                continue
            }

            let shortcutID = "switchVirtualSpace:\(slot)"
            guard !PolicyEngine.isShortcutDisabled(
                frontmostBundleID: frontmostBundleID,
                shortcutID: shortcutID,
                disabledInApps: shortcuts.disabledInApps,
                focusBySlotEnabledInApps: shortcuts.focusBySlotEnabledInApps,
                frontmostBelongsToActiveWorkspace: frontmostBelongsToActiveWorkspace
            ) else {
                return nil
            }

            return .switchSpace(slot)
        }

        return nil
    }
}

enum SpaceSwitchCompletion {
    static func incompleteMessage(
        converged: Bool,
        unresolvedSlotCount: Int
    ) -> String? {
        guard !converged else { return nil }
        return unresolvedSlotCount == 0
            ? "space switch did not converge"
            : "space switch incomplete: \(unresolvedSlotCount) unresolved slots"
    }
}

enum HotkeyFastPathPreparation {
    static func perform(
        invalidateFocusEvents: () -> Void,
        onStart: () -> Void
    ) {
        invalidateFocusEvents()
        onStart()
    }
}

enum HotkeyEventRouting {
    static func shouldUseMainFallback(
        eventType: CGEventType,
        overlaySessionActive: Bool
    ) -> Bool {
        eventType != .flagsChanged || overlaySessionActive
    }
}

enum HotkeyFastPathExecutionResult: Sendable {
    case success(SpaceSwitchOutcome)
    case partial(SpaceSwitchOutcome, String)
    case failure(String)
}

private struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keyCode: Int
    let modifiers: Set<String>
    let key: String

    var type: CGEventType? {
        CGEventType(rawValue: typeRawValue)
    }

    init(type: CGEventType, event: CGEvent) {
        typeRawValue = type.rawValue
        keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        modifiers = eventModifierSet(flags: event.flags)
        key = normalizedKey(from: event)
    }
}

private struct HotkeyFastPathSnapshot: Sendable {
    var shortcuts: ResolvedShortcuts?
    var frontmostBundleID: String?
    var frontmostBelongsToActiveWorkspace: Bool
    var overlaySessionActive: Bool
}

private final class HotkeyFastPathState: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = HotkeyFastPathSnapshot(
        shortcuts: nil,
        frontmostBundleID: nil,
        frontmostBelongsToActiveWorkspace: true,
        overlaySessionActive: false
    )

    func updateShortcuts(_ shortcuts: ResolvedShortcuts?) {
        lock.lock()
        snapshot.shortcuts = shortcuts
        lock.unlock()
    }

    func updatePolicy(frontmostBundleID: String?, frontmostBelongsToActiveWorkspace: Bool) {
        lock.lock()
        snapshot.frontmostBundleID = frontmostBundleID
        snapshot.frontmostBelongsToActiveWorkspace = frontmostBelongsToActiveWorkspace
        lock.unlock()
    }

    func updateOverlaySessionActive(_ active: Bool) {
        lock.lock()
        snapshot.overlaySessionActive = active
        lock.unlock()
    }

    func isOverlaySessionActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot.overlaySessionActive
    }

    func action(event: HotkeyEventSnapshot) -> HotkeyFastPathAction? {
        guard event.type == .keyDown else {
            return nil
        }

        lock.lock()
        let current = snapshot
        lock.unlock()

        guard !current.overlaySessionActive,
              let shortcuts = current.shortcuts
        else {
            return nil
        }

        return HotkeyFastPathAction.match(
            eventKeyCode: event.keyCode,
            modifiers: event.modifiers,
            shortcuts: shortcuts,
            frontmostBundleID: current.frontmostBundleID,
            frontmostBelongsToActiveWorkspace: current.frontmostBelongsToActiveWorkspace
        )
    }
}

private final class HotkeyFastPathExecutor: @unchecked Sendable {
    private let engine: VirtualSpaceEngine
    private let configManager: ConfigManager
    private let logger: ShitsuraeLogger
    private let onStart: @Sendable (String) -> Void
    private let onFinish: @Sendable (String, HotkeyFastPathExecutionResult) -> Void

    init(
        engine: VirtualSpaceEngine,
        configManager: ConfigManager,
        logger: ShitsuraeLogger,
        onStart: @escaping @Sendable (String) -> Void,
        onFinish: @escaping @Sendable (String, HotkeyFastPathExecutionResult) -> Void
    ) {
        self.engine = engine
        self.configManager = configManager
        self.logger = logger
        self.onStart = onStart
        self.onFinish = onFinish
    }

    func execute(_ action: HotkeyFastPathAction) {
        switch action {
        case let .switchSpace(spaceID):
            switchSpace(to: spaceID)
        }
    }

    private func switchSpace(to spaceID: Int) {
        let label = "switch to space \(spaceID)"
        guard let config = configManager.configIfLoaded() else {
            onFinish(label, .failure("config not loaded"))
            return
        }

        let engine = engine
        let logger = logger
        HotkeyFastPathPreparation.perform(
            invalidateFocusEvents: { engine.invalidatePendingFocusEvents() },
            onStart: { onStart(label) }
        )
        Task.detached(priority: .high) {
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Shitsurae \(label)"
            )
            defer {
                ProcessInfo.processInfo.endActivity(activity)
            }

            do {
                let outcome = try await engine.switchSpace(to: spaceID, config: config)
                if let message = SpaceSwitchCompletion.incompleteMessage(
                    converged: outcome.converged,
                    unresolvedSlotCount: outcome.unresolvedSlots.count
                ) {
                    logger.log(
                        level: "warn",
                        event: "app.action.partial",
                        fields: [
                            "label": label,
                            "error": message,
                            "targetSpace": outcome.targetSpaceID,
                            "unresolvedSlots": outcome.unresolvedSlots.count,
                        ]
                    )
                    self.onFinish(label, .partial(outcome, message))
                } else {
                    self.onFinish(label, .success(outcome))
                }
            } catch {
                let message = (error as? VirtualSpaceEngineError).map {
                    CommandRouter.mapEngineError($0).message
                } ?? String(describing: error)
                logger.log(level: "warn", event: "app.action.failed", fields: ["label": label, "error": message])
                self.onFinish(label, .failure(message))
            }
        }
    }
}

private final class HotkeyEventTapController: @unchecked Sendable {
    private let lock = NSLock()
    private let fastPathState: HotkeyFastPathState
    private let fastPathExecutor: HotkeyFastPathExecutor
    private let logger: ShitsuraeLogger
    private let fallback: (HotkeyEventSnapshot) -> Bool
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(
        fastPathState: HotkeyFastPathState,
        fastPathExecutor: HotkeyFastPathExecutor,
        logger: ShitsuraeLogger,
        fallback: @escaping (HotkeyEventSnapshot) -> Bool
    ) {
        self.fastPathState = fastPathState
        self.fastPathExecutor = fastPathExecutor
        self.logger = logger
        self.fallback = fallback
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return eventTap != nil
    }

    func start() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.run(semaphore: semaphore)
        }
        thread.name = "Shitsurae Hotkey Event Tap"
        thread.qualityOfService = .userInteractive

        lock.lock()
        self.thread = thread
        lock.unlock()

        thread.start()
        return semaphore.wait(timeout: .now() + 1) == .success && isRunning
    }

    func stop() {
        lock.lock()
        let loop = runLoop
        lock.unlock()

        guard let loop else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            self.lock.lock()
            let tap = self.eventTap
            let source = self.runLoopSource
            self.eventTap = nil
            self.runLoopSource = nil
            self.runLoop = nil
            self.lock.unlock()

            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
            semaphore.signal()
        }
        CFRunLoopWakeUp(loop)
        _ = semaphore.wait(timeout: .now() + 1)
    }

    private func run(semaphore: DispatchSemaphore) {
        lock.lock()
        runLoop = CFRunLoopGetCurrent()
        lock.unlock()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<HotkeyEventTapController>.fromOpaque(refcon).takeUnretainedValue()
            let swallow = controller.handle(type: type, event: event)
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
            semaphore.signal()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        lock.lock()
        eventTap = tap
        runLoopSource = source
        lock.unlock()

        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        semaphore.signal()
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            logger.log(
                level: "warn",
                event: "hotkey.tapDisabled",
                fields: [
                    "reason": type == .tapDisabledByTimeout ? "timeout" : "userInput",
                ]
            )
            return false
        }

        let snapshot = HotkeyEventSnapshot(type: type, event: event)
        if let action = fastPathState.action(event: snapshot) {
            fastPathExecutor.execute(action)
            return true
        }

        guard HotkeyEventRouting.shouldUseMainFallback(
            eventType: type,
            overlaySessionActive: fastPathState.isOverlaySessionActive()
        ) else {
            return false
        }

        return DispatchQueue.main.sync {
            fallback(snapshot)
        }
    }
}

@MainActor
final class HotkeyManager {
    private weak var model: AppModel?
    private let fastPathState = HotkeyFastPathState()
    private let fastPathExecutor: HotkeyFastPathExecutor
    private var eventTapController: HotkeyEventTapController?
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
        fastPathExecutor = HotkeyFastPathExecutor(
            engine: model.engine,
            configManager: model.configManager,
            logger: model.logger,
            onStart: { [weak model] label in
                // Both lifecycle notifications use the same serial queue so
                // an immediate preflight failure cannot overtake start and
                // leave the UI stuck in `.running`.
                DispatchQueue.main.async { [weak model] in
                    model?.handleFastPathActionStarted(label)
                }
            },
            onFinish: { [weak model] label, result in
                DispatchQueue.main.async { [weak model] in
                    model?.handleFastPathSwitchFinished(label: label, result: result)
                }
            }
        )
    }

    func start() {
        guard let model else { return }
        let controller = HotkeyEventTapController(
            fastPathState: fastPathState,
            fastPathExecutor: fastPathExecutor,
            logger: model.logger
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
        }

        guard controller.start() else {
            model.logger.error(event: "hotkey.tapCreateFailed")
            return
        }

        eventTapController = controller
        updateFastPathPolicy(
            frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            frontmostBelongsToActiveWorkspace: model.frontmostBelongsToActiveWorkspaceForShortcutPolicy()
        )
    }

    func stop() {
        eventTapController?.stop()
        eventTapController = nil
        restoreNativeSwitcherHotKeys()
        overlay?.hide()
    }

    func reload(shortcuts: ResolvedShortcuts?) {
        self.shortcuts = shortcuts
        fastPathState.updateShortcuts(shortcuts)

        // Own Cmd+Tab only when our switcher can actually run: the trigger
        // is Cmd+Tab AND the event tap exists. Without the tap (e.g. missing
        // Accessibility permission) disabling the system hotkey would leave
        // the user with no working Cmd+Tab at all.
        let triggerIsCommandTab = shortcuts.map {
            $0.switcherTrigger.key.lowercased() == "tab"
                && Set($0.switcherTrigger.modifiers.map { $0.lowercased() }) == ["cmd"]
        } ?? false
        let shouldOwnCommandTab = triggerIsCommandTab && eventTapController?.isRunning == true

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

    func updateFastPathPolicy(frontmostBundleID: String?, frontmostBelongsToActiveWorkspace: Bool) {
        fastPathState.updatePolicy(
            frontmostBundleID: frontmostBundleID,
            frontmostBelongsToActiveWorkspace: frontmostBelongsToActiveWorkspace
        )
    }

    // MARK: - Event handling

    /// Returns true when the event was consumed.
    private func handle(_ event: HotkeyEventSnapshot) -> Bool {
        if event.type == .tapDisabledByTimeout || event.type == .tapDisabledByUserInput {
            return false
        }

        if session != nil {
            return handleOverlayEvent(event)
        }

        guard event.type == .keyDown, let shortcuts else {
            return false
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        func disabled(_ shortcutID: String) -> Bool {
            PolicyEngine.isShortcutDisabled(
                frontmostBundleID: frontmostBundleID,
                shortcutID: shortcutID,
                disabledInApps: shortcuts.disabledInApps,
                focusBySlotEnabledInApps: shortcuts.focusBySlotEnabledInApps,
                frontmostBelongsToActiveWorkspace: model?.frontmostBelongsToActiveWorkspaceForShortcutPolicy() ?? true
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
        fastPathState.updateOverlaySessionActive(true)

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
                    self.model?.focusWindow(identity: candidates[index].identity)
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
        fastPathState.updateOverlaySessionActive(true)

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

            let focusedIdentity = await engine.resolveTargetWindow(selector: WindowTargetSelector())?.identity
            let currentIndex = candidates.firstIndex(where: { $0.identity == focusedIdentity }) ?? 0
            let startIndex = forward
                ? (currentIndex + 1) % candidates.count
                : (currentIndex - 1 + candidates.count) % candidates.count

            session.candidates = candidates
            session.selectedIndex = startIndex
            self.session = session
            self.showOverlay(showThumbnails: config.config.overlay?.showThumbnails)
        }
    }

    private func handleOverlayEvent(_ event: HotkeyEventSnapshot) -> Bool {
        guard var session else {
            return false
        }

        if event.type == .flagsChanged {
            let held = event.modifiers
            if session.holdModifiers.isDisjoint(with: held) == false {
                return true // some trigger modifiers still held
            }
            // All trigger modifiers released → accept.
            acceptSession()
            return true
        }

        guard event.type == .keyDown else {
            return false
        }

        let key = event.key
        let modifiers = event.modifiers

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
        event: HotkeyEventSnapshot,
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
            if let advanceForward = Self.cycleOverlayAdvanceForward(forKeyCode: event.keyCode, shortcuts: shortcuts) {
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

    private func isTriggerRepeat(event: HotkeyEventSnapshot) -> Bool {
        guard let shortcuts, let session else { return false }
        switch session.kind {
        case .switcher:
            let trigger = shortcuts.switcherTrigger
            return keyCode(for: trigger.key) == event.keyCode
        case .cycle:
            let next = shortcuts.nextWindow
            let prev = shortcuts.prevWindow
            let code = event.keyCode
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
        fastPathState.updateOverlaySessionActive(false)
        overlay?.hide()

        // Candidates still loading: remember the release; the loader
        // completes it as a quick-tap switch.
        if session.candidates.isEmpty {
            pendingQuickAccept = sessionGeneration
            return
        }

        guard session.candidates.indices.contains(session.selectedIndex) else {
            return
        }
        model?.focusWindow(identity: session.candidates[session.selectedIndex].identity)
    }

    private func cancelSession() {
        session = nil
        fastPathState.updateOverlaySessionActive(false)
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

private func eventMatchesHotkey(event: HotkeyEventSnapshot, key: String, modifiers: [String]) -> Bool {
    guard let expectedKeyCode = keyCode(for: key) else {
        return false
    }

    guard event.keyCode == expectedKeyCode else {
        return false
    }

    let expected = Set(modifiers.map { $0.lowercased() })
    return event.modifiers == expected
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
