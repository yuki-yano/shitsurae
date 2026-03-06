import Foundation

public struct DiagnosticsJSON: Codable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let permissions: PermissionsStatus
    public let spacesMode: SpacesMode
    public let spacesModeCompatibility: SpacesModeCompatibility
    public let eventTap: EventTapStatus
    public let backend: BackendStatus
    public let configFiles: [ConfigFileStatus]
    public let layouts: [String]
    public let spaces: [SpaceStatus]
    public let lastConfigReload: ConfigReloadStatus
    public let watch: WatchStatus
    public let recentErrors: [RecentError]
}

public struct PermissionsStatus: Codable {
    public let accessibility: PermissionItem
    public let automation: PermissionItem
    public let screenRecording: PermissionItem
}

public struct PermissionItem: Codable {
    public let granted: Bool
    public let required: Bool
}

public struct SpacesModeCompatibility: Codable {
    public let matches: Bool
    public let expected: SpacesMode
    public let actual: SpacesMode?
    public let reason: String?
}

public struct EventTapStatus: Codable {
    public let enabled: Bool
    public let reason: String?

    public init(enabled: Bool, reason: String?) {
        self.enabled = enabled
        self.reason = reason
    }
}

public struct BackendStatus: Codable {
    public let initialized: Bool
    public let name: String
    public let reason: String?
}

public struct SpaceStatus: Codable {
    public let spaceID: Int
    public let displayID: String
    public let monitorRole: MonitorRole?
}

public struct WatchStatus: Codable {
    public let debounceMs: Int
    public let watcherRunning: Bool
}

public struct RecentError: Codable {
    public let at: String
    public let code: Int
    public let summary: String
}

public final class RecentErrorStore: @unchecked Sendable {
    public static let shared = RecentErrorStore()

    private let lock = NSLock()
    private var items: [RecentError] = []

    public func record(_ code: ErrorCode, summary: String) {
        lock.lock()
        defer { lock.unlock() }

        let item = RecentError(at: Date.rfc3339UTC(), code: code.rawValue, summary: summary)
        items.insert(item, at: 0)
        if items.count > 50 {
            items = Array(items.prefix(50))
        }
    }

    public func list() -> [RecentError] {
        lock.lock()
        defer { lock.unlock() }

        return items
            .sorted {
                if $0.at != $1.at { return $0.at > $1.at }
                if $0.code != $1.code { return $0.code < $1.code }
                return $0.summary < $1.summary
            }
    }
}

public enum DiagnosticsService {
    public static func collect(
        loadedConfig: LoadedConfig?,
        loadError: ConfigLoadError?,
        lastConfigReload: ConfigReloadStatus,
        supportedBuildCatalogURL: URL,
        watchOverride: WatchStatus? = nil
    ) -> DiagnosticsJSON {
        let expectedSpacesMode = loadedConfig?.config.resolvedSpacesMode ?? .perDisplay
        let actualSpacesMode = SystemProbe.actualSpacesMode()
        let mismatchReason: String?
        if let actualSpacesMode {
            mismatchReason = actualSpacesMode == expectedSpacesMode ? nil : "spacesModeMismatch"
        } else {
            mismatchReason = "actualSpacesModeUnavailable"
        }
        let spacesModeCompatibility = SpacesModeCompatibility(
            matches: actualSpacesMode.map { $0 == expectedSpacesMode } ?? false,
            expected: expectedSpacesMode,
            actual: actualSpacesMode,
            reason: mismatchReason
        )

        let eventTap = EventTapRuntimeStatusStore.shared.get()
            ?? EventTapStatus(
                enabled: false,
                reason: "runtimeStatusUnavailable"
            )

        let backendAvailability = SystemProbe.supportedBackendAvailable(catalogURL: supportedBuildCatalogURL)
        let backend = BackendStatus(
            initialized: backendAvailability.0,
            name: "skyLight",
            reason: backendAvailability.1
        )

        let configFiles = loadedConfig?.configFiles
            ?? loadError?.errors.map {
                ConfigFileStatus(
                    path: $0.path,
                    loaded: false,
                    errorCode: $0.code,
                    message: $0.message
                )
            }
            ?? []

        let spaces = collectSpaces(config: loadedConfig?.config)
        let layouts = loadedConfig.map { Array($0.config.layouts.keys).sorted() } ?? []

        let watch = watchOverride ?? WatchStatus(
            debounceMs: 250,
            watcherRunning: false
        )

        return DiagnosticsJSON(
            schemaVersion: 1,
            generatedAt: Date.rfc3339UTC(),
            permissions: PermissionsStatus(
                accessibility: PermissionItem(granted: SystemProbe.accessibilityGranted(), required: true),
                automation: PermissionItem(granted: false, required: false),
                screenRecording: PermissionItem(
                    granted: SystemProbe.screenRecordingGranted(),
                    required: loadedConfig?.config.overlay?.showThumbnails == true
                )
            ),
            spacesMode: expectedSpacesMode,
            spacesModeCompatibility: spacesModeCompatibility,
            eventTap: eventTap,
            backend: backend,
            configFiles: configFiles.sorted { $0.path < $1.path },
            layouts: layouts,
            spaces: spaces.sorted {
                if $0.displayID != $1.displayID { return $0.displayID < $1.displayID }
                return $0.spaceID < $1.spaceID
            },
            lastConfigReload: lastConfigReload,
            watch: watch,
            recentErrors: RecentErrorStore.shared.list()
        )
    }

    private static func collectSpaces(config: ShitsuraeConfig?) -> [SpaceStatus] {
        guard let config else { return [] }

        let defaultDisplayID = SystemProbe.displays().first?.id ?? "unknown"
        var result: [SpaceStatus] = []

        for (_, layout) in config.layouts {
            for space in layout.spaces {
                let displayID = space.display?.id ?? defaultDisplayID
                result.append(
                    SpaceStatus(
                        spaceID: space.spaceID,
                        displayID: displayID,
                        monitorRole: space.display?.monitor
                    )
                )
            }
        }

        return result
    }
}
