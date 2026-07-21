import Foundation

/// Owns the loaded config: initial load, hot reload via ConfigWatcher, and
/// the keep-last-valid policy on reload errors.
public final class ConfigManager: @unchecked Sendable {
    private let lock = NSLock()
    private let loader: ConfigLoader
    private let directoryURL: URL
    private let logger: ShitsuraeLogger
    private var watcher: ConfigWatcher?
    private var current: LoadedConfig?
    private var lastReloadStatus: ConfigReloadStatus?
    private var lastErrors: [ValidateErrorItem] = []
    /// Invoked after every reload attempt (success and failure) so UIs can
    /// surface errors, not just config changes.
    private var onChange: (@Sendable () -> Void)?

    public init(
        directoryURL: URL? = nil,
        loader: ConfigLoader = ConfigLoader(),
        logger: ShitsuraeLogger,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.loader = loader
        self.directoryURL = directoryURL ?? ConfigPathResolver.configDirectoryURL(environment: environment)
        self.logger = logger
    }

    /// Current valid config; throws when no load has ever succeeded.
    public func config() throws -> LoadedConfig {
        lock.lock()
        defer { lock.unlock() }
        guard let current else {
            throw ConfigLoadError(
                code: .validationError,
                errors: lastErrors.isEmpty
                    ? [ValidateErrorItem(code: .validationError, path: directoryURL.path, message: "config not loaded")]
                    : lastErrors
            )
        }
        return current
    }

    public func configIfLoaded() -> LoadedConfig? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func reloadStatus() -> ConfigReloadStatus? {
        lock.lock()
        defer { lock.unlock() }
        return lastReloadStatus
    }

    public func configErrors() -> [ValidateErrorItem] {
        lock.lock()
        defer { lock.unlock() }
        return lastErrors
    }

    /// Loads once and starts watching. Initial load failure is recorded but
    /// not fatal — the app keeps running and reports via diagnostics.
    public func start(onChange: (@Sendable () -> Void)? = nil) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()

        reload(trigger: "startup")

        let watcher = ConfigWatcher(
            directoryURL: directoryURL,
            configLoader: loader
        ) { [weak self] result in
            self?.handleReload(result: result, trigger: "fileChange")
        }
        watcher.start()

        lock.lock()
        self.watcher = watcher
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let watcher = watcher
        self.watcher = nil
        lock.unlock()

        // ConfigWatcher invokes its reload callback on its private queue. Do
        // not wait for that queue while holding ConfigManager's lock: a reload
        // already in flight may be waiting to enter handleReload().
        watcher?.stop()
    }

    @discardableResult
    public func reload(trigger: String) -> Bool {
        do {
            let loaded = try loader.load(from: directoryURL)
            handleReload(result: .success(loaded), trigger: trigger)
            return true
        } catch let error as ConfigLoadError {
            handleReload(result: .failure(error), trigger: trigger)
            return false
        } catch {
            handleReload(
                result: .failure(
                    ConfigLoadError(
                        code: .validationError,
                        errors: [
                            ValidateErrorItem(
                                code: .validationError,
                                path: directoryURL.path,
                                message: error.localizedDescription
                            ),
                        ]
                    )
                ),
                trigger: trigger
            )
            return false
        }
    }

    private func handleReload(result: Result<LoadedConfig, ConfigLoadError>, trigger: String) {
        switch result {
        case let .success(loaded):
            lock.lock()
            current = loaded
            lastErrors = []
            lastReloadStatus = ConfigReloadStatus(
                status: "success",
                at: Date.rfc3339UTC(),
                trigger: trigger
            )
            let callback = onChange
            lock.unlock()

            logger.log(event: "config.reload", fields: ["trigger": trigger, "status": "success"])
            callback?()

        case let .failure(error):
            lock.lock()
            lastErrors = error.errors
            lastReloadStatus = ConfigReloadStatus(
                status: "error",
                at: Date.rfc3339UTC(),
                trigger: trigger,
                errorCode: error.code.rawValue,
                message: error.localizedDescription
            )
            let callback = onChange
            lock.unlock()

            // Keep the previous valid config (do not clear `current`).
            logger.log(
                level: "error",
                event: "config.reload",
                fields: ["trigger": trigger, "status": "error", "message": error.localizedDescription]
            )
            callback?()
        }
    }
}
