import Foundation

public enum RuntimeStateStoreError: Error, Equatable {
    case corrupted(fileURL: URL, backupURL: URL?)
    case readPermissionDenied(fileURL: URL)
    case readFailed(fileURL: URL, reason: String)
    case encodingFailed
    case staleWriteRejected(
        expectedRevision: UInt64,
        actualRevision: UInt64,
        expectedConfigGeneration: String,
        actualConfigGeneration: String
    )
    case writePermissionDenied(fileURL: URL)
    case writeFailed(fileURL: URL, reason: String)

    public var validationSubcode: String? {
        switch self {
        case .corrupted:
            return "runtimeStateCorrupted"
        case .readPermissionDenied:
            return "runtimeStateReadPermissionDenied"
        case .staleWriteRejected:
            return "staleStateWriteRejected"
        case .readFailed, .encodingFailed, .writePermissionDenied, .writeFailed:
            return nil
        }
    }

    public var rootCauseCategory: String {
        switch self {
        case .corrupted:
            return "runtimeStateCorrupted"
        case .readPermissionDenied:
            return "runtimeStateReadPermissionDenied"
        case .readFailed:
            return "runtimeStateReadFailed"
        case .encodingFailed:
            return "runtimeStateEncodingFailed"
        case .staleWriteRejected:
            return "staleStateWriteRejected"
        case .writePermissionDenied:
            return "runtimeStateWritePermissionDenied"
        case .writeFailed:
            return "runtimeStateWriteFailed"
        }
    }
}

public struct RuntimeStateWriteExpectation: Equatable {
    public let revision: UInt64
    public let configGeneration: String

    public init(revision: UInt64, configGeneration: String) {
        self.revision = revision
        self.configGeneration = configGeneration
    }
}

public struct PendingUnresolvedSlot: Codable, Equatable {
    public let slot: Int
    public let spaceID: Int
    public let reason: String

    public init(slot: Int, spaceID: Int, reason: String) {
        self.slot = slot
        self.spaceID = spaceID
        self.reason = reason
    }
}

public enum PendingSwitchStatus: String, Codable, Equatable {
    case inFlight
    case recoveryRequired
}

public struct PendingSwitchTransaction: Codable, Equatable {
    public let requestID: String
    public let startedAt: String
    public let activeLayoutName: String
    public let attemptedTargetSpaceID: Int
    public let previousActiveSpaceID: Int?
    public let configGeneration: String
    public let status: PendingSwitchStatus
    public let manualRecoveryRequired: Bool
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(
        requestID: String,
        startedAt: String,
        activeLayoutName: String,
        attemptedTargetSpaceID: Int,
        previousActiveSpaceID: Int?,
        configGeneration: String,
        status: PendingSwitchStatus,
        manualRecoveryRequired: Bool = false,
        unresolvedSlots: [PendingUnresolvedSlot] = []
    ) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.activeLayoutName = activeLayoutName
        self.attemptedTargetSpaceID = attemptedTargetSpaceID
        self.previousActiveSpaceID = previousActiveSpaceID
        self.configGeneration = configGeneration
        self.status = status
        self.manualRecoveryRequired = manualRecoveryRequired
        self.unresolvedSlots = unresolvedSlots
    }
}

public struct PendingVisibilityConvergence: Codable, Equatable {
    public let requestID: String
    public let startedAt: String
    public let layoutName: String
    public let targetSpaceID: Int
    public let unresolvedSlots: [PendingUnresolvedSlot]

    public init(
        requestID: String,
        startedAt: String,
        layoutName: String,
        targetSpaceID: Int,
        unresolvedSlots: [PendingUnresolvedSlot] = []
    ) {
        self.requestID = requestID
        self.startedAt = startedAt
        self.layoutName = layoutName
        self.targetSpaceID = targetSpaceID
        self.unresolvedSlots = unresolvedSlots
    }
}

public enum PersistedTitleMatchKind: String, Codable, Equatable {
    case none
    case equals
    case contains
    case regex
}

public enum VirtualWindowVisibilityState: String, Codable, Equatable {
    case visible
    case hiddenOffscreen
}

public struct SlotEntry: Codable, Equatable {
    public let layoutName: String
    public let slot: Int
    public let layoutOriginSpaceID: Int?
    public let layoutOriginSlot: Int?
    public let source: WindowSource
    public let bundleID: String
    public let definitionFingerprint: String
    public let pid: Int?
    public let titleMatchKind: PersistedTitleMatchKind
    public let titleMatchValue: String?
    public let excludeTitleRegex: String?
    public let role: String?
    public let subrole: String?
    public let matchIndex: Int?
    public let lastKnownTitle: String?
    public let profile: String?
    public let spaceID: Int?
    public let nativeSpaceID: Int?
    public let displayID: String?
    public let windowID: UInt32?
    public let lastVisibleFrame: ResolvedFrame?
    public let lastHiddenFrame: ResolvedFrame?
    public let visibilityState: VirtualWindowVisibilityState?
    public let lastActivatedAt: String?

    public var title: String {
        lastKnownTitle ?? titleMatchValue ?? bundleID
    }

    public init(
        layoutName: String = "__legacy__",
        slot: Int,
        layoutOriginSpaceID: Int? = nil,
        layoutOriginSlot: Int? = nil,
        source: WindowSource,
        bundleID: String,
        definitionFingerprint: String = "legacy",
        pid: Int? = nil,
        titleMatchKind: PersistedTitleMatchKind = .none,
        titleMatchValue: String? = nil,
        excludeTitleRegex: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        matchIndex: Int? = nil,
        lastKnownTitle: String? = nil,
        profile: String? = nil,
        spaceID: Int?,
        nativeSpaceID: Int? = nil,
        displayID: String?,
        windowID: UInt32?,
        lastVisibleFrame: ResolvedFrame? = nil,
        lastHiddenFrame: ResolvedFrame? = nil,
        visibilityState: VirtualWindowVisibilityState? = nil,
        lastActivatedAt: String? = nil,
        title: String? = nil
    ) {
        self.layoutName = layoutName
        self.slot = slot
        self.layoutOriginSpaceID = layoutOriginSpaceID
        self.layoutOriginSlot = layoutOriginSlot
        self.source = source
        self.bundleID = bundleID
        self.definitionFingerprint = definitionFingerprint
        self.pid = pid
        self.titleMatchKind = titleMatchKind
        self.titleMatchValue = titleMatchValue
        self.excludeTitleRegex = excludeTitleRegex
        self.role = role
        self.subrole = subrole
        self.matchIndex = matchIndex
        self.lastKnownTitle = lastKnownTitle ?? title
        self.profile = profile
        self.spaceID = spaceID
        self.nativeSpaceID = nativeSpaceID ?? spaceID
        self.displayID = displayID
        self.windowID = windowID
        self.lastVisibleFrame = lastVisibleFrame
        self.lastHiddenFrame = lastHiddenFrame
        self.visibilityState = visibilityState
        self.lastActivatedAt = lastActivatedAt
    }

    public init(
        slot: Int,
        source: WindowSource,
        bundleID: String,
        title: String,
        profile: String? = nil,
        spaceID: Int?,
        displayID: String?,
        windowID: UInt32?
    ) {
        self.init(
            layoutName: "__legacy__",
            slot: slot,
            source: source,
            bundleID: bundleID,
            lastKnownTitle: title,
            profile: profile,
            spaceID: spaceID,
            nativeSpaceID: spaceID,
            displayID: displayID,
            windowID: windowID
        )
    }

    enum CodingKeys: String, CodingKey {
        case layoutName
        case slot
        case layoutOriginSpaceID
        case layoutOriginSlot
        case source
        case bundleID
        case definitionFingerprint
        case pid
        case titleMatchKind
        case titleMatchValue
        case excludeTitleRegex
        case role
        case subrole
        case matchIndex
        case lastKnownTitle
        case profile
        case spaceID
        case nativeSpaceID
        case displayID
        case windowID
        case lastVisibleFrame
        case lastHiddenFrame
        case visibilityState
        case lastActivatedAt
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layoutName = try container.decodeIfPresent(String.self, forKey: .layoutName) ?? "__legacy__"
        slot = try container.decode(Int.self, forKey: .slot)
        layoutOriginSpaceID = try container.decodeIfPresent(Int.self, forKey: .layoutOriginSpaceID)
        layoutOriginSlot = try container.decodeIfPresent(Int.self, forKey: .layoutOriginSlot)
        source = try container.decode(WindowSource.self, forKey: .source)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        definitionFingerprint = try container.decodeIfPresent(String.self, forKey: .definitionFingerprint) ?? "legacy"
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
        titleMatchKind = try container.decodeIfPresent(PersistedTitleMatchKind.self, forKey: .titleMatchKind) ?? .none
        titleMatchValue = try container.decodeIfPresent(String.self, forKey: .titleMatchValue)
        excludeTitleRegex = try container.decodeIfPresent(String.self, forKey: .excludeTitleRegex)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        subrole = try container.decodeIfPresent(String.self, forKey: .subrole)
        matchIndex = try container.decodeIfPresent(Int.self, forKey: .matchIndex)
        let legacyTitle = try container.decodeIfPresent(String.self, forKey: .title)
        lastKnownTitle = try container.decodeIfPresent(String.self, forKey: .lastKnownTitle) ?? legacyTitle
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        spaceID = try container.decodeIfPresent(Int.self, forKey: .spaceID)
        nativeSpaceID = try container.decodeIfPresent(Int.self, forKey: .nativeSpaceID) ?? spaceID
        displayID = try container.decodeIfPresent(String.self, forKey: .displayID)
        windowID = try container.decodeIfPresent(UInt32.self, forKey: .windowID)
        lastVisibleFrame = try container.decodeIfPresent(ResolvedFrame.self, forKey: .lastVisibleFrame)
        lastHiddenFrame = try container.decodeIfPresent(ResolvedFrame.self, forKey: .lastHiddenFrame)
        visibilityState = try container.decodeIfPresent(VirtualWindowVisibilityState.self, forKey: .visibilityState)
        lastActivatedAt = try container.decodeIfPresent(String.self, forKey: .lastActivatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layoutName, forKey: .layoutName)
        try container.encode(slot, forKey: .slot)
        try container.encodeIfPresent(layoutOriginSpaceID, forKey: .layoutOriginSpaceID)
        try container.encodeIfPresent(layoutOriginSlot, forKey: .layoutOriginSlot)
        try container.encode(source, forKey: .source)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(definitionFingerprint, forKey: .definitionFingerprint)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encode(titleMatchKind, forKey: .titleMatchKind)
        try container.encodeIfPresent(titleMatchValue, forKey: .titleMatchValue)
        try container.encodeIfPresent(excludeTitleRegex, forKey: .excludeTitleRegex)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(subrole, forKey: .subrole)
        try container.encodeIfPresent(matchIndex, forKey: .matchIndex)
        try container.encodeIfPresent(lastKnownTitle, forKey: .lastKnownTitle)
        try container.encodeIfPresent(profile, forKey: .profile)
        try container.encodeIfPresent(spaceID, forKey: .spaceID)
        try container.encodeIfPresent(nativeSpaceID, forKey: .nativeSpaceID)
        try container.encodeIfPresent(displayID, forKey: .displayID)
        try container.encodeIfPresent(windowID, forKey: .windowID)
        try container.encodeIfPresent(lastVisibleFrame, forKey: .lastVisibleFrame)
        try container.encodeIfPresent(lastHiddenFrame, forKey: .lastHiddenFrame)
        try container.encodeIfPresent(visibilityState, forKey: .visibilityState)
        try container.encodeIfPresent(lastActivatedAt, forKey: .lastActivatedAt)
    }
}

public struct RuntimeState: Codable, Equatable {
    public let updatedAt: String
    public let revision: UInt64
    public let stateMode: SpaceInterpretationMode
    public let configGeneration: String
    public let liveArrangeRecoveryRequired: Bool
    public let activeLayoutName: String?
    public let activeVirtualSpaceID: Int?
    public let pendingSwitchTransaction: PendingSwitchTransaction?
    public let pendingVisibilityConvergence: PendingVisibilityConvergence?
    public let slots: [SlotEntry]

    public init(
        updatedAt: String,
        revision: UInt64 = 0,
        stateMode: SpaceInterpretationMode = .native,
        configGeneration: String = "legacy",
        liveArrangeRecoveryRequired: Bool = false,
        activeLayoutName: String? = nil,
        activeVirtualSpaceID: Int? = nil,
        pendingSwitchTransaction: PendingSwitchTransaction? = nil,
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil,
        slots: [SlotEntry]
    ) {
        self.updatedAt = updatedAt
        self.revision = revision
        self.stateMode = stateMode
        self.configGeneration = configGeneration
        self.liveArrangeRecoveryRequired = liveArrangeRecoveryRequired
        self.activeLayoutName = activeLayoutName
        self.activeVirtualSpaceID = activeVirtualSpaceID
        self.pendingSwitchTransaction = pendingSwitchTransaction
        self.pendingVisibilityConvergence = pendingVisibilityConvergence
        self.slots = slots
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt
        case revision
        case stateMode
        case configGeneration
        case liveArrangeRecoveryRequired
        case activeLayoutName
        case activeVirtualSpaceID
        case pendingSwitchTransaction
        case pendingVisibilityConvergence
        case slots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? Date.rfc3339UTC()
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        stateMode = try container.decodeIfPresent(SpaceInterpretationMode.self, forKey: .stateMode) ?? .native
        configGeneration = try container.decodeIfPresent(String.self, forKey: .configGeneration) ?? "legacy"
        liveArrangeRecoveryRequired = try container.decodeIfPresent(Bool.self, forKey: .liveArrangeRecoveryRequired) ?? false
        activeLayoutName = try container.decodeIfPresent(String.self, forKey: .activeLayoutName)
        activeVirtualSpaceID = try container.decodeIfPresent(Int.self, forKey: .activeVirtualSpaceID)
        pendingSwitchTransaction = try container.decodeIfPresent(PendingSwitchTransaction.self, forKey: .pendingSwitchTransaction)
        pendingVisibilityConvergence = try container.decodeIfPresent(PendingVisibilityConvergence.self, forKey: .pendingVisibilityConvergence)
        slots = try container.decodeIfPresent([SlotEntry].self, forKey: .slots) ?? []
    }
}

public struct SlotSpaceGroup: Equatable {
    public let spaceID: Int
    public let slots: [SlotEntry]

    public init(spaceID: Int, slots: [SlotEntry]) {
        self.spaceID = spaceID
        self.slots = slots
    }
}

extension RuntimeState {
    public func with(
        updatedAt: String? = nil,
        revision: UInt64? = nil,
        stateMode: SpaceInterpretationMode? = nil,
        configGeneration: String? = nil,
        liveArrangeRecoveryRequired: Bool? = nil,
        slots: [SlotEntry]? = nil
    ) -> RuntimeState {
        RuntimeState(
            updatedAt: updatedAt ?? self.updatedAt,
            revision: revision ?? self.revision,
            stateMode: stateMode ?? self.stateMode,
            configGeneration: configGeneration ?? self.configGeneration,
            liveArrangeRecoveryRequired: liveArrangeRecoveryRequired ?? self.liveArrangeRecoveryRequired,
            activeLayoutName: activeLayoutName,
            activeVirtualSpaceID: activeVirtualSpaceID,
            pendingSwitchTransaction: pendingSwitchTransaction,
            pendingVisibilityConvergence: pendingVisibilityConvergence,
            slots: slots ?? self.slots
        )
    }

    public func withActiveVirtualContext(
        updatedAt: String? = nil,
        revision: UInt64? = nil,
        stateMode: SpaceInterpretationMode? = nil,
        configGeneration: String? = nil,
        liveArrangeRecoveryRequired: Bool? = nil,
        layoutName: String,
        spaceID: Int?,
        pendingSwitchTransaction: PendingSwitchTransaction? = nil,
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil,
        slots: [SlotEntry]? = nil
    ) -> RuntimeState {
        RuntimeState(
            updatedAt: updatedAt ?? self.updatedAt,
            revision: revision ?? self.revision,
            stateMode: stateMode ?? self.stateMode,
            configGeneration: configGeneration ?? self.configGeneration,
            liveArrangeRecoveryRequired: liveArrangeRecoveryRequired ?? self.liveArrangeRecoveryRequired,
            activeLayoutName: layoutName,
            activeVirtualSpaceID: spaceID,
            pendingSwitchTransaction: pendingSwitchTransaction,
            pendingVisibilityConvergence: pendingVisibilityConvergence,
            slots: slots ?? self.slots
        )
    }

    public func clearingActiveVirtualContext(
        updatedAt: String? = nil,
        revision: UInt64? = nil,
        stateMode: SpaceInterpretationMode? = nil,
        configGeneration: String? = nil,
        liveArrangeRecoveryRequired: Bool? = nil,
        pendingSwitchTransaction: PendingSwitchTransaction? = nil,
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil,
        slots: [SlotEntry]? = nil
    ) -> RuntimeState {
        RuntimeState(
            updatedAt: updatedAt ?? self.updatedAt,
            revision: revision ?? self.revision,
            stateMode: stateMode ?? self.stateMode,
            configGeneration: configGeneration ?? self.configGeneration,
            liveArrangeRecoveryRequired: liveArrangeRecoveryRequired ?? self.liveArrangeRecoveryRequired,
            activeLayoutName: nil,
            activeVirtualSpaceID: nil,
            pendingSwitchTransaction: pendingSwitchTransaction,
            pendingVisibilityConvergence: pendingVisibilityConvergence,
            slots: slots ?? self.slots
        )
    }

    /// Groups slot entries by spaceID (nil maps to 0), sorted by spaceID then slot number.
    public func slotsBySpace() -> [SlotSpaceGroup] {
        let grouped = Dictionary(grouping: slots) { $0.spaceID ?? 0 }
        return grouped.keys.sorted().map { spaceID in
            SlotSpaceGroup(
                spaceID: spaceID,
                slots: grouped[spaceID]!.sorted { $0.slot < $1.slot }
            )
        }
    }
}

public final class RuntimeStateStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileManager: FileManager = .default,
        stateFileURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager

        if let stateFileURL {
            fileURL = stateFileURL
        } else {
            let stateDir = ConfigPathResolver.stateDirectoryURL(environment: environment)
            fileURL = stateDir.appendingPathComponent("runtime-state.json")
        }
    }

    public func loadStrict() throws -> RuntimeState {
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                return try JSONDecoder().decode(RuntimeState.self, from: data)
            } catch {
                let backupURL = backupCorruptedStateFileIfPossible()
                throw RuntimeStateStoreError.corrupted(fileURL: fileURL, backupURL: backupURL)
            }
        } catch let error as RuntimeStateStoreError {
            throw error
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return RuntimeState(updatedAt: Date.rfc3339UTC(), slots: [])
            }
            if Self.isPermissionDenied(error) {
                throw RuntimeStateStoreError.readPermissionDenied(fileURL: fileURL)
            }
            throw RuntimeStateStoreError.readFailed(fileURL: fileURL, reason: error.localizedDescription)
        }
    }

    public func load() -> RuntimeState {
        do {
            return try loadStrict()
        } catch {
            return RuntimeState(updatedAt: Date.rfc3339UTC(), slots: [])
        }
    }

    public func saveStrict(
        state: RuntimeState,
        expecting expectation: RuntimeStateWriteExpectation? = nil
    ) throws {
        if state.configGeneration != "legacy",
           state.slots.contains(where: { $0.definitionFingerprint == "legacy" || $0.spaceID == nil })
        {
            throw RuntimeStateStoreError.writeFailed(
                fileURL: fileURL,
                reason: "legacy slot metadata cannot be saved in current generation"
            )
        }

        let normalized = state.with(
            updatedAt: Date.rfc3339UTC(),
            slots: normalizedSlots(state.slots)
        )
        let data: Data
        do {
            data = try JSONEncoder.pretty.encode(normalized)
        } catch {
            throw RuntimeStateStoreError.encodingFailed
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            if Self.isPermissionDenied(error) {
                throw RuntimeStateStoreError.writePermissionDenied(fileURL: fileURL)
            }
            throw RuntimeStateStoreError.writeFailed(fileURL: fileURL, reason: error.localizedDescription)
        }

        if let expectation {
            let currentState = try loadStrict()
            guard currentState.revision == expectation.revision,
                  currentState.configGeneration == expectation.configGeneration
            else {
                throw RuntimeStateStoreError.staleWriteRejected(
                    expectedRevision: expectation.revision,
                    actualRevision: currentState.revision,
                    expectedConfigGeneration: expectation.configGeneration,
                    actualConfigGeneration: currentState.configGeneration
                )
            }
        }

        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            if Self.isPermissionDenied(error) {
                throw RuntimeStateStoreError.writePermissionDenied(fileURL: fileURL)
            }
            throw RuntimeStateStoreError.writeFailed(fileURL: fileURL, reason: error.localizedDescription)
        }
    }

    public func save(state: RuntimeState) {
        try? saveStrict(state: state, expecting: nil)
    }

    public func saveStrict(
        slots: [SlotEntry],
        stateMode: SpaceInterpretationMode = .native,
        configGeneration: String = "legacy",
        liveArrangeRecoveryRequired: Bool = false,
        activeLayoutName: String? = nil,
        activeVirtualSpaceID: Int? = nil,
        revision: UInt64 = 0,
        pendingSwitchTransaction: PendingSwitchTransaction? = nil,
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil,
        expecting expectation: RuntimeStateWriteExpectation? = nil
    ) throws {
        try saveStrict(
            state: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: revision,
                stateMode: stateMode,
                configGeneration: configGeneration,
                liveArrangeRecoveryRequired: liveArrangeRecoveryRequired,
                activeLayoutName: activeLayoutName,
                activeVirtualSpaceID: activeVirtualSpaceID,
                pendingSwitchTransaction: pendingSwitchTransaction,
                pendingVisibilityConvergence: pendingVisibilityConvergence,
                slots: slots
            ),
            expecting: expectation
        )
    }

    public func save(
        slots: [SlotEntry],
        stateMode: SpaceInterpretationMode = .native,
        configGeneration: String = "legacy",
        liveArrangeRecoveryRequired: Bool = false,
        activeLayoutName: String? = nil,
        activeVirtualSpaceID: Int? = nil,
        revision: UInt64 = 0,
        pendingSwitchTransaction: PendingSwitchTransaction? = nil,
        pendingVisibilityConvergence: PendingVisibilityConvergence? = nil
    ) {
        try? saveStrict(
            state: RuntimeState(
                updatedAt: Date.rfc3339UTC(),
                revision: revision,
                stateMode: stateMode,
                configGeneration: configGeneration,
                liveArrangeRecoveryRequired: liveArrangeRecoveryRequired,
                activeLayoutName: activeLayoutName,
                activeVirtualSpaceID: activeVirtualSpaceID,
                pendingSwitchTransaction: pendingSwitchTransaction,
                pendingVisibilityConvergence: pendingVisibilityConvergence,
                slots: slots
            ),
            expecting: nil
        )
    }

    /// Delete the runtime state file so the next load returns a fresh state.
    public func clear() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func backupCorruptedStateFileIfPossible() -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "runtime-state.corrupt-\(Self.backupTimestamp()).json"
        )
        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == EACCES
            || nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
            || nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError
    }

    private func normalizedSlots(_ slots: [SlotEntry]) -> [SlotEntry] {
        let deduplicated = deduplicateRuntimeManagedSlots(slots)
        return deduplicated.sorted { lhs, rhs in
            if lhs.layoutName != rhs.layoutName { return lhs.layoutName < rhs.layoutName }
            if lhs.spaceID != rhs.spaceID {
                switch (lhs.spaceID, rhs.spaceID) {
                case let (.some(left), .some(right)): return left < right
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
            }
            return lhs.slot < rhs.slot
        }
    }

    private func deduplicateRuntimeManagedSlots(_ slots: [SlotEntry]) -> [SlotEntry] {
        var grouped: [String: [SlotEntry]] = [:]
        var orderedKeys: [String] = []
        var preserved: [SlotEntry] = []

        for entry in slots {
            guard Self.isRuntimeManagedVirtualWorkspaceEntry(entry) else {
                preserved.append(entry)
                continue
            }

            let key = "\(entry.layoutName)\u{0}\(entry.definitionFingerprint)"
            if grouped[key] == nil {
                orderedKeys.append(key)
            }
            grouped[key, default: []].append(entry)
        }

        let merged = orderedKeys.compactMap { key in
            grouped[key].map(mergeRuntimeManagedSlots)
        }
        return preserved + merged
    }

    private func mergeRuntimeManagedSlots(_ entries: [SlotEntry]) -> SlotEntry {
        guard let preferred = entries.max(by: isPreferredRuntimeManagedEntry) else {
            preconditionFailure("runtime-managed slot group must not be empty")
        }

        return SlotEntry(
            layoutName: preferred.layoutName,
            slot: entries.map(\.slot).min() ?? preferred.slot,
            source: preferred.source,
            bundleID: preferred.bundleID,
            definitionFingerprint: preferred.definitionFingerprint,
            pid: preferred.pid ?? entries.compactMap(\.pid).last,
            titleMatchKind: preferred.titleMatchKind,
            titleMatchValue: preferred.titleMatchValue ?? entries.compactMap(\.titleMatchValue).last,
            excludeTitleRegex: preferred.excludeTitleRegex ?? entries.compactMap(\.excludeTitleRegex).last,
            role: preferred.role ?? entries.compactMap(\.role).last,
            subrole: preferred.subrole ?? entries.compactMap(\.subrole).last,
            matchIndex: preferred.matchIndex ?? entries.compactMap(\.matchIndex).last,
            lastKnownTitle: preferred.lastKnownTitle ?? entries.compactMap(\.lastKnownTitle).last,
            profile: preferred.profile ?? entries.compactMap(\.profile).last,
            spaceID: preferred.spaceID,
            nativeSpaceID: preferred.nativeSpaceID ?? entries.compactMap(\.nativeSpaceID).last,
            displayID: preferred.displayID ?? entries.compactMap(\.displayID).last,
            windowID: preferred.windowID ?? entries.compactMap(\.windowID).last,
            lastVisibleFrame: preferred.lastVisibleFrame ?? entries.compactMap(\.lastVisibleFrame).last,
            lastHiddenFrame: preferred.lastHiddenFrame ?? entries.compactMap(\.lastHiddenFrame).last,
            visibilityState: preferred.visibilityState ?? entries.compactMap(\.visibilityState).last,
            lastActivatedAt: entries.compactMap(\.lastActivatedAt).max()
        )
    }

    private func isPreferredRuntimeManagedEntry(_ lhs: SlotEntry, _ rhs: SlotEntry) -> Bool {
        if runtimeManagedPriority(lhs) != runtimeManagedPriority(rhs) {
            return runtimeManagedPriority(lhs) < runtimeManagedPriority(rhs)
        }
        return lhs.slot > rhs.slot
    }

    private func runtimeManagedPriority(_ entry: SlotEntry) -> (Int, Int, Int, Int, String, Int) {
        let hasWindowID = entry.windowID == nil ? 0 : 1
        let visibilityRank: Int
        switch entry.visibilityState {
        case .visible:
            visibilityRank = 2
        case .hiddenOffscreen:
            visibilityRank = 1
        case nil:
            visibilityRank = 0
        }
        let hasVisibleFrame = entry.lastVisibleFrame == nil ? 0 : 1
        let hasHiddenFrame = entry.lastHiddenFrame == nil ? 0 : 1
        let activatedAt = entry.lastActivatedAt ?? ""
        return (hasWindowID, visibilityRank, hasVisibleFrame, hasHiddenFrame, activatedAt, -entry.slot)
    }

    private static func isRuntimeManagedVirtualWorkspaceEntry(_ entry: SlotEntry) -> Bool {
        entry.definitionFingerprint.hasPrefix("runtimeVirtualWorkspace\u{0}")
    }
}
