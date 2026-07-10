import Foundation
import Testing
@testable import ShitsuraeCore

@Suite("ProfileCache")
struct ProfileCacheTests {
    private let chrome = "com.google.Chrome"

    // バグ2-a 回帰: nil解決は永続化されず、TTL後に再解決される
    @Test func nilResolutionIsRetriedAfterTTL() {
        let cache = ProfileCache(pendingTTL: 5)
        let base = Date(timeIntervalSince1970: 1000)
        var resolverCalls = 0

        // First probe: lsof not ready yet → nil.
        let first = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1, now: base) { _, _ in
            resolverCalls += 1
            return nil
        }
        #expect(first == nil)
        #expect(resolverCalls == 1)
        #expect(cache.entryKind(bundleID: chrome, pid: 100, processStartTime: 1) == "pending")

        // Within TTL: no re-resolution.
        let second = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1, now: base.addingTimeInterval(2)) { _, _ in
            resolverCalls += 1
            return "Default"
        }
        #expect(second == nil)
        #expect(resolverCalls == 1)

        // After TTL: re-resolved and cached.
        let third = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1, now: base.addingTimeInterval(6)) { _, _ in
            resolverCalls += 1
            return "Default"
        }
        #expect(third == "Default")
        #expect(resolverCalls == 2)
        #expect(cache.entryKind(bundleID: chrome, pid: 100, processStartTime: 1) == "resolved")
    }

    @Test func resolvedValueIsCached() {
        let cache = ProfileCache()
        var resolverCalls = 0

        for _ in 0 ..< 3 {
            let result = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1) { _, _ in
                resolverCalls += 1
                return "Profile 1"
            }
            #expect(result == "Profile 1")
        }
        #expect(resolverCalls == 1)
    }

    @Test func invalidateDropsEntriesForBundleID() {
        let cache = ProfileCache()
        _ = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1) { _, _ in "Default" }
        #expect(cache.entryKind(bundleID: chrome, pid: 100, processStartTime: 1) == "resolved")

        cache.invalidate(bundleID: chrome)
        #expect(cache.entryKind(bundleID: chrome, pid: 100, processStartTime: 1) == nil)
    }

    @Test func nonChromiumBundleIDIsNeverResolvedOrCached() {
        let cache = ProfileCache()
        var resolverCalls = 0

        let result = cache.profileDirectory(
            bundleID: "com.apple.TextEdit",
            pid: 1,
            processStartTime: 1
        ) { _, _ in
            resolverCalls += 1
            return "ShouldNotHappen"
        }
        #expect(result == nil)
        #expect(resolverCalls == 0)
        #expect(cache.entryKind(bundleID: "com.apple.TextEdit", pid: 1, processStartTime: 1) == nil)
    }

    @Test func distinctPidsResolveIndependently() {
        let cache = ProfileCache()
        _ = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1) { _, _ in "Default" }
        _ = cache.profileDirectory(bundleID: chrome, pid: 200, processStartTime: 2) { _, _ in "Profile 1" }

        let a = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1) { _, _ in nil }
        let b = cache.profileDirectory(bundleID: chrome, pid: 200, processStartTime: 2) { _, _ in nil }
        #expect(a == "Default")
        #expect(b == "Profile 1")
    }

    @Test func reusedPIDWithNewProcessGenerationDoesNotReuseProfile() {
        let cache = ProfileCache()
        _ = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 1) { _, _ in "Old" }
        let current = cache.profileDirectory(bundleID: chrome, pid: 100, processStartTime: 2) { _, _ in "New" }
        #expect(current == "New")
    }
}
