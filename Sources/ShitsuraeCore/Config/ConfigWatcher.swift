import Darwin
import Foundation

/// Watches the config directory via kqueue and reloads after a debounce.
/// On reload failure the previous valid config is kept by the caller.
public final class ConfigWatcher: @unchecked Sendable {
    private let directoryURL: URL
    private let debounceMs: Int
    private let configLoader: ConfigLoader
    private let onReload: (Result<LoadedConfig, ConfigLoadError>) -> Void

    private let queue = DispatchQueue(label: "shitsurae.config-watcher")
    private let queueKey = DispatchSpecificKey<Void>()
    private var source: DispatchSourceFileSystemObject?
    private var pendingWork: DispatchWorkItem?
    private var pendingRearm: DispatchWorkItem?
    private var running = false

    public init(
        directoryURL: URL,
        debounceMs: Int = 300,
        configLoader: ConfigLoader = ConfigLoader(),
        onReload: @escaping (Result<LoadedConfig, ConfigLoadError>) -> Void
    ) {
        self.directoryURL = directoryURL
        self.debounceMs = debounceMs
        self.configLoader = configLoader
        self.onReload = onReload
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        performOnQueue {
            stopLocked()
            running = true
            try? FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return installSourceLocked()
        }
    }

    public func stop() {
        performOnQueue {
            stopLocked()
        }
    }

    private func installSourceLocked() -> Bool {
        let directoryFD = open(directoryURL.path, O_EVTONLY)
        guard directoryFD >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            self.scheduleReload()
            if !events.intersection([.rename, .delete]).isEmpty {
                self.rearmDirectoryWatchLocked()
            }
        }

        source.setCancelHandler {
            close(directoryFD)
        }

        self.source = source
        source.resume()
        return true
    }

    private func stopLocked() {
        running = false
        pendingWork?.cancel()
        pendingWork = nil
        pendingRearm?.cancel()
        pendingRearm = nil

        source?.cancel()
        source = nil
    }

    private func rearmDirectoryWatchLocked() {
        source?.cancel()
        source = nil
        pendingRearm?.cancel()

        guard running else { return }
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        if installSourceLocked() {
            pendingRearm = nil
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.rearmDirectoryWatchLocked()
        }
        pendingRearm = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func scheduleReload() {
        pendingWork?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }

            do {
                let loaded = try self.configLoader.load(from: self.directoryURL)
                self.onReload(.success(loaded))
            } catch let error as ConfigLoadError {
                self.onReload(.failure(error))
            } catch {
                let fallback = ConfigLoadError(
                    code: .validationError,
                    errors: [
                        ValidateErrorItem(
                            code: .validationError,
                            path: self.directoryURL.path,
                            message: error.localizedDescription
                        ),
                    ]
                )
                self.onReload(.failure(fallback))
            }
        }

        pendingWork = work
        let delay = DispatchTime.now() + .milliseconds(debounceMs)
        queue.asyncAfter(deadline: delay, execute: work)
    }

    private func performOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }
}
