import Foundation

public struct SlotEntry: Codable, Equatable {
    public let slot: Int
    public let source: WindowSource
    public let bundleID: String
    public let title: String
    public let spaceID: Int?
    public let displayID: String?
    public let windowID: UInt32?
}

public struct RuntimeState: Codable, Equatable {
    public let updatedAt: String
    public let slots: [SlotEntry]
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

    public func load() -> RuntimeState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: data)
        else {
            return RuntimeState(updatedAt: Date.rfc3339UTC(), slots: [])
        }

        return state
    }

    public func save(slots: [SlotEntry]) {
        let state = RuntimeState(updatedAt: Date.rfc3339UTC(), slots: slots.sorted { $0.slot < $1.slot })
        guard let data = try? JSONEncoder.pretty.encode(state) else {
            return
        }

        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }
}
