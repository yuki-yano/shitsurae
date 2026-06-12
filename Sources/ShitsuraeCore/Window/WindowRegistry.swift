import Foundation

/// Central window resolution for v2.
///
/// All entry→window resolution goes through `resolve`, which treats the whole
/// set of entries and the whole pool of windows as one assignment problem.
/// This makes the core v1 bug class impossible by construction: two entries
/// can never resolve to the same window, because an assigned window leaves the
/// candidate pool.
///
/// Phases:
/// 1. windowID exact matches (windows the user actually saw bound last time).
/// 2. `match.index` entries, selected against a stable snapshot of the
///    remaining pool — all index entries see the same ordering, so
///    index 1 / index 2 stay consistent regardless of resolution order.
/// 3. Remaining entries via maximum matching (Kuhn's augmenting paths), so
///    a complete assignment is found whenever one exists.
///
/// The write-side counterpart `lookup` is intentionally stricter
/// (nil-fail-fast): it returns an entry only on windowID match or a unique
/// rule match. v1's "fall back to the first entry" here corrupted slot state
/// (windowID + lastActivatedAt written to the wrong entry).
public enum WindowRegistry {
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let rule: WindowMatchRule
        public let windowID: UInt32?

        public init(id: String, rule: WindowMatchRule, windowID: UInt32? = nil) {
            self.id = id
            self.rule = rule
            self.windowID = windowID
        }
    }

    public struct Resolution: Equatable, Sendable {
        /// entry id → assigned window
        public let assignments: [String: WindowSnapshot]
        /// entry ids that could not be resolved (no candidate, ambiguous,
        /// or index out of bounds)
        public let unresolved: [String]
        /// windows that no entry claimed
        public let unassignedWindows: [WindowSnapshot]
    }

    // MARK: - Bulk resolution (read side: space switch / arrange)

    public static func resolve(entries: [Entry], windows: [WindowSnapshot]) -> Resolution {
        var assignments: [String: WindowSnapshot] = [:]
        var unresolved: [String] = []
        var pool = windows
        var remaining: [Entry] = []

        // Phase 1: windowID exact matches.
        for entry in entries {
            if let windowID = entry.windowID,
               let index = pool.firstIndex(where: { $0.windowID == windowID })
            {
                assignments[entry.id] = pool.remove(at: index)
            } else {
                remaining.append(entry)
            }
        }

        // Phase 2: index-based entries resolve against a fixed snapshot of
        // the pool so all of them see identical ordering.
        let indexEntries = remaining.filter { $0.rule.index != nil }
        let otherEntries = remaining.filter { $0.rule.index == nil }
        let indexPhasePool = pool

        for entry in indexEntries {
            let candidates = sortedCandidates(rule: entry.rule, pool: indexPhasePool)
            let zeroBased = (entry.rule.index ?? 1) - 1
            guard zeroBased >= 0, zeroBased < candidates.count else {
                unresolved.append(entry.id)
                continue
            }

            let chosen = candidates[zeroBased]
            guard let poolIndex = pool.firstIndex(where: { $0.windowID == chosen.windowID }) else {
                // Another index entry with an overlapping rule already took
                // this window — ambiguous configuration; fail fast.
                unresolved.append(entry.id)
                continue
            }

            assignments[entry.id] = pool.remove(at: poolIndex)
        }

        // Phase 3: remaining entries, maximum matching via augmenting paths
        // (Kuhn's algorithm). Plain greedy can starve a later entry whose
        // only candidate was taken by an earlier one even though a complete
        // assignment exists; augmenting paths reassign in that case.
        // Iteration order (most-specific first) and candidate order
        // (sortedCandidates) keep the result deterministic and preference-
        // aware when several maximum matchings exist.
        let ordered = otherEntries.enumerated().sorted { lhs, rhs in
            let lhsScore = specificity(of: lhs.element.rule)
            let rhsScore = specificity(of: rhs.element.rule)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.offset < rhs.offset
        }
        .map(\.element)

        let candidatesByEntry = Dictionary(uniqueKeysWithValues: ordered.map { entry in
            (entry.id, sortedCandidates(rule: entry.rule, pool: pool))
        })
        let entryByID = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0) })
        var entryIDByWindowID: [UInt32: String] = [:]
        var windowByEntryID: [String: WindowSnapshot] = [:]

        func augment(_ entry: Entry, visited: inout Set<UInt32>) -> Bool {
            for candidate in candidatesByEntry[entry.id] ?? [] {
                guard visited.insert(candidate.windowID).inserted else { continue }

                if let holderID = entryIDByWindowID[candidate.windowID] {
                    guard let holder = entryByID[holderID],
                          augment(holder, visited: &visited)
                    else {
                        continue
                    }
                }

                entryIDByWindowID[candidate.windowID] = entry.id
                windowByEntryID[entry.id] = candidate
                return true
            }
            return false
        }

        for entry in ordered {
            var visited = Set<UInt32>()
            if !augment(entry, visited: &visited) {
                unresolved.append(entry.id)
            }
        }

        for (entryID, window) in windowByEntryID {
            assignments[entryID] = window
            if let poolIndex = pool.firstIndex(where: { $0.windowID == window.windowID }) {
                pool.remove(at: poolIndex)
            }
        }

        return Resolution(
            assignments: assignments,
            unresolved: unresolved,
            unassignedWindows: pool
        )
    }

    // MARK: - Single-window lookup (write side: MRU marking / workspace move)

    /// Finds the entry a concrete window belongs to. Strict by design:
    /// returns nil unless the match is unambiguous. Callers must treat nil as
    /// "do not write anything".
    public static func lookup(window: WindowSnapshot, entries: [Entry]) -> Entry? {
        if let exact = entries.first(where: { $0.windowID == window.windowID }) {
            return exact
        }

        let matching = entries.filter { entry in
            entry.windowID == nil && ruleMatches(rule: entry.rule, window: window, ignoreIndex: true)
        }

        guard matching.count == 1 else {
            return nil
        }

        return matching[0]
    }

    // MARK: - Rule evaluation

    static func ruleMatches(rule: WindowMatchRule, window: WindowSnapshot, ignoreIndex: Bool = false) -> Bool {
        guard window.bundleID == rule.bundleID else { return false }

        if let matcher = rule.title {
            if let equals = matcher.equals {
                guard window.title == equals else { return false }
            } else if let contains = matcher.contains {
                guard window.title.contains(contains) else { return false }
            } else if let regex = matcher.regex {
                guard window.title.range(of: regex, options: .regularExpression) != nil else { return false }
            }
        }

        if let role = rule.role, window.role != role {
            return false
        }

        if let subrole = rule.subrole, window.subrole != subrole {
            return false
        }

        if let profile = rule.profile, window.profileDirectory != profile {
            return false
        }

        if let excludeRegex = rule.excludeTitleRegex,
           window.title.range(of: excludeRegex, options: .regularExpression) != nil
        {
            return false
        }

        if !ignoreIndex, rule.index != nil {
            // index selection requires pool context; handled in resolve().
            return true
        }

        return true
    }

    /// Candidates matching the rule (without index selection), in the stable
    /// order index selection and greedy picks both use:
    /// non-empty title → larger area → frontmost → windowID.
    static func sortedCandidates(rule: WindowMatchRule, pool: [WindowSnapshot]) -> [WindowSnapshot] {
        pool
            .filter { ruleMatches(rule: rule, window: $0, ignoreIndex: true) }
            .sorted { lhs, rhs in
                let leftHasTitle = !lhs.title.isEmpty
                let rightHasTitle = !rhs.title.isEmpty
                if leftHasTitle != rightHasTitle {
                    return leftHasTitle
                }

                let leftArea = lhs.frame.width * lhs.frame.height
                let rightArea = rhs.frame.width * rhs.frame.height
                if leftArea != rightArea {
                    return leftArea > rightArea
                }

                if lhs.frontIndex != rhs.frontIndex { return lhs.frontIndex < rhs.frontIndex }
                return lhs.windowID < rhs.windowID
            }
    }

    static func specificity(of rule: WindowMatchRule) -> Int {
        var score = 0
        if rule.title != nil { score += 4 }
        if rule.profile != nil { score += 2 }
        if rule.role != nil || rule.subrole != nil { score += 1 }
        if rule.excludeTitleRegex != nil { score += 1 }
        return score
    }
}
