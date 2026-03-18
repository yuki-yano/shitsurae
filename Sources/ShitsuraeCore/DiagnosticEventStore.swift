import Foundation

public struct DiagnosticEvent: Codable, Equatable {
    public let schemaVersion: Int
    public let at: String
    public let event: String
    public let requestID: String
    public let code: Int
    public let subcode: String?
    public let activeLayoutName: String?
    public let activeVirtualSpaceID: Int?
    public let attemptedTargetSpaceID: Int?
    public let previousActiveSpaceID: Int?
    public let configGeneration: String?
    public let revision: UInt64?
    public let rootCauseCategory: String?
    public let permissionScope: String?
    public let failedOperation: String?
    public let manualRecoveryRequired: Bool?
    public let lockOwnerPID: Int?
    public let lockOwnerProcessKind: String?
    public let lockOwnerStartedAt: String?
    public let lockWaitTimeoutMS: Int?
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(
        at: String? = nil,
        event: String,
        requestID: String,
        code: Int,
        subcode: String? = nil,
        activeLayoutName: String? = nil,
        activeVirtualSpaceID: Int? = nil,
        attemptedTargetSpaceID: Int? = nil,
        previousActiveSpaceID: Int? = nil,
        configGeneration: String? = nil,
        revision: UInt64? = nil,
        rootCauseCategory: String? = nil,
        permissionScope: String? = nil,
        failedOperation: String? = nil,
        manualRecoveryRequired: Bool? = nil,
        lockOwnerPID: Int? = nil,
        lockOwnerProcessKind: String? = nil,
        lockOwnerStartedAt: String? = nil,
        lockWaitTimeoutMS: Int? = nil,
        unresolvedSlots: [PendingUnresolvedSlot] = []
    ) {
        self.schemaVersion = 1
        self.at = at ?? Date.rfc3339UTC()
        self.event = event
        self.requestID = requestID
        self.code = code
        self.subcode = subcode
        self.activeLayoutName = activeLayoutName
        self.activeVirtualSpaceID = activeVirtualSpaceID
        self.attemptedTargetSpaceID = attemptedTargetSpaceID
        self.previousActiveSpaceID = previousActiveSpaceID
        self.configGeneration = configGeneration
        self.revision = revision
        self.rootCauseCategory = rootCauseCategory
        self.permissionScope = permissionScope
        self.failedOperation = failedOperation
        self.manualRecoveryRequired = manualRecoveryRequired
        self.lockOwnerPID = lockOwnerPID
        self.lockOwnerProcessKind = lockOwnerProcessKind
        self.lockOwnerStartedAt = lockOwnerStartedAt
        self.lockWaitTimeoutMS = lockWaitTimeoutMS
        self.unresolvedSlots = unresolvedSlots
    }
}

public final class DiagnosticEventStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileManager: FileManager = .default,
        fileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ConfigPathResolver.stateDirectoryURL(environment: environment)
                .appendingPathComponent("diagnostic-events.jsonl")
        }
    }

    public func record(_ event: DiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? JSONEncoder().encode(event),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }

        line += "\n"
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return
        }
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    public func recent(limit: Int = 50) -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        return text
            .split(separator: "\n")
            .compactMap { line in
                try? JSONDecoder().decode(DiagnosticEvent.self, from: Data(line.utf8))
            }
            .suffix(limit)
            .sorted { lhs, rhs in
                if lhs.at != rhs.at { return lhs.at > rhs.at }
                return lhs.event < rhs.event
            }
    }
}
