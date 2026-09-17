import Foundation

/// Shared manual preflight/executor selection. Protected identities are
/// removed before index ranking; persisted exact bindings still reserve live
/// identities that cannot currently receive geometry writes.
enum ArrangeWindowSelection {
    static func protectedIdentities(state: RuntimeState, layoutName: String, retiring: Set<String>) -> Set<WindowIdentity> {
        let names = Set(state.activeWorkspaces.map(\.layoutName)).subtracting(retiring).subtracting([layoutName])
        return Set(state.slots.filter { names.contains($0.layoutName) && $0.origin == .layout }.compactMap(\.boundIdentity))
    }

    static func candidates(observation: WindowObservation, ignore: IgnoreRuleSet?, excluded: Set<WindowIdentity>) -> [WindowSnapshot] {
        WindowEligibility.geometryCandidates(in: observation).filter {
            !excluded.contains($0.identity) && !PolicyEngine.matchesIgnoreRule(window: $0, rules: ignore)
        }
    }

    static func registryEntries(layoutName: String, layout: LayoutDefinition, config: ShitsuraeConfig,
        state: RuntimeState, excluding: Set<String>
    ) -> [(fingerprint: String, entry: WindowRegistry.Entry)] {
        let previous = Dictionary(state.slots(layoutName: layoutName).filter { $0.origin == .layout }
            .map { ($0.definitionFingerprint, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.spaces.flatMap { space in
            space.windows.compactMap { definition in
                guard !PolicyEngine.matchesIgnoreAppRule(windowDefinition: definition, rules: config.ignore?.apply) else { return nil }
                let fresh = SlotEntry.makeEntry(layoutName: layoutName, spaceID: space.spaceID, definition: definition)
                guard !excluding.contains(fresh.definitionFingerprint) else { return nil }
                return (fresh.definitionFingerprint, previous[fresh.definitionFingerprint]?.registryEntry ?? fresh.registryEntry)
            }
        }
    }
}
