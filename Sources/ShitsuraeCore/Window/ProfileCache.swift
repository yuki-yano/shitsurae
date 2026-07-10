import Foundation

/// Chromium profile-directory cache keyed by the complete process instance.
///
/// v1 cached `nil` resolutions forever, so a browser probed right after launch
/// (before its profile lock file shows up in lsof) could never match its
/// `match.profile` rule again. v2 never persists "resolved to nil": an
/// unresolved probe is stored as `.pending` and retried after a short TTL, and
/// app launch/termination invalidates the affected entries immediately.
public final class ProfileCache: @unchecked Sendable {
    enum CacheEntry {
        case resolved(String)
        case pending(since: Date)
    }

    private struct Key: Hashable {
        let bundleID: String
        let pid: Int
        let processStartTime: UInt64
    }

    private let lock = NSLock()
    private var entries: [Key: CacheEntry] = [:]
    private let pendingTTL: TimeInterval

    public init(pendingTTL: TimeInterval = 5.0) {
        self.pendingTTL = pendingTTL
    }

    /// Returns the cached profile directory, or resolves it via `resolver`.
    /// A nil resolution is cached as pending and retried once `pendingTTL`
    /// has elapsed.
    public func profileDirectory(
        bundleID: String,
        pid: Int,
        processStartTime: UInt64,
        now: Date = Date(),
        resolver: (String, Int) -> String?
    ) -> String? {
        guard ChromiumProfileSupport.supports(bundleID: bundleID) else {
            return nil
        }

        let key = Key(bundleID: bundleID, pid: pid, processStartTime: processStartTime)

        lock.lock()
        let cached = entries[key]
        lock.unlock()

        switch cached {
        case let .resolved(profile):
            return profile
        case let .pending(since) where now.timeIntervalSince(since) < pendingTTL:
            return nil
        case .pending, nil:
            break
        }

        let resolved = resolver(bundleID, pid)

        lock.lock()
        if let resolved {
            entries[key] = .resolved(resolved)
        } else {
            entries[key] = .pending(since: now)
        }
        lock.unlock()

        return resolved
    }

    /// Drops all entries for a bundleID. Call on app launch/termination
    /// notifications — old pids are dead and new pids must re-resolve.
    public func invalidate(bundleID: String) {
        lock.lock()
        entries = entries.filter { $0.key.bundleID != bundleID }
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func entryKind(bundleID: String, pid: Int, processStartTime: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        switch entries[Key(bundleID: bundleID, pid: pid, processStartTime: processStartTime)] {
        case .resolved: return "resolved"
        case .pending: return "pending"
        case nil: return nil
        }
    }
}
