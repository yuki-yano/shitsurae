import Foundation

public final class ShitsuraeLogger {
    private let fileManager: FileManager
    public let logFileURL: URL
    private let maxFileSize: UInt64 = 10 * 1024 * 1024
    private let maxGenerations: Int = 5
    private let retentionDays: Double = 14

    public init(fileManager: FileManager = .default, logFileURL: URL? = nil) {
        self.fileManager = fileManager

        if let logFileURL {
            self.logFileURL = logFileURL
        } else {
            let home = NSHomeDirectory()
            self.logFileURL = URL(fileURLWithPath: home)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Shitsurae", isDirectory: true)
                .appendingPathComponent("shitsurae.log")
        }

        ensureDirectory()
        pruneExpiredLogs()
    }

    public func log(level: String = "info", event: String, fields: [String: Any] = [:]) {
        rotateIfNeeded()

        var payload: [String: Any] = [
            "timestamp": iso8601Now(),
            "level": level,
            "event": event,
        ]

        for (key, value) in fields {
            payload[key] = value
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }

        append(line + "\n")
    }

    private func ensureDirectory() {
        let directory = logFileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    private func append(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            return
        }
        defer { try? handle.close() }

        handle.seekToEndOfFile()
        if let data = text.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func rotateIfNeeded() {
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? UInt64,
              size >= maxFileSize
        else {
            return
        }

        for generation in stride(from: maxGenerations, through: 1, by: -1) {
            let source = logFileURL.appendingPathExtension("\(generation)")
            let destination = logFileURL.appendingPathExtension("\(generation + 1)")

            if generation == maxGenerations {
                try? fileManager.removeItem(at: source)
                continue
            }

            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        let first = logFileURL.appendingPathExtension("1")
        if fileManager.fileExists(atPath: logFileURL.path) {
            try? fileManager.moveItem(at: logFileURL, to: first)
        }

        fileManager.createFile(atPath: logFileURL.path, contents: nil)
        pruneExpiredLogs()
    }

    private func pruneExpiredLogs() {
        let directory = logFileURL.deletingLastPathComponent()
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-retentionDays * 24 * 60 * 60)

        for item in items where item.lastPathComponent.hasPrefix("shitsurae.log") {
            guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate
            else {
                continue
            }

            if modifiedAt < cutoff {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    private func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}
