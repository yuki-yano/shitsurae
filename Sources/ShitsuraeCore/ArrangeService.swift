import CryptoKit
import CoreGraphics
import Foundation

public struct PlanItem: Codable {
    public let spaceID: Int
    public let slot: Int?
    public let source: WindowSource
    public let bundleID: String
    public let action: String
    public let frame: ResolvedFrame?
    public let launch: Bool
}

public struct SkippedItem: Codable {
    public let spaceID: Int?
    public let slot: Int?
    public let reason: String
    public let detail: String
}

public struct WarningItem: Codable {
    public let code: String
    public let detail: String
}

public struct ErrorItem: Codable {
    public let code: Int
    public let message: String
    public let spaceID: Int?
    public let slot: Int?
}

public struct ArrangeDryRunJSON: Codable {
    public let schemaVersion: Int
    public let layout: String
    public let spacesMode: SpacesMode
    public let plan: [PlanItem]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]
}

public struct ArrangeExecutionJSON: Codable {
    public let schemaVersion: Int
    public let layout: String
    public let spacesMode: SpacesMode
    public let result: String
    public let subcode: String?
    public let unresolvedSlots: [PendingUnresolvedSlot]
    public let hardErrors: [ErrorItem]
    public let softErrors: [ErrorItem]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]
    public let exitCode: Int
}

public struct ArrangeContext {
    public let config: ShitsuraeConfig
    public let supportedBuildCatalogURL: URL
    public let configGeneration: String

    public init(
        config: ShitsuraeConfig,
        supportedBuildCatalogURL: URL,
        configGeneration: String = "legacy"
    ) {
        self.config = config
        self.supportedBuildCatalogURL = supportedBuildCatalogURL
        self.configGeneration = configGeneration
    }
}

public final class ArrangeService {
    private let context: ArrangeContext
    private let logger: ShitsuraeLogger
    private let stateStore: RuntimeStateStore
    private let driver: ArrangeDriver

    private struct SlotStateKey: Hashable {
        let slot: Int
        let spaceID: Int?
    }

    public init(
        context: ArrangeContext,
        logger: ShitsuraeLogger,
        stateStore: RuntimeStateStore = RuntimeStateStore(),
        driver: ArrangeDriver = LiveArrangeDriver()
    ) {
        self.context = context
        self.logger = logger
        self.stateStore = stateStore
        self.driver = driver
    }

    public func dryRun(layoutName: String, spaceID: Int? = nil) throws -> ArrangeDryRunJSON {
        let planning = try buildExecutionPlan(layoutName: layoutName, spaceID: spaceID, includeDryRunDiagnostics: true)

        return ArrangeDryRunJSON(
            schemaVersion: 1,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            plan: planning.plan,
            skipped: planning.skipped,
            warnings: planning.warnings
        )
    }

    public func execute(layoutName: String, spaceID: Int? = nil, stateOnly: Bool = false) throws -> ArrangeExecutionJSON {
        var startFields: [String: Any] = ["layout": layoutName]
        if stateOnly {
            startFields["stateOnly"] = true
        }
        logger.log(event: "arrange.start", fields: startFields)

        let layout = try validatedLayout(layoutName, spaceID: spaceID)

        if stateOnly {
            return try executeStateOnly(layoutName: layoutName, layout: layout, spaceID: spaceID)
        }

        return try executeLiveArrange(layoutName: layoutName, layout: layout, spaceID: spaceID)
    }

    private func executeLiveArrange(
        layoutName: String,
        layout: LayoutDefinition,
        spaceID: Int?
    ) throws -> ArrangeExecutionJSON {
        let preflight: LiveArrangePreparation
        switch try prepareLiveArrange(layoutName: layoutName, layout: layout, spaceID: spaceID) {
        case let .result(result):
            return result
        case let .ready(ready):
            preflight = ready
        }

        let execution = executeLiveArrangeSteps(
            layoutName: layoutName,
            layout: layout,
            planning: preflight.planning,
            virtualHostContext: preflight.virtualHostContext
        )
        let outcome = finalizeLiveArrangeOutcome(
            layoutName: layoutName,
            hardErrors: execution.hardErrors,
            softErrors: execution.softErrors,
            unresolvedSlots: execution.unresolvedSlots
        )

        let persistedSlotEntries = persistedSlotEntriesForLiveArrange(
            layout: layout,
            arrangedSpaceID: spaceID,
            resolvedSlotEntries: execution.slotEntries
        )

        persistRuntimeState(
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: spaceID,
            slotEntries: persistedSlotEntries,
            preserveUnresolvedSelectedSlots: !isVirtualMode && outcome.result != "success",
            clearLiveArrangeRecoveryRequired: true
        )

        let output = makeArrangeExecutionOutput(
            layoutName: layoutName,
            outcome: outcome,
            execution: execution
        )

        logger.log(
            event: "arrange.finished",
            fields: [
                "layout": layoutName,
                "result": outcome.result,
                "exitCode": outcome.exitCode,
            ]
        )

        return output
    }

    private func prepareLiveArrange(
        layoutName: String,
        layout: LayoutDefinition,
        spaceID: Int?
    ) throws -> LiveArrangePreparationResult {
        if !driver.accessibilityGranted() {
            return .result(failed(
                layoutName: layoutName,
                code: .missingPermission,
                message: "Accessibility permission is required"
            ))
        }

        if !isVirtualMode {
            if let actual = driver.actualSpacesMode(), actual != context.config.resolvedSpacesMode {
                return .result(failed(
                    layoutName: layoutName,
                    code: .spacesModeMismatch,
                    message: "spacesMode mismatch expected=\(context.config.resolvedSpacesMode.rawValue) actual=\(actual.rawValue)"
                ))
            }

            let backend = driver.backendAvailable(catalogURL: context.supportedBuildCatalogURL)
            if !backend.0 {
                return .result(failed(
                    layoutName: layoutName,
                    code: .backendUnavailable,
                    message: "space backend is unavailable: \(backend.1 ?? "unknown")"
                ))
            }
        }

        let virtualHostContext = isVirtualMode ? resolveVirtualHostDisplayContext(layout: layout) : nil
        if isVirtualMode, virtualHostContext == nil {
            return .result(failed(
                layoutName: layoutName,
                code: .validationError,
                message: "host display for virtual arrange is unavailable",
                subcode: "virtualHostDisplayUnavailable"
            ))
        }

        let planning = try buildExecutionPlan(layoutName: layoutName, spaceID: spaceID, includeDryRunDiagnostics: false)
        return .ready(LiveArrangePreparation(
            planning: planning,
            virtualHostContext: virtualHostContext
        ))
    }

    private func executeLiveArrangeSteps(
        layoutName: String,
        layout: LayoutDefinition,
        planning: PlanningResult,
        virtualHostContext: (display: DisplayInfo, visibleSpace: SpaceInfo)?
    ) -> LiveArrangeStepExecution {
        var hardErrors: [ErrorItem] = []
        var softErrors: [ErrorItem] = []
        var skipped = planning.skipped
        var warnings = planning.warnings
        var slotEntries: [SlotEntry] = []
        var unresolvedSlots: [PendingUnresolvedSlot] = []

        let policy = context.config.resolvedExecutionPolicy

        for step in planning.steps {
            let result = executeLiveArrangeStep(
                step,
                layoutName: layoutName,
                layout: layout,
                policy: policy,
                virtualHostContext: virtualHostContext
            )

            skipped.append(contentsOf: result.skipped)
            warnings.append(contentsOf: result.warnings)
            slotEntries.append(contentsOf: result.slotEntries)
            unresolvedSlots.append(contentsOf: result.unresolvedSlots)
            hardErrors.append(contentsOf: result.hardErrors)
            softErrors.append(contentsOf: result.softErrors)

            if !hardErrors.isEmpty {
                break
            }
        }

        if let initialFocusSlot = layout.initialFocus?.slot {
            if let entry = slotEntries.first(where: { $0.slot == initialFocusSlot }) {
                _ = driver.activate(bundleID: entry.bundleID)
            } else {
                warnings.append(
                    WarningItem(
                        code: "initial.focus.unavailable",
                        detail: "slot \(initialFocusSlot) was not registered"
                    )
                )
            }
        }

        return LiveArrangeStepExecution(
            hardErrors: hardErrors,
            softErrors: softErrors,
            skipped: skipped,
            warnings: warnings,
            slotEntries: slotEntries,
            unresolvedSlots: unresolvedSlots
        )
    }

    private func executeLiveArrangeStep(
        _ step: ExecutionStep,
        layoutName: String,
        layout: LayoutDefinition,
        policy: ExecutionPolicy,
        virtualHostContext: (display: DisplayInfo, visibleSpace: SpaceInfo)?
    ) -> LiveArrangeStepResult {
        let windowDef = step.window

        if PolicyEngine.matchesIgnoreRule(windowDefinition: windowDef, rules: context.config.ignore?.apply) {
            return LiveArrangeStepResult(
                skipped: [
                    SkippedItem(
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot,
                        reason: "ignoreApply",
                        detail: "matched ignore.apply rule"
                    ),
                ],
                warnings: [
                    WarningItem(
                        code: "ignore.apply.matched",
                        detail: "slot \(windowDef.slot) skipped by ignore.apply"
                    ),
                ]
            )
        }

        let launch = windowDef.launch ?? true
        let launchRequest = ApplicationLaunchRequest(
            bundleID: windowDef.match.bundleID,
            profileDirectory: windowDef.match.profile
        )
        let preLaunchWindowIDs = launch && windowDef.match.profile != nil
            ? Set(driver.queryWindowsOnAllSpaces().filter { $0.bundleID == windowDef.match.bundleID }.map(\.windowID))
            : nil
        if launch, !driver.launch(request: launchRequest) {
            return LiveArrangeStepResult(
                softErrors: [
                    ErrorItem(
                        code: ErrorCode.appLaunchFailed.rawValue,
                        message: "failed to launch app: \(windowDef.match.bundleID)",
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot
                    ),
                ]
            )
        }

        let waitOutcome = waitForWindow(
            rule: windowDef.match,
            policy: policy,
            slot: windowDef.slot,
            spaceID: step.space.spaceID,
            layoutName: layoutName,
            preLaunchWindowIDs: preLaunchWindowIDs
        )

        switch waitOutcome {
        case let .found(window):
            if let virtualHostContext,
               let unresolved = unresolvedVirtualArrangeSlot(
                   observedWindow: window,
                   slot: windowDef.slot,
                   spaceID: step.space.spaceID,
                   hostContext: virtualHostContext
               )
            {
                return LiveArrangeStepResult(
                    hardErrors: [
                        ErrorItem(
                            code: ErrorCode.validationError.rawValue,
                            message: "tracked window is outside host native space",
                            spaceID: step.space.spaceID,
                            slot: windowDef.slot
                        ),
                    ],
                    unresolvedSlots: [unresolved]
                )
            }

            if !isVirtualMode, window.spaceID != step.space.spaceID {
                if !driver.moveWindowToSpace(
                    windowID: window.windowID,
                    bundleID: window.bundleID,
                    displayID: step.display?.id,
                    spaceID: step.space.spaceID,
                    spacesMode: context.config.resolvedSpacesMode,
                    method: policy.spaceMoveMethod(for: window.bundleID)
                ) {
                    return LiveArrangeStepResult(
                        hardErrors: [
                            ErrorItem(
                                code: ErrorCode.spaceMoveFailed.rawValue,
                                message: "failed to move window to target space",
                                spaceID: step.space.spaceID,
                                slot: windowDef.slot
                            ),
                        ]
                    )
                }
            }

            if !setFrameWithRetry(
                windowID: window.windowID,
                bundleID: window.bundleID,
                frame: step.resolvedFrame
            ) {
                return LiveArrangeStepResult(
                    softErrors: [
                        ErrorItem(
                            code: ErrorCode.operationTimedOut.rawValue,
                            message: "failed to apply frame",
                            spaceID: step.space.spaceID,
                            slot: windowDef.slot
                        ),
                    ]
                )
            }

            return LiveArrangeStepResult(
                slotEntries: [
                    makeSlotEntry(
                        layoutName: layoutName,
                        spaceID: step.space.spaceID,
                        window: windowDef,
                        observedWindow: window,
                        displayID: step.display?.id ?? window.displayID,
                        visibleFrame: step.resolvedFrame
                    ),
                ]
            )

        case .fullscreenExcluded:
            return LiveArrangeStepResult(
                skipped: [
                    SkippedItem(
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot,
                        reason: "fullscreenExcluded",
                        detail: "matched window is fullscreen and excluded"
                    ),
                ]
            )
        case .notFound:
            return LiveArrangeStepResult(
                softErrors: [
                    ErrorItem(
                        code: ErrorCode.targetWindowNotFound.rawValue,
                        message: "target window not found: \(windowDef.match.bundleID)",
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot
                    ),
                ]
            )
        }
    }

    private func finalizeLiveArrangeOutcome(
        layoutName _: String,
        hardErrors: [ErrorItem],
        softErrors: [ErrorItem],
        unresolvedSlots: [PendingUnresolvedSlot]
    ) -> LiveArrangeOutcome {
        if let firstHard = hardErrors.first {
            return LiveArrangeOutcome(
                result: "failed",
                exitCode: firstHard.code,
                subcode: unresolvedSlots.isEmpty ? nil : "virtualSpaceUnresolvedSlots"
            )
        }
        if !softErrors.isEmpty {
            return LiveArrangeOutcome(
                result: "partial",
                exitCode: ErrorCode.partialSuccess.rawValue,
                subcode: nil
            )
        }
        return LiveArrangeOutcome(
            result: "success",
            exitCode: ErrorCode.success.rawValue,
            subcode: nil
        )
    }

    private func executeStateOnly(layoutName: String, layout: LayoutDefinition, spaceID: Int?) throws -> ArrangeExecutionJSON {
        let slotEntries = stateOnlySlotEntries(layout: layout, arrangedSpaceID: spaceID)

        persistRuntimeState(
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: spaceID,
            slotEntries: slotEntries,
            preserveUnresolvedSelectedSlots: false,
            clearLiveArrangeRecoveryRequired: false
        )

        let output = makeStateOnlyArrangeExecutionOutput(layoutName: layoutName)

        logger.log(
            event: "arrange.finished",
            fields: [
                "layout": layoutName,
                "result": "success",
                "exitCode": ErrorCode.success.rawValue,
                "stateOnly": true,
            ]
        )

        return output
    }

    private func persistRuntimeState(
        layoutName: String,
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        slotEntries: [SlotEntry],
        preserveUnresolvedSelectedSlots: Bool,
        clearLiveArrangeRecoveryRequired: Bool
    ) {
        let currentState = stateStore.load()
        let preservedEntries = preservedRuntimeStateEntries(
            currentState: currentState,
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: arrangedSpaceID,
            slotEntries: slotEntries,
            preserveUnresolvedSelectedSlots: preserveUnresolvedSelectedSlots
        )
        let nextState = makePersistedArrangeRuntimeState(
            currentState: currentState,
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: arrangedSpaceID,
            slotEntries: slotEntries,
            preservedEntries: preservedEntries,
            clearLiveArrangeRecoveryRequired: clearLiveArrangeRecoveryRequired
        )
        stateStore.save(state: nextState)
    }

    private func persistedSlotEntriesForLiveArrange(
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        resolvedSlotEntries: [SlotEntry]
    ) -> [SlotEntry] {
        if isVirtualMode {
            return mergeResolvedSlotEntries(
                base: stateOnlySlotEntries(layout: layout, arrangedSpaceID: arrangedSpaceID),
                resolved: resolvedSlotEntries
            )
        }

        return resolvedSlotEntries
    }

    private func makeArrangeExecutionOutput(
        layoutName: String,
        outcome: LiveArrangeOutcome,
        execution: LiveArrangeStepExecution
    ) -> ArrangeExecutionJSON {
        ArrangeExecutionJSON(
            schemaVersion: 2,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            result: outcome.result,
            subcode: outcome.subcode,
            unresolvedSlots: execution.unresolvedSlots,
            hardErrors: execution.hardErrors,
            softErrors: execution.softErrors,
            skipped: execution.skipped,
            warnings: execution.warnings,
            exitCode: outcome.exitCode
        )
    }

    private func makeStateOnlyArrangeExecutionOutput(layoutName: String) -> ArrangeExecutionJSON {
        ArrangeExecutionJSON(
            schemaVersion: 2,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            result: "success",
            subcode: nil,
            unresolvedSlots: [],
            hardErrors: [],
            softErrors: [],
            skipped: [],
            warnings: [
                WarningItem(
                    code: "arrange.stateOnly",
                    detail: "updated runtime state without applying layout operations"
                ),
            ],
            exitCode: ErrorCode.success.rawValue
        )
    }

    private func preservedRuntimeStateEntries(
        currentState: RuntimeState,
        layoutName: String,
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        slotEntries: [SlotEntry],
        preserveUnresolvedSelectedSlots: Bool
    ) -> [SlotEntry] {
        let selectedSpaces = Set(
            layout.spaces.compactMap { space -> Int? in
                guard arrangedSpaceID == nil || space.spaceID == arrangedSpaceID else {
                    return nil
                }
                return space.spaceID
            }
        )
        let selectedSlotKeys = Set(
            layout.spaces.flatMap { space -> [SlotStateKey] in
                guard arrangedSpaceID == nil || space.spaceID == arrangedSpaceID else {
                    return []
                }
                return space.windows.map { window in
                    SlotStateKey(slot: window.slot, spaceID: space.spaceID)
                }
            }
        )
        let registeredKeys = Set(
            slotEntries.map { entry in
                SlotStateKey(slot: entry.slot, spaceID: entry.spaceID)
            }
        )

        return currentState.slots.filter { entry in
            if isVirtualMode, entry.layoutName != layoutName {
                return false
            }

            let key = SlotStateKey(slot: entry.slot, spaceID: entry.spaceID)

            if let entrySpaceID = entry.spaceID, selectedSpaces.contains(entrySpaceID) {
                return preserveUnresolvedSelectedSlots &&
                    selectedSlotKeys.contains(key) &&
                    !registeredKeys.contains(key)
            }

            return arrangedSpaceID != nil
        }
    }

    private func makePersistedArrangeRuntimeState(
        currentState: RuntimeState,
        layoutName: String,
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        slotEntries: [SlotEntry],
        preservedEntries: [SlotEntry],
        clearLiveArrangeRecoveryRequired: Bool
    ) -> RuntimeState {
        let nextState = currentState.with(
            revision: currentState.revision + 1,
            stateMode: context.config.resolvedSpaceInterpretationMode,
            configGeneration: context.configGeneration,
            liveArrangeRecoveryRequired: clearLiveArrangeRecoveryRequired
                ? false
                : currentState.liveArrangeRecoveryRequired,
            slots: preservedEntries + slotEntries
        )

        if isVirtualMode {
            return nextState.withActiveVirtualContext(
                layoutName: layoutName,
                spaceID: resolvedVirtualActiveSpaceID(
                    layout: layout,
                    currentState: currentState,
                    arrangedSpaceID: arrangedSpaceID,
                    slotEntries: slotEntries
                ),
                pendingSwitchTransaction: currentState.pendingSwitchTransaction
            )
        }

        return nextState.clearingActiveVirtualContext(
            pendingSwitchTransaction: currentState.pendingSwitchTransaction
        )
    }

    private func resolvedVirtualActiveSpaceID(
        layout: LayoutDefinition,
        currentState: RuntimeState,
        arrangedSpaceID: Int?,
        slotEntries: [SlotEntry]
    ) -> Int? {
        if let arrangedSpaceID {
            return arrangedSpaceID
        }

        if let activeSpaceID = currentState.activeVirtualSpaceID,
           layout.spaces.contains(where: { $0.spaceID == activeSpaceID }),
           slotEntries.contains(where: { $0.spaceID == activeSpaceID && $0.windowID != nil })
        {
            return activeSpaceID
        }

        if let resolvedSpaceID = slotEntries.first(where: { $0.windowID != nil })?.spaceID {
            return resolvedSpaceID
        }

        return layout.spaces.first?.spaceID
    }

    private func waitForWindow(
        rule: WindowMatchRule,
        policy _: ExecutionPolicy,
        slot: Int,
        spaceID: Int,
        layoutName: String,
        preLaunchWindowIDs: Set<UInt32>?
    ) -> WaitOutcome {
        let totalTimeoutMs = 5000
        let deadline = Date().addingTimeInterval(TimeInterval(totalTimeoutMs) / 1000)
        let preferredWindow = preferredWindowIdentity(for: rule, slot: slot, spaceID: spaceID, layoutName: layoutName)

        while Date() <= deadline {
            let candidates = driver.queryWindowsOnAllSpaces().filter { $0.bundleID == rule.bundleID }
            let nonFullscreen = candidates.filter { !$0.isFullscreen }

            if let preferredWindow,
               let preferred = nonFullscreen.first(where: {
                   $0.windowID == preferredWindow.windowID &&
                       (preferredWindow.pid == nil || $0.pid == preferredWindow.pid)
               })
            {
                return .found(preferred)
            }

            if let found = selectWindow(rule: rule, candidates: nonFullscreen, preLaunchWindowIDs: preLaunchWindowIDs) {
                return .found(found)
            }

            if selectWindow(rule: rule, candidates: candidates, preLaunchWindowIDs: preLaunchWindowIDs) != nil {
                return .fullscreenExcluded
            }

            let remainingMs = Int(deadline.timeIntervalSinceNow * 1000)
            if remainingMs <= 0 {
                break
            }

            let waitMs = min(100, remainingMs)
            driver.sleep(milliseconds: waitMs)
        }

        logger.log(
            level: "error",
            event: "arrange.waitWindow.timeout",
            fields: ["spaceID": spaceID, "slot": slot]
        )

        return .notFound
    }

    private func preferredWindowIdentity(
        for rule: WindowMatchRule,
        slot: Int,
        spaceID: Int,
        layoutName: String
    ) -> (windowID: UInt32, pid: Int?)? {
        guard let entry = stateStore.load().slots.first(where: {
            $0.layoutName == (isVirtualMode ? layoutName : "__legacy__")
                && $0.slot == slot
                && $0.spaceID == spaceID
                && $0.bundleID == rule.bundleID
                && $0.profile == rule.profile
        }),
        let windowID = entry.windowID
        else {
            return nil
        }
        return (windowID, entry.pid)
    }

    private func selectWindow(
        rule: WindowMatchRule,
        candidates: [WindowSnapshot],
        preLaunchWindowIDs: Set<UInt32>?
    ) -> WindowSnapshot? {
        if let found = WindowMatchEngine.select(rule: rule, candidates: candidates) {
            return found
        }

        guard rule.profile != nil,
              let preLaunchWindowIDs
        else {
            return nil
        }

        let newCandidates = candidates.filter { !preLaunchWindowIDs.contains($0.windowID) }
        guard !newCandidates.isEmpty else {
            return nil
        }

        let fallbackRule = WindowMatchRule(
            bundleID: rule.bundleID,
            title: rule.title,
            role: rule.role,
            subrole: rule.subrole,
            profile: nil,
            excludeTitleRegex: rule.excludeTitleRegex,
            index: rule.index
        )
        return WindowMatchEngine.select(rule: fallbackRule, candidates: newCandidates)
    }

    private func setFrameWithRetry(
        windowID: UInt32,
        bundleID: String,
        frame: ResolvedFrame
    ) -> Bool {
        let attempts = 2
        for current in 0 ..< attempts {
            if driver.setWindowFrame(windowID: windowID, bundleID: bundleID, frame: frame) {
                return true
            }

            if current < attempts - 1 {
                driver.sleep(milliseconds: 100)
            }
        }

        return false
    }

    private func buildExecutionPlan(
        layoutName: String,
        spaceID: Int?,
        includeDryRunDiagnostics: Bool
    ) throws -> PlanningResult {
        let layout = try validatedLayout(layoutName, spaceID: spaceID)

        let displays = driver.displays()
        let defaultDisplay = displays.first

        var selectedSpaceIDs = Set<Int>()
        var selectedSpaces: [SelectedSpace] = []
        var skipped: [SkippedItem] = []
        var warnings: [WarningItem] = []
        var plan: [PlanItem] = []
        var steps: [ExecutionStep] = []
        var registeredSlots = Set<Int>()

        for space in layout.spaces {
            if let spaceID, space.spaceID != spaceID {
                continue
            }
            if selectedSpaceIDs.contains(space.spaceID) {
                continue
            }

            let display = resolveDisplay(for: space.display, available: displays, monitors: context.config.monitors)
            guard let matchedDisplay = display else {
                skipped.append(
                    SkippedItem(
                        spaceID: space.spaceID,
                        slot: nil,
                        reason: "displayMismatch",
                        detail: "display condition did not match"
                    )
                )
                continue
            }

            selectedSpaceIDs.insert(space.spaceID)
            selectedSpaces.append(SelectedSpace(space: space, display: matchedDisplay))
        }

        let currentWindows = includeDryRunDiagnostics ? driver.queryWindowsOnAllSpaces() : []

        for selected in selectedSpaces {
            for window in selected.space.windows {
                let source = window.source ?? .window
                let launch = window.launch ?? true

                if PolicyEngine.matchesIgnoreRule(windowDefinition: window, rules: context.config.ignore?.apply) {
                    skipped.append(
                        SkippedItem(
                            spaceID: selected.space.spaceID,
                            slot: window.slot,
                            reason: "ignoreApply",
                            detail: "matched ignore.apply rule"
                        )
                    )
                    warnings.append(
                        WarningItem(
                            code: "ignore.apply.matched",
                            detail: "slot \(window.slot) skipped by ignore.apply"
                        )
                    )
                    continue
                }

                if launch {
                    plan.append(
                        PlanItem(
                            spaceID: selected.space.spaceID,
                            slot: window.slot,
                            source: source,
                            bundleID: window.match.bundleID,
                            action: "launch",
                            frame: nil,
                            launch: true
                        )
                    )
                }

                if includeDryRunDiagnostics {
                    let nonFullscreen = currentWindows.filter { !$0.isFullscreen }
                    if WindowMatchEngine.select(rule: window.match, candidates: nonFullscreen) == nil {
                        skipped.append(
                            SkippedItem(
                                spaceID: selected.space.spaceID,
                                slot: window.slot,
                                reason: "noWindowMatched",
                                detail: "no current window matched"
                            )
                        )
                    }
                }

                plan.append(
                    PlanItem(
                        spaceID: selected.space.spaceID,
                        slot: window.slot,
                        source: source,
                        bundleID: window.match.bundleID,
                        action: "waitWindow",
                        frame: nil,
                        launch: launch
                    )
                )

                if !isVirtualMode {
                    plan.append(
                        PlanItem(
                            spaceID: selected.space.spaceID,
                            slot: window.slot,
                            source: source,
                            bundleID: window.match.bundleID,
                            action: "moveSpace",
                            frame: nil,
                            launch: launch
                        )
                    )
                }

                let resolvedFrame = try resolveFrame(window: window, display: selected.display ?? defaultDisplay)
                plan.append(
                    PlanItem(
                        spaceID: selected.space.spaceID,
                        slot: window.slot,
                        source: source,
                        bundleID: window.match.bundleID,
                        action: "setFrame",
                        frame: resolvedFrame,
                        launch: launch
                    )
                )

                plan.append(
                    PlanItem(
                        spaceID: selected.space.spaceID,
                        slot: window.slot,
                        source: source,
                        bundleID: window.match.bundleID,
                        action: "registerSlot",
                        frame: nil,
                        launch: launch
                    )
                )

                steps.append(
                    ExecutionStep(
                        space: selected.space,
                        display: selected.display,
                        window: window,
                        resolvedFrame: resolvedFrame
                    )
                )
                registeredSlots.insert(window.slot)
            }
        }

        if let initialSlot = layout.initialFocus?.slot {
            if registeredSlots.contains(initialSlot) {
                plan.append(
                    PlanItem(
                        spaceID: selectedSpaces.first?.space.spaceID ?? 1,
                        slot: initialSlot,
                        source: .window,
                        bundleID: "",
                        action: "focusInitial",
                        frame: nil,
                        launch: false
                    )
                )
            } else {
                warnings.append(
                    WarningItem(
                        code: "initial.focus.unavailable",
                        detail: "slot \(initialSlot) was not registered"
                    )
                )
            }
        }

        return PlanningResult(plan: plan, skipped: skipped, warnings: warnings, steps: steps)
    }

    private func resolveFrame(window: WindowDefinition, display: DisplayInfo?) throws -> ResolvedFrame {
        let basisRect = display?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        return try LengthParser.resolveFrame(window.frame, basis: basisRect, scale: display?.scale ?? 2.0)
    }

    private func resolveDisplay(
        for definition: DisplayDefinition?,
        available: [DisplayInfo],
        monitors: MonitorsDefinition?
    ) -> DisplayInfo? {
        guard !available.isEmpty else { return nil }

        if definition == nil {
            return available.first(where: \.isPrimary) ?? available.sorted(by: { $0.id < $1.id }).first
        }

        var candidates = available

        if let monitor = definition?.monitor {
            switch monitor {
            case .primary:
                candidates = available.filter(\.isPrimary)
            case .secondary:
                if let explicit = monitors?.secondary?.id {
                    candidates = available.filter { $0.id == explicit }
                } else {
                    let primaryID = available.first(where: \.isPrimary)?.id
                    candidates = available
                        .filter { $0.id != primaryID }
                        .sorted { $0.id < $1.id }
                    if candidates.count > 1 {
                        candidates = [candidates[0]]
                    }
                }
            }
        }

        if let id = definition?.id {
            candidates = candidates.filter { $0.id == id }
        }

        if let width = definition?.width {
            candidates = candidates.filter { $0.width == width }
        }

        if let height = definition?.height {
            candidates = candidates.filter { $0.height == height }
        }

        return candidates.first
    }

    private func requiredLayout(_ layoutName: String) throws -> LayoutDefinition {
        guard let layout = context.config.layouts[layoutName] else {
            throw ShitsuraeError(.validationError, "layout not found: \(layoutName)")
        }
        return layout
    }

    private func validatedLayout(_ layoutName: String, spaceID: Int?) throws -> LayoutDefinition {
        let layout = try requiredLayout(layoutName)

        if let spaceID, !layout.spaces.contains(where: { $0.spaceID == spaceID }) {
            throw ShitsuraeError(.validationError, "space not found in layout: \(spaceID)")
        }

        return layout
    }

    private func stateOnlySlotEntries(layout: LayoutDefinition, arrangedSpaceID: Int?) -> [SlotEntry] {
        let existingState = stateStore.load()
        var selectedSpaceIDs = Set<Int>()
        var entries: [SlotEntry] = []
        let displays = driver.displays()
        let defaultDisplay = displays.first

        for space in layout.spaces {
            if let arrangedSpaceID, space.spaceID != arrangedSpaceID {
                continue
            }

            if !selectedSpaceIDs.insert(space.spaceID).inserted {
                continue
            }

            let resolvedDisplay = resolveDisplay(
                for: space.display,
                available: displays,
                monitors: context.config.monitors
            ) ?? defaultDisplay

            for window in space.windows {
                let fingerprint = definitionFingerprint(
                    layoutName: layoutName(for: layout),
                    spaceID: space.spaceID,
                    window: window
                )
                let carried = existingState.slots.first {
                    $0.layoutName == layoutName(for: layout) && $0.definitionFingerprint == fingerprint
                }

                entries.append(
                    makeStateOnlySlotEntry(
                        layoutName: layoutName(for: layout),
                        spaceID: space.spaceID,
                        window: window,
                        existing: carried,
                        displayID: resolvedDisplay?.id ?? space.display?.id,
                        desiredVisibleFrame: try? resolveFrame(window: window, display: resolvedDisplay)
                    )
                )
            }
        }

        return entries
    }

    private func runtimeStateTitle(for rule: WindowMatchRule) -> String {
        if let equals = rule.title?.equals, !equals.isEmpty {
            return equals
        }
        if let contains = rule.title?.contains, !contains.isEmpty {
            return contains
        }
        return rule.bundleID
    }

    private var isVirtualMode: Bool {
        context.config.resolvedSpaceInterpretationMode == .virtual
    }

    private func makeSlotEntry(
        layoutName: String,
        spaceID: Int,
        window: WindowDefinition,
        observedWindow: WindowSnapshot,
        displayID: String?,
        visibleFrame: ResolvedFrame
    ) -> SlotEntry {
        let titleMatch = persistedTitleMatch(for: window.match)
        return SlotEntry(
            layoutName: isVirtualMode ? layoutName : "__legacy__",
            slot: window.slot,
            source: window.source ?? .window,
            bundleID: window.match.bundleID,
            definitionFingerprint: definitionFingerprint(layoutName: layoutName, spaceID: spaceID, window: window),
            pid: observedWindow.pid,
            titleMatchKind: titleMatch.kind,
            titleMatchValue: titleMatch.value,
            excludeTitleRegex: window.match.excludeTitleRegex,
            role: window.match.role,
            subrole: window.match.subrole,
            matchIndex: window.match.index,
            lastKnownTitle: observedWindow.title,
            profile: window.match.profile ?? observedWindow.profileDirectory,
            spaceID: spaceID,
            nativeSpaceID: observedWindow.spaceID,
            displayID: displayID,
            windowID: observedWindow.windowID,
            lastVisibleFrame: visibleFrame,
            lastHiddenFrame: nil,
            visibilityState: isVirtualMode ? .visible : nil,
            lastActivatedAt: existingVirtualLastActivatedAt(spaceID: spaceID, window: observedWindow)
        )
    }

    private func makeStateOnlySlotEntry(
        layoutName: String,
        spaceID: Int,
        window: WindowDefinition,
        existing: SlotEntry?,
        displayID: String?,
        desiredVisibleFrame: ResolvedFrame?
    ) -> SlotEntry {
        let titleMatch = persistedTitleMatch(for: window.match)
        let lastKnownTitle: String?
        if isVirtualMode {
            lastKnownTitle = existing?.lastKnownTitle
        } else {
            lastKnownTitle = existing?.lastKnownTitle ?? runtimeStateTitle(for: window.match)
        }

        return SlotEntry(
            layoutName: isVirtualMode ? layoutName : "__legacy__",
            slot: window.slot,
            source: window.source ?? .window,
            bundleID: window.match.bundleID,
            definitionFingerprint: definitionFingerprint(layoutName: layoutName, spaceID: spaceID, window: window),
            pid: existing?.pid,
            titleMatchKind: titleMatch.kind,
            titleMatchValue: titleMatch.value,
            excludeTitleRegex: window.match.excludeTitleRegex,
            role: window.match.role,
            subrole: window.match.subrole,
            matchIndex: window.match.index,
            lastKnownTitle: lastKnownTitle,
            profile: window.match.profile ?? existing?.profile,
            spaceID: spaceID,
            nativeSpaceID: existing?.nativeSpaceID,
            displayID: existing?.displayID ?? displayID,
            windowID: existing?.windowID,
            lastVisibleFrame: existing?.lastVisibleFrame ?? desiredVisibleFrame,
            lastHiddenFrame: existing?.lastHiddenFrame,
            visibilityState: existing?.visibilityState,
            lastActivatedAt: existing?.lastActivatedAt
        )
    }

    private func mergeResolvedSlotEntries(
        base: [SlotEntry],
        resolved: [SlotEntry]
    ) -> [SlotEntry] {
        guard !base.isEmpty else {
            return resolved
        }

        let resolvedByFingerprint = Dictionary(
            uniqueKeysWithValues: resolved.map { ($0.definitionFingerprint, $0) }
        )

        return base.map { entry in
            resolvedByFingerprint[entry.definitionFingerprint] ?? entry
        }
    }

    private func existingVirtualLastActivatedAt(spaceID: Int, window: WindowSnapshot) -> String? {
        guard isVirtualMode else {
            return nil
        }

        return stateStore.load().slots.first(where: {
            $0.spaceID == spaceID && $0.windowID == window.windowID
        })?.lastActivatedAt
    }

    private func persistedTitleMatch(for rule: WindowMatchRule) -> (kind: PersistedTitleMatchKind, value: String?) {
        if let equals = rule.title?.equals {
            return (.equals, equals)
        }
        if let contains = rule.title?.contains {
            return (.contains, contains)
        }
        if let regex = rule.title?.regex {
            return (.regex, regex)
        }
        return (.none, nil)
    }

    private func definitionFingerprint(layoutName: String, spaceID: Int, window: WindowDefinition) -> String {
        let titleMatch = persistedTitleMatch(for: window.match)

        func field(_ key: String, _ value: String?) -> String {
            "\(key)=\(value ?? "<nil>")"
        }

        let fields = [
            field("layoutName", layoutName),
            field("spaceID", String(spaceID)),
            field("slot", String(window.slot)),
            field("source", (window.source ?? .window).rawValue),
            field("bundleID", window.match.bundleID),
            field("profile", window.match.profile),
            field("titleMatchKind", titleMatch.kind.rawValue),
            field("titleMatchValue", titleMatch.value),
            field("excludeTitleRegex", window.match.excludeTitleRegex),
            field("role", window.match.role),
            field("subrole", window.match.subrole),
            field("matchIndex", window.match.index.map(String.init)),
        ].joined(separator: "\u{0}")

        let digest = SHA256.hash(data: Data(fields.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func layoutName(for targetLayout: LayoutDefinition) -> String {
        context.config.layouts.first(where: { $0.value == targetLayout })?.key ?? "__unknown__"
    }

    private func failed(layoutName: String, code: ErrorCode, message: String, subcode: String? = nil) -> ArrangeExecutionJSON {
        logger.log(level: "error", event: "arrange.failed", fields: ["code": code.rawValue, "message": message])
        return ArrangeExecutionJSON(
            schemaVersion: 2,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            result: "failed",
            subcode: subcode,
            unresolvedSlots: [],
            hardErrors: [
                ErrorItem(code: code.rawValue, message: message, spaceID: nil, slot: nil),
            ],
            softErrors: [],
            skipped: [],
            warnings: [],
            exitCode: code.rawValue
        )
    }

    private func resolveVirtualHostDisplayContext(layout: LayoutDefinition) -> (display: DisplayInfo, visibleSpace: SpaceInfo)? {
        guard let hostDisplay = resolveVirtualHostDisplay(layout: layout) else {
            return nil
        }

        let visibleSpaces = driver.spaces().filter { $0.displayID == hostDisplay.id && $0.isVisible }
        guard visibleSpaces.count == 1, let visibleSpace = visibleSpaces.first else {
            return nil
        }

        return (hostDisplay, visibleSpace)
    }

    private func resolveVirtualHostDisplay(layout: LayoutDefinition) -> DisplayInfo? {
        let displays = driver.displays()
        guard !displays.isEmpty else {
            return nil
        }

        let explicitDefinitions = layout.spaces.compactMap(\.display)
        if let firstDefinition = explicitDefinitions.first {
            return resolveDisplay(for: firstDefinition, available: displays, monitors: context.config.monitors)
        }

        let frontmostUsableWindow = driver.queryWindows().first {
            $0.displayID != nil && !isShitsuraeManagedBundle($0.bundleID)
        }
        if let displayID = frontmostUsableWindow?.displayID {
            return displays.first(where: { $0.id == displayID })
        }

        let visibleDisplayIDs = Set(driver.spaces().compactMap { $0.isVisible ? $0.displayID : nil })
        guard visibleDisplayIDs.count == 1,
              let displayID = visibleDisplayIDs.first
        else {
            return nil
        }

        return displays.first(where: { $0.id == displayID })
    }

    private func unresolvedVirtualArrangeSlot(
        observedWindow: WindowSnapshot,
        slot: Int,
        spaceID: Int,
        hostContext: (display: DisplayInfo, visibleSpace: SpaceInfo)
    ) -> PendingUnresolvedSlot? {
        guard observedWindow.spaceID != hostContext.visibleSpace.spaceID ||
                observedWindow.displayID != hostContext.display.id
        else {
            return nil
        }

        return PendingUnresolvedSlot(
            slot: slot,
            spaceID: spaceID,
            reason: "hostNativeSpaceMismatch"
        )
    }

}

private enum WaitOutcome {
    case found(WindowSnapshot)
    case fullscreenExcluded
    case notFound
}

private enum LiveArrangePreparationResult {
    case ready(LiveArrangePreparation)
    case result(ArrangeExecutionJSON)
}

private struct LiveArrangePreparation {
    let planning: PlanningResult
    let virtualHostContext: (display: DisplayInfo, visibleSpace: SpaceInfo)?
}

private struct LiveArrangeStepResult {
    var hardErrors: [ErrorItem] = []
    var softErrors: [ErrorItem] = []
    var skipped: [SkippedItem] = []
    var warnings: [WarningItem] = []
    var slotEntries: [SlotEntry] = []
    var unresolvedSlots: [PendingUnresolvedSlot] = []
}

private struct LiveArrangeStepExecution {
    let hardErrors: [ErrorItem]
    let softErrors: [ErrorItem]
    let skipped: [SkippedItem]
    let warnings: [WarningItem]
    let slotEntries: [SlotEntry]
    let unresolvedSlots: [PendingUnresolvedSlot]
}

private struct LiveArrangeOutcome {
    let result: String
    let exitCode: Int
    let subcode: String?
}

private struct SelectedSpace {
    let space: SpaceDefinition
    let display: DisplayInfo?
}

private struct ExecutionStep {
    let space: SpaceDefinition
    let display: DisplayInfo?
    let window: WindowDefinition
    let resolvedFrame: ResolvedFrame
}

private struct PlanningResult {
    let plan: [PlanItem]
    let skipped: [SkippedItem]
    let warnings: [WarningItem]
    let steps: [ExecutionStep]
}
