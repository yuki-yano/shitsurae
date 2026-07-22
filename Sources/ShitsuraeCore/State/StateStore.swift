import Foundation

public enum RuntimeStateStoreError: Error, Equatable {
    case corrupted(fileURL: URL, backupURL: URL?)
    case unsupportedSchema(fileURL: URL, actualVersion: Int?, expectedVersion: Int)
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
}

public struct RuntimeStateWriteExpectation: Equatable, Sendable {
    public let revision: UInt64
    public let configGeneration: String

    public init(revision: UInt64, configGeneration: String) {
        self.revision = revision
        self.configGeneration = configGeneration
    }
}

/// JSON persistence for RuntimeState at
/// `~/.local/state/shitsurae/runtime-state.json`.
///
/// Single-writer by design: only the GUI app's engine actor writes. The
/// revision/configGeneration expectation is kept as a tripwire against
/// external modification, not as a cross-process lock.
///
/// State loading is fail-closed: an unreadable, corrupt, or unsupported file is
/// never converted into an empty state because it may be the only record of
/// windows currently parked offscreen.
public final class RuntimeStateStore: @unchecked Sendable {
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
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                return RuntimeState()
            }
            if Self.isPermissionDenied(error) {
                throw RuntimeStateStoreError.readPermissionDenied(fileURL: fileURL)
            }
            throw RuntimeStateStoreError.readFailed(fileURL: fileURL, reason: error.localizedDescription)
        }

        struct SchemaProbe: Decodable {
            let schemaVersion: Int?
        }

        let probe: SchemaProbe
        do {
            probe = try JSONDecoder().decode(SchemaProbe.self, from: data)
        } catch {
            let backupURL = copyStateFile(label: "corrupt")
            throw RuntimeStateStoreError.corrupted(fileURL: fileURL, backupURL: backupURL)
        }

        guard probe.schemaVersion == RuntimeState.currentSchemaVersion else {
            throw RuntimeStateStoreError.unsupportedSchema(
                fileURL: fileURL,
                actualVersion: probe.schemaVersion,
                expectedVersion: RuntimeState.currentSchemaVersion
            )
        }

        do {
            return try JSONDecoder().decode(RuntimeState.self, from: data).canonicalized()
        } catch {
            let backupURL = copyStateFile(label: "corrupt")
            throw RuntimeStateStoreError.corrupted(fileURL: fileURL, backupURL: backupURL)
        }
    }

    @discardableResult
    public func saveStrict(
        state: RuntimeState,
        expecting expectation: RuntimeStateWriteExpectation? = nil
    ) throws -> RuntimeState {
        var normalized = state.canonicalized()
        normalized.schemaVersion = RuntimeState.currentSchemaVersion
        normalized.updatedAt = Date.rfc3339UTC()

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
        return normalized
    }

    public func save(state: RuntimeState) {
        _ = try? saveStrict(state: state, expecting: nil)
    }

    /// Delete the runtime state file so the next load returns a fresh state.
    public func clear() {
        try? fileManager.removeItem(at: fileURL)
    }

    static func sortedSlots(_ slots: [SlotEntry]) -> [SlotEntry] {
        RuntimeState(slots: slots).canonicalized().slots
    }

    private func copyStateFile(label: String) -> URL? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "runtime-state.\(label)-\(Self.backupTimestamp()).json"
        )
        do {
            try fileManager.copyItem(at: fileURL, to: backupURL)
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
}
