import AppKit
import CoreGraphics
import Foundation

public struct CommandResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public struct CommandServiceRuntimeHooks: @unchecked Sendable {
    public let accessibilityGranted: () -> Bool
    public let listWindows: () -> [WindowSnapshot]
    public let listWindowsOnAllSpaces: () -> [WindowSnapshot]
    public let focusedWindow: () -> WindowSnapshot?
    public let activateBundle: (String) -> Bool
    public let activateWindowWithTitle: (String, String) -> Bool
    public let focusWindow: (UInt32, String) -> Bool
    public let setFocusedWindowFrame: (ResolvedFrame) -> Bool
    public let setWindowFrame: (UInt32, String, ResolvedFrame) -> Bool
    public let displays: () -> [DisplayInfo]
    public let spaces: () -> [SpaceInfo]
    public let runProcess: (String, [String]) -> (exitCode: Int32, output: String)

    public init(
        accessibilityGranted: @escaping () -> Bool,
        listWindows: @escaping () -> [WindowSnapshot],
        focusedWindow: @escaping () -> WindowSnapshot?,
        activateBundle: @escaping (String) -> Bool,
        setFocusedWindowFrame: @escaping (ResolvedFrame) -> Bool,
        displays: @escaping () -> [DisplayInfo],
        runProcess: @escaping (String, [String]) -> (exitCode: Int32, output: String),
        activateWindowWithTitle: @escaping (String, String) -> Bool = { bundleID, title in
            WindowQueryService.activate(bundleID: bundleID, preferredWindowTitle: title)
        },
        focusWindow: @escaping (UInt32, String) -> Bool = WindowQueryService.focusWindow,
        setWindowFrame: @escaping (UInt32, String, ResolvedFrame) -> Bool = WindowQueryService.setWindowFrame,
        spaces: @escaping () -> [SpaceInfo] = { WindowQueryService.listSpaces() },
        listWindowsOnAllSpaces: @escaping () -> [WindowSnapshot] = { WindowQueryService.listWindowsOnAllSpaces() }
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.listWindows = listWindows
        self.listWindowsOnAllSpaces = listWindowsOnAllSpaces
        self.focusedWindow = focusedWindow
        self.activateBundle = activateBundle
        self.activateWindowWithTitle = activateWindowWithTitle
        self.focusWindow = focusWindow
        self.setFocusedWindowFrame = setFocusedWindowFrame
        self.setWindowFrame = setWindowFrame
        self.displays = displays
        self.spaces = spaces
        self.runProcess = runProcess
    }

    public static let live = CommandServiceRuntimeHooks(
        accessibilityGranted: SystemProbe.accessibilityGranted,
        listWindows: { WindowQueryService.listWindows() },
        focusedWindow: { WindowQueryService.focusedWindow() },
        activateBundle: { WindowQueryService.activate(bundleID: $0) },
        setFocusedWindowFrame: WindowQueryService.setFocusedWindowFrame,
        displays: SystemProbe.displays,
        runProcess: { executable, arguments in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = nil
            process.standardError = Pipe()

            let outputPipe = Pipe()
            process.standardOutput = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (Int32(ErrorCode.externalCommandFailed.rawValue), "")
            }

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        },
        spaces: { WindowQueryService.listSpaces() },
        listWindowsOnAllSpaces: { WindowQueryService.listWindowsOnAllSpaces() }
    )
}

public final class CommandService {
    public static let bundledSupportedBuildCatalogURL = BundledResourceLocator.supportedBuildCatalogURL()

    private let configLoader: ConfigLoader
    private let logger: ShitsuraeLogger
    private let stateStore: RuntimeStateStore
    private let supportedBuildCatalogURL: URL
    private let arrangeDriver: ArrangeDriver
    private let arrangeRequestDeduplicator: ArrangeRequestDeduplicating
    private let autoReloadMonitorEnabled: Bool
    private let environment: [String: String]
    private let configDirectoryOverride: URL?
    private let runtimeHooks: CommandServiceRuntimeHooks
    private let configWatchDebounceMs = 250

    private var lastConfigReload: ConfigReloadStatus
    private var watchStatus: WatchStatus
    private var watcher: ConfigWatcher?
    private var cachedValidConfig: LoadedConfig?

    public var onAutoReload: ((Bool) -> Void)?

    public init(
        configLoader: ConfigLoader = ConfigLoader(),
        logger: ShitsuraeLogger = ShitsuraeLogger(),
        stateStore: RuntimeStateStore = RuntimeStateStore(),
        supportedBuildCatalogURL: URL = CommandService.bundledSupportedBuildCatalogURL,
        arrangeDriver: ArrangeDriver = LiveArrangeDriver(),
        arrangeRequestDeduplicator: ArrangeRequestDeduplicating? = nil,
        enableAutoReloadMonitor: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configDirectoryOverride: URL? = nil,
        runtimeHooks: CommandServiceRuntimeHooks = .live
    ) {
        self.configLoader = configLoader
        self.logger = logger
        self.stateStore = stateStore
        self.supportedBuildCatalogURL = supportedBuildCatalogURL
        self.arrangeDriver = arrangeDriver
        self.arrangeRequestDeduplicator = arrangeRequestDeduplicator
            ?? FileBasedArrangeRequestDeduplicator(environment: environment)
        self.autoReloadMonitorEnabled = enableAutoReloadMonitor
        self.environment = environment
        self.configDirectoryOverride = configDirectoryOverride
        self.runtimeHooks = runtimeHooks
        self.lastConfigReload = ConfigReloadStatus(
            status: "success",
            at: Date.rfc3339UTC(),
            trigger: "manual",
            errorCode: nil,
            message: nil
        )
        self.watchStatus = WatchStatus(debounceMs: configWatchDebounceMs, watcherRunning: false)

        if enableAutoReloadMonitor {
            setupAutoReloadMonitor()
        }
    }

    deinit {
        watcher?.stop()
    }

    public func validate(json: Bool) -> CommandResult {
        do {
            _ = try loadConfigFromSource()
            let payload = ValidateJSON(schemaVersion: 1, valid: true, errors: [])
            if json {
                return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
            }
            return CommandResult(exitCode: 0, stdout: "valid\n")
        } catch let error as ConfigLoadError {
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message)
            if json {
                let payload = ValidateJSON(schemaVersion: 1, valid: false, errors: error.errors)
                return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n")
            }

            let message = error.errors.map { "\($0.path): \($0.message)" }.joined(separator: "\n") + "\n"
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: message)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }
    }

    public func layoutsList() -> CommandResult {
        do {
            let loaded = try loadConfig(trigger: "manual")
            let output = loaded.config.layouts.keys.sorted().joined(separator: "\n")
            if output.isEmpty {
                return CommandResult(exitCode: 0)
            }
            return CommandResult(exitCode: 0, stdout: output + "\n")
        } catch let error as ConfigLoadError {
            let message = error.errors.map { $0.message }.joined(separator: "\n") + "\n"
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: message)
        } catch {
            return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: error.localizedDescription + "\n")
        }
    }

    public func diagnostics(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "diagnostics supports --json only\n"
            )
        }

        let loaded: LoadedConfig?
        let loadError: ConfigLoadError?

        do {
            loaded = try loadConfig(trigger: "manual")
            loadError = nil
        } catch let error as ConfigLoadError {
            loaded = nil
            loadError = error
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message)
        } catch {
            return errorAsResult(code: .backendUnavailable, message: "failed to load config", json: true)
        }

        let diagnostics = DiagnosticsService.collect(
            loadedConfig: loaded,
            loadError: loadError,
            lastConfigReload: lastConfigReload,
            supportedBuildCatalogURL: supportedBuildCatalogURL
        )

        return CommandResult(exitCode: 0, stdout: encodeJSON(diagnostics) + "\n")
    }

    public func arrange(
        layoutName: String,
        spaceID: Int? = nil,
        dryRun: Bool,
        verbose: Bool,
        json: Bool,
        stateOnly: Bool = false
    ) -> CommandResult {
        if dryRun, stateOnly {
            return errorAsResult(
                code: .validationError,
                message: "dryRun and stateOnly cannot be combined",
                json: json
            )
        }

        if !dryRun, !stateOnly, arrangeRequestDeduplicator.shouldSuppress(layoutName: layoutName, spaceID: spaceID) {
            var fields: [String: Any] = ["layout": layoutName]
            if let spaceID {
                fields["spaceID"] = spaceID
            }
            logger.log(level: "info", event: "arrange.duplicateSuppressed", fields: fields)
            let execution = ArrangeExecutionJSON(
                schemaVersion: 1,
                layout: layoutName,
                spacesMode: .perDisplay,
                result: "success",
                hardErrors: [],
                softErrors: [],
                skipped: [],
                warnings: [
                    WarningItem(
                        code: "arrange.duplicateSuppressed",
                        detail: "suppressed duplicate arrange request"
                    ),
                ],
                exitCode: ErrorCode.success.rawValue
            )
            if json {
                return CommandResult(exitCode: 0, stdout: encodeJSON(execution) + "\n")
            }
            let stdout = renderExecution(execution)
            let stderr = verbose ? renderVerbose(execution) : ""
            return CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
        }

        do {
            let loaded = try loadConfig(trigger: "manual")
            let service = ArrangeService(
                context: ArrangeContext(config: loaded.config, supportedBuildCatalogURL: supportedBuildCatalogURL),
                logger: logger,
                stateStore: stateStore,
                driver: arrangeDriver
            )

            if dryRun {
                let plan = try service.dryRun(layoutName: layoutName, spaceID: spaceID)
                if json {
                    return CommandResult(exitCode: 0, stdout: encodeJSON(plan) + "\n")
                }
                return CommandResult(exitCode: 0, stdout: renderDryRun(plan))
            }

            let execution = try service.execute(layoutName: layoutName, spaceID: spaceID, stateOnly: stateOnly)
            if json {
                return CommandResult(exitCode: Int32(execution.exitCode), stdout: encodeJSON(execution) + "\n")
            }

            let stdout = renderExecution(execution)
            let stderr = verbose ? renderVerbose(execution) : ""
            return CommandResult(exitCode: Int32(execution.exitCode), stdout: stdout, stderr: stderr)
        } catch let error as ConfigLoadError {
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message)
            if json {
                if dryRun {
                    let payload = CommonErrorJSON(code: error.code, message: error.errors.first?.message ?? "config load failed")
                    return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n")
                }

                let failed = ArrangeExecutionJSON(
                    schemaVersion: 1,
                    layout: layoutName,
                    spacesMode: .perDisplay,
                    result: "failed",
                    hardErrors: [
                        ErrorItem(
                            code: error.code.rawValue,
                            message: error.errors.first?.message ?? "config load failed",
                            spaceID: nil,
                            slot: nil
                        ),
                    ],
                    softErrors: [],
                    skipped: [],
                    warnings: [],
                    exitCode: error.code.rawValue
                )

                return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(failed) + "\n")
            }

            let stderr = error.errors.map { "\($0.path): \($0.message)" }.joined(separator: "\n") + "\n"
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: stderr)
        } catch let error as ShitsuraeError {
            if json {
                let payload = CommonErrorJSON(code: error.code, message: error.message, subcode: error.subcode)
                return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n")
            }
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: error.message + "\n")
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }
    }

    public func windowCurrent(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "window current supports --json only\n"
            )
        }

        guard runtimeHooks.accessibilityGranted() else {
            return commonJSONError(.missingPermission, "Accessibility permission is required", toStdErr: false)
        }

        guard let focused = runtimeHooks.focusedWindow() else {
            return commonJSONError(.targetWindowNotFound, "focused window not found", toStdErr: false)
        }

        let spacesMode = (try? loadConfig(trigger: "manual").config.resolvedSpacesMode) ?? .perDisplay
        let slotEntry = findSlotEntry(for: focused)

        let payload = WindowCurrentJSON(
            schemaVersion: 1,
            windowID: focused.windowID,
            bundleID: focused.bundleID,
            pid: focused.pid,
            title: focused.title,
            profile: slotEntry?.profile ?? focused.profileDirectory,
            spaceID: focused.isFullscreen ? nil : focused.spaceID,
            spacesMode: spacesMode,
            displayID: focused.displayID ?? "unknown",
            role: focused.role,
            subrole: focused.subrole,
            isMinimized: focused.minimized,
            frame: focused.frame,
            slot: slotEntry?.slot
        )

        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    private func currentSpaceID() -> Int? {
        WindowQueryService.currentSpaceID(
            focusedWindow: runtimeHooks.focusedWindow(),
            spaces: runtimeHooks.spaces()
        )
    }

    public func displayList(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "display list supports --json only\n"
            )
        }

        let payload = DisplayListJSON(
            schemaVersion: 1,
            displays: runtimeHooks.displays().map(displaySummary)
        )
        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func displayCurrent(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "display current supports --json only\n"
            )
        }

        guard let focused = runtimeHooks.focusedWindow() else {
            return commonJSONError(.targetWindowNotFound, "focused window not found", toStdErr: false)
        }

        let displays = runtimeHooks.displays()
        guard let display = resolveDisplay(for: focused, displays: displays) else {
            return commonJSONError(.targetWindowNotFound, "current display not found", toStdErr: false)
        }

        let payload = DisplayCurrentJSON(schemaVersion: 1, display: displaySummary(display))
        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func spaceList(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "space list supports --json only\n"
            )
        }

        let windows = runtimeHooks.listWindowsOnAllSpaces()
        let focused = runtimeHooks.focusedWindow()
        let payload = SpaceListJSON(
            schemaVersion: 1,
            spaces: runtimeHooks.spaces().map { space in
                spaceSummary(space, windows: windows, focused: focused)
            }
        )
        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func spaceCurrent(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "space current supports --json only\n"
            )
        }

        guard let focused = runtimeHooks.focusedWindow() else {
            return commonJSONError(.targetWindowNotFound, "focused window not found", toStdErr: false)
        }

        guard let targetSpaceID = focused.spaceID else {
            return commonJSONError(.targetWindowNotFound, "current space not found", toStdErr: false)
        }

        let windows = runtimeHooks.listWindowsOnAllSpaces()
        let spaces = runtimeHooks.spaces()
        guard let space = spaces.first(where: { matches(space: $0, spaceID: targetSpaceID, displayID: focused.displayID) }) else {
            return commonJSONError(.targetWindowNotFound, "current space not found", toStdErr: false)
        }

        let payload = SpaceCurrentJSON(
            schemaVersion: 1,
            space: spaceSummary(space, windows: windows, focused: focused)
        )
        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func windowMove(x: LengthValue, y: LengthValue) -> CommandResult {
        windowMove(target: nil, x: x, y: y)
    }

    public func windowMove(target: WindowTargetSelector?, x: LengthValue, y: LengthValue) -> CommandResult {
        mutateWindow(target: target, x: x, y: y, width: nil, height: nil)
    }

    public func windowResize(width: LengthValue, height: LengthValue) -> CommandResult {
        windowResize(target: nil, width: width, height: height)
    }

    public func windowResize(target: WindowTargetSelector?, width: LengthValue, height: LengthValue) -> CommandResult {
        mutateWindow(target: target, x: nil, y: nil, width: width, height: height)
    }

    public func windowSet(x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) -> CommandResult {
        windowSet(target: nil, x: x, y: y, width: width, height: height)
    }

    public func windowSet(target: WindowTargetSelector?, x: LengthValue, y: LengthValue, width: LengthValue, height: LengthValue) -> CommandResult {
        mutateWindow(target: target, x: x, y: y, width: width, height: height)
    }

    public func focus(slot: Int) -> CommandResult {
        focus(slot: slot, target: nil)
    }

    public func focus(slot: Int?, target: WindowTargetSelector?) -> CommandResult {
        guard runtimeHooks.accessibilityGranted() else {
            return CommandResult(exitCode: Int32(ErrorCode.missingPermission.rawValue))
        }

        let normalizedTarget: WindowTargetSelector?
        do {
            normalizedTarget = try validateWindowTargetSelector(target)
        } catch let error as ShitsuraeError {
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: error.message + "\n")
        } catch {
            return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: error.localizedDescription + "\n")
        }

        if slot != nil, normalizedTarget != nil {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "slot cannot be combined with windowID, bundleID, or title\n"
            )
        }

        if let slot {
            return focusBySlot(slot)
        }

        guard let normalizedTarget else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "slot, windowID, or bundleID is required\n"
            )
        }

        if let windowID = normalizedTarget.windowID {
            let windows = runtimeHooks.listWindows()
            guard let window = windows.first(where: { $0.windowID == windowID }) else {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
            guard runtimeHooks.focusWindow(window.windowID, window.bundleID) else {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
            return CommandResult(exitCode: 0)
        }

        guard let bundleID = normalizedTarget.bundleID else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "slot, windowID, or bundleID is required\n"
            )
        }

        let activated: Bool
        if let title = normalizedTarget.title {
            let windows = runtimeHooks.listWindows()
            if let window = resolveWindow(bundleID: bundleID, title: title, windows: windows) {
                activated = runtimeHooks.focusWindow(window.windowID, window.bundleID)
            } else {
                activated = runtimeHooks.activateWindowWithTitle(bundleID, title)
            }
        } else {
            activated = runtimeHooks.activateBundle(bundleID)
        }

        guard activated else {
            return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
        }

        return CommandResult(exitCode: 0)
    }

    private func focusBySlot(_ slot: Int) -> CommandResult {
        guard (1 ... 9).contains(slot) else {
            return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "slot must be 1..9\n")
        }

        let state = stateStore.load()
        let currentSpaceID = currentSpaceID()
        guard let entry = resolveSlotEntry(slot: slot, state: state, currentSpaceID: currentSpaceID) else {
            return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
        }

        let loadedConfig: LoadedConfig?
        do {
            loadedConfig = try loadConfig(trigger: "manual")
        } catch let error as ConfigLoadError {
            return CommandResult(exitCode: Int32(error.code.rawValue))
        } catch {
            loadedConfig = nil
        }

        let windows = runtimeHooks.listWindows()

        if let ignoreRules = loadedConfig?.config.ignore?.focus {
            let targetWindow = resolveSlotWindow(entry: entry, windows: windows)
            if PolicyEngine.matchesIgnoreRule(window: targetWindow, rules: ignoreRules) {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
        }

        if let window = resolveTrackedSlotWindow(entry: entry, windows: windows) {
            guard runtimeHooks.focusWindow(window.windowID, window.bundleID) else {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
            return CommandResult(exitCode: 0)
        }

        if !runtimeHooks.activateBundle(entry.bundleID) {
            return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
        }

        return CommandResult(exitCode: 0)
    }

    public func shouldHandleFocusShortcut(slot: Int) -> Bool {
        guard (1 ... 9).contains(slot) else {
            return false
        }

        guard runtimeHooks.accessibilityGranted() else {
            return false
        }

        let windows = runtimeHooks.listWindows()
        let state = stateStore.load()
        guard let entry = resolveSlotEntry(
            slot: slot,
            state: state,
            currentSpaceID: currentSpaceID()
        ),
              focusShortcutTargetExists(entry: entry, windows: windows)
        else {
            return false
        }

        let loadedConfig = try? loadConfig(trigger: "manual")

        if let ignoreRules = loadedConfig?.config.ignore?.focus {
            let targetWindow = resolveSlotWindow(entry: entry, windows: windows)
            if PolicyEngine.matchesIgnoreRule(window: targetWindow, rules: ignoreRules) {
                return false
            }
        }

        return true
    }

    public func switcherList(json: Bool, includeAllSpacesOverride: Bool?) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "switcher list supports --json only\n"
            )
        }

        guard runtimeHooks.accessibilityGranted() else {
            return commonJSONError(.missingPermission, "Accessibility permission is required", toStdErr: false)
        }

        let loaded: LoadedConfig?
        do {
            loaded = try loadConfig(trigger: "manual")
        } catch let error as ConfigLoadError where isNoConfigFilesError(error) {
            loaded = nil
        } catch let error as ConfigLoadError {
            let payload = CommonErrorJSON(code: error.code, message: error.errors.first?.message ?? "failed to load config")
            return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n")
        } catch {
            return commonJSONError(.backendUnavailable, "failed to enumerate switcher candidates", toStdErr: false)
        }

        let shortcuts = loaded?.config.resolvedShortcuts ?? ResolvedShortcuts(from: nil)
        let includeAllSpaces = includeAllSpacesOverride ?? false
        let quickKeys = Array(shortcuts.quickKeys)
        let ignoreFocusRules = loaded?.config.ignore?.focus

        let windows = runtimeHooks.listWindows().filter {
            !$0.isFullscreen && !$0.hidden && !$0.minimized
        }
        let currentSpaceID = currentSpaceID()
        let slots = stateStore.load().slots

        var internalCandidates: [InternalCandidate] = []

        for window in windows {
            if PolicyEngine.matchesIgnoreRule(window: window, rules: ignoreFocusRules) {
                continue
            }

            if !includeAllSpaces,
               let currentSpaceID,
               let spaceID = window.spaceID,
               currentSpaceID != spaceID
            {
                continue
            }

            let slot = slots.first(where: { slot in
                if let windowID = slot.windowID {
                    return windowID == window.windowID
                }
                return slot.bundleID == window.bundleID
            })?.slot

            internalCandidates.append(
                InternalCandidate(
                    candidate: SwitcherCandidate(
                        id: "window:\(window.windowID)",
                        source: .window,
                        title: window.title.isEmpty ? window.bundleID : window.title,
                        bundleID: window.bundleID,
                        profile: window.profileDirectory,
                        spaceID: window.spaceID,
                        displayID: window.displayID,
                        slot: slot,
                        quickKey: nil
                    ),
                    frontIndex: window.frontIndex,
                    windowID: window.windowID,
                    inCurrentSpace: currentSpaceID != nil && window.spaceID == currentSpaceID
                )
            )
        }

        let ordered = orderCandidates(internalCandidates, prioritizeCurrentSpace: true)
        let keyed = ordered.enumerated().map { index, item in
            let quickKey = index < quickKeys.count ? String(quickKeys[index]) : nil
            return SwitcherCandidate(
                id: item.candidate.id,
                source: item.candidate.source,
                title: item.candidate.title,
                bundleID: item.candidate.bundleID,
                profile: item.candidate.profile,
                spaceID: item.candidate.spaceID,
                displayID: item.candidate.displayID,
                slot: item.candidate.slot,
                quickKey: quickKey
            )
        }

        let payload = SwitcherListJSON(
            schemaVersion: 1,
            generatedAt: Date.rfc3339UTC(),
            includeAllSpaces: includeAllSpaces,
            spacesMode: loaded?.config.resolvedSpacesMode ?? .perDisplay,
            candidates: keyed
        )

        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    private func mutateWindow(
        target: WindowTargetSelector?,
        x: LengthValue?,
        y: LengthValue?,
        width: LengthValue?,
        height: LengthValue?
    ) -> CommandResult {
        guard runtimeHooks.accessibilityGranted() else {
            return CommandResult(exitCode: Int32(ErrorCode.missingPermission.rawValue))
        }

        let normalizedTarget: WindowTargetSelector?
        do {
            normalizedTarget = try validateWindowTargetSelector(target)
        } catch let error as ShitsuraeError {
            return CommandResult(exitCode: Int32(error.code.rawValue), stderr: error.message + "\n")
        } catch {
            return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: error.localizedDescription + "\n")
        }

        let window: WindowSnapshot
        switch resolveTargetWindow(normalizedTarget) {
        case let .success(resolved):
            window = resolved
        case let .failure(result):
            return result
        }

        let displays = runtimeHooks.displays()
        let display = displays.first(where: { $0.id == window.displayID }) ?? displays.first
        let basis = display?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let scale = display?.scale ?? 2.0

        do {
            let resolvedX = try x.map { try LengthParser.parse($0).resolve(dimension: basis.width, scale: scale) }
            let resolvedY = try y.map { try LengthParser.parse($0).resolve(dimension: basis.height, scale: scale) }
            let resolvedW = try width.map { try LengthParser.parse($0).resolve(dimension: basis.width, scale: scale) }
            let resolvedH = try height.map { try LengthParser.parse($0).resolve(dimension: basis.height, scale: scale) }

            let nextWidth = resolvedW ?? window.frame.width
            let nextHeight = resolvedH ?? window.frame.height
            if nextWidth < 1 || nextHeight < 1 {
                return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue))
            }

            let frame = ResolvedFrame(
                x: basis.origin.x + (resolvedX ?? (window.frame.x - basis.origin.x)),
                y: basis.origin.y + (resolvedY ?? (window.frame.y - basis.origin.y)),
                width: nextWidth,
                height: nextHeight
            )

            let updated: Bool
            if normalizedTarget == nil {
                updated = runtimeHooks.setFocusedWindowFrame(frame)
            } else {
                updated = runtimeHooks.setWindowFrame(window.windowID, window.bundleID, frame)
            }

            if !updated {
                return CommandResult(exitCode: Int32(ErrorCode.operationTimedOut.rawValue))
            }

            return CommandResult(exitCode: 0)
        } catch {
            return CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue))
        }
    }

    private func resolveTargetWindow(_ target: WindowTargetSelector?) -> TargetWindowResolution {
        if let target {
            let windows = runtimeHooks.listWindows()
            if let windowID = target.windowID {
                guard let window = windows.first(where: { $0.windowID == windowID }) else {
                    return .failure(CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue)))
                }
                return .success(window)
            }

            guard let bundleID = target.bundleID else {
                return .failure(
                    CommandResult(
                        exitCode: Int32(ErrorCode.validationError.rawValue),
                        stderr: "window target requires windowID or bundleID\n"
                    )
                )
            }

            let matchedWindow = windows.first { window in
                guard window.bundleID == bundleID else {
                    return false
                }
                if let title = target.title {
                    return window.title == title
                }
                return true
            }

            guard let matchedWindow else {
                return .failure(CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue)))
            }
            return .success(matchedWindow)
        }

        guard let focused = runtimeHooks.focusedWindow() else {
            return .failure(CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue)))
        }
        return .success(focused)
    }

    private func validateWindowTargetSelector(_ target: WindowTargetSelector?) throws -> WindowTargetSelector? {
        guard let target, !target.isEmpty else {
            return nil
        }

        if let windowID = target.windowID {
            guard windowID > 0 else {
                throw ShitsuraeError(.validationError, "windowID must be greater than zero")
            }
            guard target.bundleID == nil, target.title == nil else {
                throw ShitsuraeError(.validationError, "windowID cannot be combined with bundleID or title")
            }
            return target
        }

        guard let bundleID = target.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty
        else {
            throw ShitsuraeError(.validationError, "title requires bundleID")
        }

        let title = target.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, title.isEmpty {
            throw ShitsuraeError(.validationError, "title must not be empty")
        }

        return WindowTargetSelector(windowID: nil, bundleID: bundleID, title: title)
    }

    private func resolveWindow(bundleID: String, title: String, windows: [WindowSnapshot]) -> WindowSnapshot? {
        windows.first { window in
            window.bundleID == bundleID && window.title == title
        }
    }

    private func resolveTrackedSlotWindow(entry: SlotEntry, windows: [WindowSnapshot]) -> WindowSnapshot? {
        guard let windowID = entry.windowID else {
            return nil
        }

        return windows.first(where: { $0.windowID == windowID })
    }

    private func resolveSlotWindow(entry: SlotEntry, windows: [WindowSnapshot]) -> WindowSnapshot {
        if let windowID = entry.windowID,
           let exact = windows.first(where: { $0.windowID == windowID })
        {
            return exact
        }

        if let byBundle = windows.first(where: { $0.bundleID == entry.bundleID }) {
            return byBundle
        }

        return WindowSnapshot(
            windowID: entry.windowID ?? 0,
            bundleID: entry.bundleID,
            pid: 0,
            title: entry.title,
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: 100, height: 100),
            spaceID: entry.spaceID,
            displayID: entry.displayID,
            isFullscreen: false,
            frontIndex: Int.max
        )
    }

    private func focusShortcutTargetExists(entry: SlotEntry, windows: [WindowSnapshot]) -> Bool {
        if let windowID = entry.windowID,
           windows.contains(where: { $0.windowID == windowID })
        {
            return true
        }

        return windows.contains(where: { $0.bundleID == entry.bundleID })
    }

    private func findSlotEntry(for window: WindowSnapshot) -> SlotEntry? {
        let state = stateStore.load()

        if let matchedByWindowID = state.slots.first(where: { $0.windowID == window.windowID }) {
            return matchedByWindowID
        }

        return state.slots.first(where: { $0.bundleID == window.bundleID })
    }

    private func resolveSlotEntry(slot: Int, state: RuntimeState, currentSpaceID: Int?) -> SlotEntry? {
        let matching = state.slots.filter { $0.slot == slot }
        if let currentSpaceID,
           let currentSpaceMatch = matching.first(where: { $0.spaceID == currentSpaceID })
        {
            return currentSpaceMatch
        }

        return matching.first
    }

    private func displaySummary(_ display: DisplayInfo) -> DisplaySummaryJSON {
        DisplaySummaryJSON(
            id: display.id,
            isPrimary: display.isPrimary,
            scale: display.scale,
            pixelWidth: display.width,
            pixelHeight: display.height,
            frame: resolvedFrame(display.frame),
            visibleFrame: resolvedFrame(display.visibleFrame)
        )
    }

    private func resolveDisplay(for window: WindowSnapshot, displays: [DisplayInfo]) -> DisplayInfo? {
        if let displayID = window.displayID,
           let exact = displays.first(where: { $0.id == displayID })
        {
            return exact
        }

        if displays.count == 1 {
            return displays[0]
        }

        return nil
    }

    private func spaceSummary(_ space: SpaceInfo, windows: [WindowSnapshot], focused: WindowSnapshot?) -> SpaceSummaryJSON {
        let windowIDs = windows
            .filter { matches(space: space, window: $0) }
            .map(\.windowID)
            .sorted()
        let hasFocus = focused.map { matches(space: space, window: $0) } ?? false

        return SpaceSummaryJSON(
            spaceID: space.spaceID,
            displayID: space.displayID,
            isVisible: space.isVisible,
            isNativeFullscreen: space.isNativeFullscreen,
            hasFocus: hasFocus,
            windowIDs: windowIDs
        )
    }

    private func matches(space: SpaceInfo, window: WindowSnapshot) -> Bool {
        guard window.spaceID == space.spaceID else {
            return false
        }

        if let displayID = space.displayID {
            return window.displayID == displayID
        }

        return true
    }

    private func matches(space: SpaceInfo, spaceID: Int, displayID targetDisplayID: String?) -> Bool {
        guard space.spaceID == spaceID else {
            return false
        }

        if let displayID = space.displayID {
            return displayID == targetDisplayID
        }

        return true
    }

    private func resolvedFrame(_ rect: CGRect) -> ResolvedFrame {
        ResolvedFrame(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    private func orderCandidates(_ candidates: [InternalCandidate], prioritizeCurrentSpace: Bool) -> [InternalCandidate] {
        let baseSorted = candidates.sorted { lhs, rhs in
            if lhs.frontIndex != rhs.frontIndex { return lhs.frontIndex < rhs.frontIndex }

            switch (lhs.windowID, rhs.windowID) {
            case let (.some(left), .some(right)):
                if left != right { return left < right }
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                break
            }

            return lhs.candidate.id < rhs.candidate.id
        }

        let spaceOrdered: [InternalCandidate]
        if prioritizeCurrentSpace {
            let current = baseSorted.filter(\.inCurrentSpace)
            let other = baseSorted.filter { !$0.inCurrentSpace }
            spaceOrdered = current + other
        } else {
            spaceOrdered = baseSorted
        }

        let indexed = Array(spaceOrdered.enumerated())
        let slotted = indexed
            .filter { $0.element.candidate.slot != nil }
            .sorted { lhs, rhs in
                let leftSlot = lhs.element.candidate.slot ?? Int.max
                let rightSlot = rhs.element.candidate.slot ?? Int.max
                if leftSlot != rightSlot {
                    return leftSlot < rightSlot
                }
                return lhs.offset < rhs.offset
            }
        let nonSlotted = indexed.filter { $0.element.candidate.slot == nil }
        return (slotted + nonSlotted).map(\.element)
    }

    private func setupAutoReloadMonitor() {
        let directory = resolvedConfigDirectoryURL()

        // 初期状態は手動読込で決め、失敗時は既定 watch 設定を維持する。
        do {
            let loaded = try configLoader.load(from: directory)
            cachedValidConfig = loaded
            watchStatus = WatchStatus(
                debounceMs: configWatchDebounceMs,
                watcherRunning: false
            )
            updateLastReload(status: "success", code: nil, message: nil, trigger: "manual")
        } catch let error as ConfigLoadError {
            watchStatus = WatchStatus(debounceMs: configWatchDebounceMs, watcherRunning: false)
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message, trigger: "manual")
            RecentErrorStore.shared.record(error.code, summary: error.errors.first?.message ?? "config load failed")
        } catch {
            watchStatus = WatchStatus(debounceMs: configWatchDebounceMs, watcherRunning: false)
            updateLastReload(status: "failed", code: ErrorCode.validationError.rawValue, message: error.localizedDescription, trigger: "manual")
            RecentErrorStore.shared.record(.validationError, summary: error.localizedDescription)
        }

        let watcher = ConfigWatcher(
            directoryURL: directory,
            debounceMs: watchStatus.debounceMs,
            configLoader: configLoader
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(loaded):
                self.cachedValidConfig = loaded
                self.updateLastReload(status: "success", code: nil, message: nil, trigger: "auto")
                self.onAutoReload?(true)
            case let .failure(error):
                self.updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message, trigger: "auto")
                RecentErrorStore.shared.record(error.code, summary: error.errors.first?.message ?? "auto reload failed")
                self.onAutoReload?(false)
            }
        }

        let running = watcher.start()
        self.watcher = watcher
        watchStatus = WatchStatus(
            debounceMs: watchStatus.debounceMs,
            watcherRunning: running
        )
    }

    private func loadConfig(trigger: String) throws -> LoadedConfig {
        do {
            let loaded = try loadConfigFromSource()
            updateLastReload(status: "success", code: nil, message: nil, trigger: trigger)
            cachedValidConfig = loaded
            return loaded
        } catch let error as ConfigLoadError {
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message, trigger: trigger)
            throw error
        }
    }

    private func updateLastReload(status: String, code: Int?, message: String?, trigger: String = "manual") {
        lastConfigReload = ConfigReloadStatus(
            status: status,
            at: Date.rfc3339UTC(),
            trigger: trigger,
            errorCode: code,
            message: message
        )
    }

    private func renderDryRun(_ plan: ArrangeDryRunJSON) -> String {
        var lines: [String] = []
        lines.append("layout: \(plan.layout)")
        lines.append("spacesMode: \(plan.spacesMode.rawValue)")
        lines.append("planCount: \(plan.plan.count)")
        lines.append("skippedCount: \(plan.skipped.count)")
        lines.append("warningCount: \(plan.warnings.count)")
        return lines.joined(separator: "\n") + "\n"
    }

    private func renderExecution(_ execution: ArrangeExecutionJSON) -> String {
        [
            "layout: \(execution.layout)",
            "result: \(execution.result)",
            "exitCode: \(execution.exitCode)",
            "hardErrors: \(execution.hardErrors.count)",
            "softErrors: \(execution.softErrors.count)",
            "skipped: \(execution.skipped.count)",
            "warnings: \(execution.warnings.count)",
        ].joined(separator: "\n") + "\n"
    }

    private func renderVerbose(_ execution: ArrangeExecutionJSON) -> String {
        var lines: [String] = []
        for error in execution.hardErrors {
            lines.append("hardError code=\(error.code) message=\(error.message)")
        }
        for error in execution.softErrors {
            lines.append("softError code=\(error.code) message=\(error.message)")
        }
        for warning in execution.warnings {
            lines.append("warning code=\(warning.code) detail=\(warning.detail)")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func commonJSONError(_ code: ErrorCode, _ message: String, toStdErr: Bool, subcode: String? = nil) -> CommandResult {
        let payload = CommonErrorJSON(code: code, message: message, subcode: subcode)
        let encoded = encodeJSON(payload) + "\n"
        if toStdErr {
            return CommandResult(exitCode: Int32(code.rawValue), stderr: encoded)
        }
        return CommandResult(exitCode: Int32(code.rawValue), stdout: encoded)
    }

    private func errorAsResult(code: ErrorCode, message: String, json: Bool) -> CommandResult {
        if json {
            let payload = CommonErrorJSON(code: code, message: message)
            return CommandResult(exitCode: Int32(code.rawValue), stdout: encodeJSON(payload) + "\n")
        }

        return CommandResult(exitCode: Int32(code.rawValue), stderr: message + "\n")
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder.pretty.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return text
    }

    private func loadConfigFromSource() throws -> LoadedConfig {
        if let configDirectoryOverride {
            return try configLoader.load(from: configDirectoryOverride)
        }
        return try configLoader.loadFromDefaultDirectory(environment: environment)
    }

    private func isNoConfigFilesError(_ error: ConfigLoadError) -> Bool {
        guard error.code == .validationError else {
            return false
        }

        return error.errors.contains(where: { $0.message == "no YAML config files found" })
    }

    private func resolvedConfigDirectoryURL() -> URL {
        if let configDirectoryOverride {
            return configDirectoryOverride
        }
        return ConfigPathResolver.configDirectoryURL(environment: environment)
    }
}

private struct InternalCandidate {
    let candidate: SwitcherCandidate
    let frontIndex: Int
    let windowID: UInt32?
    let inCurrentSpace: Bool
}

private enum TargetWindowResolution {
    case success(WindowSnapshot)
    case failure(CommandResult)
}
