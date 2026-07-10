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
/// 1. exact PID + process generation + windowID + bundleID matches.
/// 2. `match.index` entries, selected against a stable snapshot of the
///    remaining pool — all index entries see the same ordering, so
///    index 1 / index 2 stay consistent regardless of resolution order.
/// 3. Remaining entries via maximum matching (Kuhn's augmenting paths), so
///    a complete assignment is found whenever one exists.
///
/// The write-side counterpart `assignedEntry(for:entries:windows:)` reuses
/// this same global assignment, so single-window decisions always agree with
/// bulk resolution. v1's "fall back to the first entry" corrupted slot state
/// (windowID + lastActivatedAt written to the wrong entry); determinism now
/// comes from `resolve` itself instead of a nil-fail-fast side matcher.
public enum WindowRegistry {
    public enum BindingPolicy: Equatable, Sendable {
        /// Prefer the persisted concrete identity, then rebind from the
        /// layout rule when the application was relaunched or the window was
        /// recreated.
        case exactThenRule
        /// The persisted concrete identity is the only valid binding.
        /// Runtime-adopted entries use this policy so a dead window can never
        /// attach itself to a different window from the same application.
        case exactOnly
    }

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let rule: WindowMatchRule
        public let pid: Int?
        public let processStartTime: UInt64?
        public let windowID: UInt32?
        public let bindingPolicy: BindingPolicy

        public init(
            id: String,
            rule: WindowMatchRule,
            pid: Int? = nil,
            processStartTime: UInt64? = nil,
            windowID: UInt32? = nil,
            bindingPolicy: BindingPolicy = .exactThenRule
        ) {
            self.id = id
            self.rule = rule
            self.pid = pid
            self.processStartTime = processStartTime
            self.windowID = windowID
            self.bindingPolicy = bindingPolicy
        }
    }

    public enum UnresolvedReason: Equatable, Sendable {
        case reservedExactIdentity
        case exactOnlyMissing
        case indexOutOfBounds
        case candidateConflict
        case noCandidate
    }

    public struct Resolution: Equatable, Sendable {
        /// entry id → assigned window
        public let assignments: [String: WindowSnapshot]
        /// entry ids that could not be resolved (no candidate, ambiguous,
        /// or index out of bounds)
        public let unresolved: [String]
        public let unresolvedReasons: [String: UnresolvedReason]
        /// Windows that no entry claimed and are safe to auto-adopt.
        public let unassignedWindows: [WindowSnapshot]
        /// Manageable windows matching a layout entry whose persisted exact
        /// identity is still CG-alive (or whose full inventory is unknown).
        /// Auto-adopting them would permanently block the layout entry's later
        /// fallback, so callers must leave them unmanaged for this pass.
        public let deferredWindows: [WindowSnapshot]
    }

    // MARK: - Bulk resolution (read side: space switch / arrange)

    public static func resolve(
        entries: [Entry],
        manageableWindows: [WindowSnapshot],
        fullInventory: WindowInventory
    ) -> Resolution {
        var assignments: [String: WindowSnapshot] = [:]
        var unresolved: [String] = []
        var unresolvedReasons: [String: UnresolvedReason] = [:]
        var pool = manageableWindows
        var remaining: [Entry] = []
        var reservedEntries: [Entry] = []
        // Phase 1: concrete identity matches. A persisted CGWindowID can be
        // reused after its owner exits, so windowID alone is insufficient:
        // PID, process generation and the immutable bundle identity must agree.
        for entry in entries {
            if let index = pool.firstIndex(where: { exactIdentityMatches(entry: entry, window: $0) }) {
                assignments[entry.id] = pool.remove(at: index)
            } else if let identity = exactIdentity(of: entry),
                      fullInventory.mayContain(identity)
            {
                unresolved.append(entry.id)
                unresolvedReasons[entry.id] = .reservedExactIdentity
                if entry.bindingPolicy == .exactThenRule {
                    reservedEntries.append(entry)
                }
            } else if entry.bindingPolicy == .exactOnly {
                unresolved.append(entry.id)
                unresolvedReasons[entry.id] = .exactOnlyMissing
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
                unresolvedReasons[entry.id] = .indexOutOfBounds
                continue
            }

            let chosen = candidates[zeroBased]
            let chosenIdentity = chosen.identity
            guard let poolIndex = pool.firstIndex(where: { $0.identity == chosenIdentity }) else {
                // Another index entry with an overlapping rule already took
                // this window — ambiguous configuration; fail fast.
                unresolved.append(entry.id)
                unresolvedReasons[entry.id] = .candidateConflict
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
        var entryIDByWindowIdentity: [WindowIdentity: String] = [:]
        var windowByEntryID: [String: WindowSnapshot] = [:]

        func augment(_ entry: Entry, visited: inout Set<WindowIdentity>) -> Bool {
            for candidate in candidatesByEntry[entry.id] ?? [] {
                let identity = candidate.identity
                guard visited.insert(identity).inserted else { continue }

                if let holderID = entryIDByWindowIdentity[identity] {
                    guard let holder = entryByID[holderID],
                          augment(holder, visited: &visited)
                    else {
                        continue
                    }
                }

                entryIDByWindowIdentity[identity] = entry.id
                windowByEntryID[entry.id] = candidate
                return true
            }
            return false
        }

        for entry in ordered {
            var visited = Set<WindowIdentity>()
            if !augment(entry, visited: &visited) {
                unresolved.append(entry.id)
                unresolvedReasons[entry.id] = .noCandidate
            }
        }

        for (entryID, window) in windowByEntryID {
            assignments[entryID] = window
            let identity = window.identity
            if let poolIndex = pool.firstIndex(where: { $0.identity == identity }) {
                pool.remove(at: poolIndex)
            }
        }

        // Reserve the minimum *jointly assignable* candidate set needed for
        // future layout fallback. Index N needs its first N candidates kept
        // out of exact-only adoption so the rank cannot collapse. Plain and
        // overlapping rules use maximum matching so two reserved clone slots
        // reserve two distinct siblings rather than both pointing at the same
        // best candidate.
        var deferredIdentities = Set<WindowIdentity>()
        let reservedIndexEntries = reservedEntries.filter { $0.rule.index != nil }
        for entry in reservedIndexEntries {
            let candidates = sortedCandidates(rule: entry.rule, pool: pool)
            let requiredCount = max(1, entry.rule.index!)
            deferredIdentities.formUnion(candidates.prefix(requiredCount).map(\.identity))
        }

        let plainPool = pool.filter { !deferredIdentities.contains($0.identity) }
        let reservedPlainEntries = reservedEntries.enumerated()
            .filter { $0.element.rule.index == nil }
            .sorted { lhs, rhs in
                let lhsScore = specificity(of: lhs.element.rule)
                let rhsScore = specificity(of: rhs.element.rule)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        let reservedCandidates = Dictionary(uniqueKeysWithValues: reservedPlainEntries.map { entry in
            (entry.id, sortedCandidates(rule: entry.rule, pool: plainPool))
        })
        let reservedByID = Dictionary(uniqueKeysWithValues: reservedPlainEntries.map { ($0.id, $0) })
        var reservedHolderByIdentity: [WindowIdentity: String] = [:]
        var reservedWindowByEntryID: [String: WindowSnapshot] = [:]

        func reserve(_ entry: Entry, visited: inout Set<WindowIdentity>) -> Bool {
            for candidate in reservedCandidates[entry.id] ?? [] {
                let identity = candidate.identity
                guard visited.insert(identity).inserted else { continue }
                if let holderID = reservedHolderByIdentity[identity] {
                    guard let holder = reservedByID[holderID],
                          reserve(holder, visited: &visited)
                    else {
                        continue
                    }
                }
                reservedHolderByIdentity[identity] = entry.id
                reservedWindowByEntryID[entry.id] = candidate
                return true
            }
            return false
        }

        for entry in reservedPlainEntries {
            var visited = Set<WindowIdentity>()
            _ = reserve(entry, visited: &visited)
        }
        deferredIdentities.formUnion(reservedWindowByEntryID.values.map(\.identity))
        let deferredWindows = pool.filter { deferredIdentities.contains($0.identity) }
        let adoptableWindows = pool.filter { !deferredIdentities.contains($0.identity) }

        return Resolution(
            assignments: assignments,
            unresolved: unresolved,
            unresolvedReasons: unresolvedReasons,
            unassignedWindows: adoptableWindows,
            deferredWindows: deferredWindows
        )
    }

    // MARK: - Single-window lookup (write side: MRU marking / workspace move)

    /// Finds the entry a concrete window belongs to by computing the same
    /// global assignment `resolve` would produce for the given pool.
    ///
    /// Per-window decisions (focus follow, activation tracking, adoption
    /// checks, workspace moves) must never disagree with the next bulk
    /// resolution — a stricter standalone matcher here once refused to
    /// re-associate a relaunched app's new window with its layout entry,
    /// which made the focus path adopt the window into a duplicate entry.
    public static func assignedEntry(
        for window: WindowSnapshot,
        entries: [Entry],
        manageableWindows: [WindowSnapshot],
        fullInventory: WindowInventory
    ) -> Entry? {
        let resolution = resolve(
            entries: entries,
            manageableWindows: manageableWindows,
            fullInventory: fullInventory
        )
        guard let match = resolution.assignments.first(where: {
            $0.value.identity == window.identity
        }) else {
            return nil
        }
        return entries.first { $0.id == match.key }
    }

    // MARK: - Rule evaluation

    static func exactIdentityMatches(entry: Entry, window: WindowSnapshot) -> Bool {
        guard let pid = entry.pid,
              let processStartTime = entry.processStartTime,
              let windowID = entry.windowID,
              pid == window.pid,
              processStartTime == window.processStartTime,
              windowID == window.windowID
        else {
            return false
        }

        // Only the bundle identity backs up PID + generation + windowID against handle
        // reuse — it cannot change under a live pid. The rule's other fields
        // (title matchers, subrole) are volatile at runtime; re-checking them
        // here would unbind a live window whenever its title drifts.
        return window.bundleID == entry.rule.bundleID
    }

    static func exactIdentity(of entry: Entry) -> WindowIdentity? {
        guard let pid = entry.pid,
              let processStartTime = entry.processStartTime,
              let windowID = entry.windowID
        else {
            return nil
        }
        return WindowIdentity(
            pid: pid,
            processStartTime: processStartTime,
            windowID: windowID,
            bundleID: entry.rule.bundleID
        )
    }

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
                if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
                return lhs.pid < rhs.pid
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
