import Foundation

/// Wire request. Flat optional args; per-command validation happens in the
/// router. The `command` strings are the public IPC contract.
public struct CommandRequest: Codable, Sendable {
    public var command: String
    public var layout: String?
    public var monitor: String?
    public var layouts: [String]?
    public var spaceID: Int?
    public var dryRun: Bool?
    public var stateOnly: Bool?
    public var reconcile: Bool?
    public var focus: SpaceSwitchFocusPolicy?
    public var forceClearPending: Bool?
    public var windowID: UInt32?
    public var pid: Int?
    public var processStartTime: UInt64?
    public var bundleID: String?
    public var title: String?
    public var slot: Int?
    public var x: String?
    public var y: String?
    public var width: String?
    public var height: String?
    public var includeAllSpaces: Bool?

    public init(command: String) {
        self.command = command
    }

    public var selector: WindowTargetSelector {
        WindowTargetSelector(
            windowID: windowID,
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID,
            title: title
        )
    }
}

public struct CommandResponseProbe: Codable, Sendable {
    public let ok: Bool
    public let exitCode: Int
    public let error: CommonErrorJSON?
}

/// Thin dispatch from wire requests to the engine; owns nothing but
/// references. All payloads are encoded into a uniform envelope:
/// `{"ok": Bool, "exitCode": Int, "payload": ..., "error": ...}`
public final class CommandRouter: Sendable {
    public static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    private let engine: VirtualSpaceEngine
    private let configManager: ConfigManager
    private let logger: ShitsuraeLogger

    public init(engine: VirtualSpaceEngine, configManager: ConfigManager, logger: ShitsuraeLogger) {
        self.engine = engine
        self.configManager = configManager
        self.logger = logger
    }

    public func handle(requestData: Data) async -> Data {
        let request: CommandRequest
        do {
            request = try JSONDecoder().decode(CommandRequest.self, from: requestData)
        } catch {
            return Self.encodeError(
                ShitsuraeError(.validationError, "invalid request: \(error.localizedDescription)")
            )
        }

        do {
            if Self.invalidatesPendingFocus(request) {
                engine.invalidatePendingFocusEvents()
            }
            return try await dispatch(request)
        } catch let error as ShitsuraeError {
            return Self.encodeError(error)
        } catch let error as VirtualSpaceEngineError {
            return Self.encodeError(Self.mapEngineError(error))
        } catch let error as ConfigLoadError {
            return Self.encodeError(
                ShitsuraeError(error.code, error.localizedDescription)
            )
        } catch {
            return Self.encodeError(ShitsuraeError(.validationError, String(describing: error)))
        }
    }

    static func invalidatesPendingFocus(_ request: CommandRequest) -> Bool {
        switch request.command {
        case "arrange":
            // state-only still replaces active layout/workspace state. A
            // queued follow-focus continuation captured before that write
            // must not run afterward against the new state.
            return request.dryRun != true
        case "spaceSwitch", "spaceRecover", "windowWorkspace", "windowMove",
             "windowResize", "windowSet", "focus":
            return true
        default:
            return false
        }
    }

    private func dispatch(_ request: CommandRequest) async throws -> Data {
        switch request.command {
        case "arrange":
            let layoutNames = try requireNonEmpty(request.layouts, "layouts")
            let config = try configManager.config()
            if layoutNames.count > 1 {
                guard request.dryRun != true, request.stateOnly != true, request.spaceID == nil else {
                    throw ShitsuraeError(
                        .validationError,
                        "multi-display arrange does not accept --dry-run, --state-only, or --space",
                        subcode: "invalidArrangeBatchOptions"
                    )
                }
                let result = try await engine.arrange(layoutNames: layoutNames, config: config)
                return Self.encodeSuccess(result, exitCode: result.exitCode)
            }

            let layoutName = layoutNames[0]
            if request.dryRun == true {
                let result = try await engine.arrangeDryRun(
                    layoutName: layoutName,
                    spaceID: request.spaceID,
                    config: config
                )
                return Self.encodeSuccess(result)
            }
            if request.stateOnly == true {
                let result = try await engine.arrangeStateOnly(
                    layoutName: layoutName,
                    spaceID: request.spaceID,
                    config: config
                )
                return Self.encodeSuccess(result, exitCode: result.exitCode)
            }
            let result = try await engine.arrange(
                layoutName: layoutName,
                spaceID: request.spaceID,
                config: config
            )
            return Self.encodeSuccess(result, exitCode: result.exitCode)

        case "layoutsList":
            let config = try configManager.config()
            let layouts = config.config.layouts
                .map { name, layout in
                    LayoutsListJSON.LayoutSummary(
                        name: name,
                        spaceIDs: layout.spaces.map(\.spaceID).sorted(),
                        windowCount: layout.spaces.reduce(0) { $0 + $1.windows.count }
                    )
                }
                .sorted { $0.name < $1.name }
            return Self.encodeSuccess(LayoutsListJSON(layouts: layouts))

        case "validate":
            let errors = configManager.configErrors()
            let reloaded = configManager.reload(trigger: "validate")
            let finalErrors = reloaded ? [] : (configManager.configErrors().isEmpty ? errors : configManager.configErrors())
            let result = ValidateJSON(valid: reloaded, errors: finalErrors)
            return Self.encodeSuccess(result, exitCode: reloaded ? 0 : ErrorCode.validationError.rawValue)

        case "diagnostics":
            return Self.encodeSuccess(await diagnostics())

        case "displayList":
            let displays = SystemProbe.displays().map(DisplaySummaryJSON.init(display:))
            return Self.encodeSuccess(DisplayListJSON(displays: displays))

        case "displayCurrent":
            let displays = SystemProbe.displays()
            let focused = await engine.resolveTargetWindow(selector: WindowTargetSelector())
            let display = focused?.displayID.flatMap { id in displays.first(where: { $0.id == id }) }
                ?? DisplayResolver.primaryDisplay(displays)
            guard let display else {
                throw ShitsuraeError(.targetWindowNotFound, "no display available")
            }
            return Self.encodeSuccess(DisplayCurrentJSON(display: DisplaySummaryJSON(display: display)))

        case "spaceList":
            let config = try configManager.config()
            if let layoutName = request.layout {
                return Self.encodeSuccess(try await engine.spaceList(layoutName: layoutName, config: config))
            }
            return Self.encodeSuccess(await engine.spaceList(config: config))

        case "spaceCurrent":
            let config = try configManager.config()
            if let layoutName = request.layout {
                return Self.encodeSuccess(try await engine.spaceCurrent(layoutName: layoutName, config: config))
            }
            return Self.encodeSuccess(await engine.spaceCurrent(config: config))

        case "spaceSwitch":
            let spaceID = try require(request.spaceID, "spaceID")
            if request.layout != nil, request.monitor != nil {
                throw ShitsuraeError(
                    .validationError,
                    "--layout and --monitor are mutually exclusive"
                )
            }
            let config = try configManager.config()
            let outcome: SpaceSwitchOutcome
            if let layoutName = request.layout {
                outcome = try await engine.switchSpace(
                    layoutName: layoutName,
                    to: spaceID,
                    config: config,
                    reconcile: request.reconcile ?? false,
                    focusPolicy: request.focus ?? .target
                )
            } else if let monitor = request.monitor {
                outcome = try await engine.switchSpace(
                    monitor: monitor,
                    to: spaceID,
                    config: config,
                    reconcile: request.reconcile ?? false,
                    focusPolicy: request.focus ?? .target
                )
            } else {
                outcome = try await engine.switchSpace(
                    to: spaceID,
                    config: config,
                    reconcile: request.reconcile ?? false,
                    focusPolicy: request.focus ?? .target
                )
            }
            let result = SpaceSwitchJSON(requestID: UUID().uuidString.lowercased(), outcome: outcome)
            // Visibility that did not converge (or unresolved slots) is a
            // partial success — scripts must be able to detect it.
            let converged = outcome.converged && outcome.unresolvedSlots.isEmpty
            return Self.encodeSuccess(result, exitCode: converged ? 0 : ErrorCode.partialSuccess.rawValue)

        case "spaceRecover":
            guard request.forceClearPending == true else {
                throw ShitsuraeError(.validationError, "space recover requires --force-clear-pending")
            }
            let previousLayoutName = await engine.activeLayoutName()
            let previousSpaceID = await engine.activeSpaceID()
            try await engine.clearPending()
            let result = SpaceRecoveryJSON(
                requestID: UUID().uuidString.lowercased(),
                clearedPending: true,
                previousActiveLayoutName: previousLayoutName,
                previousActiveSpaceID: previousSpaceID,
                warning: "pending state cleared; run 'shitsurae space switch <id> --reconcile' to reconcile visibility"
            )
            return Self.encodeSuccess(result)

        case "windowCurrent":
            guard let result = await engine.windowCurrent() else {
                throw ShitsuraeError(.targetWindowNotFound, "no focused window")
            }
            return Self.encodeSuccess(result)

        case "windowWorkspace":
            let spaceID = try require(request.spaceID, "spaceID")
            let config = try configManager.config()
            let result = try await engine.windowWorkspace(
                selector: try validatedSelector(request),
                toSpaceID: spaceID,
                config: config
            )
            return Self.encodeSuccess(result)

        case "windowMove":
            let config = try configManager.config()
            let result = try await engine.setWindowFrame(
                selector: try validatedSelector(request),
                x: try lengthValue(request.x, "x"),
                y: try lengthValue(request.y, "y"),
                width: nil,
                height: nil,
                config: config
            )
            return Self.encodeSuccess(result)

        case "windowResize":
            let config = try configManager.config()
            let result = try await engine.setWindowFrame(
                selector: try validatedSelector(request),
                x: nil,
                y: nil,
                width: try lengthValue(request.width, "width"),
                height: try lengthValue(request.height, "height"),
                config: config
            )
            return Self.encodeSuccess(result)

        case "windowSet":
            let config = try configManager.config()
            let result = try await engine.setWindowFrame(
                selector: try validatedSelector(request),
                x: try lengthValue(request.x, "x"),
                y: try lengthValue(request.y, "y"),
                width: try lengthValue(request.width, "width"),
                height: try lengthValue(request.height, "height"),
                config: config
            )
            return Self.encodeSuccess(result)

        case "focus":
            let config = try configManager.config()
            if let slot = request.slot {
                let result = try await engine.focusSlot(slot, config: config)
                return Self.encodeSuccess(result)
            }
            let result = try await engine.focusWindow(
                selector: try validatedSelector(request),
                config: config
            )
            return Self.encodeSuccess(result)

        case "switcherList":
            let config = try configManager.config()
            let quickKeys = config.config.resolvedShortcuts.quickKeys
            let candidates = try await engine.switcherCandidates(
                includeAllSpaces: request.includeAllSpaces ?? false,
                config: config,
                excludedApps: config.config.resolvedShortcuts.switcherExcludedApps
            )
            let withKeys = candidates.enumerated().map { index, candidate in
                SwitcherCandidate(
                    id: candidate.id,
                    title: candidate.title,
                    bundleID: candidate.bundleID,
                    pid: candidate.pid,
                    processStartTime: candidate.processStartTime,
                    profile: candidate.profile,
                    spaceID: candidate.spaceID,
                    displayID: candidate.displayID,
                    slot: candidate.slot,
                    quickKey: index < quickKeys.count
                        ? String(quickKeys[quickKeys.index(quickKeys.startIndex, offsetBy: index)])
                        : nil,
                    windowID: candidate.windowID
                )
            }
            let result = SwitcherListJSON(
                generatedAt: Date.rfc3339UTC(),
                includeAllSpaces: request.includeAllSpaces ?? false,
                candidates: withKeys
            )
            return Self.encodeSuccess(result)

        default:
            throw ShitsuraeError(.validationError, "unknown command: \(request.command)")
        }
    }

    private func validatedSelector(_ request: CommandRequest) throws -> WindowTargetSelector {
        if request.windowID != nil,
           request.pid == nil || request.processStartTime == nil || request.bundleID == nil
        {
            throw ShitsuraeError(
                .validationError,
                "windowID requires pid, processStartTime and bundleID for exact identity"
            )
        }
        if request.pid != nil, request.bundleID == nil {
            throw ShitsuraeError(.validationError, "pid requires bundleID")
        }
        if request.processStartTime != nil, request.pid == nil {
            throw ShitsuraeError(.validationError, "processStartTime requires pid")
        }
        if request.title != nil, request.bundleID == nil {
            throw ShitsuraeError(.validationError, "title requires bundleID")
        }
        return request.selector
    }

    public func diagnostics() async -> DiagnosticsJSON {
        let state = await engine.currentState
        let workspaces = await engine.workspaceSummaries()
        let config = configManager.configIfLoaded()
        return DiagnosticsJSON(
            version: Self.appVersion,
            permissions: DiagnosticsJSON.Permissions(
                accessibility: SystemProbe.accessibilityGranted(),
                screenRecording: SystemProbe.screenRecordingGranted()
            ),
            configFiles: config?.configFiles ?? [],
            configReload: configManager.reloadStatus(),
            state: DiagnosticsJSON.StateSummary(
                activeWorkspaces: workspaces,
                slotCount: state.slots.count,
                hiddenCount: state.slots.filter(\.visibilityState.isManagedHidden).count,
                recoveryRequired: state.recoveryRequired,
                pendingUnresolvedSlots: state.pendingVisibilityConvergences.flatMap(\.unresolvedSlots),
                configGeneration: state.configGeneration,
                revision: state.revision
            ),
            displays: SystemProbe.displays().map(DisplaySummaryJSON.init(display:))
        )
    }

    // MARK: - Envelope encoding

    private struct Envelope<T: Encodable>: Encodable {
        let ok: Bool
        let exitCode: Int
        let payload: T?
        let error: CommonErrorJSON?
    }

    static func encodeSuccess<T: Encodable>(_ payload: T, exitCode: Int = 0) -> Data {
        let envelope = Envelope(ok: exitCode == 0, exitCode: exitCode, payload: payload, error: nil)
        return (try? JSONEncoder.pretty.encode(envelope)) ?? Data("{\"ok\":false,\"exitCode\":11}".utf8)
    }

    static func encodeError(_ error: ShitsuraeError) -> Data {
        let envelope = Envelope<String>(
            ok: false,
            exitCode: error.code.rawValue,
            payload: nil,
            error: CommonErrorJSON(code: error.code, message: error.message, subcode: error.subcode)
        )
        return (try? JSONEncoder.pretty.encode(envelope)) ?? Data("{\"ok\":false,\"exitCode\":11}".utf8)
    }

    public static func mapEngineError(_ error: VirtualSpaceEngineError) -> ShitsuraeError {
        switch error {
        case .noActiveLayout:
            return ShitsuraeError(
                .validationError,
                "no active layout; bootstrap with 'shitsurae arrange <layout> --state-only --space <id>'",
                subcode: "noActiveLayout"
            )
        case let .layoutNotFound(name):
            return ShitsuraeError(.validationError, "layout not found: \(name)", subcode: "layoutNotFound")
        case let .spaceNotFound(layoutName, spaceID):
            return ShitsuraeError(
                .validationError,
                "spaceID \(spaceID) is not defined in layout \(layoutName)",
                subcode: "spaceNotFound"
            )
        case let .workspaceNotActive(layoutName):
            return ShitsuraeError(
                .validationError,
                "workspace is not active: \(layoutName); run 'shitsurae arrange \(layoutName)' first",
                subcode: "workspaceNotActive"
            )
        case let .invalidArrangeBatch(message):
            return ShitsuraeError(
                .validationError,
                message,
                subcode: "invalidArrangeBatch"
            )
        case .hostDisplayUnavailable:
            return ShitsuraeError(.validationError, "host display is unavailable", subcode: "hostDisplayUnavailable")
        case let .monitorNotFound(alias):
            return ShitsuraeError(
                .validationError,
                "undefined monitor alias: \(alias)",
                subcode: "monitorNotFound"
            )
        case .windowNotTracked:
            return ShitsuraeError(.targetWindowNotFound, "target window not found or not tracked")
        case .ambiguousWindow:
            return ShitsuraeError(
                .targetWindowNotFound,
                "window matches multiple tracked entries; add a discriminator",
                subcode: "ambiguousWindow"
            )
        case let .stateError(message):
            return ShitsuraeError(.spaceSwitchFailed, message)
        }
    }

    // MARK: - Argument helpers

    private func require<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else {
            throw ShitsuraeError(.validationError, "missing argument: \(name)")
        }
        return value
    }

    private func requireNonEmpty<T>(_ value: [T]?, _ name: String) throws -> [T] {
        guard let value, !value.isEmpty else {
            throw ShitsuraeError(.validationError, "missing argument: \(name)")
        }
        return value
    }

    private func lengthValue(_ raw: String?, _ name: String) throws -> LengthValue? {
        guard let raw else { return nil }
        _ = try LengthParser.parse(raw) // validate early for a clear error
        return .expression(raw)
    }
}
