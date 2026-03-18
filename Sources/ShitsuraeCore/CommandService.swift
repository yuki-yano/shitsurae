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
    public let focusWindow: (UInt32, String) -> WindowInteractionResult
    public let setWindowMinimized: (UInt32, String, Bool) -> WindowInteractionResult
    public let setFocusedWindowFrame: (ResolvedFrame) -> Bool
    public let setWindowFrame: (UInt32, String, ResolvedFrame) -> Bool
    public let setWindowPosition: (UInt32, String, CGPoint) -> Bool
    public let displays: () -> [DisplayInfo]
    public let spaces: () -> [SpaceInfo]
    public let runProcess: (String, [String]) -> (exitCode: Int32, output: String)
    public let now: () -> Date

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
        focusWindow: @escaping (UInt32, String) -> WindowInteractionResult = WindowQueryService.focusWindowResult,
        setWindowMinimized: @escaping (UInt32, String, Bool) -> WindowInteractionResult = WindowQueryService.setWindowMinimizedResult,
        setWindowFrame: @escaping (UInt32, String, ResolvedFrame) -> Bool = { _, _, _ in true },
        setWindowPosition: @escaping (UInt32, String, CGPoint) -> Bool = { _, _, _ in true },
        spaces: @escaping () -> [SpaceInfo] = { WindowQueryService.listSpaces() },
        listWindowsOnAllSpaces: @escaping () -> [WindowSnapshot] = { WindowQueryService.listWindowsOnAllSpaces() },
        now: @escaping () -> Date = Date.init
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.listWindows = listWindows
        self.listWindowsOnAllSpaces = listWindowsOnAllSpaces
        self.focusedWindow = focusedWindow
        self.activateBundle = activateBundle
        self.activateWindowWithTitle = activateWindowWithTitle
        self.focusWindow = focusWindow
        self.setWindowMinimized = setWindowMinimized
        self.setFocusedWindowFrame = setFocusedWindowFrame
        self.setWindowFrame = setWindowFrame
        self.setWindowPosition = setWindowPosition
        self.displays = displays
        self.spaces = spaces
        self.runProcess = runProcess
        self.now = now
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
        setWindowFrame: { windowID, bundleID, frame in
            WindowQueryService.setWindowFrame(windowID: windowID, bundleID: bundleID, frame: frame)
        },
        setWindowPosition: WindowQueryService.setWindowPosition,
        spaces: { WindowQueryService.listSpaces() },
        listWindowsOnAllSpaces: { WindowQueryService.listWindowsOnAllSpaces() }
    )
}

public final class CommandService {
    public static let bundledSupportedBuildCatalogURL = BundledResourceLocator.supportedBuildCatalogURL()
    static let virtualSpaceCriticalSectionTimeoutMS = 10_000

    private struct WatchStatus {
        let debounceMs: Int
        let watcherRunning: Bool
    }

    private let configLoader: ConfigLoader
    private let logger: ShitsuraeLogger
    private let stateStore: RuntimeStateStore
    private let diagnosticEventStore: DiagnosticEventStore
    private let stateMutationLock: VirtualSpaceStateMutationLock
    private let stateMutationLockTimeoutMS: Int
    private let stateMutationLockPollIntervalMS: Int
    private let stateMutationOwnerProcessKind: String
    private let stateMutationOwnerStartedAt: String
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
        diagnosticEventStore: DiagnosticEventStore = DiagnosticEventStore(),
        stateMutationLock: VirtualSpaceStateMutationLock? = nil,
        stateMutationLockTimeoutMS: Int = VirtualSpaceStateMutationLock.lockWaitTimeoutMS,
        stateMutationLockPollIntervalMS: Int = VirtualSpaceStateMutationLock.defaultPollIntervalMS,
        stateMutationOwnerProcessKind: String = "cli",
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
        self.diagnosticEventStore = diagnosticEventStore
        self.stateMutationLock = stateMutationLock ?? Self.defaultStateMutationLock(environment: environment)
        self.stateMutationLockTimeoutMS = stateMutationLockTimeoutMS
        self.stateMutationLockPollIntervalMS = stateMutationLockPollIntervalMS
        self.stateMutationOwnerProcessKind = stateMutationOwnerProcessKind
        self.stateMutationOwnerStartedAt = Date.rfc3339UTC()
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

    public convenience init(
        configLoader: ConfigLoader = ConfigLoader(),
        logger: ShitsuraeLogger = ShitsuraeLogger(),
        stateStore: RuntimeStateStore = RuntimeStateStore(),
        diagnosticEventStore: DiagnosticEventStore = DiagnosticEventStore(),
        supportedBuildCatalogURL: URL = CommandService.bundledSupportedBuildCatalogURL,
        arrangeDriver: ArrangeDriver = LiveArrangeDriver(),
        arrangeRequestDeduplicator: ArrangeRequestDeduplicating? = nil,
        enableAutoReloadMonitor: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configDirectoryOverride: URL? = nil,
        runtimeHooks: CommandServiceRuntimeHooks = .live
    ) {
        self.init(
            configLoader: configLoader,
            logger: logger,
            stateStore: stateStore,
            diagnosticEventStore: diagnosticEventStore,
            stateMutationLock: nil,
            stateMutationLockTimeoutMS: VirtualSpaceStateMutationLock.lockWaitTimeoutMS,
            stateMutationLockPollIntervalMS: VirtualSpaceStateMutationLock.defaultPollIntervalMS,
            stateMutationOwnerProcessKind: "cli",
            supportedBuildCatalogURL: supportedBuildCatalogURL,
            arrangeDriver: arrangeDriver,
            arrangeRequestDeduplicator: arrangeRequestDeduplicator,
            enableAutoReloadMonitor: enableAutoReloadMonitor,
            environment: environment,
            configDirectoryOverride: configDirectoryOverride,
            runtimeHooks: runtimeHooks
        )
    }

    deinit {
        watcher?.stop()
    }

    private static func defaultStateMutationLock(environment: [String: String]) -> VirtualSpaceStateMutationLock {
        let fileURL = ConfigPathResolver.stateDirectoryURL(environment: environment)
            .appendingPathComponent("virtual-space-state.lock")
        return VirtualSpaceStateMutationLock(fileURL: fileURL)
    }

    /// Updates `lastActivatedAt` for the slot matching the given windowID.
    /// Best-effort: silently no-ops when virtual mode is inactive or the
    /// window is untracked.
    public func touchVirtualActivation(windowID: UInt32) {
        let state = stateStore.load()
        guard state.stateMode == .virtual,
              let layoutName = state.activeLayoutName
        else { return }

        guard let index = state.slots.firstIndex(where: { $0.windowID == windowID }) else {
            return
        }

        let entry = state.slots[index]
        let timestamp = Date.rfc3339UTC()
        let updated = slotEntry(
            entry,
            window: nil,
            lastVisibleFrame: entry.lastVisibleFrame,
            lastHiddenFrame: entry.lastHiddenFrame,
            visibilityState: entry.visibilityState,
            lastActivatedAt: timestamp
        )

        var newSlots = state.slots
        newSlots[index] = updated
        do {
            try stateStore.saveStrict(
                state: state.with(slots: newSlots),
                expecting: RuntimeStateWriteExpectation(
                    revision: state.revision,
                    configGeneration: state.configGeneration
                )
            )
        } catch {
            logger.log(
                level: "warn",
                event: "touchVirtualActivation.skipped",
                fields: [
                    "windowID": Int(windowID),
                    "layoutName": layoutName,
                    "reason": "concurrentModification",
                ]
            )
        }
    }

    /// Clear the persisted runtime state so the app starts fresh.
    public func clearRuntimeState() {
        stateStore.clear()
    }

    /// Returns the virtual spaceID that owns the given windowID, or nil if
    /// the window is not tracked or virtual mode is inactive.
    public func virtualSpaceIDForWindow(_ windowID: UInt32) -> Int? {
        let state = stateStore.load()
        guard state.stateMode == .virtual else { return nil }
        return state.slots.first(where: { $0.windowID == windowID })?.spaceID
    }

    /// Returns the current active virtual space ID, or nil if virtual mode
    /// is inactive or no space is active.
    public func activeVirtualSpaceID() -> Int? {
        let state = stateStore.load()
        guard state.stateMode == .virtual else { return nil }
        return state.activeVirtualSpaceID
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
                schemaVersion: 2,
                layout: layoutName,
                spacesMode: .perDisplay,
                result: "success",
                subcode: nil,
                unresolvedSlots: [],
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
            let stdout = ArrangeCommandOutputRenderer.execution(execution)
            let stderr = verbose ? ArrangeCommandOutputRenderer.verbose(execution) : ""
            return CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
        }

        do {
            let loaded = try loadConfig(trigger: "manual")
            let requestID = UUID().uuidString.lowercased()
            let runtimeState = stateStore.load()

            if loaded.config.resolvedSpaceInterpretationMode == .virtual,
               let arrangeValidationFailure = virtualArrangeValidationFailure(
                   layoutName: layoutName,
                   spaceID: spaceID,
                   stateOnly: stateOnly,
                   loadedConfig: loaded,
                   state: runtimeState,
                   json: json
               )
            {
                return arrangeValidationFailure
            }

            let service = ArrangeService(
                context: ArrangeContext(
                    config: loaded.config,
                    supportedBuildCatalogURL: supportedBuildCatalogURL,
                    configGeneration: loaded.configGeneration
                ),
                logger: logger,
                stateStore: stateStore,
                driver: arrangeDriver
            )

            if dryRun {
                let plan = try service.dryRun(layoutName: layoutName, spaceID: spaceID)
                if json {
                    return CommandResult(exitCode: 0, stdout: encodeJSON(plan) + "\n")
                }
                return CommandResult(exitCode: 0, stdout: ArrangeCommandOutputRenderer.dryRun(plan))
            }

            // Before live arrange in virtual mode, restore all hidden
            // windows to their visible positions so that the arrange
            // process finds every window in a consistent on-screen state.
            if loaded.config.resolvedSpaceInterpretationMode == .virtual,
               !stateOnly,
               let layout = loaded.config.layouts[layoutName]
            {
                restoreHiddenWindowsBeforeArrange(layoutName: layoutName, layout: layout)
            }

            let execution: ArrangeExecutionJSON
            if loaded.config.resolvedSpaceInterpretationMode == .virtual,
               spaceID != nil
            {
                do {
                    execution = try withStateMutationLock(requestID: requestID) {
                        try service.execute(layoutName: layoutName, spaceID: spaceID, stateOnly: stateOnly)
                    }
                } catch let error as VirtualSpaceStateMutationLockError {
                    return arrangeBusyResultForStateMutationLock(
                        error,
                        layoutName: layoutName,
                        spacesMode: loaded.config.resolvedSpacesMode,
                        requestID: requestID,
                        state: stateStore.load(),
                        attemptedTargetSpaceID: spaceID,
                        json: json
                    )
                }
            } else {
                execution = try service.execute(layoutName: layoutName, spaceID: spaceID, stateOnly: stateOnly)
            }

            // After a successful virtual arrange, adopt untracked windows
            // into the first workspace and hide all non-active workspace
            // windows so that only the initialFocus workspace is visible.
            if loaded.config.resolvedSpaceInterpretationMode == .virtual,
               execution.exitCode == ErrorCode.success.rawValue || execution.exitCode == ErrorCode.partialSuccess.rawValue,
               let layout = loaded.config.layouts[layoutName],
               let firstSpace = layout.spaces.first
            {
                let savedState = stateStore.load()
                if savedState.activeLayoutName == layoutName {
                    let onScreenWindows = runtimeHooks.listWindows()
                    let newEntries = adoptUntrackedWindows(
                        windows: onScreenWindows,
                        existingSlots: savedState.slots,
                        layoutName: layoutName,
                        targetSpaceID: firstSpace.spaceID
                    )
                    if !newEntries.isEmpty {
                        logger.log(
                            event: "arrange.adoptedUntrackedWindows",
                            fields: [
                                "layoutName": layoutName,
                                "targetSpaceID": firstSpace.spaceID,
                                "adoptedCount": newEntries.count,
                            ]
                        )
                    }

                    let allSlots = savedState.slots + newEntries
                    let activeSpaceID = savedState.activeVirtualSpaceID ?? firstSpace.spaceID
                    let allWindows = runtimeHooks.listWindowsOnAllSpaces()
                    let displays = runtimeHooks.displays()

                    if let hostDisplay = resolveVirtualHostDisplay(
                        layout: layout,
                        config: loaded.config,
                        focusedWindow: runtimeHooks.focusedWindow(),
                        displays: displays,
                        spaces: runtimeHooks.spaces()
                    ) {
                        // Hide ALL tracked windows that do NOT belong to the
                        // active workspace.  This covers both config-tracked
                        // and adopted entries.
                        var updatedSlots = allSlots
                        var hiddenCount = 0
                        for (index, entry) in allSlots.enumerated() {
                            guard entry.layoutName == layoutName,
                                  entry.spaceID != activeSpaceID,
                                  let windowID = entry.windowID,
                                  let window = allWindows.first(where: { $0.windowID == windowID })
                            else { continue }

                            guard let plan = planVirtualVisibility(
                                entry: entry,
                                window: window,
                                transition: .hide,
                                layout: layout,
                                hostDisplay: hostDisplay,
                                displays: displays
                            ) else { continue }
                            _ = applyVirtualVisibilityPlan(window: window, plan: plan, hooks: runtimeHooks, logger: logger)
                            updatedSlots[index] = plan.updatedEntry
                            hiddenCount += 1
                        }

                        stateStore.save(state: savedState.with(slots: updatedSlots))
                        if hiddenCount > 0 {
                            logger.log(
                                event: "arrange.hidNonActiveWorkspaceWindows",
                                fields: [
                                    "layoutName": layoutName,
                                    "activeSpaceID": activeSpaceID,
                                    "hiddenCount": hiddenCount,
                                ]
                            )
                        }
                    } else if !newEntries.isEmpty {
                        // No host display available for visibility convergence,
                        // but still save adopted entries.
                        stateStore.save(state: savedState.with(slots: allSlots))
                    }
                }
            }

            if json {
                return CommandResult(exitCode: Int32(execution.exitCode), stdout: encodeJSON(execution) + "\n")
            }

            let stdout = ArrangeCommandOutputRenderer.execution(execution)
            let stderr = verbose ? ArrangeCommandOutputRenderer.verbose(execution) : ""
            return CommandResult(exitCode: Int32(execution.exitCode), stdout: stdout, stderr: stderr)
        } catch let error as ConfigLoadError {
            updateLastReload(status: "failed", code: error.code.rawValue, message: error.errors.first?.message)
            if json {
                if dryRun {
                    let payload = CommonErrorJSON(code: error.code, message: error.errors.first?.message ?? "config load failed")
                    return CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n")
                }

                let failed = ArrangeExecutionJSON(
                    schemaVersion: 2,
                    layout: layoutName,
                    spacesMode: .perDisplay,
                    result: "failed",
                    subcode: nil,
                    unresolvedSlots: [],
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

        let loadedConfig = try? loadConfig(trigger: "manual")
        let spacesMode = loadedConfig?.config.resolvedSpacesMode ?? .perDisplay
        let readContext = reconciledRuntimeStateForRead(
            state: stateStore.load(),
            loadedConfig: loadedConfig
        )
        let state = readContext.state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let inspectionStateSubcode = virtualInspectionStateSubcode(loadedConfig: loadedConfig, state: state)
        let shouldSuppressVirtualAssignment = inspectionStateSubcode != nil
        let slotEntry = shouldSuppressVirtualAssignment ? nil : findSlotEntry(for: focused, slotEntries: slotEntries)

        let resolvedSpaceID: Int?
        let activeSpaceID: Int?
        switch mode {
        case .native:
            resolvedSpaceID = focused.isFullscreen ? nil : focused.spaceID
            activeSpaceID = focused.isFullscreen ? nil : focused.spaceID
        case .virtual:
            resolvedSpaceID = shouldSuppressVirtualAssignment ? nil : slotEntry?.spaceID
            if !shouldSuppressVirtualAssignment,
               let layout = RuntimeStateReadResolver.activeVirtualLayout(loadedConfig: loadedConfig, state: state),
               let candidate = state.activeVirtualSpaceID,
               layout.spaces.contains(where: { $0.spaceID == candidate })
            {
                activeSpaceID = candidate
            } else {
                activeSpaceID = nil
            }
        }

        let payload = WindowCurrentJSON(
            schemaVersion: 2,
            windowID: focused.windowID,
            bundleID: focused.bundleID,
            pid: focused.pid,
            title: focused.title,
            profile: slotEntry?.profile ?? focused.profileDirectory,
            spaceID: resolvedSpaceID,
            activeSpaceID: activeSpaceID,
            nativeSpaceID: focused.isFullscreen ? nil : focused.spaceID,
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
        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(
            state: stateStore.load(),
            loadedConfig: loadedConfig
        )
        let state = readContext.state
        let resolution = RuntimeStateReadResolver.resolveCurrentSpace(
            loadedConfig: loadedConfig,
            runtimeState: state,
            focusedWindow: runtimeHooks.focusedWindow(),
            spaces: runtimeHooks.spaces()
        )
        if case let .resolved(spaceID, _, _) = resolution {
            return spaceID
        }
        return nil
    }

    private func reconciledRuntimeStateForRead(
        state: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> RuntimeStateReadContext {
        let context = RuntimeStateReadResolver.reconciledRuntimeStateForRead(
            state: state,
            loadedConfig: loadedConfig
        )

        if context.deferredCrashLeftoverPromotion,
           let pending = context.state.pendingSwitchTransaction
        {
            diagnosticEventStore.record(
                DiagnosticEvent(
                    event: "state.read.crashLeftoverPromotionDeferred",
                    requestID: UUID().uuidString.lowercased(),
                    code: ErrorCode.validationError.rawValue,
                    subcode: "virtualStateRecoveryRequired",
                    activeLayoutName: pending.activeLayoutName,
                    activeVirtualSpaceID: nil,
                    attemptedTargetSpaceID: pending.attemptedTargetSpaceID,
                    previousActiveSpaceID: pending.previousActiveSpaceID,
                    configGeneration: state.configGeneration,
                    revision: state.revision,
                    rootCauseCategory: "readNormalizationNotPersisted",
                    failedOperation: "crashLeftoverPromotion",
                    manualRecoveryRequired: pending.manualRecoveryRequired,
                    unresolvedSlots: pending.unresolvedSlots
                )
            )
        }

        return context
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

        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: true)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: true)
        }
        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let windows = runtimeHooks.listWindowsOnAllSpaces()
        let focused = runtimeHooks.focusedWindow()
        let staleReadRequestID = RuntimeStateReadResolver.isStaleVirtualReadState(
            loadedConfig: loadedConfig,
            state: state
        )
            ? UUID().uuidString.lowercased()
            : nil
        if let staleReadRequestID {
            recordStaleStateReadDiagnosticEvent(
                requestID: staleReadRequestID,
                state: state,
                failedOperation: "space.list"
            )
        }

        let payload: SpaceListJSON
        switch mode {
        case .native:
            payload = SpaceListJSON(
                schemaVersion: 2,
                spaces: runtimeHooks.spaces().map { space in
                    nativeSpaceSummary(space, windows: windows, focused: focused, slotEntries: slotEntries)
                }
            )
        case .virtual:
            if let subcode = virtualInspectionStateSubcode(loadedConfig: loadedConfig, state: state) {
                return commonJSONError(
                    .validationError,
                    virtualInspectionStateMessage(subcode),
                    toStdErr: false,
                    subcode: subcode,
                    requestID: staleReadRequestID,
                    recoveryContext: nil
                )
            }
            guard let layout = RuntimeStateReadResolver.activeVirtualLayout(
                loadedConfig: loadedConfig,
                state: state
            ) else {
                return commonJSONError(
                    .validationError,
                    virtualInspectionStateMessage("virtualStateUnavailable"),
                    toStdErr: false,
                    subcode: "virtualStateUnavailable",
                    requestID: staleReadRequestID
                )
            }

            let spaces = uniqueSpaces(in: layout).map { space in
                virtualSpaceSummary(
                    space,
                    activeLayoutName: state.activeLayoutName,
                    activeSpaceID: state.activeVirtualSpaceID,
                    windows: windows,
                    slotEntries: slotEntries
                )
            }
            payload = SpaceListJSON(schemaVersion: 2, spaces: spaces)
        }

        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func spaceCurrent(json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "space current supports --json only\n"
            )
        }

        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: true)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: true)
        }
        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loadedConfig,
            state: state
        )
        let windows = runtimeHooks.listWindowsOnAllSpaces()
        let staleReadRequestID = RuntimeStateReadResolver.isStaleVirtualReadState(
            loadedConfig: loadedConfig,
            state: state
        )
            ? UUID().uuidString.lowercased()
            : nil
        if let staleReadRequestID {
            recordStaleStateReadDiagnosticEvent(
                requestID: staleReadRequestID,
                state: state,
                failedOperation: "space.current"
            )
        }

        let payload: SpaceCurrentJSON
        switch mode {
        case .native:
            guard let focused = runtimeHooks.focusedWindow() else {
                return commonJSONError(.targetWindowNotFound, "focused window not found", toStdErr: false)
            }

            guard let targetSpaceID = focused.spaceID else {
                return commonJSONError(.targetWindowNotFound, "current space not found", toStdErr: false)
            }

            let spaces = runtimeHooks.spaces()
            guard let space = spaces.first(where: { matches(space: $0, spaceID: targetSpaceID, displayID: focused.displayID) }) else {
                return commonJSONError(.targetWindowNotFound, "current space not found", toStdErr: false)
            }

            payload = SpaceCurrentJSON(
                schemaVersion: 2,
                space: nativeSpaceSummary(space, windows: windows, focused: focused, slotEntries: slotEntries)
            )
        case .virtual:
            if let subcode = virtualInspectionStateSubcode(loadedConfig: loadedConfig, state: state) {
                return commonJSONError(
                    .validationError,
                    virtualInspectionStateMessage(subcode),
                    toStdErr: false,
                    subcode: subcode,
                    requestID: staleReadRequestID,
                    recoveryContext: nil
                )
            }
            guard let layout = RuntimeStateReadResolver.activeVirtualLayout(
                loadedConfig: loadedConfig,
                state: state
            ),
                  let activeSpaceID = state.activeVirtualSpaceID,
                  let space = uniqueSpaces(in: layout).first(where: { $0.spaceID == activeSpaceID })
            else {
                return commonJSONError(
                    .validationError,
                    virtualInspectionStateMessage("virtualStateUnavailable"),
                    toStdErr: false,
                    subcode: "virtualStateUnavailable",
                    requestID: staleReadRequestID
                )
            }

            payload = SpaceCurrentJSON(
                schemaVersion: 2,
                space: virtualSpaceSummary(
                    space,
                    activeLayoutName: state.activeLayoutName,
                    activeSpaceID: activeSpaceID,
                    windows: windows,
                    slotEntries: slotEntries
                )
            )
        }

        return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
    }

    public func spaceSwitch(spaceID: Int, json: Bool, reconcile: Bool = false) -> CommandResult {
        let requestID = UUID().uuidString.lowercased()
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: json, requestID: requestID)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }
        let loadedConfig = try? loadConfig(trigger: "manual")
        let state = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig).state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        )

        switch mode {
        case .native:
            return spaceSwitchError(
                code: .validationError,
                message: "space switch is unsupported in native mode",
                subcode: "spaceSwitchUnsupportedInNativeMode",
                json: json
            )
        case .virtual:
            do {
                return try withStateMutationLock(requestID: requestID) {
                    switch prepareVirtualSpaceSwitch(
                        requestID: requestID,
                        targetSpaceID: spaceID,
                        reconcile: reconcile,
                        json: json
                    ) {
                    case let .result(result):
                        return result
                    case let .ready(context):
                        let operation = performVirtualSpaceSwitch(
                        targets: context.resolvedTargets,
                        others: context.resolvedOthers,
                        layout: context.layout,
                        hostDisplay: context.hostDisplay,
                        hooks: runtimeHooks,
                        logger: logger
                    )
                        return finalizeVirtualSpaceSwitch(
                            context: context,
                            targetSpaceID: spaceID,
                            requestID: requestID,
                            json: json,
                            operation: operation
                        )
                    }
                }
            } catch let error as VirtualSpaceStateMutationLockError {
                return stateMutationLockBusyResult(
                    error,
                    event: "space.switch.busy",
                    message: "virtual space switch is busy",
                    requestID: requestID,
                    state: state,
                    loadedConfig: loadedConfig,
                    attemptedTargetSpaceID: spaceID,
                    json: json
                )
            } catch {
                return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
            }
        }
    }

    public func spaceRecover(forceClearPending: Bool, confirmed: Bool, json: Bool) -> CommandResult {
        let requestID = UUID().uuidString.lowercased()
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: json, requestID: requestID)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }
        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        )

        guard forceClearPending else {
            return spaceSwitchError(
                code: .validationError,
                message: "space recover requires --force-clear-pending",
                subcode: "dangerousOperationRequiresConfirmation",
                requestID: requestID,
                recoveryContext: makeRecoveryContext(state: state, loadedConfig: loadedConfig),
                json: json
            )
        }

        switch prepareVirtualSpaceRecovery(
            requestID: requestID,
            confirmed: confirmed,
            json: json,
            mode: mode,
            state: state,
            loadedConfig: loadedConfig
        ) {
        case let .result(result):
            return result
        case let .ready(context):
            let lockResult: CommandResult?
            do {
                lockResult = try withStateMutationLock(requestID: requestID) {
                    saveVirtualSpaceRecoveryForceClear(
                        context: context,
                        requestID: requestID,
                        json: json
                    )
                }
            } catch let error as VirtualSpaceStateMutationLockError {
                return stateMutationLockBusyResult(
                    error,
                    event: "space.recovery.busy",
                    message: "virtual space recovery is busy",
                    requestID: requestID,
                    state: state,
                    loadedConfig: loadedConfig,
                    attemptedTargetSpaceID: context.pending.attemptedTargetSpaceID,
                    json: json
                )
            } catch {
                return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
            }
            if let lockResult {
                return lockResult
            }
            return successfulVirtualSpaceRecoveryResult(
                state: state,
                requestID: requestID,
                warning: context.warning,
                json: json
            )
        }
    }

    private func prepareVirtualSpaceRecovery(
        requestID: String,
        confirmed: Bool,
        json: Bool,
        mode: SpaceInterpretationMode,
        state: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> VirtualSpaceRecoveryPreparation {
        switch mode {
        case .native:
            return .result(spaceSwitchError(
                code: .validationError,
                message: "space recovery is unsupported in native mode",
                subcode: "spaceRecoveryUnsupportedInNativeMode",
                requestID: requestID,
                json: json
            ))
        case .virtual:
            guard let pending = state.pendingSwitchTransaction else {
                return .result(spaceSwitchError(
                    code: .validationError,
                    message: "virtual space recovery is not required",
                    subcode: "virtualStateRecoveryNotRequired",
                    requestID: requestID,
                    recoveryContext: makeRecoveryContext(state: state, loadedConfig: loadedConfig),
                    json: json
                ))
            }

            guard confirmed else {
                return .result(spaceSwitchError(
                    code: .validationError,
                    message: "space recover requires --yes confirmation",
                    subcode: "dangerousOperationRequiresConfirmation",
                    requestID: requestID,
                    recoveryContext: makeRecoveryContext(
                        state: state,
                        loadedConfig: loadedConfig,
                        attemptedTargetSpaceID: pending.attemptedTargetSpaceID
                    ),
                    json: json
                ))
            }

            guard recoveryForceClearEligible(loadedConfig: loadedConfig, state: state) else {
                return .result(spaceSwitchError(
                    code: .validationError,
                    message: "force clear is not allowed while live recovery remains available",
                    subcode: "virtualStateRecoveryForceClearNotAllowedWhileLiveRecoveryAvailable",
                    requestID: requestID,
                    recoveryContext: makeRecoveryContext(
                        state: state,
                        loadedConfig: loadedConfig,
                        attemptedTargetSpaceID: pending.attemptedTargetSpaceID
                    ),
                    json: json
                ))
            }

            let warning = "warning: pending virtual space recovery state was force-cleared; run a live arrange to reconcile tracked windows"
            let nextState = state.clearingActiveVirtualContext(
                updatedAt: Date.rfc3339UTC(),
                stateMode: loadedConfig?.config.resolvedSpaceInterpretationMode ?? state.stateMode,
                configGeneration: loadedConfig?.configGeneration ?? state.configGeneration,
                liveArrangeRecoveryRequired: true,
                slots: []
            )
            return .ready(VirtualSpaceRecoveryContext(
                state: state,
                pending: pending,
                nextState: nextState,
                warning: warning
            ))
        }
    }

    private func saveVirtualSpaceRecoveryForceClear(
        context: VirtualSpaceRecoveryContext,
        requestID: String,
        json: Bool
    ) -> CommandResult? {
        do {
            try stateStore.saveStrict(
                state: context.nextState,
                expecting: RuntimeStateWriteExpectation(
                    revision: context.state.revision,
                    configGeneration: context.state.configGeneration
                )
            )
            return nil
        } catch {
            return failedVirtualSpaceRecoveryForceClearResult(
                context: context,
                requestID: requestID,
                json: json,
                error: error
            )
        }
    }

    private func successfulVirtualSpaceRecoveryResult(
        state: RuntimeState,
        requestID: String,
        warning: String,
        json: Bool
    ) -> CommandResult {
        let payload = SpaceRecoveryJSON(
            requestID: requestID,
            clearedPending: true,
            previousActiveLayoutName: state.activeLayoutName,
            previousActiveSpaceID: state.activeVirtualSpaceID,
            warning: warning,
            nextActionKind: "discoverAndReconcile",
            discoveryCommand: "shitsurae arrange <layout> --dry-run --json",
            reconcileCommandTemplate: "shitsurae arrange <layout> --space <id>"
        )

        if json {
            return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
        }

        return CommandResult(exitCode: 0, stdout: warning + "\n")
    }

    private func failedVirtualSpaceRecoveryForceClearResult(
        context: VirtualSpaceRecoveryContext,
        requestID: String,
        json: Bool,
        error: Error
    ) -> CommandResult {
        recordVirtualSpaceDiagnosticEvent(
            event: "space.recovery.forceClearWriteFailed",
            requestID: requestID,
            code: .validationError,
            subcode: "spaceRecoveryStateWriteFailed",
            state: context.state,
            attemptedTargetSpaceID: context.pending.attemptedTargetSpaceID,
            rootCauseCategory: runtimeStateWriteRootCause(error),
            failedOperation: "forceClearSave",
            manualRecoveryRequired: true
        )
        return spaceSwitchError(
            code: .validationError,
            message: "space recovery state write failed",
            subcode: "spaceRecoveryStateWriteFailed",
            requestID: requestID,
            recoveryContext: RecoveryContextJSON(
                activeLayoutName: context.state.activeLayoutName ?? context.pending.activeLayoutName,
                activeVirtualSpaceID: context.state.activeVirtualSpaceID,
                attemptedTargetSpaceID: context.pending.attemptedTargetSpaceID,
                previousActiveSpaceID: context.pending.previousActiveSpaceID,
                recoveryForceClearEligible: true,
                manualRecoveryRequired: true,
                unresolvedSlots: context.pending.unresolvedSlots
            ),
            json: json
        )
    }

    private func prepareVirtualSpaceSwitch(
        requestID: String,
        targetSpaceID: Int,
        reconcile: Bool,
        json: Bool
    ) -> VirtualSpaceSwitchPreparation {
        let lockedContext: LockedRuntimeStateMutationContext
        switch loadLockedRuntimeStateMutationContext(requestID: requestID, json: json) {
        case let .result(result):
            return .result(result)
        case let .ready(context):
            lockedContext = context
        }

        let lockedPersistedState = lockedContext.persistedState
        let lockedLoadedConfig = lockedContext.loadedConfig
        let lockedState = lockedContext.state
        let lockedMode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: lockedLoadedConfig,
            state: lockedState
        )
        guard lockedMode == .virtual else {
            return .result(spaceSwitchError(
                code: .validationError,
                message: "space switch is unsupported in native mode",
                subcode: "spaceSwitchUnsupportedInNativeMode",
                json: json
            ))
        }

        guard let layout = RuntimeStateReadResolver.activeVirtualLayout(
            loadedConfig: lockedLoadedConfig,
            state: lockedState
        ),
        let layoutName = lockedState.activeLayoutName
        else {
            return .result(spaceSwitchError(
                code: .validationError,
                message: "active virtual space is unavailable",
                subcode: "virtualStateUnavailable",
                json: json
            ))
        }

        guard let targetSpace = uniqueSpaces(in: layout).first(where: { $0.spaceID == targetSpaceID }) else {
            return .result(spaceSwitchError(
                code: .validationError,
                message: "virtual space not found: \(targetSpaceID)",
                subcode: "virtualSpaceNotFound",
                json: json
            ))
        }

        let previousSpaceID = lockedState.activeVirtualSpaceID
        let didChangeSpace = previousSpaceID != targetSpaceID
        logger.log(
            event: "space.switch.started",
            fields: [
                "requestID": requestID,
                "layoutName": layoutName,
                "previousSpaceID": previousSpaceID as Any,
                "targetSpaceID": targetSpaceID,
                "didChangeSpace": didChangeSpace,
                "reconcile": reconcile,
            ]
        )

        let windows = runtimeHooks.listWindowsOnAllSpaces()
        if !didChangeSpace && !reconcile {
            return .result(noopSpaceSwitchResult(
                requestID: requestID,
                layoutName: layoutName,
                targetSpace: targetSpace,
                targetSpaceID: targetSpaceID,
                previousSpaceID: previousSpaceID,
                state: lockedState,
                windows: windows,
                json: json
            ))
        }

        guard runtimeHooks.accessibilityGranted() else {
            recordVirtualSpaceDiagnosticEvent(
                event: "space.switch.permissionDenied",
                requestID: requestID,
                code: .missingPermission,
                subcode: "virtualSpaceSwitchPermissionDenied",
                state: lockedState,
                attemptedTargetSpaceID: targetSpaceID,
                rootCauseCategory: "permissionDenied",
                permissionScope: "accessibility"
            )
            return .result(spaceSwitchError(
                code: .missingPermission,
                message: "Accessibility permission is required",
                subcode: "virtualSpaceSwitchPermissionDenied",
                json: json
            ))
        }

        let hostDisplay: DisplayInfo?
        if requiresVirtualHostDisplayPreflight(didChangeSpace: didChangeSpace, reconcile: reconcile) {
            let displays = runtimeHooks.displays()
            hostDisplay = resolveVirtualHostDisplay(
                layout: layout,
                config: lockedLoadedConfig?.config,
                focusedWindow: runtimeHooks.focusedWindow(),
                displays: displays,
                spaces: runtimeHooks.spaces()
            ) ?? displays.first(where: \.isPrimary) ?? displays.first
        } else {
            hostDisplay = nil
        }

        if requiresVirtualHostDisplayPreflight(didChangeSpace: didChangeSpace, reconcile: reconcile),
           hostDisplay == nil
        {
            return .result(spaceSwitchError(
                code: .validationError,
                message: "host display for virtual space switch is unavailable",
                subcode: "virtualHostDisplayUnavailable",
                requestID: requestID,
                recoveryContext: makeRecoveryContext(
                    state: lockedState,
                    loadedConfig: lockedLoadedConfig,
                    attemptedTargetSpaceID: targetSpaceID
                ),
                json: json
            ))
        }

        let slotsWithAdopted = prepareSpaceSwitchSlots(
            requestID: requestID,
            layoutName: layoutName,
            previousSpaceID: previousSpaceID,
            targetSpaceID: targetSpaceID,
            state: lockedState
        )
        let resolvedWindows = resolveSpaceSwitchWindows(
            requestID: requestID,
            targetSpaceID: targetSpaceID,
            layoutName: layoutName,
            slots: slotsWithAdopted,
            windows: windows
        )

        return .ready(VirtualSpaceSwitchContext(
            persistedState: lockedPersistedState,
            loadedConfig: lockedLoadedConfig,
            state: lockedState,
            layout: layout,
            layoutName: layoutName,
            targetSpace: targetSpace,
            targetSpaceID: targetSpaceID,
            previousSpaceID: previousSpaceID,
            didChangeSpace: didChangeSpace,
            hostDisplay: hostDisplay,
            windows: windows,
            slotsWithAdopted: slotsWithAdopted,
            resolvedTargets: resolvedWindows.targets,
            resolvedOthers: resolvedWindows.others,
            configGeneration: lockedLoadedConfig?.configGeneration ?? lockedState.configGeneration
        ))
    }

    private func noopSpaceSwitchResult(
        requestID: String,
        layoutName: String,
        targetSpace: SpaceDefinition,
        targetSpaceID: Int,
        previousSpaceID: Int?,
        state: RuntimeState,
        windows: [WindowSnapshot],
        json: Bool
    ) -> CommandResult {
        let payload = SpaceSwitchJSON(
            requestID: requestID,
            layoutName: layoutName,
            space: virtualSpaceSummary(
                targetSpace,
                activeLayoutName: state.activeLayoutName,
                activeSpaceID: targetSpaceID,
                windows: windows,
                slotEntries: state.slots
            ),
            previousSpaceID: previousSpaceID,
            didChangeSpace: false,
            action: "noop"
        )

        if json {
            return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
        }

        return CommandResult(
            exitCode: 0,
            stdout: "requestID=\(requestID) action=noop layout=\(layoutName) space=\(targetSpaceID) didChangeSpace=false\n"
        )
    }

    private func prepareSpaceSwitchSlots(
        requestID: String,
        layoutName: String,
        previousSpaceID: Int?,
        targetSpaceID: Int,
        state: RuntimeState
    ) -> [SlotEntry] {
        let slotsWithUpdatedActivation: [SlotEntry]
        if let previousSpaceID,
           let focusedWindow = runtimeHooks.focusedWindow()
        {
            slotsWithUpdatedActivation = markVirtualActivatedWindow(
                focusedWindow,
                in: state.slots,
                layoutName: layoutName,
                spaceID: previousSpaceID,
                activatedAt: runtimeHooks.now()
            )
        } else {
            slotsWithUpdatedActivation = state.slots
        }

        let slotsWithPrunedRuntimeManagedWindows = pruneGoneRuntimeManagedWindows(
            slots: slotsWithUpdatedActivation,
            layoutName: layoutName,
            windows: runtimeHooks.listWindowsOnAllSpaces()
        )
        let prunedCount = slotsWithUpdatedActivation.count - slotsWithPrunedRuntimeManagedWindows.count
        if prunedCount > 0 {
            logger.log(
                event: "space.switch.prunedRuntimeManagedWindows",
                fields: [
                    "requestID": requestID,
                    "layoutName": layoutName,
                    "prunedCount": prunedCount,
                ]
            )
        }

        let currentAdoptSpaceID = previousSpaceID ?? targetSpaceID
        let adoptedEntries = adoptUntrackedWindows(
            windows: runtimeHooks.listWindows(),
            existingSlots: slotsWithPrunedRuntimeManagedWindows,
            layoutName: layoutName,
            targetSpaceID: currentAdoptSpaceID
        )
        guard !adoptedEntries.isEmpty else {
            return slotsWithPrunedRuntimeManagedWindows
        }

        logger.log(
            event: "space.switch.adoptedUntrackedWindows",
            fields: [
                "requestID": requestID,
                "targetSpaceID": currentAdoptSpaceID,
                "adoptedCount": adoptedEntries.count,
            ]
        )
        return slotsWithPrunedRuntimeManagedWindows + adoptedEntries
    }

    private func resolveSpaceSwitchWindows(
        requestID: String,
        targetSpaceID: Int,
        layoutName: String,
        slots: [SlotEntry],
        windows: [WindowSnapshot]
    ) -> (targets: [VirtualSwitchWindow], others: [VirtualSwitchWindow]) {
        let trackedEntries = slots.filter { $0.layoutName == layoutName }
        let targetEntries = trackedEntries.filter { $0.spaceID == targetSpaceID }
        let otherEntries = trackedEntries.filter { $0.spaceID != targetSpaceID }
        let resolvedTargets = targetEntries.compactMap { resolveVirtualSwitchWindow(entry: $0, windows: windows) }

        if resolvedTargets.count != targetEntries.count {
            let resolvedFingerprints = Set(resolvedTargets.map(\.entry.definitionFingerprint))
            let unresolvedSlots = targetEntries.compactMap { entry -> PendingUnresolvedSlot? in
                guard !resolvedFingerprints.contains(entry.definitionFingerprint) else {
                    return nil
                }
                return PendingUnresolvedSlot(
                    slot: entry.slot,
                    spaceID: entry.spaceID ?? targetSpaceID,
                    reason: "trackedWindowNotResolved"
                )
            }
            logger.log(
                level: "warn",
                event: "space.switch.unresolvedSlots",
                fields: [
                    "requestID": requestID,
                    "targetSpaceID": targetSpaceID,
                    "expectedCount": targetEntries.count,
                    "resolvedCount": resolvedTargets.count,
                    "unresolvedSlots": unresolvedSlots.map { ["slot": $0.slot, "spaceID": $0.spaceID, "reason": $0.reason] },
                ]
            )
        }

        let resolvedOthersRaw = otherEntries.compactMap { resolveVirtualSwitchWindow(entry: $0, windows: windows) }
        let targetWindowIDs = Set(resolvedTargets.map(\.window.windowID))
        let resolvedOthers = resolvedOthersRaw.filter { !targetWindowIDs.contains($0.window.windowID) }
        return (resolvedTargets, resolvedOthers)
    }

    private func finalizeVirtualSpaceSwitch(
        context: VirtualSpaceSwitchContext,
        targetSpaceID: Int,
        requestID: String,
        json: Bool,
        operation: VirtualSwitchOperationResult
    ) -> CommandResult {
        let action = context.didChangeSpace ? "switch" : "reconcile"
        var nextSlots = applyVirtualVisibilityChanges(
            operation.appliedChanges,
            to: context.slotsWithAdopted
        )
        nextSlots = markVirtualActivatedWindow(
            operation.focusedTarget?.window,
            in: nextSlots,
            layoutName: context.layoutName,
            spaceID: targetSpaceID,
            activatedAt: runtimeHooks.now()
        )
        let nextState = context.state.withActiveVirtualContext(
            updatedAt: Date.rfc3339UTC(),
            revision: context.state.revision + (context.didChangeSpace ? 1 : 0),
            stateMode: .virtual,
            configGeneration: context.configGeneration,
            liveArrangeRecoveryRequired: false,
            layoutName: context.layoutName,
            spaceID: targetSpaceID,
            slots: nextSlots
        )

        do {
            try stateStore.saveStrict(
                state: nextState,
                expecting: RuntimeStateWriteExpectation(
                    revision: context.persistedState.revision,
                    configGeneration: context.persistedState.configGeneration
                )
            )
        } catch let error as RuntimeStateStoreError where error.validationSubcode == "staleStateWriteRejected" {
            return failedVirtualSpaceSwitchResult(
                context: context,
                targetSpaceID: targetSpaceID,
                requestID: requestID,
                json: json,
                nextState: nextState,
                error: error,
                rootCauseCategory: "staleStateWriteRejected"
            )
        } catch {
            return failedVirtualSpaceSwitchResult(
                context: context,
                targetSpaceID: targetSpaceID,
                requestID: requestID,
                json: json,
                nextState: nextState,
                error: error,
                rootCauseCategory: runtimeStateWriteRootCause(error)
            )
        }

        logger.log(
            event: "space.switch.completed",
            fields: [
                "requestID": requestID,
                "layoutName": context.layoutName,
                "previousSpaceID": context.previousSpaceID as Any,
                "targetSpaceID": targetSpaceID,
                "nextActiveSpaceID": nextState.activeVirtualSpaceID as Any,
                "didChangeSpace": context.didChangeSpace,
                "action": action,
                "targetCount": context.resolvedTargets.count,
                "otherCount": context.resolvedOthers.count,
                "focusedWindowID": operation.focusedTarget?.window.windowID as Any,
            ]
        )

        let payload = SpaceSwitchJSON(
            requestID: requestID,
            layoutName: context.layoutName,
            space: virtualSpaceSummary(
                context.targetSpace,
                activeLayoutName: nextState.activeLayoutName,
                activeSpaceID: targetSpaceID,
                windows: context.windows,
                slotEntries: nextState.slots
            ),
            previousSpaceID: context.previousSpaceID,
            didChangeSpace: context.didChangeSpace,
            action: action
        )

        if json {
            return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
        }

        return CommandResult(
            exitCode: 0,
            stdout: "requestID=\(requestID) action=\(action) layout=\(context.layoutName) space=\(targetSpaceID) didChangeSpace=\(context.didChangeSpace)\n"
        )
    }

    private func failedVirtualSpaceSwitchResult(
        context: VirtualSpaceSwitchContext,
        targetSpaceID: Int,
        requestID: String,
        json: Bool,
        nextState: RuntimeState,
        error: Error,
        rootCauseCategory: String
    ) -> CommandResult {
        recordVirtualSpaceDiagnosticEvent(
            event: "space.switch.failed",
            requestID: requestID,
            code: .virtualSpaceSwitchFailed,
            subcode: "virtualSpaceSwitchFailed",
            state: context.state,
            attemptedTargetSpaceID: targetSpaceID,
            rootCauseCategory: rootCauseCategory,
            failedOperation: "finalizeStateSave",
            manualRecoveryRequired: true
        )
        logger.log(
            level: "error",
            event: "space.switch.stateSave.failed",
            fields: [
                "requestID": requestID,
                "layoutName": context.layoutName,
                "previousSpaceID": context.previousSpaceID as Any,
                "targetSpaceID": targetSpaceID,
                "nextActiveSpaceID": nextState.activeVirtualSpaceID as Any,
                "reason": rootCauseCategory,
                "error": error.localizedDescription,
            ]
        )
        return spaceSwitchError(
            code: .virtualSpaceSwitchFailed,
            message: "virtual space switch final state write failed",
            subcode: "virtualSpaceSwitchFailed",
            requestID: requestID,
            recoveryContext: makeRecoveryContext(
                state: context.state,
                loadedConfig: context.loadedConfig,
                attemptedTargetSpaceID: targetSpaceID
            ),
            json: json
        )
    }

    /// Adopt any on-screen windows that are not yet tracked into the
    /// current virtual workspace.  Called periodically so that newly
    /// opened windows are managed without waiting for a workspace switch.
    /// Returns the number of newly adopted windows.
    @discardableResult
    public func adoptUntrackedWindowsIntoCurrentWorkspace() -> Int {
        let state = stateStore.load()
        guard state.stateMode == .virtual,
              let layoutName = state.activeLayoutName,
              let activeSpaceID = state.activeVirtualSpaceID
        else { return 0 }

        let onScreenWindows = runtimeHooks.listWindows()
        let prunedSlots = pruneGoneRuntimeManagedWindows(
            slots: state.slots,
            layoutName: layoutName,
            windows: runtimeHooks.listWindowsOnAllSpaces()
        )
        let newEntries = adoptUntrackedWindows(
            windows: onScreenWindows,
            existingSlots: prunedSlots,
            layoutName: layoutName,
            targetSpaceID: activeSpaceID
        )
        let adoptedCount = newEntries.count
        let prunedCount = state.slots.count - prunedSlots.count
        guard adoptedCount > 0 || prunedCount > 0 else { return 0 }

        // Use revision-aware save to prevent overwriting concurrent
        // state changes (e.g. a space switch that completed between
        // our load and this save).
        do {
            try stateStore.saveStrict(
                slots: prunedSlots + newEntries,
                stateMode: state.stateMode,
                configGeneration: state.configGeneration,
                liveArrangeRecoveryRequired: state.liveArrangeRecoveryRequired,
                activeLayoutName: state.activeLayoutName,
                activeVirtualSpaceID: state.activeVirtualSpaceID,
                revision: state.revision,
                expecting: RuntimeStateWriteExpectation(
                    revision: state.revision,
                    configGeneration: state.configGeneration
                )
            )
        } catch {
            // Concurrent modification — skip this adoption cycle.
            logger.log(
                level: "warn",
                event: "adopt.periodic.skipped",
                fields: [
                    "layoutName": layoutName,
                    "targetSpaceID": activeSpaceID,
                    "reason": "concurrentModification",
                ]
            )
            return 0
        }
        if prunedCount > 0 {
            logger.log(
                event: "adopt.periodic.prunedRuntimeManagedWindows",
                fields: [
                    "layoutName": layoutName,
                    "targetSpaceID": activeSpaceID,
                    "prunedCount": prunedCount,
                ]
            )
        }
        if adoptedCount > 0 {
            logger.log(
                event: "adopt.periodic",
                fields: [
                    "layoutName": layoutName,
                    "targetSpaceID": activeSpaceID,
                    "adoptedCount": adoptedCount,
                ]
            )
        }
        return adoptedCount
    }

    public func restoreVirtualWorkspaceWindowsForShutdown() -> CommandResult {
        let requestID = UUID().uuidString.lowercased()
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: false, requestID: requestID)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: false)
        }

        do {
            let result = try withStateMutationLock(requestID: requestID) {
                let lockedContext: LockedRuntimeStateMutationContext
                switch loadLockedRuntimeStateMutationContext(requestID: requestID, json: false) {
                case let .result(result):
                    return result
                case let .ready(context):
                    lockedContext = context
                }

                let lockedPersistedState = lockedContext.persistedState

                guard requiresVirtualShutdownRestore(lockedPersistedState) else {
                    return CommandResult(exitCode: 0)
                }

                guard runtimeHooks.accessibilityGranted() else {
                    return CommandResult(
                        exitCode: Int32(ErrorCode.missingPermission.rawValue),
                        stderr: "Accessibility permission is required to restore virtual workspace windows before shutdown\n"
                    )
                }

                let lockedLoadedConfig = lockedContext.loadedConfig
                let displays = runtimeHooks.displays()
                let activeLayout = lockedPersistedState.activeLayoutName.flatMap {
                    lockedLoadedConfig?.config.layouts[$0]
                }
                let windows = runtimeHooks.listWindowsOnAllSpaces()
                let restoration = restoreVirtualWorkspaceSlotsForShutdown(
                    requestID: requestID,
                    slots: lockedPersistedState.slots,
                    layout: activeLayout,
                    displays: displays,
                    windows: windows
                )

                guard restoration.restoreFailures.isEmpty else {
                    let joined = restoration.restoreFailures.joined(separator: ", ")
                    logger.log(
                        level: "error",
                        event: "virtual.shutdownRestore.failed",
                        fields: [
                            "requestID": requestID,
                            "targets": joined,
                        ]
                    )
                    return CommandResult(
                        exitCode: Int32(ErrorCode.virtualSpaceSwitchFailed.rawValue),
                        stderr: "failed to restore virtual workspace windows before shutdown: \(joined)\n"
                    )
                }

                return persistVirtualShutdownRestoreState(
                    persistedState: lockedPersistedState,
                    nextSlots: restoration.nextSlots
                )
            }
            return result
        } catch let error as VirtualSpaceStateMutationLockError {
            return stateMutationLockBusyResult(
                error,
                event: "virtual.shutdownRestore.busy",
                message: "virtual shutdown restore is busy",
                requestID: requestID,
                state: persistedState,
                loadedConfig: try? loadConfig(trigger: "manual"),
                attemptedTargetSpaceID: persistedState.activeVirtualSpaceID,
                json: false
            )
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: false)
        }
    }

    private func resolvedShutdownRestoreFrame(
        entry: SlotEntry,
        layout: LayoutDefinition?,
        displays: [DisplayInfo]
    ) -> ResolvedFrame? {
        guard let layout else {
            return nil
        }

        let hostDisplay: DisplayInfo?
        if let displayID = entry.displayID {
            hostDisplay = displays.first(where: { $0.id == displayID })
        } else {
            hostDisplay = displays.first
        }

        guard let hostDisplay else {
            return nil
        }

        return resolvedVirtualLayoutFrame(
            entry: entry,
            layout: layout,
            hostDisplay: hostDisplay,
            displays: displays
        )
    }

    private func restoreVirtualWorkspaceSlotsForShutdown(
        requestID: String,
        slots: [SlotEntry],
        layout: LayoutDefinition?,
        displays: [DisplayInfo],
        windows: [WindowSnapshot]
    ) -> (nextSlots: [SlotEntry], restoreFailures: [String]) {
        var nextSlots = slots
        var restoreFailures: [String] = []

        for (index, entry) in slots.enumerated() {
            let visibleFrame = resolvedShutdownRestoreFrame(
                entry: entry,
                layout: layout,
                displays: displays
            ) ?? entry.lastVisibleFrame

            guard let visibleFrame else {
                nextSlots[index] = slotEntry(
                    entry,
                    window: nil,
                    lastVisibleFrame: nil,
                    lastHiddenFrame: nil,
                    visibilityState: .visible,
                    lastActivatedAt: entry.lastActivatedAt
                )
                continue
            }

            guard let window = resolveVirtualSwitchWindow(entry: entry, windows: windows)?.window else {
                nextSlots[index] = slotEntry(
                    entry,
                    window: nil,
                    lastVisibleFrame: visibleFrame,
                    lastHiddenFrame: nil,
                    visibilityState: .visible,
                    lastActivatedAt: entry.lastActivatedAt
                )
                continue
            }

            if window.minimized,
               !runtimeHooks.setWindowMinimized(window.windowID, window.bundleID, false).isSuccess
            {
                logger.log(
                    level: "warn",
                    event: "virtual.shutdownRestore.skipped",
                    fields: [
                        "requestID": requestID,
                        "windowID": Int(window.windowID),
                        "bundleID": window.bundleID,
                        "reason": "restoreFromMinimizedFailed",
                    ]
                )
            }

            let restored = runtimeHooks.setWindowFrame(window.windowID, window.bundleID, visibleFrame)
                || runtimeHooks.setWindowPosition(
                    window.windowID,
                    window.bundleID,
                    CGPoint(x: visibleFrame.x, y: visibleFrame.y)
                )

            guard restored else {
                restoreFailures.append("\(entry.bundleID)#\(entry.slot)")
                continue
            }

            nextSlots[index] = slotEntry(
                entry,
                window: window,
                lastVisibleFrame: visibleFrame,
                lastHiddenFrame: nil,
                visibilityState: .visible,
                lastActivatedAt: entry.lastActivatedAt
            )
        }

        return (nextSlots, restoreFailures)
    }

    private func persistVirtualShutdownRestoreState(
        persistedState: RuntimeState,
        nextSlots: [SlotEntry]
    ) -> CommandResult {
        let nextState = persistedState.clearingActiveVirtualContext(
            updatedAt: Date.rfc3339UTC(),
            revision: persistedState.revision + 1,
            liveArrangeRecoveryRequired: false,
            slots: nextSlots
        )
        do {
            try stateStore.saveStrict(
                state: nextState,
                expecting: RuntimeStateWriteExpectation(
                    revision: persistedState.revision,
                    configGeneration: persistedState.configGeneration
                )
            )
            return CommandResult(exitCode: 0)
        } catch {
            return errorAsResult(
                code: .validationError,
                message: "failed to persist restored virtual workspace state",
                json: false
            )
        }
    }

    public func windowMove(x: LengthValue, y: LengthValue) -> CommandResult {
        windowMove(target: nil, x: x, y: y)
    }

    public func windowWorkspace(spaceID: Int, json: Bool) -> CommandResult {
        windowWorkspace(target: nil, spaceID: spaceID, json: json)
    }

    public func windowWorkspace(target: WindowTargetSelector?, spaceID: Int, json: Bool) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "window workspace supports --json only\n"
            )
        }

        guard spaceID > 0 else {
            return errorAsResult(code: .validationError, message: "spaceID must be greater than zero", json: json)
        }

        guard runtimeHooks.accessibilityGranted() else {
            return errorAsResult(code: .missingPermission, message: "Accessibility permission is required", json: json)
        }

        let normalizedTarget: WindowTargetSelector?
        do {
            normalizedTarget = try validateWindowTargetSelector(target)
        } catch let error as ShitsuraeError {
            return errorAsResult(code: error.code, message: error.message, json: json)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }

        let requestID = UUID().uuidString.lowercased()
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return runtimeStateLoadErrorResult(error, json: json, requestID: requestID)
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }

        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state

        guard RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        ) == .virtual else {
            return commonJSONError(
                .validationError,
                "window workspace is unsupported in native mode",
                toStdErr: false,
                subcode: "windowWorkspaceUnsupportedInNativeMode",
                requestID: requestID
            )
        }

        if let subcode = virtualInspectionStateSubcode(loadedConfig: loadedConfig, state: state) {
            return commonJSONError(
                .validationError,
                virtualInspectionStateMessage(subcode),
                toStdErr: false,
                subcode: subcode,
                requestID: requestID,
                recoveryContext: nil
            )
        }

        guard let layout = RuntimeStateReadResolver.activeVirtualLayout(
            loadedConfig: loadedConfig,
            state: state
        )
        else {
            return commonJSONError(
                .validationError,
                virtualInspectionStateMessage("virtualStateUnavailable"),
                toStdErr: false,
                subcode: "virtualStateUnavailable",
                requestID: requestID
            )
        }

        guard uniqueSpaces(in: layout).contains(where: { $0.spaceID == spaceID }) else {
            return commonJSONError(
                .validationError,
                "virtual space not found: \(spaceID)",
                toStdErr: false,
                subcode: "virtualSpaceNotFound",
                requestID: requestID
            )
        }

        let lockResult: CommandResult
        do {
            lockResult = try withStateMutationLock(requestID: requestID) {
                let lockedContext: LockedRuntimeStateMutationContext
                switch loadLockedRuntimeStateMutationContext(requestID: requestID, json: json) {
                case let .result(result):
                    return result
                case let .ready(context):
                    lockedContext = context
                }

                let lockedState = lockedContext.persistedState
                let lockedLoadedConfig = lockedContext.loadedConfig
                let lockedRuntimeState = lockedContext.state

                if let subcode = virtualInspectionStateSubcode(loadedConfig: lockedLoadedConfig, state: lockedRuntimeState) {
                    return commonJSONError(
                        .validationError,
                        virtualInspectionStateMessage(subcode),
                        toStdErr: false,
                        subcode: subcode,
                        requestID: requestID,
                        recoveryContext: nil
                    )
                }

                guard let lockedLayout = RuntimeStateReadResolver.activeVirtualLayout(
                    loadedConfig: lockedLoadedConfig,
                    state: lockedRuntimeState
                ),
                      let lockedLayoutName = lockedRuntimeState.activeLayoutName,
                      let lockedActiveSpaceID = lockedRuntimeState.activeVirtualSpaceID
                else {
                    return commonJSONError(
                        .validationError,
                        virtualInspectionStateMessage("virtualStateUnavailable"),
                        toStdErr: false,
                        subcode: "virtualStateUnavailable",
                        requestID: requestID
                    )
                }

                guard uniqueSpaces(in: lockedLayout).contains(where: { $0.spaceID == spaceID }) else {
                    return commonJSONError(
                        .validationError,
                        "virtual space not found: \(spaceID)",
                        toStdErr: false,
                        subcode: "virtualSpaceNotFound",
                        requestID: requestID
                    )
                }

                let windows = runtimeHooks.listWindowsOnAllSpaces()
                let window: WindowSnapshot
                switch resolveTargetWindowForWorkspace(normalizedTarget, windows: windows) {
                case let .success(resolved):
                    window = resolved
                case let .failure(result):
                    if json {
                        return commonJSONError(
                            .targetWindowNotFound,
                            result.stderr.isEmpty ? "target window not found" : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                            toStdErr: false,
                            requestID: requestID
                        )
                    }
                    return result
                }

                var updatedSlots = lockedRuntimeState.slots
                let targetEntries = updatedSlots.enumerated().filter { _, entry in
                    entry.layoutName == lockedLayoutName
                }

                let existingMatch = findVirtualSlotEntry(
                    for: window,
                    activeLayoutName: lockedLayoutName,
                    activeSpaceID: lockedActiveSpaceID,
                    slotEntries: targetEntries.map(\.element)
                )
                let existingIndex = existingMatch.flatMap { matched in
                    updatedSlots.firstIndex(where: { $0.layoutName == lockedLayoutName && $0.definitionFingerprint == matched.definitionFingerprint && $0.slot == matched.slot })
                }

                let previousSpaceID = existingMatch?.spaceID
                let didCreateTrackingEntry = existingMatch == nil
                let desiredSlot = preferredVirtualWorkspaceSlot(
                    existingEntry: existingMatch,
                    targetSpaceID: spaceID,
                    activeLayoutName: lockedLayoutName,
                    slotEntries: targetEntries.map(\.element)
                )

                let updatedEntry = updatedVirtualWorkspaceEntry(
                    existingEntry: existingMatch,
                    layoutName: lockedLayoutName,
                    targetSpaceID: spaceID,
                    slot: desiredSlot,
                    window: window
                )

                let displays = runtimeHooks.displays()
                let spaces = runtimeHooks.spaces()
                let hostDisplay = resolveVirtualHostDisplay(
                    layout: lockedLayout,
                    config: lockedLoadedConfig?.config,
                    focusedWindow: window,
                    displays: displays,
                    spaces: spaces
                ) ?? displays.first(where: \.isPrimary) ?? displays.first
                guard let hostDisplay else {
                    return commonJSONError(
                        .validationError,
                        "host display for virtual window workspace is unavailable",
                        toStdErr: false,
                        subcode: "virtualHostDisplayUnavailable",
                        requestID: requestID
                    )
                }

                guard let visibilityPlan = planVirtualVisibility(
                    entry: updatedEntry,
                    window: window,
                    transition: spaceID == lockedActiveSpaceID ? .show : .hide,
                    layout: lockedLayout,
                    hostDisplay: hostDisplay,
                    displays: displays
                ) else {
                    return commonJSONError(
                        .validationError,
                        "visible frame for virtual window is unavailable",
                        toStdErr: false,
                        subcode: "virtualVisibleFrameUnavailable",
                        requestID: requestID
                    )
                }

                guard applyVirtualVisibilityPlan(window: window, plan: visibilityPlan, hooks: runtimeHooks, logger: logger) else {
                    return commonJSONError(
                        .operationTimedOut,
                        "failed to apply virtual window visibility",
                        toStdErr: false,
                        subcode: "virtualWindowVisibilityApplyFailed",
                        requestID: requestID
                    )
                }

                if let existingIndex {
                    updatedSlots.remove(at: existingIndex)
                }
                updatedSlots.append(visibilityPlan.updatedEntry)

                do {
                    try stateStore.saveStrict(
                        state: lockedRuntimeState.with(
                            updatedAt: Date.rfc3339UTC(),
                            revision: lockedRuntimeState.revision + 1,
                            slots: updatedSlots
                        ),
                        expecting: RuntimeStateWriteExpectation(
                            revision: lockedState.revision,
                            configGeneration: lockedState.configGeneration
                        )
                    )
                } catch let error as RuntimeStateStoreError {
                    return runtimeStateLoadErrorResult(error, json: json, requestID: requestID)
                } catch {
                    return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
                }

                let payload = WindowWorkspaceJSON(
                    requestID: requestID,
                    windowID: window.windowID,
                    bundleID: window.bundleID,
                    slot: desiredSlot,
                    previousSpaceID: previousSpaceID,
                    spaceID: spaceID,
                    didChangeSpace: previousSpaceID != spaceID,
                    didCreateTrackingEntry: didCreateTrackingEntry,
                    visibilityAction: visibilityPlan.action
                )
                if json {
                    return CommandResult(exitCode: 0, stdout: encodeJSON(payload) + "\n")
                }
                return CommandResult(
                    exitCode: 0,
                    stdout: "requestID=\(requestID) windowID=\(window.windowID) space=\(spaceID) previousSpace=\(previousSpaceID.map(String.init) ?? "nil") slot=\(desiredSlot) visibility=\(visibilityPlan.action) didChangeSpace=\(previousSpaceID != spaceID)\n"
                )
            }
        } catch let error as VirtualSpaceStateMutationLockError {
            return stateMutationLockBusyResult(
                error,
                event: "window.workspace.busy",
                message: "virtual window workspace mutation is busy",
                requestID: requestID,
                state: state,
                loadedConfig: loadedConfig,
                attemptedTargetSpaceID: spaceID,
                json: json
            )
        } catch {
            return errorAsResult(code: .validationError, message: error.localizedDescription, json: json)
        }

        return lockResult
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
            guard runtimeHooks.focusWindow(window.windowID, window.bundleID).isSuccess else {
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
                activated = runtimeHooks.focusWindow(window.windowID, window.bundleID).isSuccess
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

        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: runtimeStateErrorMessage(error) + "\n"
            )
        } catch {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: error.localizedDescription + "\n"
            )
        }
        let loadedConfig: LoadedConfig?
        do {
            loadedConfig = try loadConfig(trigger: "manual")
        } catch let error as ConfigLoadError {
            return CommandResult(exitCode: Int32(error.code.rawValue))
        } catch {
            loadedConfig = nil
        }
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state
        if RuntimeStateReadResolver.isStaleVirtualReadState(loadedConfig: loadedConfig, state: state) {
            recordStaleStateReadDiagnosticEvent(
                requestID: UUID().uuidString.lowercased(),
                state: state,
                failedOperation: "focus.slot"
            )
        }

        if let unavailableResult = unavailableVirtualFocusResult(loadedConfig: loadedConfig, state: state) {
            return unavailableResult
        }

        let currentSpaceID = currentSpaceID()
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loadedConfig,
            state: state
        )
        guard let entry = resolveSlotEntry(slot: slot, slotEntries: slotEntries, currentSpaceID: currentSpaceID) else {
            return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
        }

        let windows = runtimeHooks.listWindows()

        if let ignoreRules = loadedConfig?.config.ignore?.focus {
            let targetWindow = resolveSlotWindow(entry: entry, windows: windows)
            if PolicyEngine.matchesIgnoreRule(window: targetWindow, rules: ignoreRules) {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
        }

        if let window = resolveTrackedSlotWindow(entry: entry, windows: windows) {
            let focusResult = runtimeHooks.focusWindow(window.windowID, window.bundleID)
            // Supplement with activateBundle to ensure the app is brought to
            // the foreground.  The SkyLight private API used by focusWindow
            // doesn't reliably raise the app on all macOS versions.
            if !focusResult.isSuccess, !runtimeHooks.activateBundle(window.bundleID) {
                return CommandResult(exitCode: Int32(ErrorCode.targetWindowNotFound.rawValue))
            }
            _ = runtimeHooks.activateBundle(window.bundleID)
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
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch {
            return false
        }
        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loadedConfig)
        let state = readContext.state
        if unavailableVirtualFocusResult(loadedConfig: loadedConfig, state: state) != nil {
            return false
        }
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loadedConfig,
            state: state
        )
        guard let entry = resolveSlotEntry(
            slot: slot,
            slotEntries: slotEntries,
            currentSpaceID: currentSpaceID()
        ),
              focusShortcutTargetExists(entry: entry, windows: windows)
        else {
            return false
        }

        if let ignoreRules = loadedConfig?.config.ignore?.focus {
            let targetWindow = resolveSlotWindow(entry: entry, windows: windows)
            if PolicyEngine.matchesIgnoreRule(window: targetWindow, rules: ignoreRules) {
                return false
            }
        }

        return true
    }

    public func switcherCandidateQuery(includeAllSpacesOverride: Bool?) -> SwitcherCandidateQueryResolution {
        guard runtimeHooks.accessibilityGranted() else {
            return .failure(
                commonJSONError(.missingPermission, "Accessibility permission is required", toStdErr: false)
            )
        }

        let loaded: LoadedConfig?
        do {
            loaded = try loadConfig(trigger: "manual")
        } catch let error as ConfigLoadError where isNoConfigFilesError(error) {
            loaded = nil
        } catch let error as ConfigLoadError {
            let payload = CommonErrorJSON(code: error.code, message: error.errors.first?.message ?? "failed to load config")
            return .failure(CommandResult(exitCode: Int32(error.code.rawValue), stdout: encodeJSON(payload) + "\n"))
        } catch {
            return .failure(commonJSONError(.backendUnavailable, "failed to enumerate switcher candidates", toStdErr: false))
        }

        let shortcuts = loaded?.config.resolvedShortcuts ?? ResolvedShortcuts(from: nil)
        let includeAllSpaces = includeAllSpacesOverride ?? false
        let ignoreFocusRules = loaded?.config.ignore?.focus
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return .failure(runtimeStateLoadErrorResult(error, json: true))
        } catch {
            return .failure(errorAsResult(code: .validationError, message: error.localizedDescription, json: true))
        }
        let readContext = reconciledRuntimeStateForRead(state: persistedState, loadedConfig: loaded)
        let state = readContext.state
        let mode = RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loaded,
            state: state
        )
        let slotEntries = RuntimeStateReadResolver.slotEntriesForEffectiveMode(
            loadedConfig: loaded,
            state: state
        )
        let staleReadRequestID = RuntimeStateReadResolver.isStaleVirtualReadState(
            loadedConfig: loaded,
            state: state
        )
            ? UUID().uuidString.lowercased()
            : nil
        if let staleReadRequestID {
            recordStaleStateReadDiagnosticEvent(
                requestID: staleReadRequestID,
                state: state,
                failedOperation: "switcher.list"
            )
        }

        let internalCandidates: [InternalCandidate]
        switch mode {
        case .native:
            let windows = runtimeHooks.listWindows().filter {
                !$0.isFullscreen && !$0.hidden && !$0.minimized
            }
            let currentSpaceID = currentSpaceID()

            var nativeCandidates: [InternalCandidate] = []
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

                let slot = slotEntries.first(where: { slot in
                    if let windowID = slot.windowID {
                        return windowID == window.windowID
                    }
                    return slot.bundleID == window.bundleID
                })?.slot

                nativeCandidates.append(
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
                        inCurrentSpace: currentSpaceID != nil && window.spaceID == currentSpaceID,
                        lastActivatedAt: nil
                    )
                )
            }
            internalCandidates = orderCandidates(nativeCandidates, prioritizeCurrentSpace: true)
        case .virtual:
            if let subcode = virtualInspectionStateSubcode(loadedConfig: loaded, state: state) {
                return .failure(
                    commonJSONError(
                        .validationError,
                        virtualInspectionStateMessage(subcode),
                        toStdErr: false,
                        subcode: subcode,
                        requestID: staleReadRequestID
                    )
                )
            }
            guard let layout = RuntimeStateReadResolver.activeVirtualLayout(
                loadedConfig: loaded,
                state: state
            ),
                  let activeSpaceID = state.activeVirtualSpaceID,
                  let activeLayoutName = state.activeLayoutName
            else {
                return .failure(
                    commonJSONError(
                        .validationError,
                        virtualInspectionStateMessage("virtualStateUnavailable"),
                        toStdErr: false,
                        subcode: "virtualStateUnavailable",
                        requestID: staleReadRequestID
                    )
                )
            }

            let windowsSource = includeAllSpaces
                ? runtimeHooks.listWindowsOnAllSpaces()
                : runtimeHooks.listWindows()
            let windows = windowsSource.filter { window in
                if window.isFullscreen || window.hidden {
                    return false
                }
                return includeAllSpaces || !window.minimized
            }

            let candidateEntries = slotEntries.filter { entry in
                guard entry.layoutName == activeLayoutName else {
                    return false
                }
                return includeAllSpaces || entry.spaceID == activeSpaceID
            }

            let activeLayoutSpaceIDs = Set(uniqueSpaces(in: layout).map(\.spaceID))
            var seenWindowIDs = Set<UInt32>()
            var virtualCandidates: [InternalCandidate] = []
            for entry in candidateEntries {
                guard let entrySpaceID = entry.spaceID,
                      activeLayoutSpaceIDs.contains(entrySpaceID),
                      let resolved = resolveVirtualSwitchWindow(entry: entry, windows: windows),
                      seenWindowIDs.insert(resolved.window.windowID).inserted,
                      !PolicyEngine.matchesIgnoreRule(window: resolved.window, rules: ignoreFocusRules)
                else {
                    continue
                }

                virtualCandidates.append(
                    InternalCandidate(
                        candidate: SwitcherCandidate(
                            id: "window:\(resolved.window.windowID)",
                            source: .window,
                            title: resolved.window.title.isEmpty ? resolved.window.bundleID : resolved.window.title,
                            bundleID: resolved.window.bundleID,
                            profile: resolved.window.profileDirectory,
                            spaceID: entrySpaceID,
                            displayID: resolved.window.displayID ?? entry.displayID,
                            slot: entry.slot,
                            quickKey: nil
                        ),
                        frontIndex: resolved.window.frontIndex,
                        windowID: resolved.window.windowID,
                        inCurrentSpace: entrySpaceID == activeSpaceID,
                        lastActivatedAt: entry.lastActivatedAt
                    )
                )
            }

            internalCandidates = orderVirtualCandidates(virtualCandidates)
        }

        return .success(
            SwitcherCandidateQuery(
                includeAllSpaces: includeAllSpaces,
                spacesMode: loaded?.config.resolvedSpacesMode ?? .perDisplay,
                quickKeys: shortcuts.quickKeys,
                candidates: internalCandidates.map(\.candidate)
            )
        )
    }

    public func switcherCandidates(
        includeAllSpacesOverride: Bool?,
        excludedBundleIDs: Set<String>,
        quickKeys: String
    ) -> SwitcherCandidatesResolution {
        switch switcherCandidateQuery(includeAllSpacesOverride: includeAllSpacesOverride) {
        case let .success(query):
            return .success(
                ShortcutCandidateFilter.filter(
                    candidates: query.candidates,
                    excludedBundleIDs: excludedBundleIDs,
                    quickKeys: quickKeys
                )
            )
        case let .failure(result):
            return .failure(result)
        }
    }

    public func switcherList(json: Bool, includeAllSpacesOverride: Bool?) -> CommandResult {
        guard json else {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: "switcher list supports --json only\n"
            )
        }

        let query: SwitcherCandidateQuery
        switch switcherCandidateQuery(includeAllSpacesOverride: includeAllSpacesOverride) {
        case let .success(resolved):
            query = resolved
        case let .failure(result):
            return result
        }

        let payload = SwitcherListJSON(
            schemaVersion: 1,
            generatedAt: Date.rfc3339UTC(),
            includeAllSpaces: query.includeAllSpaces,
            spacesMode: query.spacesMode,
            candidates: ShortcutCandidateFilter.filter(
                candidates: query.candidates,
                excludedBundleIDs: [],
                quickKeys: query.quickKeys
            )
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

    private func resolveTargetWindowForWorkspace(
        _ target: WindowTargetSelector?,
        windows: [WindowSnapshot]
    ) -> TargetWindowResolution {
        if let target {
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

    private func findVirtualSlotEntry(
        for window: WindowSnapshot,
        activeLayoutName: String,
        activeSpaceID: Int,
        slotEntries: [SlotEntry]
    ) -> SlotEntry? {
        let entries = slotEntries.filter { $0.layoutName == activeLayoutName }

        if let exact = entries.first(where: { $0.windowID == window.windowID }) {
            return exact
        }

        let matching = entries.filter { entry in
            guard entry.bundleID == window.bundleID else {
                return false
            }
            if let profile = entry.profile, profile != window.profileDirectory {
                return false
            }
            if let role = entry.role, role != window.role {
                return false
            }
            if let subrole = entry.subrole, subrole != window.subrole {
                return false
            }
            if let titleMatcher = persistedTitleMatcher(for: entry) {
                return matchesPersistedTitle(window.title, matcher: titleMatcher)
            }
            return true
        }

        if let activeMatch = matching.first(where: { $0.spaceID == activeSpaceID }) {
            return activeMatch
        }

        return matching.first
    }

    /// Slot range for windows that are tracked for virtual workspace
    /// visibility (show/hide) but are NOT targets of Cmd+1-9 focus-by-slot.
    /// Slots 1-9 are reserved for layout-defined windows.
    static let untrackedSlotOffset = 100

    private func preferredVirtualWorkspaceSlot(
        existingEntry: SlotEntry?,
        targetSpaceID: Int,
        activeLayoutName: String,
        slotEntries: [SlotEntry]
    ) -> Int {
        let occupied = Set(
            slotEntries
                .filter { entry in
                    entry.layoutName == activeLayoutName
                        && entry.spaceID == targetSpaceID
                        && entry.windowID != existingEntry?.windowID
                }
                .map(\.slot)
        )

        if let existingSlot = existingEntry?.slot, !occupied.contains(existingSlot) {
            return existingSlot
        }

        // New (untracked) windows get slots starting at untrackedSlotOffset
        // so they participate in workspace show/hide but are NOT matched by
        // Cmd+1-9 focus-by-slot (which only targets slots 1-9).
        let startSlot = existingEntry == nil ? Self.untrackedSlotOffset : 1
        var slot = startSlot
        while occupied.contains(slot) {
            slot += 1
        }
        return slot
    }

    private func updatedVirtualWorkspaceEntry(
        existingEntry: SlotEntry?,
        layoutName: String,
        targetSpaceID: Int,
        slot: Int,
        window: WindowSnapshot
    ) -> SlotEntry {
        if let existingEntry {
            return SlotEntry(
                layoutName: layoutName,
                slot: slot,
                source: existingEntry.source,
                bundleID: existingEntry.bundleID,
                definitionFingerprint: existingEntry.definitionFingerprint,
                pid: window.pid,
                titleMatchKind: existingEntry.titleMatchKind,
                titleMatchValue: existingEntry.titleMatchValue,
                excludeTitleRegex: existingEntry.excludeTitleRegex,
                role: existingEntry.role,
                subrole: existingEntry.subrole,
                matchIndex: existingEntry.matchIndex,
                lastKnownTitle: window.title,
                profile: existingEntry.profile ?? window.profileDirectory,
                spaceID: targetSpaceID,
                nativeSpaceID: window.spaceID,
                displayID: window.displayID ?? existingEntry.displayID,
                windowID: window.windowID,
                lastVisibleFrame: existingEntry.lastVisibleFrame,
                lastHiddenFrame: existingEntry.lastHiddenFrame,
                visibilityState: existingEntry.visibilityState
            )
        }

        let titleMatchValue = window.title.isEmpty ? nil : window.title
        let titleMatchKind: PersistedTitleMatchKind = titleMatchValue == nil ? .none : .equals
        return SlotEntry(
            layoutName: layoutName,
            slot: slot,
            source: .window,
            bundleID: window.bundleID,
            definitionFingerprint: runtimeVirtualWorkspaceFingerprint(layoutName: layoutName, window: window),
            pid: window.pid,
            titleMatchKind: titleMatchKind,
            titleMatchValue: titleMatchValue,
            excludeTitleRegex: nil,
            role: window.role,
            subrole: window.subrole,
            matchIndex: nil,
            lastKnownTitle: window.title,
            profile: window.profileDirectory,
            spaceID: targetSpaceID,
            nativeSpaceID: window.spaceID,
            displayID: window.displayID,
            windowID: window.windowID,
            lastVisibleFrame: window.frame,
            lastHiddenFrame: nil,
            visibilityState: .visible
        )
    }

    private func runtimeVirtualWorkspaceFingerprint(layoutName: String, window: WindowSnapshot) -> String {
        [
            "runtimeVirtualWorkspace",
            layoutName,
            window.bundleID,
            window.title,
            window.role,
            window.subrole ?? "",
            window.profileDirectory ?? "",
        ].joined(separator: "\u{0}")
    }

    private func pruneGoneRuntimeManagedWindows(
        slots: [SlotEntry],
        layoutName: String,
        windows: [WindowSnapshot]
    ) -> [SlotEntry] {
        let liveWindowIDs = Set(windows.map(\.windowID))

        return slots.filter { entry in
            guard entry.layoutName == layoutName,
                  isRuntimeManagedVirtualWorkspaceEntry(entry)
            else {
                return true
            }

            guard let windowID = entry.windowID else {
                return false
            }

            return liveWindowIDs.contains(windowID)
        }
    }

    private func isRuntimeManagedVirtualWorkspaceEntry(_ entry: SlotEntry) -> Bool {
        entry.definitionFingerprint.hasPrefix("runtimeVirtualWorkspace\u{0}")
    }

    /// Detect windows that are not tracked in slot entries and create entries
    /// for them so they participate in virtual workspace show/hide.
    /// Callers should pass on-screen-only windows (from `listWindows()`) rather
    /// than the all-spaces list to avoid adopting hundreds of background helper
    /// windows that CGWindowList reports but the user never sees.
    func adoptUntrackedWindows(
        windows: [WindowSnapshot],
        existingSlots: [SlotEntry],
        layoutName: String,
        targetSpaceID: Int
    ) -> [SlotEntry] {
        let trackedWindowIDs = Set(existingSlots.compactMap(\.windowID))

        var newEntries: [SlotEntry] = []
        var nextSlot = Self.untrackedSlotOffset
        let occupiedSlots = Set(
            existingSlots
                .filter { $0.layoutName == layoutName && $0.spaceID == targetSpaceID }
                .map(\.slot)
        )
        while occupiedSlots.contains(nextSlot) {
            nextSlot += 1
        }

        for window in windows {
            guard !trackedWindowIDs.contains(window.windowID) else { continue }
            guard !window.bundleID.isEmpty else { continue }
            guard !window.minimized, !window.hidden, !window.isFullscreen else { continue }

            let titleMatchValue = window.title.isEmpty ? nil : window.title
            let titleMatchKind: PersistedTitleMatchKind = titleMatchValue == nil ? .none : .equals
            newEntries.append(SlotEntry(
                layoutName: layoutName,
                slot: nextSlot,
                source: .window,
                bundleID: window.bundleID,
                definitionFingerprint: runtimeVirtualWorkspaceFingerprint(layoutName: layoutName, window: window),
                pid: window.pid,
                titleMatchKind: titleMatchKind,
                titleMatchValue: titleMatchValue,
                role: window.role,
                subrole: window.subrole,
                lastKnownTitle: window.title,
                profile: window.profileDirectory,
                spaceID: targetSpaceID,
                nativeSpaceID: window.spaceID,
                displayID: window.displayID,
                windowID: window.windowID,
                lastVisibleFrame: window.frame,
                visibilityState: .visible
            ))
            nextSlot += 1
        }

        return newEntries
    }

    private func restoreHiddenWindowsBeforeArrange(layoutName: String, layout: LayoutDefinition) {
        let state = stateStore.load()
        guard state.stateMode == .virtual,
              state.activeLayoutName == layoutName
        else { return }

        let allWindows = runtimeHooks.listWindowsOnAllSpaces()
        let displays = runtimeHooks.displays()
        guard let hostDisplay = resolveVirtualHostDisplay(
            layout: layout,
            config: cachedValidConfig?.config,
            focusedWindow: runtimeHooks.focusedWindow(),
            displays: displays,
            spaces: runtimeHooks.spaces()
        ) else { return }

        var updatedSlots = state.slots
        var restoredCount = 0

        for (index, entry) in state.slots.enumerated() {
            guard entry.layoutName == layoutName,
                  entry.visibilityState == .hiddenOffscreen,
                  let windowID = entry.windowID,
                  let window = allWindows.first(where: { $0.windowID == windowID })
            else { continue }

            guard let plan = planVirtualVisibility(
                entry: entry,
                window: window,
                transition: .show,
                layout: layout,
                hostDisplay: hostDisplay,
                displays: displays
            ) else { continue }
            _ = applyVirtualVisibilityPlan(window: window, plan: plan, hooks: runtimeHooks, logger: logger)
            updatedSlots[index] = plan.updatedEntry
            restoredCount += 1
        }

        if restoredCount > 0 {
            stateStore.save(
                slots: updatedSlots,
                stateMode: state.stateMode,
                configGeneration: state.configGeneration,
                liveArrangeRecoveryRequired: state.liveArrangeRecoveryRequired,
                activeLayoutName: state.activeLayoutName,
                activeVirtualSpaceID: state.activeVirtualSpaceID,
                revision: state.revision
            )
            logger.log(
                event: "arrange.restoredHiddenWindows",
                fields: [
                    "layoutName": layoutName,
                    "restoredCount": restoredCount,
                ]
            )
        }
    }

    private func matchesPersistedTitle(_ title: String, matcher: TitleMatcher) -> Bool {
        if let equals = matcher.equals {
            return title == equals
        }
        if let contains = matcher.contains {
            return title.contains(contains)
        }
        if let regex = matcher.regex {
            return title.range(of: regex, options: .regularExpression) != nil
        }
        return true
    }

    private func markVirtualActivatedWindow(
        _ window: WindowSnapshot?,
        in slots: [SlotEntry],
        layoutName: String,
        spaceID: Int,
        activatedAt: Date
    ) -> [SlotEntry] {
        guard let window else {
            return slots
        }

        let focusedEntry = findVirtualSlotEntry(
            for: window,
            activeLayoutName: layoutName,
            activeSpaceID: spaceID,
            slotEntries: slots
        )
        guard let focusedEntry else {
            return slots
        }

        let activationTimestamp = makeRFC3339UTCFormatter().string(from: activatedAt)
        return slots.map { entry in
            guard entry.layoutName == focusedEntry.layoutName,
                  entry.definitionFingerprint == focusedEntry.definitionFingerprint,
                  entry.slot == focusedEntry.slot
            else {
                return entry
            }

            return slotEntry(
                entry,
                window: window,
                lastVisibleFrame: entry.lastVisibleFrame,
                lastHiddenFrame: entry.lastHiddenFrame,
                visibilityState: entry.visibilityState,
                lastActivatedAt: activationTimestamp
            )
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

    private func unavailableVirtualFocusResult(
        loadedConfig: LoadedConfig?,
        state: RuntimeState
    ) -> CommandResult? {
        guard RuntimeStateReadResolver.effectiveSpaceInterpretationMode(
            loadedConfig: loadedConfig,
            state: state
        ) == .virtual else {
            return nil
        }

        if let subcode = virtualInspectionStateSubcode(loadedConfig: loadedConfig, state: state) {
            return CommandResult(
                exitCode: Int32(ErrorCode.validationError.rawValue),
                stderr: virtualInspectionStateMessage(subcode) + "\n"
            )
        }

        guard RuntimeStateReadResolver.activeVirtualLayout(loadedConfig: loadedConfig, state: state) == nil else {
            return nil
        }

        return CommandResult(
            exitCode: Int32(ErrorCode.validationError.rawValue),
            stderr: virtualInspectionStateMessage("virtualStateUnavailable") + "\n"
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

    private func findSlotEntry(for window: WindowSnapshot, slotEntries: [SlotEntry]) -> SlotEntry? {
        if let matchedByWindowID = slotEntries.first(where: { $0.windowID == window.windowID }) {
            return matchedByWindowID
        }

        return slotEntries.first(where: { $0.bundleID == window.bundleID })
    }

    private func resolveSlotEntry(slot: Int, slotEntries: [SlotEntry], currentSpaceID: Int?) -> SlotEntry? {
        let matching = slotEntries.filter { $0.slot == slot }
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

    private func nativeSpaceSummary(
        _ space: SpaceInfo,
        windows: [WindowSnapshot],
        focused: WindowSnapshot?,
        slotEntries: [SlotEntry]
    ) -> SpaceSummaryJSON {
        let trackedWindowIDs = slotEntries
            .filter { $0.spaceID == space.spaceID }
            .compactMap(\.windowID)
            .filter { windowID in
                windows.contains(where: { $0.windowID == windowID && matches(space: space, window: $0) })
            }
            .sorted()
        let hasFocus = focused.map { matches(space: space, window: $0) } ?? false

        return SpaceSummaryJSON(
            spaceID: space.spaceID,
            kind: .native,
            displayID: space.displayID,
            isVisible: space.isVisible,
            isNativeFullscreen: space.isNativeFullscreen,
            hasFocus: hasFocus,
            trackedWindowIDs: trackedWindowIDs
        )
    }

    private func virtualSpaceSummary(
        _ space: SpaceDefinition,
        activeLayoutName: String?,
        activeSpaceID: Int?,
        windows: [WindowSnapshot],
        slotEntries: [SlotEntry]
    ) -> SpaceSummaryJSON {
        let trackedWindowIDs = slotEntries
            .filter { $0.layoutName == activeLayoutName && $0.spaceID == space.spaceID }
            .compactMap(\.windowID)
            .filter { windowID in windows.contains(where: { $0.windowID == windowID }) }
            .sorted()

        return SpaceSummaryJSON(
            spaceID: space.spaceID,
            kind: .virtual,
            displayID: space.display?.id,
            isVisible: activeSpaceID == space.spaceID,
            isNativeFullscreen: false,
            hasFocus: activeSpaceID == space.spaceID,
            trackedWindowIDs: trackedWindowIDs
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

    private func orderVirtualCandidates(_ candidates: [InternalCandidate]) -> [InternalCandidate] {
        candidates.sorted { lhs, rhs in
            // Primary: most recently activated first (descending).
            switch compareVirtualActivationRecency(lhs.lastActivatedAt, rhs.lastActivatedAt) {
            case .orderedAscending:
                return false
            case .orderedDescending:
                return true
            case .orderedSame:
                break
            }

            // Tie-breaker: front index (lower = more recently focused).
            if lhs.frontIndex != rhs.frontIndex {
                return lhs.frontIndex < rhs.frontIndex
            }

            // Final tie-breaker: stable ordering by window ID.
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

    private func stateMutationLockOwnerMetadata(requestID: String) -> VirtualSpaceLockOwnerMetadata {
        VirtualSpaceLockOwnerMetadata(
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            processKind: stateMutationOwnerProcessKind,
            startedAt: stateMutationOwnerStartedAt,
            requestID: requestID
        )
    }

    private func loadLockedRuntimeStateMutationContext(
        requestID: String,
        json: Bool
    ) -> LockedRuntimeStateMutationPreparation {
        let persistedState: RuntimeState
        do {
            persistedState = try stateStore.loadStrict()
        } catch let error as RuntimeStateStoreError {
            return .result(runtimeStateLoadErrorResult(error, json: json, requestID: requestID))
        } catch {
            return .result(errorAsResult(code: .validationError, message: error.localizedDescription, json: json))
        }

        let loadedConfig = try? loadConfig(trigger: "manual")
        let readContext = reconciledRuntimeStateForRead(
            state: persistedState,
            loadedConfig: loadedConfig
        )
        return .ready(LockedRuntimeStateMutationContext(
            persistedState: persistedState,
            loadedConfig: loadedConfig,
            readContext: readContext
        ))
    }

    private func withStateMutationLock<T>(
        requestID: String,
        body: () throws -> T
    ) throws -> T {
        try stateMutationLock.withLock(
            owner: stateMutationLockOwnerMetadata(requestID: requestID),
            timeoutMS: stateMutationLockTimeoutMS,
            pollIntervalMS: stateMutationLockPollIntervalMS,
            body: body
        )
    }

    private func stateMutationLockBusyResult(
        _ error: VirtualSpaceStateMutationLockError,
        event: String,
        message: String,
        requestID: String,
        state: RuntimeState,
        loadedConfig: LoadedConfig?,
        attemptedTargetSpaceID: Int?,
        json: Bool
    ) -> CommandResult {
        switch error {
        case let .timedOut(ownerMetadata, ownerMetadataUnavailable, timeoutMS):
            recordVirtualSpaceDiagnosticEvent(
                event: event,
                requestID: requestID,
                code: .validationError,
                subcode: "virtualStateBusy",
                state: state,
                attemptedTargetSpaceID: attemptedTargetSpaceID,
                rootCauseCategory: ownerMetadataUnavailable ? "ownerMetadataUnavailable" : "stateMutationLockTimedOut",
                lockOwnerMetadata: ownerMetadata,
                lockWaitTimeoutMS: timeoutMS
            )
            return spaceSwitchError(
                code: .validationError,
                message: message,
                subcode: "virtualStateBusy",
                requestID: requestID,
                recoveryContext: makeRecoveryContext(
                    state: state,
                    loadedConfig: loadedConfig,
                    attemptedTargetSpaceID: attemptedTargetSpaceID,
                    lockOwnerMetadata: ownerMetadata,
                    lockWaitTimeoutMS: timeoutMS
                ),
                json: json
            )
        case let .ioFailed(reason):
            return spaceSwitchError(
                code: .validationError,
                message: "state mutation lock failed: \(reason)",
                subcode: "stateMutationLockFailed",
                requestID: requestID,
                recoveryContext: makeRecoveryContext(
                    state: state,
                    loadedConfig: loadedConfig,
                    attemptedTargetSpaceID: attemptedTargetSpaceID
                ),
                json: json
            )
        }
    }

    private func arrangeBusyResultForStateMutationLock(
        _ error: VirtualSpaceStateMutationLockError,
        layoutName: String,
        spacesMode: SpacesMode,
        requestID: String,
        state: RuntimeState,
        attemptedTargetSpaceID: Int?,
        json: Bool
    ) -> CommandResult {
        switch error {
        case let .timedOut(ownerMetadata, ownerMetadataUnavailable, timeoutMS):
            recordVirtualSpaceDiagnosticEvent(
                event: "arrange.busy",
                requestID: requestID,
                code: .validationError,
                subcode: "virtualStateBusy",
                state: state,
                attemptedTargetSpaceID: attemptedTargetSpaceID,
                rootCauseCategory: ownerMetadataUnavailable ? "ownerMetadataUnavailable" : "stateMutationLockTimedOut",
                lockOwnerMetadata: ownerMetadata,
                lockWaitTimeoutMS: timeoutMS
            )
            let payload = ArrangeExecutionJSON(
                schemaVersion: 2,
                layout: layoutName,
                spacesMode: spacesMode,
                result: "failed",
                subcode: "virtualStateBusy",
                unresolvedSlots: [],
                hardErrors: [
                    ErrorItem(
                        code: ErrorCode.validationError.rawValue,
                        message: "virtual arrange is busy",
                        spaceID: attemptedTargetSpaceID,
                        slot: nil
                    ),
                ],
                softErrors: [],
                skipped: [],
                warnings: [],
                exitCode: ErrorCode.validationError.rawValue
            )
            if json {
                return CommandResult(exitCode: Int32(payload.exitCode), stdout: encodeJSON(payload) + "\n")
            }
            return CommandResult(
                exitCode: Int32(payload.exitCode),
                stdout: ArrangeCommandOutputRenderer.execution(payload)
            )
        case let .ioFailed(reason):
            let payload = ArrangeExecutionJSON(
                schemaVersion: 2,
                layout: layoutName,
                spacesMode: spacesMode,
                result: "failed",
                subcode: "stateMutationLockFailed",
                unresolvedSlots: [],
                hardErrors: [
                    ErrorItem(
                        code: ErrorCode.validationError.rawValue,
                        message: "state mutation lock failed: \(reason)",
                        spaceID: attemptedTargetSpaceID,
                        slot: nil
                    ),
                ],
                softErrors: [],
                skipped: [],
                warnings: [],
                exitCode: ErrorCode.validationError.rawValue
            )
            if json {
                return CommandResult(exitCode: Int32(payload.exitCode), stdout: encodeJSON(payload) + "\n")
            }
            return CommandResult(
                exitCode: Int32(payload.exitCode),
                stdout: ArrangeCommandOutputRenderer.execution(payload)
            )
        }
    }

    private func virtualArrangeValidationFailure(
        layoutName: String,
        spaceID: Int?,
        stateOnly: Bool,
        loadedConfig: LoadedConfig,
        state: RuntimeState,
        json: Bool
    ) -> CommandResult? {
        guard loadedConfig.config.resolvedSpaceInterpretationMode == .virtual else {
            return nil
        }

        if state.liveArrangeRecoveryRequired, stateOnly {
            return arrangeFailureResult(
                layoutName: layoutName,
                spacesMode: loadedConfig.config.resolvedSpacesMode,
                message: "virtual space recovery requires live arrange",
                subcode: "virtualStateRecoveryRequiresLiveArrange",
                exitCode: ErrorCode.validationError.rawValue,
                spaceID: spaceID,
                json: json
            )
        }

        guard let pending = state.pendingSwitchTransaction else {
            return nil
        }

        switch pending.status {
        case .inFlight:
            return nil
        case .recoveryRequired:
            if stateOnly {
                return arrangeFailureResult(
                    layoutName: layoutName,
                    spacesMode: loadedConfig.config.resolvedSpacesMode,
                    message: "virtual space recovery requires live arrange",
                    subcode: "virtualStateRecoveryRequiresLiveArrange",
                    exitCode: ErrorCode.validationError.rawValue,
                    spaceID: spaceID,
                    json: json
                )
            }

            guard let targetSpaceID = spaceID else {
                return nil
            }

            let strictMatch = layoutName == pending.activeLayoutName &&
                (targetSpaceID == pending.previousActiveSpaceID || targetSpaceID == pending.attemptedTargetSpaceID)
            guard strictMatch else {
                return arrangeFailureResult(
                    layoutName: layoutName,
                    spacesMode: loadedConfig.config.resolvedSpacesMode,
                    message: "virtual space recovery target does not match pending transaction",
                    subcode: "virtualStateRecoveryTargetMismatch",
                    exitCode: ErrorCode.validationError.rawValue,
                    spaceID: targetSpaceID,
                    json: json
                )
            }

            let availableSpaceIDs = Set(loadedConfig.config.layouts[layoutName]?.spaces.map(\.spaceID) ?? [])
            guard availableSpaceIDs.contains(targetSpaceID) else {
                return arrangeFailureResult(
                    layoutName: layoutName,
                    spacesMode: loadedConfig.config.resolvedSpacesMode,
                    message: "virtual space recovery target is unavailable in current config",
                    subcode: "virtualStateRecoveryTargetUnavailable",
                    exitCode: ErrorCode.validationError.rawValue,
                    spaceID: targetSpaceID,
                    json: json
                )
            }
        }

        return nil
    }

    private func recordVirtualSpaceDiagnosticEvent(
        event: String,
        requestID: String,
        code: ErrorCode,
        subcode: String,
        state: RuntimeState,
        attemptedTargetSpaceID: Int? = nil,
        previousActiveSpaceID: Int? = nil,
        rootCauseCategory: String? = nil,
        permissionScope: String? = nil,
        failedOperation: String? = nil,
        manualRecoveryRequired: Bool? = nil,
        lockOwnerMetadata: VirtualSpaceLockOwnerMetadata? = nil,
        lockWaitTimeoutMS: Int? = nil
    ) {
        let pending = state.pendingSwitchTransaction
        diagnosticEventStore.record(
            DiagnosticEvent(
                event: event,
                requestID: requestID,
                code: code.rawValue,
                subcode: subcode,
                activeLayoutName: state.activeLayoutName ?? pending?.activeLayoutName,
                activeVirtualSpaceID: state.activeVirtualSpaceID,
                attemptedTargetSpaceID: attemptedTargetSpaceID ?? pending?.attemptedTargetSpaceID,
                previousActiveSpaceID: previousActiveSpaceID ?? pending?.previousActiveSpaceID,
                configGeneration: state.configGeneration,
                revision: state.revision,
                rootCauseCategory: rootCauseCategory,
                permissionScope: permissionScope,
                failedOperation: failedOperation,
                manualRecoveryRequired: manualRecoveryRequired ?? pending?.manualRecoveryRequired,
                lockOwnerPID: lockOwnerMetadata?.pid,
                lockOwnerProcessKind: lockOwnerMetadata?.processKind,
                lockOwnerStartedAt: lockOwnerMetadata?.startedAt,
                lockWaitTimeoutMS: lockWaitTimeoutMS,
                unresolvedSlots: pending?.unresolvedSlots ?? []
            )
        )
    }

    private func recordStaleStateReadDiagnosticEvent(
        requestID: String,
        state: RuntimeState,
        failedOperation: String
    ) {
        diagnosticEventStore.record(
            DiagnosticEvent(
                event: "state.read.staleGeneration",
                requestID: requestID,
                code: ErrorCode.validationError.rawValue,
                subcode: "virtualStateUnavailable",
                activeLayoutName: state.activeLayoutName,
                activeVirtualSpaceID: state.activeVirtualSpaceID,
                configGeneration: state.configGeneration,
                revision: state.revision,
                rootCauseCategory: "staleStateRead",
                failedOperation: failedOperation
            )
        )
    }

    // spaceSwitchFailureEventName was removed along with rollback support.

    private func virtualSwitchOperationFailureRootCause(failedOperation _: String?) -> String {
        "visibilityConvergenceFailed"
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
    let lastActivatedAt: String?
}

private enum VirtualSpaceSwitchPreparation {
    case ready(VirtualSpaceSwitchContext)
    case result(CommandResult)
}

private enum VirtualSpaceRecoveryPreparation {
    case ready(VirtualSpaceRecoveryContext)
    case result(CommandResult)
}

private struct VirtualSpaceRecoveryContext {
    let state: RuntimeState
    let pending: PendingSwitchTransaction
    let nextState: RuntimeState
    let warning: String
}

struct VirtualSpaceSwitchContext {
    let persistedState: RuntimeState
    let loadedConfig: LoadedConfig?
    let state: RuntimeState
    let layout: LayoutDefinition
    let layoutName: String
    let targetSpace: SpaceDefinition
    let targetSpaceID: Int
    let previousSpaceID: Int?
    let didChangeSpace: Bool
    let hostDisplay: DisplayInfo?
    let windows: [WindowSnapshot]
    let slotsWithAdopted: [SlotEntry]
    let resolvedTargets: [VirtualSwitchWindow]
    let resolvedOthers: [VirtualSwitchWindow]
    let configGeneration: String
}

private enum TargetWindowResolution {
    case success(WindowSnapshot)
    case failure(CommandResult)
}
