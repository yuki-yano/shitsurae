import Foundation
import Darwin

public final class ConfigWatcher {
    private let directoryURL: URL
    private let debounceMs: Int
    private let configLoader: ConfigLoader
    private let onReload: (Result<LoadedConfig, ConfigLoadError>) -> Void

    private let queue = DispatchQueue(label: "com.yukiyano.shitsurae.configwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var pendingWork: DispatchWorkItem?

    public init(
        directoryURL: URL,
        debounceMs: Int,
        configLoader: ConfigLoader,
        onReload: @escaping (Result<LoadedConfig, ConfigLoadError>) -> Void
    ) {
        self.directoryURL = directoryURL
        self.debounceMs = debounceMs
        self.configLoader = configLoader
        self.onReload = onReload
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        stop()

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        directoryFD = open(directoryURL.path, O_EVTONLY)
        guard directoryFD >= 0 else {
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.directoryFD >= 0 {
                close(self.directoryFD)
                self.directoryFD = -1
            }
        }

        self.source = source
        source.resume()
        return true
    }

    public func stop() {
        pendingWork?.cancel()
        pendingWork = nil

        source?.cancel()
        source = nil

        if directoryFD >= 0 {
            close(directoryFD)
            directoryFD = -1
        }
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
}
