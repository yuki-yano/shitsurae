import Foundation

public enum ChromiumProfileSupport {
    private static let applicationSupportSubpaths: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "org.chromium.Chromium": "Chromium",
        "com.microsoft.edgemac": "Microsoft Edge",
    ]

    public static func supports(bundleID: String) -> Bool {
        applicationSupportSubpaths[bundleID] != nil
    }

    public static func launchArguments(profileDirectory: String) -> [String] {
        ["--profile-directory=\(profileDirectory)", "--new-window", "about:blank"]
    }

    public static func lsofArguments(pid: Int) -> [String] {
        ["-Fn", "-p", String(pid)]
    }

    static func applicationSupportDirectory(
        bundleID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        guard let subpath = applicationSupportSubpaths[bundleID] else {
            return nil
        }

        return homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent(subpath)
    }

    static func localStateURL(
        bundleID: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        applicationSupportDirectory(bundleID: bundleID, homeDirectory: homeDirectory)?
            .appendingPathComponent("Local State")
    }

    public static func resolveUnambiguousProfileDirectory(
        bundleID: String,
        lsofOutput: String,
        localStateData: Data?
    ) -> String? {
        guard let supportDirectoryMarker = supportDirectoryMarker(bundleID: bundleID) else {
            return nil
        }

        var observed = observedProfileDirectories(
            lsofOutput: lsofOutput,
            supportDirectoryMarker: supportDirectoryMarker
        )
        observed.remove("System Profile")

        if let localStateData {
            let known = knownProfileDirectories(localStateData: localStateData)
            if !known.isEmpty {
                observed = observed.intersection(known)
            }
        }

        guard observed.count == 1 else {
            return nil
        }

        return observed.first
    }

    static func observedProfileDirectories(
        lsofOutput: String,
        supportDirectoryMarker: String
    ) -> Set<String> {
        let prefix = supportDirectoryMarker + "/"

        return Set(
            lsofOutput
                .split(separator: "\n")
                .compactMap { line -> String? in
                    guard let range = line.range(of: prefix) else {
                        return nil
                    }

                    let suffix = line[range.upperBound...]
                    guard let slash = suffix.firstIndex(of: "/") else {
                        return nil
                    }

                    let candidate = String(suffix[..<slash])
                    return candidate.isEmpty ? nil : candidate
                }
        )
    }

    static func knownProfileDirectories(localStateData: Data) -> Set<String> {
        guard let root = try? JSONSerialization.jsonObject(with: localStateData) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let infoCache = profile["info_cache"] as? [String: Any]
        else {
            return []
        }

        return Set(infoCache.keys)
    }

    private static func supportDirectoryMarker(bundleID: String) -> String? {
        applicationSupportSubpaths[bundleID].map { "Library/Application Support/\($0)" }
    }
}
