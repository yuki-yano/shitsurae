import Foundation

public extension VirtualSpaceEngine {
    // MARK: - Dry run

    func arrangeDryRun(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> ArrangeDryRunJSON {
        let (layout, hostDisplay, displays) = try arrangeContext(
            layoutName: layoutName,
            spaceID: spaceID,
            config: config
        )

        let plan = ArrangePlanner.buildPlan(
            layoutName: layoutName,
            layout: layout,
            spaceID: spaceID,
            config: config.config,
            hostDisplay: hostDisplay,
            displays: displays,
            currentWindows: control.listAllWindows()
        )

        return ArrangeDryRunJSON(
            layout: layoutName,
            availableSpaceIDs: layout.spaces.map(\.spaceID).sorted(),
            plan: plan.planItems,
            skipped: plan.skipped,
            warnings: plan.warnings
        )
    }

    // MARK: - State only

    func arrangeStateOnly(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> ArrangeExecutionJSON {
        let (layout, _, _) = try arrangeContext(layoutName: layoutName, spaceID: spaceID, config: config)
        let activeSpaceID = spaceID
            ?? currentState.primaryActiveSpaceID
            ?? layout.spaces.map(\.spaceID).min()
            ?? 1

        try bootstrapState(layoutName: layoutName, activeSpaceID: activeSpaceID, config: config)

        return ArrangeExecutionJSON(
            layout: layoutName,
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

    // MARK: - Live arrange

    /// Full arrange: restore hidden windows → launch/wait/place every window
    /// of the selected scope → rebuild state → re-hide non-active workspaces.
    /// The pre/post processing v1 spread across CommandService lives here.
    func arrange(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> ArrangeExecutionJSON {
        logger.log(event: "arrange.start", fields: ["layout": layoutName])

        guard control.accessibilityGranted() else {
            return ArrangeExecutionJSON(
                layout: layoutName,
                result: "failed",
                subcode: "missingPermission",
                unresolvedSlots: [],
                hardErrors: [
                    ErrorItem(
                        code: ErrorCode.missingPermission.rawValue,
                        message: "Accessibility permission is required",
                        spaceID: nil,
                        slot: nil
                    ),
                ],
                softErrors: [],
                skipped: [],
                warnings: [],
                exitCode: ErrorCode.missingPermission.rawValue
            )
        }

        let (layout, hostDisplay, displays) = try arrangeContext(
            layoutName: layoutName,
            spaceID: spaceID,
            config: config
        )

        // Invariant: every managed window is visible before arranging, so
        // frame placement never fights the offscreen parking.
        restoreHiddenWindowsBeforeArrange(layoutName: layoutName, layout: layout, config: config)

        let plan = ArrangePlanner.buildPlan(
            layoutName: layoutName,
            layout: layout,
            spaceID: spaceID,
            config: config.config,
            hostDisplay: hostDisplay,
            displays: displays,
            currentWindows: nil
        )

        var softErrors: [ErrorItem] = []
        var boundWindows: [String: WindowSnapshot] = [:] // fingerprint → window
        var frames: [String: ResolvedFrame] = [:]

        for step in plan.steps {
            let definition = step.definition
            let launch = definition.launch ?? true
            let fingerprint = SlotEntry.fingerprint(
                layoutName: layoutName,
                spaceID: step.spaceID,
                definition: definition
            )

            let preLaunchWindowIDs = launch && definition.match.profile != nil
                ? Set(control.listAllWindows().filter { $0.bundleID == definition.match.bundleID }.map(\.windowID))
                : nil

            if launch,
               !control.launchApplication(
                   request: ApplicationLaunchRequest(
                       bundleID: definition.match.bundleID,
                       profileDirectory: definition.match.profile
                   )
               )
            {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.appLaunchFailed.rawValue,
                        message: "failed to launch app: \(definition.match.bundleID)",
                        spaceID: step.spaceID,
                        slot: definition.slot
                    )
                )
                continue
            }

            guard let window = waitForWindow(
                rule: definition.match,
                layoutName: layoutName,
                spaceID: step.spaceID,
                slot: definition.slot,
                preLaunchWindowIDs: preLaunchWindowIDs,
                alreadyBound: Set(boundWindows.values.map(\.windowID))
            ) else {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.targetWindowNotFound.rawValue,
                        message: "target window not found: \(definition.match.bundleID)",
                        spaceID: step.spaceID,
                        slot: definition.slot
                    )
                )
                continue
            }

            if !setFrameWithRetry(window: window, frame: step.resolvedFrame) {
                softErrors.append(
                    ErrorItem(
                        code: ErrorCode.operationTimedOut.rawValue,
                        message: "failed to apply frame",
                        spaceID: step.spaceID,
                        slot: definition.slot
                    )
                )
                // Still bind the window: placement failed but tracking works.
            }

            boundWindows[fingerprint] = window
            frames[fingerprint] = step.resolvedFrame
        }

        if let initialFocusSlot = layout.initialFocus?.slot,
           let focusStep = plan.steps.first(where: { $0.definition.slot == initialFocusSlot })
        {
            let fingerprint = SlotEntry.fingerprint(
                layoutName: layoutName,
                spaceID: focusStep.spaceID,
                definition: focusStep.definition
            )
            if let window = boundWindows[fingerprint] {
                if !control.focusWindow(windowID: window.windowID, bundleID: window.bundleID).isSuccess {
                    _ = control.activateBundle(bundleID: window.bundleID)
                }
            }
        }

        // Rebuild state for the arranged scope, binding resolved windows.
        try rebuildStateAfterArrange(
            layoutName: layoutName,
            layout: layout,
            arrangedSpaceID: spaceID,
            boundWindows: boundWindows,
            frames: frames,
            config: config,
            hostDisplay: hostDisplay
        )

        // Adopt windows no layout slot claimed into the active workspace so
        // they are tracked (and hidden/shown) from the start.
        _ = try? adoptUntrackedWindows(config: config)

        // Re-hide everything outside the active workspace.
        let activeSpaceID = currentState.activeSpaceID(displayID: hostDisplay.id)
            ?? currentState.primaryActiveSpaceID
            ?? spaceID
            ?? layout.spaces.map(\.spaceID).min()
            ?? 1
        let switchOutcome = try switchSpace(to: activeSpaceID, config: config, reconcile: true)

        let unresolvedSlots = switchOutcome.unresolvedSlots
        let result = softErrors.isEmpty ? "success" : "partial"
        let exitCode = softErrors.isEmpty ? ErrorCode.success.rawValue : ErrorCode.partialSuccess.rawValue

        logger.log(
            event: "arrange.finished",
            fields: [
                "layout": layoutName,
                "result": result,
                "exitCode": exitCode,
            ]
        )

        return ArrangeExecutionJSON(
            layout: layoutName,
            result: result,
            subcode: unresolvedSlots.isEmpty ? nil : "unresolvedSlots",
            unresolvedSlots: unresolvedSlots,
            hardErrors: [],
            softErrors: softErrors,
            skipped: plan.skipped,
            warnings: plan.warnings,
            exitCode: exitCode
        )
    }

    // MARK: - Helpers

    private func arrangeContext(
        layoutName: String,
        spaceID: Int?,
        config: LoadedConfig
    ) throws -> (LayoutDefinition, DisplayInfo, [DisplayInfo]) {
        guard let layout = config.config.layouts[layoutName] else {
            throw VirtualSpaceEngineError.layoutNotFound(layoutName)
        }
        if let spaceID, !layout.spaces.contains(where: { $0.spaceID == spaceID }) {
            throw VirtualSpaceEngineError.spaceNotFound(layoutName: layoutName, spaceID: spaceID)
        }

        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            throw VirtualSpaceEngineError.hostDisplayUnavailable
        }

        return (layout, hostDisplay, displays)
    }

    private func restoreHiddenWindowsBeforeArrange(
        layoutName: String,
        layout: LayoutDefinition,
        config: LoadedConfig
    ) {
        let displays = control.displays()
        guard let hostDisplay = DisplayResolver.hostDisplay(
            layout: layout,
            config: config.config,
            displays: displays
        ) else {
            return
        }

        let hiddenEntries = currentState.slots(layoutName: layoutName)
            .filter { $0.visibilityState == .hiddenOffscreen }
        guard !hiddenEntries.isEmpty else {
            return
        }

        let windows = control.listAllWindows()
        let resolution = WindowRegistry.resolve(
            entries: hiddenEntries.map(\.registryEntry),
            windows: windows
        )

        let plans = hiddenEntries.compactMap { entry -> VisibilityPlan? in
            guard let window = resolution.assignments[entry.id] else { return nil }
            return VisibilityPlanner.plan(
                entry: entry,
                window: window,
                transition: .show,
                layout: layout,
                hostDisplay: hostDisplay,
                displays: displays
            )
        }

        let applied = VisibilityApplier.apply(plans: plans, control: control, logger: logger)
        _ = VisibilityApplier.converge(
            changes: applied,
            control: control,
            logger: logger,
            retryDelaysMS: retryDelaysMS
        )
    }

    private func rebuildStateAfterArrange(
        layoutName: String,
        layout: LayoutDefinition,
        arrangedSpaceID: Int?,
        boundWindows: [String: WindowSnapshot],
        frames: [String: ResolvedFrame],
        config: LoadedConfig,
        hostDisplay: DisplayInfo
    ) throws {
        let existing = currentState.slots(layoutName: layoutName)
        let existingByFingerprint = Dictionary(
            existing.map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var entries: [SlotEntry] = []
        for space in layout.spaces {
            for definition in space.windows {
                if PolicyEngine.matchesIgnoreRule(windowDefinition: definition, rules: config.config.ignore?.apply) {
                    continue
                }
                var entry = SlotEntry.makeEntry(
                    layoutName: layoutName,
                    spaceID: space.spaceID,
                    definition: definition
                )

                if let previous = existingByFingerprint[entry.definitionFingerprint] {
                    entry.id = previous.id
                    entry.spaceID = previous.spaceID
                    entry.pid = previous.pid
                    entry.windowID = previous.windowID
                    entry.lastKnownTitle = previous.lastKnownTitle
                    entry.displayID = previous.displayID
                    entry.lastVisibleFrame = previous.lastVisibleFrame
                    entry.lastHiddenFrame = previous.lastHiddenFrame
                    entry.visibilityState = previous.visibilityState
                    entry.lastActivatedAt = previous.lastActivatedAt
                }

                if let window = boundWindows[entry.definitionFingerprint] {
                    entry = entry.bound(to: window)
                    // arrange moves the window back to its layout space.
                    entry.spaceID = space.spaceID
                    entry.visibilityState = .visible
                    entry.lastVisibleFrame = frames[entry.definitionFingerprint] ?? entry.lastVisibleFrame
                    entry.lastHiddenFrame = nil
                }

                entries.append(entry)
            }
        }

        let adopted = existing.filter { $0.origin == .adopted }

        var newState = currentState
        newState.slots = newState.slots.filter { $0.layoutName != layoutName } + entries + adopted
        newState.activeLayoutName = layoutName
        newState.configGeneration = config.configGeneration
        if newState.activeSpaceID(displayID: hostDisplay.id) == nil {
            newState.setActiveSpace(
                displayID: hostDisplay.id,
                spaceID: arrangedSpaceID ?? layout.spaces.map(\.spaceID).min() ?? 1
            )
        } else if let arrangedSpaceID {
            newState.setActiveSpace(displayID: hostDisplay.id, spaceID: arrangedSpaceID)
        }
        newState.liveArrangeRecoveryRequired = false

        try replaceState(newState)
    }

    private func waitForWindow(
        rule: WindowMatchRule,
        layoutName: String,
        spaceID: Int,
        slot: Int,
        preLaunchWindowIDs: Set<UInt32>?,
        alreadyBound: Set<UInt32>
    ) -> WindowSnapshot? {
        let deadline = Date().addingTimeInterval(TimeInterval(arrangeWaitTimeoutMS) / 1000)

        let preferredWindowID = currentState.slots(layoutName: layoutName)
            .first(where: { $0.spaceID == spaceID && $0.slot == slot && $0.bundleID == rule.bundleID })?
            .windowID

        while Date() <= deadline {
            // index rules must see the FULL pool: shrinking it per bound
            // window shifts the index positions and breaks index:2 after
            // index:1 has bound (same bug class as v1's switch path).
            // alreadyBound is enforced after selection instead.
            let nonFullscreen = control.listAllWindows().filter { !$0.isFullscreen }

            if let preferredWindowID,
               !alreadyBound.contains(preferredWindowID),
               let preferred = nonFullscreen.first(where: { $0.windowID == preferredWindowID })
            {
                return preferred
            }

            if let found = selectWindow(
                rule: rule,
                candidates: nonFullscreen,
                preLaunchWindowIDs: preLaunchWindowIDs,
                alreadyBound: alreadyBound
            ) {
                return found
            }

            let remainingMS = Int(deadline.timeIntervalSinceNow * 1000)
            if remainingMS <= 0 {
                break
            }
            control.sleep(milliseconds: min(100, remainingMS))
        }

        logger.error(event: "arrange.waitWindow.timeout", fields: ["spaceID": spaceID, "slot": slot])
        return nil
    }

    private func selectWindow(
        rule: WindowMatchRule,
        candidates: [WindowSnapshot],
        preLaunchWindowIDs: Set<UInt32>?,
        alreadyBound: Set<UInt32>
    ) -> WindowSnapshot? {
        if let found = pick(rule: rule, pool: candidates, alreadyBound: alreadyBound) {
            return found
        }

        // Profile launch fallback: lsof may lag right after a profile-window
        // launch; a window that appeared after the launch is the one we made.
        guard rule.profile != nil, let preLaunchWindowIDs else {
            return nil
        }

        let newWindows = candidates.filter { !preLaunchWindowIDs.contains($0.windowID) }
        guard !newWindows.isEmpty else {
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
        return pick(rule: fallbackRule, pool: newWindows, alreadyBound: alreadyBound)
    }

    /// index selection runs against the full sorted pool (stable positions);
    /// the chosen window is rejected only afterwards when another step
    /// already bound it. Non-index rules pick the best unbound candidate.
    private func pick(
        rule: WindowMatchRule,
        pool: [WindowSnapshot],
        alreadyBound: Set<UInt32>
    ) -> WindowSnapshot? {
        let matched = WindowRegistry.sortedCandidates(rule: rule, pool: pool)
        if let index = rule.index {
            let zeroBased = index - 1
            guard zeroBased >= 0, zeroBased < matched.count else { return nil }
            let chosen = matched[zeroBased]
            return alreadyBound.contains(chosen.windowID) ? nil : chosen
        }
        return matched.first(where: { !alreadyBound.contains($0.windowID) })
    }

    private func setFrameWithRetry(window: WindowSnapshot, frame: ResolvedFrame) -> Bool {
        let attempts = 2
        for current in 0 ..< attempts {
            if control.setWindowFrame(windowID: window.windowID, bundleID: window.bundleID, frame: frame) {
                return true
            }
            if current < attempts - 1 {
                control.sleep(milliseconds: 100)
            }
        }
        return false
    }
}
