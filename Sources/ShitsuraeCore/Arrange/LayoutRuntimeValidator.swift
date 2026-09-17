import Foundation

/// Manual arrange checks only its effective runtime scope, not inactive sets.
enum LayoutRuntimeValidator {
    static func validate(layoutName: String, layout: LayoutDefinition, host: DisplayInfo,
        config: ShitsuraeConfig, state: RuntimeState, displays: [DisplayInfo], observation: WindowObservation?
    ) throws -> Set<String> {
        let retiring = Set(state.activeWorkspaces.compactMap { scope -> String? in
            guard scope.layoutName != layoutName else { return nil }
            let resolved = config.layouts[scope.layoutName].flatMap {
                DisplayResolver.hostDisplay(layout: $0, config: config, displays: displays)
            }
            return scope.displayID == host.id || resolved?.id == host.id ? scope.layoutName : nil
        })
        let kept = state.activeWorkspaces.filter { $0.layoutName != layoutName && !retiring.contains($0.layoutName) }
        var hosts = [host.id: layoutName]
        for scope in kept {
            let id = config.layouts[scope.layoutName].flatMap {
                DisplayResolver.hostDisplay(layout: $0, config: config, displays: displays)?.id
            } ?? scope.displayID
            if let other = hosts.updateValue(scope.layoutName, forKey: id) {
                throw ShitsuraeError(.validationError, "host \(id) conflicts: \(other), \(scope.layoutName)", subcode: "displayCollision")
            }
        }
        let retainedNames = Set(kept.map(\.layoutName))
        let owned = state.slots.filter { retainedNames.contains($0.layoutName) && $0.origin == .layout }
        let ignored = ArrangePlanner.buildPlan(layoutName: layoutName, layout: layout, spaceID: nil,
            config: config, hostDisplay: host, displays: displays,
            currentWindows: observation.map { WindowEligibility.geometryCandidates(in: $0) }).ignoredDefinitionFingerprints
        let records = ArrangeWindowSelection.registryEntries(layoutName: layoutName, layout: layout,
            config: config, state: state, excluding: ignored)
        for record in records {
            if let conflict = owned.first(where: { $0.matchRule == record.entry.rule }) {
                throw ShitsuraeError(.validationError, "identical matcher: \(layoutName) conflicts with retained \(conflict.layoutName) slot \(conflict.slot)", subcode: "candidateConflict")
            }
        }
        guard let observation else { return retiring }
        let protected = ArrangeWindowSelection.protectedIdentities(state: state, layoutName: layoutName, retiring: retiring)
        let pool = ArrangeWindowSelection.candidates(observation: observation, ignore: config.ignore?.apply, excluded: protected)
        let legal = WindowRegistry.resolve(entries: records.map(\.entry), manageableWindows: pool, fullInventory: observation.inventory)
        let withProtected = WindowRegistry.resolve(entries: records.map(\.entry),
            manageableWindows: ArrangeWindowSelection.candidates(observation: observation, ignore: config.ignore?.apply, excluded: []),
            fullInventory: observation.inventory)
        for record in records {
            guard legal.assignments[record.entry.id] == nil,
                  legal.unresolvedReasons[record.entry.id] != .reservedExactIdentity,
                  let candidate = withProtected.assignments[record.entry.id],
                  protected.contains(candidate.identity),
                  let owner = owned.first(where: { $0.boundIdentity == candidate.identity }),
                  let scope = kept.first(where: { $0.layoutName == owner.layoutName }) else { continue }
            let dormant = !displays.contains { $0.id == scope.displayID }
            throw ShitsuraeError(.validationError, "windowOwnedByOtherLayout: \(owner.layoutName) display=\(scope.displayID) dormant=\(dormant) identity=\(candidate.identity)", subcode: "windowOwnedByOtherLayout")
        }
        return retiring
    }
}
