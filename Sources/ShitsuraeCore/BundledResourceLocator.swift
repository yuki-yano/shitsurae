import Foundation

enum BundledResourceLocator {
    private static let resourceBundleName = "shitsurae_ShitsuraeCore.bundle"

    static func supportedBuildCatalogURL(
        mainBundle: Bundle = .main,
        fallbackURL: @escaping @autoclosure () -> URL? = Bundle.module.url(forResource: "supported-macos-builds", withExtension: "json")
    ) -> URL {
        resolveResourceURL(
            resourceName: "supported-macos-builds",
            resourceExtension: "json",
            resourceBundleName: resourceBundleName,
            searchRoots: searchRoots(for: mainBundle),
            fallbackURL: fallbackURL
        )
    }

    static func resolveResourceURL(
        resourceName: String,
        resourceExtension: String,
        resourceBundleName: String,
        searchRoots: [URL],
        fallbackURL: () -> URL?
    ) -> URL {
        if let bundledURL = bundledResourceURL(
            resourceName: resourceName,
            resourceExtension: resourceExtension,
            resourceBundleName: resourceBundleName,
            searchRoots: searchRoots
        ) {
            return bundledURL
        }

        if let fallback = fallbackURL() {
            return fallback
        }

        preconditionFailure("missing bundled resource: \(resourceName).\(resourceExtension)")
    }

    static func bundledResourceURL(
        resourceName: String,
        resourceExtension: String,
        resourceBundleName: String,
        searchRoots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for root in searchRoots {
            let candidate = root
                .appendingPathComponent(resourceBundleName, isDirectory: true)
                .appendingPathComponent("\(resourceName).\(resourceExtension)", isDirectory: false)

            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func searchRoots(for mainBundle: Bundle) -> [URL] {
        var roots: [URL] = []
        var seenPaths = Set<String>()

        func append(_ url: URL?) {
            guard let url else {
                return
            }

            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                return
            }

            roots.append(url)
        }

        append(mainBundle.resourceURL)
        append(mainBundle.bundleURL)
        append(mainBundle.executableURL?.deletingLastPathComponent())

        return roots
    }
}
