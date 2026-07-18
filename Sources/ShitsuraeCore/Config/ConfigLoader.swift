import CryptoKit
import Foundation
import Yams

public struct ConfigLoadError: Error, LocalizedError, Sendable {
    public let code: ErrorCode
    public let errors: [ValidateErrorItem]

    public init(code: ErrorCode, errors: [ValidateErrorItem]) {
        self.code = code
        self.errors = errors
    }

    public var errorDescription: String? {
        guard !errors.isEmpty else {
            return "Failed to load config."
        }

        let messages = errors.map { error in
            let location: String
            switch (error.line, error.column) {
            case let (.some(line), .some(column)):
                location = "\(error.path):\(line):\(column)"
            case let (.some(line), .none):
                location = "\(error.path):\(line)"
            default:
                location = error.path
            }
            return "\(location): \(error.message)"
        }

        if messages.count == 1 {
            return messages[0]
        }

        return (["Failed to load config:"] + messages.map { "- \($0)" }).joined(separator: "\n")
    }
}

public final class ConfigLoader: @unchecked Sendable {
    // FileManager is documented thread-safe; @unchecked silences the formal
    // Sendable gap.
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func loadFromDefaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LoadedConfig {
        let directoryURL = ConfigPathResolver.configDirectoryURL(environment: environment)
        return try load(from: directoryURL)
    }

    public func load(from directoryURL: URL) throws -> LoadedConfig {
        let files = try ConfigPathResolver.discoverConfigFiles(in: directoryURL, fileManager: fileManager)

        guard !files.isEmpty else {
            let error = ValidateErrorItem(
                code: .validationError,
                path: directoryURL.path,
                message: "no YAML config files found"
            )
            throw ConfigLoadError(code: .validationError, errors: [error])
        }

        var statuses: [ConfigFileStatus] = []
        var parseErrors: [ValidateErrorItem] = []
        var decoded: [(URL, ShitsuraeConfigFile)] = []

        for file in files {
            do {
                let yaml = try String(contentsOf: file, encoding: .utf8)
                if let node = try compose(yaml: yaml) {
                    let schemaErrors = ConfigSchemaValidator.validate(
                        node: node,
                        sourcePath: file.path
                    )
                    if !schemaErrors.isEmpty {
                        parseErrors.append(contentsOf: schemaErrors)
                        statuses.append(
                            ConfigFileStatus(
                                path: file.path,
                                loaded: false,
                                errorCode: ErrorCode.validationError.rawValue,
                                message: schemaErrors.map(\.message).joined(separator: "; ")
                            )
                        )
                        continue
                    }
                }
                let parsed = try YAMLDecoder().decode(ShitsuraeConfigFile.self, from: yaml)
                decoded.append((file, parsed))
                statuses.append(ConfigFileStatus(path: file.path, loaded: true, errorCode: nil, message: nil))
            } catch let error as ShitsuraeError {
                // Removed-key errors (mode.space / executionPolicy) surface as
                // validation errors with the file path attached.
                let validateError = ValidateErrorItem(
                    code: error.code,
                    path: file.path,
                    message: error.message
                )
                parseErrors.append(validateError)
                statuses.append(
                    ConfigFileStatus(
                        path: file.path,
                        loaded: false,
                        errorCode: error.code.rawValue,
                        message: error.message
                    )
                )
            } catch {
                // Yams wraps Decodable errors; unwrap removed-key errors too.
                if let shitsuraeError = Self.unwrapShitsuraeError(error) {
                    let validateError = ValidateErrorItem(
                        code: shitsuraeError.code,
                        path: file.path,
                        message: shitsuraeError.message
                    )
                    parseErrors.append(validateError)
                    statuses.append(
                        ConfigFileStatus(
                            path: file.path,
                            loaded: false,
                            errorCode: shitsuraeError.code.rawValue,
                            message: shitsuraeError.message
                        )
                    )
                    continue
                }

                let (line, column) = Self.extractLineColumn(from: String(describing: error))
                let validateError = ValidateErrorItem(
                    code: .invalidYAMLSyntax,
                    path: file.path,
                    line: line,
                    column: column,
                    message: "invalid YAML syntax: \(error.localizedDescription)"
                )
                parseErrors.append(validateError)
                statuses.append(
                    ConfigFileStatus(
                        path: file.path,
                        loaded: false,
                        errorCode: ErrorCode.invalidYAMLSyntax.rawValue,
                        message: validateError.message
                    )
                )
            }
        }

        if !parseErrors.isEmpty {
            throw ConfigLoadError(code: Self.prioritize(errors: parseErrors), errors: parseErrors.sorted(by: Self.sortErrors))
        }

        let mergeResult = merge(decodedFiles: decoded)
        if !mergeResult.errors.isEmpty {
            let code = Self.prioritize(errors: mergeResult.errors)
            throw ConfigLoadError(code: code, errors: mergeResult.errors.sorted(by: Self.sortErrors))
        }

        let config = mergeResult.config!
        let validationErrors = ConfigValidator.validate(config: config, sourcePath: directoryURL.path)
        if !validationErrors.isEmpty {
            let code = Self.prioritize(errors: validationErrors)
            throw ConfigLoadError(code: code, errors: validationErrors)
        }

        return LoadedConfig(
            config: config,
            configFiles: statuses.sorted { $0.path < $1.path },
            directoryURL: directoryURL,
            configGeneration: Self.makeConfigGeneration(from: files)
        )
    }

    private func merge(decodedFiles: [(URL, ShitsuraeConfigFile)]) -> (config: ShitsuraeConfig?, errors: [ValidateErrorItem]) {
        var app: AppDefinition?
        var ignore: IgnoreDefinition?
        var overlay: OverlayDefinition?
        var monitors: MonitorsDefinition?
        var shortcuts: ShortcutsDefinition?
        var mode: ModeDefinition?
        var layouts: [String: LayoutDefinition] = [:]
        var errors: [ValidateErrorItem] = []

        var singletonDefinedBy: [String: String] = [:]

        for (fileURL, item) in decodedFiles {
            let path = fileURL.path

            func assignSingleton<T: Equatable>(_ key: String, _ value: T?, _ destination: inout T?) {
                guard let value else { return }
                if singletonDefinedBy[key] != nil {
                    errors.append(
                        ValidateErrorItem(
                            code: .configMergeConflict,
                            path: path,
                            message: "\(key) is defined in multiple files"
                        )
                    )
                    return
                }
                singletonDefinedBy[key] = path
                destination = value
            }

            assignSingleton("app", item.app, &app)
            assignSingleton("overlay", item.overlay, &overlay)
            assignSingleton("monitors", item.monitors, &monitors)
            assignSingleton("shortcuts", item.shortcuts, &shortcuts)
            assignSingleton("mode", item.mode, &mode)

            ignore = mergeIgnore(left: ignore, right: item.ignore)

            if let fileLayouts = item.layouts {
                for (name, definition) in fileLayouts {
                    if layouts[name] != nil {
                        errors.append(
                            ValidateErrorItem(
                                code: .configMergeConflict,
                                path: path,
                                message: "layout '\(name)' is defined in multiple files"
                            )
                        )
                    } else {
                        layouts[name] = definition
                    }
                }
            }
        }

        guard errors.isEmpty else {
            return (nil, errors)
        }

        let config = ShitsuraeConfig(
            app: app,
            ignore: ignore,
            overlay: overlay,
            monitors: monitors,
            layouts: layouts,
            shortcuts: shortcuts,
            mode: mode
        )

        return (config, [])
    }

    private func mergeIgnore(left: IgnoreDefinition?, right: IgnoreDefinition?) -> IgnoreDefinition? {
        guard left != nil || right != nil else { return nil }

        let apply = mergeRuleSet(left?.apply, right?.apply)
        let focus = mergeRuleSet(left?.focus, right?.focus)
        return IgnoreDefinition(apply: apply, focus: focus)
    }

    private func mergeRuleSet(_ left: IgnoreRuleSet?, _ right: IgnoreRuleSet?) -> IgnoreRuleSet? {
        guard left != nil || right != nil else { return nil }

        var apps: [String] = []
        var appSet = Set<String>()
        for source in [left?.apps ?? [], right?.apps ?? []] {
            for app in source where !appSet.contains(app) {
                appSet.insert(app)
                apps.append(app)
            }
        }

        let windows = (left?.windows ?? []) + (right?.windows ?? [])

        return IgnoreRuleSet(
            apps: apps.isEmpty ? nil : apps,
            windows: windows.isEmpty ? nil : windows
        )
    }

    private static func unwrapShitsuraeError(_ error: Error) -> ShitsuraeError? {
        if let direct = error as? ShitsuraeError {
            return direct
        }
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case let .dataCorrupted(context):
                return context.underlyingError as? ShitsuraeError
            case let .keyNotFound(_, context),
                 let .typeMismatch(_, context),
                 let .valueNotFound(_, context):
                return context.underlyingError as? ShitsuraeError
            @unknown default:
                return nil
            }
        }
        // Yams surfaces underlying errors via its own wrapper whose
        // description embeds the message; fall back to string probing.
        let text = String(describing: error)
        if text.contains("removedConfigKey") {
            if text.contains("mode.space") {
                return ShitsuraeError(
                    .validationError,
                    "mode.space was removed in v2 (always virtual); delete the mode.space key",
                    subcode: "removedConfigKey"
                )
            }
            if text.contains("executionPolicy") {
                return ShitsuraeError(
                    .validationError,
                    "executionPolicy was removed in v2 (Mission Control support was dropped); delete the executionPolicy section",
                    subcode: "removedConfigKey"
                )
            }
        }
        return nil
    }

    private static func prioritize(errors: [ValidateErrorItem]) -> ErrorCode {
        if errors.contains(where: { $0.code == ErrorCode.invalidYAMLSyntax.rawValue }) {
            return .invalidYAMLSyntax
        }
        if errors.contains(where: { $0.code == ErrorCode.configMergeConflict.rawValue }) {
            return .configMergeConflict
        }
        if errors.contains(where: { $0.code == ErrorCode.slotConflict.rawValue }) {
            return .slotConflict
        }
        return .validationError
    }

    private static func extractLineColumn(from text: String) -> (Int?, Int?) {
        let pattern = #"line\s+(\d+),\s*column\s+(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (nil, nil)
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return (nil, nil)
        }

        let line = Int(nsText.substring(with: match.range(at: 1)))
        let column = Int(nsText.substring(with: match.range(at: 2)))
        return (line, column)
    }

    private static func sortErrors(_ lhs: ValidateErrorItem, _ rhs: ValidateErrorItem) -> Bool {
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        if lhs.line != rhs.line {
            switch (lhs.line, rhs.line) {
            case let (.some(left), .some(right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }
        if lhs.column != rhs.column {
            switch (lhs.column, rhs.column) {
            case let (.some(left), .some(right)): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }
        return lhs.code < rhs.code
    }

    private static func makeConfigGeneration(from files: [URL]) -> String {
        let sortedFiles = files.sorted { $0.path < $1.path }
        var bytes = Data()

        for file in sortedFiles {
            let resolvedPath = file.resolvingSymlinksInPath().path
            bytes.append(Data(resolvedPath.utf8))
            bytes.append(0)
            if let contents = try? Data(contentsOf: file) {
                bytes.append(contents)
            }
        }

        let digest = SHA256.hash(data: bytes)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
