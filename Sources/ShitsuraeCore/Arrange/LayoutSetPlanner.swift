import CryptoKit
import Foundation

/// Pure planner shared by live set application, dry-run and GUI presentation.
public enum LayoutSetPlanner {
    public static func build(
        setName: String,
        config: ShitsuraeConfig,
        state: RuntimeState,
        displays: [DisplayInfo],
        currentWindows: [WindowSnapshot]?
    ) throws -> LayoutSetPlan {
        guard let definition = config.layoutSets[setName] else {
            throw LayoutSetPlanError.setNotFound(setName)
        }

        let primaryDisplayID = DisplayResolver.primaryDisplay(displays)?.id
        var displayOwners: [String: [String]] = [:]
        var members: [LayoutSetMemberPlan] = []
        let sameSet = state.selectedLayoutSet?.name == setName

        for layoutName in definition.layouts {
            guard let layout = config.layouts[layoutName] else {
                throw LayoutSetPlanError.memberLayoutNotFound(layoutName)
            }
            guard let display = DisplayResolver.hostDisplay(layout: layout, config: config, displays: displays) else {
                throw LayoutSetPlanError.hostDisplayUnavailable(layoutName)
            }
            displayOwners[display.id, default: []].append(layoutName)

            let validSpaceIDs = Set(layout.spaces.map(\.spaceID))
            let targetSpaceID: Int
            if sameSet,
               let previous = state.activeWorkspace(layoutName: layoutName),
               validSpaceIDs.contains(previous.spaceID)
            {
                targetSpaceID = previous.spaceID
            } else {
                targetSpaceID = validSpaceIDs.min() ?? 1
            }

            let arrangePlan = ArrangePlanner.buildPlan(
                layoutName: layoutName,
                layout: layout,
                spaceID: nil,
                config: config,
                hostDisplay: display,
                displays: displays,
                currentWindows: currentWindows
            )
            members.append(
                LayoutSetMemberPlan(
                    layoutName: layoutName,
                    resolvedDisplayID: display.id,
                    targetSpaceID: targetSpaceID,
                    arrangePlan: arrangePlan
                )
            )

            if display.id == primaryDisplayID,
               let slot = layout.initialFocus?.slot,
               let focusedDefinition = layout.spaces
                   .first(where: { $0.spaceID == targetSpaceID })?
                   .windows.first(where: { $0.slot == slot }),
               Set(config.ignore?.apply?.apps ?? []).contains(focusedDefinition.match.bundleID)
            {
                throw LayoutSetPlanError.initialFocusExcluded(
                    layout: layoutName,
                    bundleID: focusedDefinition.match.bundleID
                )
            }
        }

        if let collision = displayOwners.first(where: { $0.value.count > 1 }) {
            throw LayoutSetPlanError.displayCollision(
                displayID: collision.key,
                layouts: collision.value.sorted()
            )
        }

        if let currentWindows {
            try validateGlobalCandidateAssignment(
                members: members,
                state: state,
                config: config,
                currentWindows: currentWindows
            )
        }

        let sourceNames = Set(
            state.activeWorkspaces.map(\.layoutName)
                + state.slots.filter(\.visibilityState.isManagedHidden).map(\.layoutName)
        )
        let targetNames = Set(definition.layouts)
        let retiring = sourceNames.subtracting(targetNames).sorted()

        let targetMatcherKeys = Set(definition.layouts.flatMap { layoutName in
            config.layouts[layoutName]?.spaces.flatMap { space in
                space.windows.map { matcherKey($0.match) }
            } ?? []
        })
        let transferIdentities = Set(state.slots.compactMap { entry -> WindowIdentity? in
            guard targetMatcherKeys.contains(matcherKey(entry.matchRule)) else { return nil }
            return entry.boundIdentity
        })
        let releasedEntryIDs = state.slots
            .filter { retiring.contains($0.layoutName) }
            .filter { entry in
                guard let identity = entry.boundIdentity else { return true }
                return !transferIdentities.contains(identity)
            }
            .map(\.id)
            .sorted()

        return LayoutSetPlan(
            setName: setName,
            memberNames: definition.layouts,
            definitionDigest: ConfigDigest.layoutSet(name: setName, config: config),
            topologyDigest: topologyDigest(displays),
            members: members,
            sourceLayoutNames: sourceNames.sorted(),
            retiringLayoutNames: retiring,
            releasedEntryIDs: releasedEntryIDs,
            transferredIdentities: transferIdentities,
            warnings: []
        )
    }

    public static func matcherKey(_ rule: WindowMatchRule) -> String {
        let data = (try? JSONEncoder.sorted.encode(rule)) ?? Data()
        return data.base64EncodedString()
    }

    public static func topologyDigest(_ displays: [DisplayInfo]) -> String {
        let value = displays
            .sorted { $0.id < $1.id }
            .map { "\($0.id)|\($0.isPrimary)|\($0.visibleFrame)" }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).hex
    }

    private static func validateGlobalCandidateAssignment(
        members: [LayoutSetMemberPlan],
        state: RuntimeState,
        config: ShitsuraeConfig,
        currentWindows: [WindowSnapshot]
    ) throws {
        struct CandidateEntry {
            let layoutName: String
            let entry: WindowRegistry.Entry
        }

        let previous = Dictionary(
            state.slots.filter { $0.origin == .layout }.map { ($0.definitionFingerprint, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var records: [CandidateEntry] = []
        for member in members {
            for step in member.arrangePlan.steps {
                let fingerprint = SlotEntry.fingerprint(
                    layoutName: member.layoutName,
                    spaceID: step.spaceID,
                    definition: step.definition
                )
                let old = previous[fingerprint]
                records.append(
                    CandidateEntry(
                        layoutName: member.layoutName,
                        entry: WindowRegistry.Entry(
                            id: "set-plan:\(member.layoutName):\(step.spaceID):\(step.definition.slot):\(fingerprint)",
                            rule: step.definition.match,
                            pid: old?.pid,
                            processStartTime: old?.processStartTime,
                            windowID: old?.windowID,
                            bindingPolicy: .exactThenRule
                        )
                    )
                )
            }
        }
        let manageable = currentWindows.filter {
            WindowEligibility.isManageableForVirtualWorkspace($0)
                && !PolicyEngine.matchesIgnoreRule(window: $0, rules: config.ignore?.apply)
        }
        let resolution = WindowRegistry.resolve(
            entries: records.map(\.entry),
            manageableWindows: manageable,
            fullInventory: .available(currentWindows)
        )
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.entry.id, $0) })
        for entryID in resolution.unresolved
        where resolution.unresolvedReasons[entryID] == .candidateConflict {
            guard let conflicted = byID[entryID],
                  let index = conflicted.entry.rule.index
            else { continue }
            let candidates = WindowRegistry.sortedCandidates(
                rule: conflicted.entry.rule,
                pool: manageable
            )
            guard candidates.indices.contains(index - 1) else { continue }
            let identity = candidates[index - 1].identity
            let ownerLayout = resolution.assignments.first(where: { $0.value.identity == identity })
                .flatMap { byID[$0.key]?.layoutName }
            throw LayoutSetPlanError.candidateConflict(
                layouts: Set([conflicted.layoutName, ownerLayout].compactMap { $0 }).sorted(),
                identity: identity
            )
        }
    }
}

public enum ConfigDigest {
    public static func workspace(layoutName: String, config: ShitsuraeConfig) -> String {
        struct Scope: Encodable {
            let layoutName: String
            let layout: LayoutDefinition?
            let monitor: MonitorTargetDefinition?
            let ignoreApply: IgnoreRuleSet?
            let ignoreFocus: IgnoreRuleSet?
            let followFocus: Bool
        }
        let layout = config.layouts[layoutName]
        let monitor = layout?.display?.monitor.flatMap { config.monitors?[$0] }
        return digest(
            Scope(
                layoutName: layoutName,
                layout: layout,
                monitor: monitor,
                ignoreApply: config.ignore?.apply,
                ignoreFocus: config.ignore?.focus,
                followFocus: config.resolvedFollowFocus
            )
        )
    }

    public static func layoutSet(name: String, config: ShitsuraeConfig) -> String {
        guard let set = config.layoutSets[name] else { return "" }
        let value = set.layouts.sorted().map {
            "\($0):\(workspace(layoutName: $0, config: config))"
        }.joined(separator: "\n")
        return digest(value)
    }

    private static func digest<T: Encodable>(_ value: T) -> String {
        let data = (try? JSONEncoder.sorted.encode(value)) ?? Data()
        return SHA256.hash(data: data).hex
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
