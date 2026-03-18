import Foundation

public enum GUIVirtualSpaceBlockReason: String, Codable, Equatable {
    case unavailable
    case busy
    case recoveryRequiresLiveArrange
    case runtimeStateCorrupted
    case runtimeStateReadPermissionDenied
}

public struct GUIVirtualSpaceStatus: Equatable {
    public let mode: SpaceInterpretationMode
    public let activeLayoutName: String?
    public let activeVirtualSpaceID: Int?
    public let activeLayoutSpaceIDs: [Int]
    public let blockReason: GUIVirtualSpaceBlockReason?
    public let preferredRecoverySpaceID: Int?
    public let canForceClearPendingState: Bool

    public init(
        mode: SpaceInterpretationMode,
        activeLayoutName: String?,
        activeVirtualSpaceID: Int?,
        activeLayoutSpaceIDs: [Int],
        blockReason: GUIVirtualSpaceBlockReason?,
        preferredRecoverySpaceID: Int?,
        canForceClearPendingState: Bool
    ) {
        self.mode = mode
        self.activeLayoutName = activeLayoutName
        self.activeVirtualSpaceID = activeVirtualSpaceID
        self.activeLayoutSpaceIDs = activeLayoutSpaceIDs
        self.blockReason = blockReason
        self.preferredRecoverySpaceID = preferredRecoverySpaceID
        self.canForceClearPendingState = canForceClearPendingState
    }

    public var isVirtualMode: Bool {
        mode == .virtual
    }

    public var canSwitchFromMenuBar: Bool {
        isVirtualMode
            && blockReason == nil
            && activeVirtualSpaceID != nil
            && !activeLayoutSpaceIDs.isEmpty
    }

    public var canInitializeActiveSpace: Bool {
        isVirtualMode && (blockReason == nil || blockReason == .unavailable)
    }

    public var canRecoverWithLiveArrange: Bool {
        isVirtualMode
            && activeLayoutName != nil
            && preferredRecoverySpaceID != nil
            && blockReason == .recoveryRequiresLiveArrange
    }
}

public enum GUIVirtualSpaceStatusResolver {
    public static func resolve(
        config: ShitsuraeConfig?,
        diagnostics: DiagnosticsJSON?,
        spaceCurrentResult: CommandResult
    ) -> GUIVirtualSpaceStatus {
        let mode = diagnostics?.effectiveSpaceMode ?? config?.resolvedSpaceInterpretationMode ?? .native
        let activeLayoutName = diagnostics?.activeLayoutName
        let activeVirtualSpaceID = diagnostics?.activeVirtualSpaceID
        let activeLayoutSpaceIDs = activeLayoutName
            .flatMap { config?.layouts[$0] }
            .map { layout in
                Array(Set(layout.spaces.map(\.spaceID))).sorted()
            } ?? []

        guard mode == .virtual else {
            return GUIVirtualSpaceStatus(
                mode: mode,
                activeLayoutName: activeLayoutName,
                activeVirtualSpaceID: activeVirtualSpaceID,
                activeLayoutSpaceIDs: activeLayoutSpaceIDs,
                blockReason: nil,
                preferredRecoverySpaceID: nil,
                canForceClearPendingState: false
            )
        }

        let decoder = JSONDecoder()
        let data = Data(spaceCurrentResult.stdout.utf8)
        if let payload = try? decoder.decode(SpaceCurrentJSON.self, from: data),
           payload.space.kind == .virtual
        {
            return GUIVirtualSpaceStatus(
                mode: mode,
                activeLayoutName: activeLayoutName,
                activeVirtualSpaceID: activeVirtualSpaceID ?? payload.space.spaceID,
                activeLayoutSpaceIDs: activeLayoutSpaceIDs,
                blockReason: nil,
                preferredRecoverySpaceID: nil,
                canForceClearPendingState: false
            )
        }

        let errorPayload = try? decoder.decode(CommonErrorJSON.self, from: data)
        let recoveryContext = errorPayload?.recoveryContext
        let blockReason = mapBlockReason(errorPayload?.subcode)
        let preferredRecoverySpaceID = recoveryContext?.previousActiveSpaceID ?? recoveryContext?.attemptedTargetSpaceID

        return GUIVirtualSpaceStatus(
            mode: mode,
            activeLayoutName: activeLayoutName ?? recoveryContext?.activeLayoutName,
            activeVirtualSpaceID: activeVirtualSpaceID ?? recoveryContext?.activeVirtualSpaceID,
            activeLayoutSpaceIDs: activeLayoutSpaceIDs,
            blockReason: blockReason,
            preferredRecoverySpaceID: preferredRecoverySpaceID,
            canForceClearPendingState: recoveryContext?.recoveryForceClearEligible == true
        )
    }

    private static func mapBlockReason(_ subcode: String?) -> GUIVirtualSpaceBlockReason? {
        switch subcode {
        case "virtualStateBusy":
            return .busy
        case "virtualStateRecoveryRequiresLiveArrange":
            return .recoveryRequiresLiveArrange
        case "runtimeStateCorrupted":
            return .runtimeStateCorrupted
        case "runtimeStateReadPermissionDenied":
            return .runtimeStateReadPermissionDenied
        case "virtualStateUnavailable":
            return .unavailable
        default:
            return nil
        }
    }
}
