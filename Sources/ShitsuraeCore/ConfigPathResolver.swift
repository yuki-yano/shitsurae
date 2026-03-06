import Foundation

public enum ConfigPathResolver {
    public static func configDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("shitsurae", isDirectory: true)
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("shitsurae", isDirectory: true)
    }

    public static func stateDirectoryURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let xdg = environment["XDG_STATE_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("shitsurae", isDirectory: true)
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("shitsurae", isDirectory: true)
    }

    public static func discoverConfigFiles(in directoryURL: URL, fileManager: FileManager = .default) throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "yml" || ext == "yaml"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
