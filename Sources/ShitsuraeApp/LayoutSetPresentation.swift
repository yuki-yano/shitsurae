import Foundation
import ShitsuraeCore

extension ArrangeOperationKind {
    var displayLabel: String {
        switch self {
        case .arrange: "Apply Layout"
        case .arrangeSet: "Apply Layout Set"
        case .recover: "Restore Windows"
        case .switchSpace: "Switch Workspace"
        case .window: "Update Window"
        case .focus: "Focus Window"
        case .displayChange: "Adjust Displays"
        case .shutdown: "Stop Managing"
        }
    }
}

extension ArrangeOperationPhase {
    var displayLabel: String {
        switch self {
        case .admitted, .preflight, .journaled: "Preparing"
        case .waitingForWindows: "Waiting for Windows"
        case .releasing: "Restoring Previous Windows"
        case .ownershipCommitted, .placing: "Placing Windows"
        case .visibility: "Updating Visibility"
        case .focusing: "Focusing Window"
        case .recovering: "Restoring Windows"
        case .finalizing: "Finishing"
        }
    }
}

struct ArrangeOperationPollPresentation {
    let shouldRefreshRuntime: Bool
    let outcome: ArrangeActionResultPresentation?
    let label: String?

    static func make(previous: ArrangeStatusJSON, next: ArrangeStatusJSON) -> Self {
        let changed = next.active == nil && (next.lastOutcome != previous.lastOutcome || next.stateRevision != previous.stateRevision)
        let result = next.lastOutcome.map { summary in
            ArrangeActionResultPresentation(kind: summary.exitCode == 0 ? .success : summary.result == "partial" ? .partial : .failed,
                message: summary.detail ?? "exitCode=\(summary.exitCode)")
        }
        return Self(shouldRefreshRuntime: changed, outcome: changed ? result : nil, label: next.lastOutcome?.operation.displayLabel)
    }
}

struct DisplayChangeEventState {
    private(set) var generation: UInt64 = 0
    private(set) var pendingGeneration: UInt64?
    private(set) var isProcessing = false
    mutating func recordDisplayChange() { generation &+= 1; pendingGeneration = generation }
    mutating func invalidateForConfigurationChange() { generation &+= 1; pendingGeneration = nil }
    mutating func beginLatest() -> UInt64? {
        guard !isProcessing, let pendingGeneration else { return nil }
        isProcessing = true
        return pendingGeneration
    }
    mutating func didAdmit(_ admittedGeneration: UInt64) {
        if admittedGeneration == pendingGeneration { pendingGeneration = nil }
    }
    mutating func finish() { isProcessing = false }
}

struct LayoutSetPresentation: Identifiable, Equatable {
    struct Member: Identifiable, Equatable {
        let layoutName: String
        let resolvedDisplayID: String?
        let targetSpaceID: Int
        let spaceCount: Int
        let issue: String?
        let managementState: String

        var id: String { layoutName }
    }

    let name: String
    let members: [Member]
    let releasedCount: Int
    let isSelected: Bool
    let needsReapply: Bool
    let blockingReason: String?

    var id: String { name }
    var canApply: Bool { blockingReason == nil }

    static func makeAll(
        config: ShitsuraeConfig,
        state: RuntimeState,
        displays: [DisplayInfo]
    ) -> [LayoutSetPresentation] {
        config.layoutSets.map { name, definition in
            var blockingReason: String?
            var plannerError: LayoutSetPlanError?
            var sharedPlan: LayoutSetPlan?
            do {
                sharedPlan = try LayoutSetPlanner.build(setName: name, config: config, state: state,
                    displays: displays, currentWindows: nil)
            } catch let error as LayoutSetPlanError {
                plannerError = error
                blockingReason = error.displayMessage
            } catch {
                blockingReason = "This layout set cannot be applied. Check its configuration and try again."
            }
            let members = definition.layouts.map { layoutName -> Member in
                guard let layout = config.layouts[layoutName] else {
                    return Member(
                        layoutName: layoutName,
                        resolvedDisplayID: nil,
                        targetSpaceID: 1,
                        spaceCount: 0,
                        issue: "Missing layout",
                        managementState: "Inactive"
                    )
                }
                let display = DisplayResolver.hostDisplay(
                    layout: layout,
                    config: config,
                    displays: displays
                )
                var issue: String?
                if case .hostDisplayUnavailable(layoutName) = plannerError {
                    issue = "Display unavailable"
                } else if case let .displayCollision(_, layouts) = plannerError, layouts.contains(layoutName) {
                    issue = "Display collision"
                }
                let validSpaces = Set(layout.spaces.map(\.spaceID))
                let previous = state.activeWorkspace(layoutName: layoutName)?.spaceID
                let target: Int
                if state.selectedLayoutSet?.name == name,
                   let previous,
                   validSpaces.contains(previous)
                {
                    target = previous
                } else {
                    target = validSpaces.min() ?? 1
                }
                return Member(
                    layoutName: layoutName,
                    resolvedDisplayID: display?.id,
                    targetSpaceID: sharedPlan?.members.first(where: { $0.layoutName == layoutName })?.targetSpaceID ?? target,
                    spaceCount: layout.spaces.count,
                    issue: issue,
                    managementState: state.activeWorkspace(layoutName: layoutName).map { scope in
                        "\(displays.contains { $0.id == scope.displayID } ? "Active" : "Dormant") · Space \(scope.spaceID)"
                    } ?? "Inactive"
                )
            }
            let targetNames = Set(definition.layouts)
            let released = state.slots.filter {
                !targetNames.contains($0.layoutName) && $0.boundIdentity != nil
            }.count
            return LayoutSetPresentation(
                name: name,
                members: members,
                releasedCount: released,
                isSelected: state.selectedLayoutSet?.name == name,
                needsReapply: state.selectedLayoutSet?.name == name
                    && state.anySelectedSetScopeNeedsReapply(config: config),
                blockingReason: blockingReason
            )
        }.sorted { $0.name < $1.name }
    }
}

struct ArrangeActionResultPresentation: Equatable {
    enum Kind: Equatable {
        case success
        case partial
        case failed
    }

    let kind: Kind
    let message: String

    static func make(result: LayoutSetExecutionJSON) -> ArrangeActionResultPresentation {
        let unresolved = result.unresolved.map(\.reason).joined(separator: ", ")
        switch result.result {
        case "success":
            return ArrangeActionResultPresentation(kind: .success, message: "ok")
        case "partial":
            return ArrangeActionResultPresentation(
                kind: .partial,
                message: unresolved.isEmpty ? "incomplete" : unresolved
            )
        default:
            return ArrangeActionResultPresentation(
                kind: .failed,
                message: unresolved.isEmpty ? "failed" : unresolved
            )
        }
    }

    static func shouldOfferRecovery(state: RuntimeState, needsReapply: Bool, configurationUnavailable: Bool = false) -> Bool {
        state.pendingLayoutTransition != nil || needsReapply
            || (configurationUnavailable && state.hasRecoverableManagement)
    }
}

extension LayoutSetPlanError {
    var displayMessage: String {
        switch self {
        case let .setNotFound(name):
            "Layout set \(name) is missing. Select another set or restore managed windows."
        case let .memberLayoutNotFound(name):
            "Layout \(name) is missing. Update the layout set configuration."
        case let .hostDisplayUnavailable(name):
            "The display required by layout \(name) is unavailable. Connect it or select another layout set."
        case let .displayCollision(_, layouts):
            "Layouts \(layouts.joined(separator: ", ")) use the same display. Assign each member to a different display."
        case let .candidateConflict(layouts, _):
            "Layouts \(layouts.joined(separator: ", ")) would claim the same window. Update their window matching rules."
        case let .initialFocusExcluded(layout, bundleID):
            "Layout \(layout) cannot focus \(bundleID) because it is ignored. Update initial focus or the apply ignore rules."
        }
    }
}
