import Darwin
import Foundation

public struct VirtualSpaceLockOwnerMetadata: Codable, Equatable, Sendable {
    public let pid: Int
    public let processKind: String
    public let startedAt: String
    public let requestID: String

    public init(
        pid: Int,
        processKind: String,
        startedAt: String,
        requestID: String
    ) {
        self.pid = pid
        self.processKind = processKind
        self.startedAt = startedAt
        self.requestID = requestID
    }
}

public enum VirtualSpaceStateMutationLockError: Error, Equatable {
    case timedOut(ownerMetadata: VirtualSpaceLockOwnerMetadata?, ownerMetadataUnavailable: Bool, timeoutMS: Int)
    case ioFailed(reason: String)
}

public final class VirtualSpaceStateMutationLock: @unchecked Sendable {
    public static let lockWaitTimeoutMS = 5000
    public static let defaultPollIntervalMS = 50

    private static let sameProcessRegistry = SameProcessLockRegistry()

    private let fileURL: URL
    private let fileManager: FileManager
    private let sleepHook: (UInt32) -> Void

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        sleepHook: @escaping (UInt32) -> Void = { _ = usleep($0) }
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.sleepHook = sleepHook
    }

    public func withLock<T>(
        owner: VirtualSpaceLockOwnerMetadata,
        timeoutMS: Int = VirtualSpaceStateMutationLock.lockWaitTimeoutMS,
        pollIntervalMS: Int = VirtualSpaceStateMutationLock.defaultPollIntervalMS,
        body: () throws -> T
    ) throws -> T {
        let lockKey = fileURL.path
        let acquiredSameProcess = Self.sameProcessRegistry.acquire(
            key: lockKey,
            timeoutMS: timeoutMS,
            pollIntervalMS: pollIntervalMS,
            sleepHook: sleepHook
        )
        guard acquiredSameProcess else {
            let ownerMetadata = currentOwnerMetadata()
            throw VirtualSpaceStateMutationLockError.timedOut(
                ownerMetadata: ownerMetadata,
                ownerMetadataUnavailable: ownerMetadata == nil,
                timeoutMS: timeoutMS
            )
        }

        var shouldReleaseSameProcessLock = true
        do {
            let fd = try openLockFile()
            defer {
                _ = flock(fd, LOCK_UN)
                clearOwnerMetadata(fd: fd)
                close(fd)
                Self.sameProcessRegistry.release(key: lockKey)
                shouldReleaseSameProcessLock = false
            }

            try acquireFileLock(fd: fd, timeoutMS: timeoutMS, pollIntervalMS: pollIntervalMS)
            try writeOwnerMetadata(owner, fd: fd)
            return try body()
        } catch {
            if shouldReleaseSameProcessLock {
                Self.sameProcessRegistry.release(key: lockKey)
            }
            throw error
        }
    }

    public func currentOwnerMetadata() -> VirtualSpaceLockOwnerMetadata? {
        guard let data = try? Data(contentsOf: fileURL),
              !data.isEmpty
        else {
            return nil
        }

        return try? JSONDecoder().decode(VirtualSpaceLockOwnerMetadata.self, from: data)
    }

    private func openLockFile() throws -> Int32 {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: error.localizedDescription)
        }

        let fd = open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: String(cString: strerror(errno)))
        }
        return fd
    }

    private func acquireFileLock(fd: Int32, timeoutMS: Int, pollIntervalMS: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000.0)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                return
            }

            if errno != EWOULDBLOCK {
                throw VirtualSpaceStateMutationLockError.ioFailed(reason: String(cString: strerror(errno)))
            }

            guard Date() < deadline else {
                let ownerMetadata = currentOwnerMetadata()
                throw VirtualSpaceStateMutationLockError.timedOut(
                    ownerMetadata: ownerMetadata,
                    ownerMetadataUnavailable: ownerMetadata == nil,
                    timeoutMS: timeoutMS
                )
            }

            sleepHook(UInt32(pollIntervalMS * 1000))
        }
    }

    private func writeOwnerMetadata(_ owner: VirtualSpaceLockOwnerMetadata, fd: Int32) throws {
        let data: Data
        do {
            data = try JSONEncoder.pretty.encode(owner)
        } catch {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: error.localizedDescription)
        }

        guard ftruncate(fd, 0) == 0 else {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: String(cString: strerror(errno)))
        }
        guard lseek(fd, 0, SEEK_SET) >= 0 else {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: String(cString: strerror(errno)))
        }

        let written = data.withUnsafeBytes { bytes in
            write(fd, bytes.baseAddress, data.count)
        }
        guard written == data.count else {
            throw VirtualSpaceStateMutationLockError.ioFailed(reason: String(cString: strerror(errno)))
        }
        fsync(fd)
    }

    private func clearOwnerMetadata(fd: Int32) {
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        fsync(fd)
    }
}

private final class SameProcessLockRegistry: @unchecked Sendable {
    private final class Entry {
        let condition = NSCondition()
        var ownerThreadID: UInt64?
        var recursionCount: Int = 0
    }

    private let tableLock = NSLock()
    private var entries: [String: Entry] = [:]

    func acquire(
        key: String,
        timeoutMS: Int,
        pollIntervalMS: Int,
        sleepHook: (UInt32) -> Void
    ) -> Bool {
        let currentThreadID = Self.currentThreadID()
        let entry = entry(for: key)
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMS) / 1000.0)

        while true {
            entry.condition.lock()
            if entry.ownerThreadID == nil || entry.ownerThreadID == currentThreadID {
                entry.ownerThreadID = currentThreadID
                entry.recursionCount += 1
                entry.condition.unlock()
                return true
            }
            entry.condition.unlock()

            guard Date() < deadline else {
                return false
            }
            sleepHook(UInt32(pollIntervalMS * 1000))
        }
    }

    func release(key: String) {
        let currentThreadID = Self.currentThreadID()
        let entry = entry(for: key)
        entry.condition.lock()
        defer { entry.condition.unlock() }
        guard entry.ownerThreadID == currentThreadID else {
            return
        }

        entry.recursionCount -= 1
        if entry.recursionCount <= 0 {
            entry.ownerThreadID = nil
            entry.recursionCount = 0
            entry.condition.broadcast()
        }
    }

    private func entry(for key: String) -> Entry {
        tableLock.lock()
        defer { tableLock.unlock() }
        if let existing = entries[key] {
            return existing
        }
        let created = Entry()
        entries[key] = created
        return created
    }

    private static func currentThreadID() -> UInt64 {
        UInt64(pthread_mach_thread_np(pthread_self()))
    }
}
