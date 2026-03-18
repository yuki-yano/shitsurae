import Foundation

public struct RuntimeStateReadContext: Equatable {
    public let state: RuntimeState
    public let deferredCrashLeftoverPromotion: Bool

    public init(state: RuntimeState, deferredCrashLeftoverPromotion: Bool = false) {
        self.state = state
        self.deferredCrashLeftoverPromotion = deferredCrashLeftoverPromotion
    }
}

public enum CurrentSpaceResolution: Equatable {
    case resolved(spaceID: Int, kind: SpaceInterpretationMode, layoutName: String?)
    case unavailable(reason: CurrentSpaceUnavailableReason)
}

public enum CurrentSpaceUnavailableReason: Equatable {
    case uninitialized
    case staleGeneration
    case stateCorrupted
    case readPermissionDenied
}

public enum InteractiveShortcutScope: Equatable {
    case native(spaceID: Int)
    case virtual(layoutName: String, spaceID: Int)
}

public struct InteractiveShortcutContext: Equatable {
    public let currentSpaceID: Int
    public let scope: InteractiveShortcutScope
    public let slotEntries: [SlotEntry]

    public init(
        currentSpaceID: Int,
        scope: InteractiveShortcutScope,
        slotEntries: [SlotEntry]
    ) {
        self.currentSpaceID = currentSpaceID
        self.scope = scope
        self.slotEntries = slotEntries
    }
}

public enum InteractiveShortcutContextResolution: Equatable {
    case resolved(InteractiveShortcutContext)
    case unavailable(reason: CurrentSpaceUnavailableReason)
}

public enum RuntimeStateReadResolver {
    public static func reconciledRuntimeStateForRead(
        state: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> RuntimeStateReadContext {
        let normalizedContext = normalizedRuntimeStateForRead(state: state, loadedConfig: loadedConfig)
        guard normalizedContext.state != state else {
            return normalizedContext
        }

        if let deferredContext = deferredCrashLeftoverReadState(
            normalizedState: normalizedContext.state,
            persistedState: state,
            loadedConfig: loadedConfig
        ) {
            return deferredContext
        }

        return normalizedContext
    }

    public static func normalizedRuntimeStateForRead(
        state: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> RuntimeStateReadContext {
        guard state.pendingSwitchTransaction == nil else {
            if let promotedState = promotedCrashLeftoverState(state: state, loadedConfig: loadedConfig) {
                return RuntimeStateReadContext(state: promotedState)
            }
            return RuntimeStateReadContext(state: state)
        }

        return RuntimeStateReadContext(state: state)
    }

    public static func resolveCurrentSpace(
        loadedConfig: LoadedConfig?,
        runtimeState: RuntimeState,
        focusedWindow: WindowSnapshot?,
        spaces: [SpaceInfo]
    ) -> CurrentSpaceResolution {
        let mode = effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: runtimeState)

        switch mode {
        case .native:
            if let spaceID = WindowQueryService.currentSpaceID(focusedWindow: focusedWindow, spaces: spaces) {
                return .resolved(spaceID: spaceID, kind: .native, layoutName: nil)
            }
            return .unavailable(reason: .uninitialized)
        case .virtual:
            if isStaleVirtualReadState(loadedConfig: loadedConfig, state: runtimeState) {
                return .unavailable(reason: .staleGeneration)
            }

            guard let activeVirtualSpaceID = runtimeState.activeVirtualSpaceID else {
                return .unavailable(reason: .uninitialized)
            }

            if runtimeState.activeLayoutName != nil,
               activeVirtualLayout(loadedConfig: loadedConfig, state: runtimeState) == nil
            {
                return .unavailable(reason: .uninitialized)
            }

            return .resolved(
                spaceID: activeVirtualSpaceID,
                kind: .virtual,
                layoutName: runtimeState.activeLayoutName
            )
        }
    }

    public static func resolveInteractiveShortcutContextDetailed(
        loadedConfig: LoadedConfig?,
        state: RuntimeState,
        nativeCurrentSpaceID: Int?
    ) -> InteractiveShortcutContextResolution {
        let mode = effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: state)
        let slotEntries = slotEntriesForEffectiveMode(loadedConfig: loadedConfig, state: state)

        switch mode {
        case .native:
            guard let nativeCurrentSpaceID else {
                return .unavailable(reason: .uninitialized)
            }

            return .resolved(
                InteractiveShortcutContext(
                    currentSpaceID: nativeCurrentSpaceID,
                    scope: .native(spaceID: nativeCurrentSpaceID),
                    slotEntries: slotEntries
                )
            )
        case .virtual:
            if isStaleVirtualReadState(loadedConfig: loadedConfig, state: state) {
                return .unavailable(reason: .staleGeneration)
            }

            guard let layoutName = state.activeLayoutName,
                  let activeVirtualSpaceID = state.activeVirtualSpaceID,
                  activeVirtualLayout(loadedConfig: loadedConfig, state: state) != nil
            else {
                return .unavailable(reason: .uninitialized)
            }

            return .resolved(
                InteractiveShortcutContext(
                    currentSpaceID: activeVirtualSpaceID,
                    scope: .virtual(layoutName: layoutName, spaceID: activeVirtualSpaceID),
                    slotEntries: slotEntries
                )
            )
        }
    }

    public static func effectiveSpaceInterpretationMode(
        loadedConfig: LoadedConfig?,
        state: RuntimeState
    ) -> SpaceInterpretationMode {
        loadedConfig?.config.resolvedSpaceInterpretationMode ?? state.stateMode
    }

    public static func slotEntriesForEffectiveMode(
        loadedConfig: LoadedConfig?,
        state: RuntimeState
    ) -> [SlotEntry] {
        let effectiveMode = effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: state)
        guard state.stateMode == effectiveMode else {
            return []
        }
        return state.slots
    }

    public static func activeVirtualLayout(
        loadedConfig: LoadedConfig?,
        state: RuntimeState
    ) -> LayoutDefinition? {
        guard let layoutName = state.activeLayoutName,
              let activeSpaceID = state.activeVirtualSpaceID,
              let layout = loadedConfig?.config.layouts[layoutName],
              layout.spaces.contains(where: { $0.spaceID == activeSpaceID })
        else {
            return nil
        }

        return layout
    }

    public static func isStaleVirtualReadState(
        loadedConfig: LoadedConfig?,
        state: RuntimeState
    ) -> Bool {
        guard effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: state) == .virtual,
              let loadedConfig
        else {
            return false
        }

        guard isGeneratedConfigGeneration(state.configGeneration),
              isGeneratedConfigGeneration(loadedConfig.configGeneration)
        else {
            return false
        }

        return state.configGeneration != loadedConfig.configGeneration
    }

    public static func isGeneratedConfigGeneration(_ value: String) -> Bool {
        guard value.count == 64 else {
            return false
        }

        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "0123456789abcdef").contains(scalar)
        }
    }

    private static func promotedCrashLeftoverState(
        state: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> RuntimeState? {
        guard effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: state) == .virtual,
              let pending = state.pendingSwitchTransaction,
              pending.status == .inFlight,
              state.activeLayoutName != nil,
              state.activeVirtualSpaceID != nil,
              activeVirtualLayout(loadedConfig: loadedConfig, state: state) == nil
        else {
            return nil
        }

        return state.clearingActiveVirtualContext(
            stateMode: .virtual,
            pendingSwitchTransaction: PendingSwitchTransaction(
                requestID: pending.requestID,
                startedAt: pending.startedAt,
                activeLayoutName: pending.activeLayoutName,
                attemptedTargetSpaceID: pending.attemptedTargetSpaceID,
                previousActiveSpaceID: pending.previousActiveSpaceID,
                configGeneration: pending.configGeneration,
                status: .recoveryRequired,
                manualRecoveryRequired: pending.manualRecoveryRequired,
                unresolvedSlots: pending.unresolvedSlots
            )
        )
    }

    private static func deferredCrashLeftoverReadState(
        normalizedState: RuntimeState,
        persistedState: RuntimeState,
        loadedConfig: LoadedConfig?
    ) -> RuntimeStateReadContext? {
        guard persistedState.pendingSwitchTransaction?.status != .recoveryRequired,
              let pending = normalizedState.pendingSwitchTransaction,
              pending.status == .recoveryRequired,
              normalizedState.activeLayoutName == nil,
              normalizedState.activeVirtualSpaceID == nil,
              effectiveSpaceInterpretationMode(loadedConfig: loadedConfig, state: persistedState) == .virtual
        else {
            return nil
        }

        return RuntimeStateReadContext(state: normalizedState, deferredCrashLeftoverPromotion: true)
    }
}
