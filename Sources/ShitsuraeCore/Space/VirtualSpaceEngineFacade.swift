import CoreGraphics
import Foundation

extension VirtualSpaceEngine {
    /// Admission happens on the caller's executor, before the first actor
    /// await. Package-only admitted routes require the existing token and
    /// never acquire a second lease for internal calls.
    private nonisolated func admitAndRun<Value: Sendable>(
        requestID: String = UUID().uuidString.lowercased(),
        operation: ArrangeOperationKind,
        permitsRecovery: Bool = false,
        invalidatesFocus: Bool = true,
        run: @Sendable (ArrangeOperationToken) async throws -> Value,
        summarize: @Sendable (Value) -> (String, Int) = { _ in ("success", 0) }
    ) async throws -> Value {
        let token = try operationCoordinator.tryAdmit(
            requestID: requestID,
            operation: operation,
            permitsRecovery: permitsRecovery,
            requiresAuthoritativeJournalCheck: true
        )
        defer { operationCoordinator.abandon(token: token) }
        do {
            try await validateMutationAdmission(token: token, permitsRecovery: permitsRecovery, allowsTransition: false)
            if invalidatesFocus { invalidatePendingFocusEvents() }
            let value = try await run(token)
            let (result, exitCode) = summarize(value)
            if exitCode == 0, let interruption = operationCoordinator.interruptionError(token: token) { throw interruption }
            var detail: String?
            if let set = value as? LayoutSetExecutionJSON {
                detail = (set.unresolved.map(\.reason) + set.warnings.map(\.detail)).joined(separator: "; ")
            } else if let arrange = value as? ArrangeExecutionJSON {
                detail = arrange.outcomeDetail
            } else if let batch = value as? ArrangeBatchExecutionJSON {
                detail = batch.outcomeDetail
            } else if let recovery = value as? LayoutRecoveryJSON {
                detail = recovery.outcomeDetail
            }
            operationCoordinator.finish(token: token, result: result, exitCode: exitCode, detail: detail?.isEmpty == false ? detail : nil)
            return value
        } catch {
            let effectiveError = (operationCoordinator.interruptionError(token: token) as Error?) ?? error
            let mapped = (effectiveError as? ShitsuraeError)
                ?? (effectiveError as? VirtualSpaceEngineError).map(CommandRouter.mapEngineError)
            operationCoordinator.finish(
                token: token,
                result: "failed",
                exitCode: mapped?.code.rawValue ?? ErrorCode.validationError.rawValue,
                detail: mapped?.message ?? String(describing: effectiveError)
            )
            throw effectiveError
        }
    }

    package func validateMutationAdmission(
        token: ArrangeOperationToken,
        permitsRecovery: Bool = false,
        allowsTransition: Bool = true
    ) throws {
        // A facade projection can be stale. The persisted actor state is the
        // final authority and is synchronized before rejecting/continuing.
        operationCoordinator.updateJournalMirror(state: currentState, authoritative: true)
        if let interruption = operationCoordinator.interruptionError(token: token) { throw interruption }
        if let journal = currentState.pendingLayoutTransition, !permitsRecovery,
           !(allowsTransition && journal.requestID == token.requestID) {
            throw ShitsuraeError(.operationBlocked, "window recovery is required", subcode: "recoveryRequired")
        }
    }

    public nonisolated func arrange(
        layoutName: String, spaceID: Int?, config: LoadedConfig,
        applyInitialFocus: Bool = true, requestID: String = UUID().uuidString.lowercased()
    ) async throws -> ArrangeExecutionJSON {
        try await admitAndRun(requestID: requestID, operation: .arrange, run: { token in
            try await self.arrange(layoutName: layoutName, spaceID: spaceID, config: config, applyInitialFocus: applyInitialFocus, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func arrange(
        layoutNames: [String], config: LoadedConfig, requestID: String = UUID().uuidString.lowercased()
    ) async throws -> ArrangeBatchExecutionJSON {
        try await admitAndRun(requestID: requestID, operation: .arrange, run: { token in
            try await self.arrange(layoutNames: layoutNames, config: config, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func arrangeStateOnly(layoutName: String, spaceID: Int?, config: LoadedConfig) async throws -> ArrangeExecutionJSON {
        try await admitAndRun(operation: .arrange, run: { token in
            try await self.arrangeStateOnly(layoutName: layoutName, spaceID: spaceID, config: config, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func arrangeDryRun(layoutName: String, spaceID: Int?, config: LoadedConfig) async throws -> ArrangeDryRunJSON {
        try await admitAndRun(operation: .arrange, invalidatesFocus: false, run: { token in
            try await self.arrangeDryRun(layoutName: layoutName, spaceID: spaceID, config: config, token: token)
        }, summarize: { _ in ("dryRun", 0) })
    }

    public nonisolated func arrangeSet(setName: String, requestID: String, config: LoadedConfig) async throws -> LayoutSetExecutionJSON {
        try await admitAndRun(requestID: requestID, operation: .arrangeSet, run: { token in
            try await self.arrangeSet(setName: setName, requestID: requestID, config: config, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func arrangeSetDryRun(setName: String, requestID: String, config: LoadedConfig) async throws -> LayoutSetDryRunJSON {
        try await admitAndRun(requestID: requestID, operation: .arrangeSet, invalidatesFocus: false, run: { token in
            try await self.arrangeSetDryRun(setName: setName, requestID: requestID, config: config, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func recoverLayoutTransition(requestID: String) async throws -> LayoutRecoveryJSON {
        try await admitAndRun(requestID: requestID, operation: .recover, permitsRecovery: true, run: { token in
            try await self.recoverLayoutTransition(requestID: requestID, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func shutdownManagedWindows(requestID: String) async throws -> LayoutRecoveryJSON {
        try await admitAndRun(requestID: requestID, operation: .shutdown, permitsRecovery: true, run: { token in
            try await self.shutdownManagedWindows(requestID: requestID, token: token)
        }, summarize: { ($0.result, $0.exitCode) })
    }

    public nonisolated func switchSpace(
        to targetSpaceID: Int, config: LoadedConfig, reconcile: Bool = false,
        adoptionIgnoreRules: IgnoreRuleSet? = nil, focusPolicy: SpaceSwitchFocusPolicy = .target
    ) async throws -> SpaceSwitchOutcome {
        try await admitAndRun(operation: .switchSpace, run: { token in
            try await self.switchSpace(to: targetSpaceID, config: config, reconcile: reconcile, adoptionIgnoreRules: adoptionIgnoreRules, focusPolicy: focusPolicy, token: token)
        }, summarize: { ($0.converged ? "success" : "partial", $0.converged ? 0 : ErrorCode.partialSuccess.rawValue) })
    }

    public nonisolated func switchSpace(
        monitor: String, to targetSpaceID: Int, config: LoadedConfig,
        reconcile: Bool = false, focusPolicy: SpaceSwitchFocusPolicy = .target
    ) async throws -> SpaceSwitchOutcome {
        try await admitAndRun(operation: .switchSpace, run: { token in
            try await self.switchSpace(monitor: monitor, to: targetSpaceID, config: config, reconcile: reconcile, focusPolicy: focusPolicy, token: token)
        }, summarize: { ($0.converged ? "success" : "partial", $0.converged ? 0 : ErrorCode.partialSuccess.rawValue) })
    }

    public nonisolated func switchSpace(
        layoutName: String, to targetSpaceID: Int, config: LoadedConfig, reconcile: Bool = false,
        adoptionIgnoreRules: IgnoreRuleSet? = nil, shouldFocusTarget: Bool = true,
        focusPolicy: SpaceSwitchFocusPolicy = .target
    ) async throws -> SpaceSwitchOutcome {
        try await admitAndRun(operation: .switchSpace, run: { token in
            try await self.switchSpace(layoutName: layoutName, to: targetSpaceID, config: config, reconcile: reconcile, adoptionIgnoreRules: adoptionIgnoreRules, shouldFocusTarget: shouldFocusTarget, focusPolicy: focusPolicy, token: token)
        }, summarize: { ($0.converged ? "success" : "partial", $0.converged ? 0 : ErrorCode.partialSuccess.rawValue) })
    }

    public nonisolated func routeAndSwitchSpace(candidates: [ResolvedSpaceSwitchShortcut], cursorLocation: CGPoint, config: LoadedConfig) async throws -> RoutedSpaceSwitchOutcome {
        try await admitAndRun(operation: .switchSpace, run: { token in
            try await self.routeAndSwitchSpace(candidates: candidates, cursorLocation: cursorLocation, config: config, token: token)
        }, summarize: { ($0.outcome.converged ? "success" : "partial", $0.outcome.converged ? 0 : ErrorCode.partialSuccess.rawValue) })
    }

    public nonisolated func focusSlot(_ slot: Int, config: LoadedConfig) async throws -> FocusJSON {
        try await admitAndRun(operation: .focus, run: { try await self.focusSlot(slot, config: config, token: $0) })
    }

    public nonisolated func focusWindow(selector: WindowTargetSelector, config: LoadedConfig) async throws -> FocusJSON {
        try await admitAndRun(operation: .focus, run: { try await self.focusWindow(selector: selector, config: config, token: $0) })
    }

    public nonisolated func focusWindow(identity: WindowIdentity, config: LoadedConfig) async throws -> FocusJSON {
        try await admitAndRun(operation: .focus, run: { try await self.focusWindow(identity: identity, config: config, token: $0) })
    }

    public nonisolated func focusPreferredWindowInActiveWorkspace(excludingPID: Int, bundleID: String, config: LoadedConfig) async throws -> WindowIdentity? {
        try await admitAndRun(operation: .focus, run: { try await self.focusPreferredWindowInActiveWorkspace(excludingPID: excludingPID, bundleID: bundleID, config: config, token: $0) })
    }

    public nonisolated func setWindowFrame(selector: WindowTargetSelector, x: LengthValue?, y: LengthValue?, width: LengthValue?, height: LengthValue?, config: LoadedConfig) async throws -> WindowSetJSON {
        try await admitAndRun(operation: .window, run: { try await self.setWindowFrame(selector: selector, x: x, y: y, width: width, height: height, config: config, token: $0) })
    }

    public nonisolated func snapWindow(selector: WindowTargetSelector, preset: SnapPreset, config: LoadedConfig) async throws -> WindowSetJSON {
        try await admitAndRun(operation: .window, run: { try await self.snapWindow(selector: selector, preset: preset, config: config, token: $0) })
    }

    public nonisolated func windowWorkspace(selector: WindowTargetSelector, toSpaceID: Int, config: LoadedConfig) async throws -> WindowWorkspaceJSON {
        try await admitAndRun(operation: .window, run: { try await self.windowWorkspace(selector: selector, toSpaceID: toSpaceID, config: config, token: $0) })
    }

    public nonisolated func moveWindowToWorkspace(window: WindowSnapshot, toSpaceID: Int, config: LoadedConfig) async throws -> WorkspaceMoveOutcome {
        try await admitAndRun(operation: .window, run: { try await self.moveWindowToWorkspace(window: window, toSpaceID: toSpaceID, config: config, token: $0) })
    }

    public nonisolated func bootstrapState(layoutName: String, activeSpaceID: Int, config: LoadedConfig) async throws {
        try await admitAndRun(operation: .arrange, run: { try await self.bootstrapState(layoutName: layoutName, activeSpaceID: activeSpaceID, config: config, token: $0) })
    }

    public nonisolated func clearPending() async throws {
        try await admitAndRun(operation: .recover, run: { try await self.clearPending(token: $0) })
    }

    public nonisolated func clearRuntimeState() async throws {
        try await admitAndRun(operation: .shutdown, run: { try await self.clearRuntimeState(token: $0) })
    }

    public nonisolated func handleDisplayConfigurationChange(config: LoadedConfig) async throws {
        try await admitAndRun(operation: .displayChange, invalidatesFocus: false, run: { try await self.handleDisplayConfigurationChange(config: config, token: $0) })
    }

    public nonisolated func restoreAllForShutdown(config: LoadedConfig) async -> Bool {
        (try? await admitAndRun(operation: .shutdown, permitsRecovery: true, run: { try await self.restoreAllForShutdown(config: config, token: $0) }, summarize: { ($0 ? "success" : "partial", $0 ? 0 : 51) })) ?? false
    }

    public nonisolated func markActivated(window: WindowSnapshot) async {
        _ = try? await admitAndRun(operation: .focus, invalidatesFocus: false, run: { try await self.markActivated(window: window, token: $0) })
    }

    public nonisolated func adoptUntrackedWindows(config: LoadedConfig, persistChanges: Bool = true, inventory: WindowInventory? = nil, excludedWindowIdentities: Set<WindowIdentity> = [], additionalIgnoreRules: IgnoreRuleSet? = nil) async throws -> Int {
        try await admitAndRun(operation: .window, invalidatesFocus: false, run: { try await self.adoptUntrackedWindows(config: config, persistChanges: persistChanges, inventory: inventory, excludedWindowIdentities: excludedWindowIdentities, additionalIgnoreRules: additionalIgnoreRules, token: $0) })
    }

    public nonisolated func adoptWindowIntoActiveWorkspace(_ window: WindowSnapshot, config: LoadedConfig) async throws -> Bool {
        try await admitAndRun(operation: .window, invalidatesFocus: false, run: { try await self.adoptWindowIntoActiveWorkspace(window, config: config, token: $0) })
    }

    package nonisolated func trackWindow(windowID: UInt32, pid: Int, processStartTime: UInt64,
        expectedBundleID: String, config: LoadedConfig, respectFocusIgnoreRules: Bool, updateMRU: Bool,
        inventory: WindowInventory? = nil, allowBlockedBindingRefresh: Bool = false, adoptionSpaceID: Int? = nil,
        persistChanges: Bool = true, allowReleasedClaim: Bool = false
    ) async throws -> WindowTrackingResult {
        try await admitAndRun(operation: .window, invalidatesFocus: false, run: { token in
            try await self.trackWindow(windowID: windowID, pid: pid, processStartTime: processStartTime,
                expectedBundleID: expectedBundleID, config: config, respectFocusIgnoreRules: respectFocusIgnoreRules,
                updateMRU: updateMRU, inventory: inventory, allowBlockedBindingRefresh: allowBlockedBindingRefresh,
                adoptionSpaceID: adoptionSpaceID, persistChanges: persistChanges, allowReleasedClaim: allowReleasedClaim, token: token)
        })
    }

    public nonisolated func switcherCandidates(includeAllSpaces: Bool, config: LoadedConfig, excludedApps: Set<String> = []) async throws -> [SwitcherCandidate] {
        try await admitAndRun(operation: .focus, invalidatesFocus: false, run: { try await self.switcherCandidates(includeAllSpaces: includeAllSpaces, config: config, excludedApps: excludedApps, token: $0) })
    }

    public nonisolated func switcherCandidates(displayID: String, includeAllSpaces: Bool, config: LoadedConfig, excludedApps: Set<String> = []) async throws -> [SwitcherCandidate] {
        try await admitAndRun(operation: .focus, invalidatesFocus: false, run: { try await self.switcherCandidates(displayID: displayID, includeAllSpaces: includeAllSpaces, config: config, excludedApps: excludedApps, token: $0) })
    }

    public nonisolated func cycleCandidates(config: LoadedConfig, excludedApps: Set<String> = []) async throws -> [SwitcherCandidate] {
        try await admitAndRun(operation: .focus, invalidatesFocus: false, run: { try await self.cycleCandidates(config: config, excludedApps: excludedApps, token: $0) })
    }

    public nonisolated func cycleCandidates(displayID: String, config: LoadedConfig, excludedApps: Set<String> = []) async throws -> [SwitcherCandidate] {
        try await admitAndRun(operation: .focus, invalidatesFocus: false, run: { try await self.cycleCandidates(displayID: displayID, config: config, excludedApps: excludedApps, token: $0) })
    }

    public nonisolated func processFocusEvent(sequence: UInt64, windowID: UInt32, pid: Int, processStartTime: UInt64, bundleID: String, config: LoadedConfig) async -> FocusEventOutcome? {
        // Record freshness before admission even when mutation is suppressed.
        guard focusEventGate.accept(sequence) else { return nil }
        return try? await admitAndRun(operation: .focus, invalidatesFocus: false, run: { token in
            await self.processFocusEvent(sequence: sequence, windowID: windowID, pid: pid, processStartTime: processStartTime, bundleID: bundleID, config: config, token: token)
        })
    }

    public nonisolated func switchSpaceForFocusEvent(sequence: UInt64, identity: WindowIdentity, layoutName: String, to targetSpaceID: Int, config: LoadedConfig) async throws -> SpaceSwitchOutcome? {
        try await admitAndRun(operation: .switchSpace, invalidatesFocus: false, run: { token in
            try await self.switchSpaceForFocusEvent(sequence: sequence, identity: identity, layoutName: layoutName, to: targetSpaceID, config: config, token: token)
        })
    }
}
