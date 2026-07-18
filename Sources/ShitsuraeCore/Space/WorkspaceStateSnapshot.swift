import Foundation

public enum WorkspaceInventoryAvailability: Equatable, Sendable {
    case available
    case unavailable
}

public enum WorkspaceWindowBindingState: Equatable, Sendable {
    case bound
    case reservedExactIdentity
    case exactOnlyMissing
    case indexOutOfBounds
    case candidateConflict
    case noCandidate
    case inventoryUnavailable
}

public enum WorkspaceWindowActualVisibility: Equatable, Sendable {
    case visible
    case hiddenOffscreen
    case minimized
    case applicationHidden
}

public enum WorkspaceUnmanagedWindowReason: Equatable, Sendable {
    case unassigned
    case deferredForTrackedBinding
}

public struct WorkspaceLiveWindowState: Equatable, Sendable, Identifiable {
    public let identity: WindowIdentity
    public let title: String
    public let actualVisibility: WorkspaceWindowActualVisibility
    public let isFullscreen: Bool
    public let isFocused: Bool
    public let isGeometryBlocked: Bool
    public let frame: ResolvedFrame
    public let displayID: String?

    public var id: WindowIdentity { identity }

    public init(
        window: WindowSnapshot,
        displays: [DisplayInfo],
        focusedIdentity: WindowIdentity?,
        blockedIdentities: Set<WindowIdentity>
    ) {
        identity = window.identity
        title = window.title
        if window.minimized {
            actualVisibility = .minimized
        } else if VisibilityPlanner.isHiddenWindowFrame(frame: window.frame, displays: displays) {
            actualVisibility = .hiddenOffscreen
        } else if window.hidden {
            actualVisibility = .applicationHidden
        } else {
            actualVisibility = .visible
        }
        isFullscreen = window.isFullscreen
        isFocused = window.identity == focusedIdentity
        isGeometryBlocked = blockedIdentities.contains(window.identity)
        frame = window.frame
        displayID = window.displayID
    }
}

public struct WorkspaceTrackedWindowState: Equatable, Sendable, Identifiable {
    public let entryID: String
    public let slot: Int
    public let origin: SlotOrigin
    public let bundleID: String
    public let trackedTitle: String
    public let profile: String?
    public let displayID: String?
    public let trackedVisibility: VisibilityState
    public let bindingState: WorkspaceWindowBindingState
    public let liveWindow: WorkspaceLiveWindowState?
    public let pendingReasons: [String]

    public var id: String { entryID }

    /// Only off-screen parking is owned by Shitsurae. A user-minimized or
    /// application-hidden window is therefore informative, not a mismatch.
    public var hasVisibilityMismatch: Bool {
        guard let actualVisibility = liveWindow?.actualVisibility else { return false }
        return switch (trackedVisibility, actualVisibility) {
        case (.hiddenOffscreen, .visible), (.visible, .hiddenOffscreen):
            true
        default:
            false
        }
    }
}

public struct WorkspaceUnmanagedWindowState: Equatable, Sendable, Identifiable {
    public let liveWindow: WorkspaceLiveWindowState
    public let reason: WorkspaceUnmanagedWindowReason

    public var id: WindowIdentity { liveWindow.identity }
}

public struct WorkspaceStateGroup: Equatable, Sendable, Identifiable {
    public let spaceID: Int
    public let activeDisplayIDs: [String]
    public let windows: [WorkspaceTrackedWindowState]
    public let pendingUnresolvedSlots: [PendingUnresolvedSlot]

    public var id: Int { spaceID }
    public var isActive: Bool { !activeDisplayIDs.isEmpty }
}

public struct WorkspaceStateSnapshot: Equatable, Sendable {
    public let layoutName: String?
    public let revision: UInt64
    public let inventoryAvailability: WorkspaceInventoryAvailability
    public let recoveryRequired: Bool
    public let workspaces: [WorkspaceStateGroup]
    public let unmanagedWindows: [WorkspaceUnmanagedWindowState]

    public var trackedWindowCount: Int {
        workspaces.reduce(0) { $0 + $1.windows.count }
    }

    public var boundWindowCount: Int {
        workspaces.reduce(0) { count, workspace in
            count + workspace.windows.count(where: { $0.bindingState == .bound })
        }
    }

    public var hiddenWindowCount: Int {
        workspaces.reduce(0) { count, workspace in
            count + workspace.windows.count(where: { window in
                window.liveWindow?.actualVisibility == .hiddenOffscreen
            })
        }
    }
}

public extension VirtualSpaceEngine {
    /// A read-only projection for GUI status surfaces. Runtime membership and
    /// one coherent live observation are joined through the same global
    /// assignment used by workspace switches, without mutating bindings or
    /// adopting untracked windows.
    func workspaceStateSnapshot(config: LoadedConfig?) -> WorkspaceStateSnapshot {
        let state = currentState
        let observation = control.focusedWindowObservation()
        let inventory = observation.inventory
        let displays = control.displays()
        let blockedIdentities = WindowEligibility.geometryBlockedIdentities(in: observation)
        let layoutName = state.activeLayoutName
        let slots = layoutName.map { state.slots(layoutName: $0) } ?? []

        let configuredSpaceIDs = layoutName.flatMap { name in
            config?.config.layouts[name]?.spaces.map(\.spaceID)
        } ?? []
        let spaceIDs = Set(configuredSpaceIDs)
            .union(slots.map(\.spaceID))
            .union(state.activeSpaces.map(\.spaceID))
            .union(state.pendingVisibilityConvergence?.unresolvedSlots.map(\.spaceID) ?? [])
            .sorted()

        let ownershipWindows = inventory.windows.filter {
            WindowEligibility.classification(of: $0) == .manageable
        }
        let resolution = inventory.isAuthoritative
            ? WindowRegistry.resolve(
                entries: slots.map(\.registryEntry),
                manageableWindows: ownershipWindows,
                fullInventory: inventory
            )
            : nil

        let entriesBySpace = Dictionary(grouping: slots, by: \.spaceID)
        let workspaces = spaceIDs.map { spaceID in
            let trackedWindows = (entriesBySpace[spaceID] ?? []).map { entry in
                let liveWindow = resolution?.assignments[entry.id].map {
                    WorkspaceLiveWindowState(
                        window: $0,
                        displays: displays,
                        focusedIdentity: observation.focusedIdentity,
                        blockedIdentities: blockedIdentities
                    )
                }
                return WorkspaceTrackedWindowState(
                    entryID: entry.id,
                    slot: entry.slot,
                    origin: entry.origin,
                    bundleID: entry.bundleID,
                    trackedTitle: entry.title,
                    profile: entry.profile,
                    displayID: liveWindow?.displayID ?? entry.displayID,
                    trackedVisibility: entry.visibilityState,
                    bindingState: Self.workspaceBindingState(
                        entryID: entry.id,
                        resolution: resolution,
                        inventoryAvailable: inventory.isAuthoritative
                    ),
                    liveWindow: liveWindow,
                    pendingReasons: state.pendingVisibilityConvergence?.unresolvedSlots
                        .filter { $0.spaceID == spaceID && $0.slot == entry.slot }
                        .map(\.reason) ?? []
                )
            }
            .sorted { lhs, rhs in
                if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
                if lhs.origin != rhs.origin { return lhs.origin == .layout }
                return lhs.entryID < rhs.entryID
            }

            return WorkspaceStateGroup(
                spaceID: spaceID,
                activeDisplayIDs: state.activeSpaces
                    .filter { $0.spaceID == spaceID }
                    .map(\.displayID),
                windows: trackedWindows,
                pendingUnresolvedSlots: state.pendingVisibilityConvergence?.unresolvedSlots
                    .filter { $0.spaceID == spaceID } ?? []
            )
        }

        let unassignedIdentities = Set(resolution?.unassignedWindows.map(\.identity) ?? [])
        let deferredIdentities = Set(resolution?.deferredWindows.map(\.identity) ?? [])
        let unmanagedWindows = ownershipWindows.compactMap { window -> WorkspaceUnmanagedWindowState? in
            let reason: WorkspaceUnmanagedWindowReason
            if unassignedIdentities.contains(window.identity) {
                reason = .unassigned
            } else if deferredIdentities.contains(window.identity) {
                reason = .deferredForTrackedBinding
            } else {
                return nil
            }
            return WorkspaceUnmanagedWindowState(
                liveWindow: WorkspaceLiveWindowState(
                    window: window,
                    displays: displays,
                    focusedIdentity: observation.focusedIdentity,
                    blockedIdentities: blockedIdentities
                ),
                reason: reason
            )
        }

        return WorkspaceStateSnapshot(
            layoutName: layoutName,
            revision: state.revision,
            inventoryAvailability: inventory.isAuthoritative ? .available : .unavailable,
            recoveryRequired: state.recoveryRequired,
            workspaces: workspaces,
            unmanagedWindows: unmanagedWindows
        )
    }

    private static func workspaceBindingState(
        entryID: String,
        resolution: WindowRegistry.Resolution?,
        inventoryAvailable: Bool
    ) -> WorkspaceWindowBindingState {
        guard inventoryAvailable, let resolution else { return .inventoryUnavailable }
        if resolution.assignments[entryID] != nil {
            return .bound
        }
        switch resolution.unresolvedReasons[entryID] {
        case .reservedExactIdentity:
            return .reservedExactIdentity
        case .exactOnlyMissing:
            return .exactOnlyMissing
        case .indexOutOfBounds:
            return .indexOutOfBounds
        case .candidateConflict:
            return .candidateConflict
        case .noCandidate, nil:
            return .noCandidate
        }
    }
}
