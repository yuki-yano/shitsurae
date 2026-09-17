import Foundation

enum RetainedAdoptedWindows {
    struct UnverifiedEntry {
        let entry: SlotEntry
        let reason: String
    }

    /// Preserve valid Space membership and all exact recovery metadata. A
    /// removed Space falls back to this member's resolved reapply target.
    /// Unobservable physical state must keep the transition journal open and
    /// report the actual retained entry as incomplete, not a missing rule slot.
    static func retain(_ entries: [SlotEntry], layout: LayoutDefinition, targetSpaceID: Int,
        claimed: Set<WindowIdentity>, observation: WindowObservation
    ) -> (entries: [SlotEntry], unverified: [UnverifiedEntry]) {
        let valid = Set(layout.spaces.map(\.spaceID))
        let candidates = Set(WindowEligibility.geometryCandidates(in: observation).map(\.identity))
        let blocked = WindowEligibility.geometryBlockedIdentities(in: observation)
        var unverified: [UnverifiedEntry] = []
        let retained = entries.filter {
            $0.origin == .adopted
                && ($0.boundIdentity.map { !claimed.contains($0) && observation.inventory.mayContain($0) } ?? true)
        }.map { entry in
            guard !valid.contains(entry.spaceID) else { return entry }
            var moved = entry
            moved.spaceID = targetSpaceID
            if entry.boundIdentity.map({ !candidates.contains($0) }) ?? true {
                let geometryBlocked = entry.boundIdentity.map { blocked.contains($0) } ?? false
                unverified.append(UnverifiedEntry(entry: moved, reason: geometryBlocked
                    ? "retainedAdoptedGeometryBlocked" : "retainedAdoptedPhysicalStateUnverified"))
            }
            return moved
        }
        return (retained, unverified)
    }
}
