import Foundation
import Darwin

public protocol ArrangeRequestDeduplicating {
    func shouldSuppress(layoutName: String, spaceID: Int?) -> Bool
}

private struct RecentArrangeRequest: Codable {
    let layoutName: String
    let spaceID: Int?
    let requestedAt: TimeInterval
}

public final class FileBasedArrangeRequestDeduplicator: ArrangeRequestDeduplicating {
    private let fileURL: URL
    private let duplicateWindowSeconds: TimeInterval
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        fileURL: URL? = nil,
        duplicateWindowSeconds: TimeInterval = 2.0,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.duplicateWindowSeconds = duplicateWindowSeconds
        self.now = now
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = ConfigPathResolver
                .stateDirectoryURL(environment: environment)
                .appendingPathComponent("recent-arrange-request.json")
        }
    }

    public func shouldSuppress(layoutName: String, spaceID: Int?) -> Bool {
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        let current = now().timeIntervalSince1970
        if let data = try? Data(contentsOf: fileURL),
           let previous = try? JSONDecoder().decode(RecentArrangeRequest.self, from: data),
           previous.layoutName == layoutName,
           previous.spaceID == spaceID,
           current - previous.requestedAt < duplicateWindowSeconds
        {
            let updated = RecentArrangeRequest(layoutName: layoutName, spaceID: spaceID, requestedAt: current)
            if let encoded = try? JSONEncoder.pretty.encode(updated) {
                try? encoded.write(to: fileURL, options: .atomic)
            }
            return true
        }

        let entry = RecentArrangeRequest(layoutName: layoutName, spaceID: spaceID, requestedAt: current)
        if let encoded = try? JSONEncoder.pretty.encode(entry) {
            try? encoded.write(to: fileURL, options: .atomic)
        }
        return false
    }
}
