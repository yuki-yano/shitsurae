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
    public let hardErrors: [ErrorItem]
    public let softErrors: [ErrorItem]
    public let skipped: [SkippedItem]
    public let warnings: [WarningItem]
    public let exitCode: Int
}

public struct ArrangeContext {
    public let config: ShitsuraeConfig
    public let supportedBuildCatalogURL: URL
}

public final class ArrangeService {
    private let context: ArrangeContext
    private let logger: ShitsuraeLogger
    private let stateStore: RuntimeStateStore
    private let driver: ArrangeDriver

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

    public func execute(layoutName: String, spaceID: Int? = nil) throws -> ArrangeExecutionJSON {
        logger.log(event: "arrange.start", fields: ["layout": layoutName])

        if !driver.accessibilityGranted() {
            return failed(
                layoutName: layoutName,
                code: .missingPermission,
                message: "Accessibility permission is required"
            )
        }

        if let actual = driver.actualSpacesMode(), actual != context.config.resolvedSpacesMode {
            return failed(
                layoutName: layoutName,
                code: .spacesModeMismatch,
                message: "spacesMode mismatch expected=\(context.config.resolvedSpacesMode.rawValue) actual=\(actual.rawValue)"
            )
        }

        let backend = driver.backendAvailable(catalogURL: context.supportedBuildCatalogURL)
        if !backend.0 {
            return failed(
                layoutName: layoutName,
                code: .backendUnavailable,
                message: "space backend is unavailable: \(backend.1 ?? "unknown")"
            )
        }

        let planning = try buildExecutionPlan(layoutName: layoutName, spaceID: spaceID, includeDryRunDiagnostics: false)

        var hardErrors: [ErrorItem] = []
        var softErrors: [ErrorItem] = []
        var skipped = planning.skipped
        var warnings = planning.warnings
        var slotEntries: [SlotEntry] = []

        let policy = context.config.resolvedExecutionPolicy
        let layout = try requiredLayout(layoutName)

        for step in planning.steps {
            let windowDef = step.window
            let source = windowDef.source ?? .window

            if PolicyEngine.matchesIgnoreRule(windowDefinition: windowDef, rules: context.config.ignore?.apply) {
                skipped.append(
                    SkippedItem(
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot,
                        reason: "ignoreApply",
                        detail: "matched ignore.apply rule"
                    )
                )
                warnings.append(
                    WarningItem(
                        code: "ignore.apply.matched",
                        detail: "slot \(windowDef.slot) skipped by ignore.apply"
                    )
                )
                continue
            }

            let launch = windowDef.launch ?? true
            if launch, !driver.launch(bundleID: windowDef.match.bundleID) {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.appLaunchFailed.rawValue,
                        message: "failed to launch app: \(windowDef.match.bundleID)",
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot
                    )
                )
                continue
            }

            let waitOutcome = waitForWindow(
                rule: windowDef.match,
                policy: policy,
                slot: windowDef.slot,
                spaceID: step.space.spaceID
            )

            switch waitOutcome {
            case let .found(window):
                if window.spaceID != step.space.spaceID {
                    if !driver.moveWindowToSpace(
                        windowID: window.windowID,
                        bundleID: window.bundleID,
                        displayID: step.display?.id,
                        spaceID: step.space.spaceID,
                        spacesMode: context.config.resolvedSpacesMode,
                        method: policy.spaceMoveMethod(for: window.bundleID)
                    ) {
                        hardErrors.append(
                            ErrorItem(
                                code: ErrorCode.spaceMoveFailed.rawValue,
                                message: "failed to move window to target space",
                                spaceID: step.space.spaceID,
                                slot: windowDef.slot
                            )
                        )
                        break
                    }
                }

                if !setFrameWithRetry(
                    windowID: window.windowID,
                    bundleID: window.bundleID,
                    frame: step.resolvedFrame
                ) {
                    softErrors.append(
                        ErrorItem(
                            code: ErrorCode.operationTimedOut.rawValue,
                            message: "failed to apply frame",
                            spaceID: step.space.spaceID,
                            slot: windowDef.slot
                        )
                    )
                    continue
                }

                slotEntries.append(
                    SlotEntry(
                        slot: windowDef.slot,
                        source: source,
                        bundleID: windowDef.match.bundleID,
                        title: window.title,
                        spaceID: step.space.spaceID,
                        displayID: step.display?.id ?? window.displayID,
                        windowID: window.windowID
                    )
                )

            case .fullscreenExcluded:
                skipped.append(
                    SkippedItem(
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot,
                        reason: "fullscreenExcluded",
                        detail: "matched window is fullscreen and excluded"
                    )
                )
                continue
            case .notFound:
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.targetWindowNotFound.rawValue,
                        message: "target window not found: \(windowDef.match.bundleID)",
                        spaceID: step.space.spaceID,
                        slot: windowDef.slot
                    )
                )
                continue
            }

            if !hardErrors.isEmpty {
                break
            }
        }

        stateStore.save(slots: slotEntries)

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

        let result: String
        let exitCode: Int

        if let firstHard = hardErrors.first {
            result = "failed"
            exitCode = firstHard.code
        } else if !softErrors.isEmpty {
            result = "partial"
            exitCode = ErrorCode.partialSuccess.rawValue
        } else {
            result = "success"
            exitCode = ErrorCode.success.rawValue
        }

        let output = ArrangeExecutionJSON(
            schemaVersion: 1,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            result: result,
            hardErrors: hardErrors,
            softErrors: softErrors,
            skipped: skipped,
            warnings: warnings,
            exitCode: exitCode
        )

        logger.log(
            event: "arrange.finished",
            fields: [
                "layout": layoutName,
                "result": result,
                "exitCode": exitCode,
            ]
        )

        return output
    }

    private func waitForWindow(
        rule: WindowMatchRule,
        policy _: ExecutionPolicy,
        slot: Int,
        spaceID: Int
    ) -> WaitOutcome {
        let totalTimeoutMs = 5000
        let deadline = Date().addingTimeInterval(TimeInterval(totalTimeoutMs) / 1000)

        while Date() <= deadline {
            let candidates = driver.queryWindowsOnAllSpaces().filter { $0.bundleID == rule.bundleID }
            let nonFullscreen = candidates.filter { !$0.isFullscreen }

            if let found = WindowMatchEngine.select(rule: rule, candidates: nonFullscreen) {
                return .found(found)
            }

            if WindowMatchEngine.select(rule: rule, candidates: candidates) != nil {
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
        let layout = try requiredLayout(layoutName)

        if let spaceID, !layout.spaces.contains(where: { $0.spaceID == spaceID }) {
            throw ShitsuraeError(.validationError, "space not found in layout: \(spaceID)")
        }

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

    private func failed(layoutName: String, code: ErrorCode, message: String) -> ArrangeExecutionJSON {
        logger.log(level: "error", event: "arrange.failed", fields: ["code": code.rawValue, "message": message])
        return ArrangeExecutionJSON(
            schemaVersion: 1,
            layout: layoutName,
            spacesMode: context.config.resolvedSpacesMode,
            result: "failed",
            hardErrors: [
                ErrorItem(code: code.rawValue, message: message, spaceID: nil, slot: nil),
            ],
            softErrors: [],
            skipped: [],
            warnings: [],
            exitCode: code.rawValue
        )
    }

}

private enum WaitOutcome {
    case found(WindowSnapshot)
    case fullscreenExcluded
    case notFound
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
