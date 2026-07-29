import ArgumentParser
import Foundation
import ShitsuraeCore

// Thin client: every subcommand serializes a CommandRequest, sends it to the
// GUI app over the unix socket (auto-launching the app when needed), and
// prints the payload. The CLI holds no window-management logic.

func executeRemote(_ request: CommandRequest, json: Bool) -> Never {
    do {
        let responseData = try CommandClient.send(request: request)
        let probe = try JSONDecoder().decode(CommandResponseProbe.self, from: responseData)

        if let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] {
            if let error = object["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "unknown error"
                if json {
                    printJSONFragment(error)
                } else {
                    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
                }
            } else if let payload = object["payload"] {
                if json {
                    printJSONFragment(payload)
                } else {
                    printHumanReadable(payload)
                }
            }
        }

        exit(Int32(probe.exitCode))
    } catch CommandClientError.serverUnavailable {
        writeFormattedError(
            code: .backendUnavailable,
            message: "Shitsurae.app is not reachable (launch failed?)",
            json: json
        )
        exit(Int32(ErrorCode.backendUnavailable.rawValue))
    } catch {
        writeFormattedError(
            code: .ipcCommunicationError,
            message: String(describing: error),
            json: json
        )
        exit(Int32(ErrorCode.ipcCommunicationError.rawValue))
    }
}

func writeFormattedError(code: ErrorCode, message: String, json: Bool) {
    let output = CLIOutputFormatter.error(code: code, message: message, json: json)
    FileHandle.standardOutput.write(output.standardOutput)
    FileHandle.standardError.write(output.standardError)
}

func printJSONFragment(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object) || object is [Any],
          let data = try? JSONSerialization.data(
              withJSONObject: object,
              options: [.prettyPrinted, .sortedKeys]
          )
    else {
        print(object)
        return
    }
    print(String(data: data, encoding: .utf8) ?? "")
}

func printHumanReadable(_ payload: Any) {
    guard let dictionary = payload as? [String: Any] else {
        print(payload)
        return
    }

    if let result = dictionary["result"] as? String,
       let layouts = dictionary["layouts"] as? [[String: Any]],
       layouts.allSatisfy({ $0["layout"] is String && $0["result"] is String })
    {
        print("result: \(result)")
        for layout in layouts {
            print("\(layout["layout"] ?? "?")\tresult=\(layout["result"] ?? "?")")
        }
        return
    }

    if let result = dictionary["result"] as? String {
        print("result: \(result)")
        if let unresolved = dictionary["unresolvedSlots"] as? [[String: Any]], !unresolved.isEmpty {
            for slot in unresolved {
                print("unresolved: spaceID=\(slot["spaceID"] ?? "?") slot=\(slot["slot"] ?? "?") reason=\(slot["reason"] ?? "?")")
            }
        }
        return
    }

    if let layouts = dictionary["layouts"] as? [[String: Any]] {
        for layout in layouts {
            let name = layout["name"] as? String ?? "?"
            let spaces = (layout["spaceIDs"] as? [Int])?.map(String.init).joined(separator: ",") ?? ""
            print("\(name)\tspaces=[\(spaces)]\twindows=\(layout["windowCount"] ?? 0)")
        }
        return
    }

    if let candidates = dictionary["candidates"] as? [[String: Any]] {
        for candidate in candidates {
            let quickKey = candidate["quickKey"] as? String ?? " "
            let title = candidate["title"] as? String ?? ""
            let bundleID = candidate["bundleID"] as? String ?? ""
            let spaceID = candidate["spaceID"].map { "\($0)" } ?? "-"
            print("[\(quickKey)] \(title)\t\(bundleID)\tspace=\(spaceID)")
        }
        return
    }

    printJSONFragment(dictionary)
}

struct JSONFlag: ParsableArguments {
    @Flag(name: .customLong("json"), help: "Output machine-readable JSON")
    var json = false
}

struct WindowSelectorOptions: ParsableArguments {
    @Option(name: .customLong("window-id"), help: "Target window ID")
    var windowID: UInt32?

    @Option(name: .customLong("pid"), help: "Target process ID (required with --window-id)")
    var pid: Int?

    @Option(name: .customLong("process-start-time"), help: "Target process generation (required with --window-id)")
    var processStartTime: UInt64?

    @Option(name: .customLong("bundle-id"), help: "Target application bundle ID")
    var bundleID: String?

    @Option(name: .customLong("title"), help: "Window title substring (with --bundle-id)")
    var title: String?

    var value: CLIWindowSelector {
        CLIWindowSelector(
            windowID: windowID,
            pid: pid,
            processStartTime: processStartTime,
            bundleID: bundleID,
            title: title
        )
    }
}

struct ShitsuraeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shitsurae",
        abstract: "Virtual desktop window manager for macOS",
        version: ShitsuraeCLIVersion.current,
        subcommands: [
            Arrange.self,
            Layouts.self,
            Validate.self,
            Diagnostics.self,
            Display.self,
            Space.self,
            Window.self,
            Focus.self,
            Switcher.self,
        ]
    )
}

struct Arrange: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Apply one or more display layouts")

    @Argument(help: "Layout names; multiple names are applied as one logical batch")
    var layouts: [String] = []

    @Flag(name: .customLong("dry-run"), help: "Show the plan without applying")
    var dryRun = false

    @Flag(name: .customLong("state-only"), help: "Update runtime state only")
    var stateOnly = false

    @Option(name: .customLong("space"), help: "Apply only this virtual space")
    var space: Int?

    @OptionGroup var jsonFlag: JSONFlag

    func validate() throws {
        guard !layouts.isEmpty else {
            throw ValidationError("at least one layout name is required")
        }
        if layouts.count > 1, dryRun || stateOnly || space != nil {
            throw ValidationError(
                "multi-display arrange does not accept --dry-run, --state-only, or --space"
            )
        }
    }

    func run() throws {
        let request = CLIRequestBuilder.arrange(
            layouts: layouts,
            dryRun: dryRun,
            stateOnly: stateOnly,
            spaceID: space
        )
        executeRemote(request, json: jsonFlag.json)
    }
}

struct Layouts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Layout operations",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List defined layouts")

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "layoutsList"), json: jsonFlag.json)
        }
    }
}

struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Validate config files")

    @OptionGroup var jsonFlag: JSONFlag

    func run() throws {
        // Validation runs locally — works even while the app is starting up.
        do {
            let loaded = try ConfigLoader().loadFromDefaultDirectory()
            let result = ValidateJSON(valid: true, errors: [])
            if jsonFlag.json {
                printValidate(result)
            } else {
                print("valid (\(loaded.config.layouts.count) layouts)")
            }
            throw ExitCode.success
        } catch let error as ConfigLoadError {
            let result = ValidateJSON(valid: false, errors: error.errors)
            if jsonFlag.json {
                printValidate(result)
            } else {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            }
            throw ExitCode(Int32(error.code.rawValue))
        }
    }

    private func printValidate(_ result: ValidateJSON) {
        if let data = try? JSONEncoder.pretty.encode(result) {
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }
}

struct Diagnostics: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show diagnostics")

    @OptionGroup var jsonFlag: JSONFlag

    func run() throws {
        executeRemote(CommandRequest(command: "diagnostics"), json: jsonFlag.json)
    }
}

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Display operations",
        subcommands: [List.self, Current.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List displays")

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "displayList"), json: jsonFlag.json)
        }
    }

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the display of the focused window")

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "displayCurrent"), json: jsonFlag.json)
        }
    }
}

struct Space: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Virtual workspace operations",
        subcommands: [List.self, Current.self, Switch.self, Recover.self]
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List virtual workspaces")

        @Option(name: .customLong("layout"), help: "Query this active layout instead of the primary workspace")
        var layout: String?

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(
                CLIRequestBuilder.spaceQuery(command: "spaceList", layout: layout),
                json: jsonFlag.json
            )
        }
    }

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the active virtual workspace")

        @Option(name: .customLong("layout"), help: "Query this active layout instead of the primary workspace")
        var layout: String?

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(
                CLIRequestBuilder.spaceQuery(command: "spaceCurrent", layout: layout),
                json: jsonFlag.json
            )
        }
    }

    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the active virtual workspace")

        @Argument(help: "Target space ID")
        var spaceID: Int

        @Option(name: .customLong("layout"), help: "Switch this active layout instead of the primary workspace")
        var layout: String?

        @Option(name: .customLong("monitor"), help: "Switch the active workspace on this monitor alias")
        var monitor: String?

        @Option(name: .customLong("focus"), help: "Focus policy: target or preserve")
        var focus = "target"

        @Flag(name: .customLong("reconcile"), help: "Force visibility reconciliation")
        var reconcile = false

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            guard layout == nil || monitor == nil else {
                throw ValidationError("--layout and --monitor are mutually exclusive")
            }
            guard let focusPolicy = SpaceSwitchFocusPolicy(rawValue: focus.lowercased()) else {
                throw ValidationError("--focus must be target or preserve")
            }
            let request = CLIRequestBuilder.spaceSwitch(
                spaceID: spaceID,
                layout: layout,
                monitor: monitor,
                focus: focusPolicy,
                reconcile: reconcile
            )
            executeRemote(request, json: jsonFlag.json)
        }
    }

    struct Recover: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Clear pending recovery state")

        @Flag(name: .customLong("force-clear-pending"), help: "Clear the pending state")
        var forceClearPending = false

        @Flag(name: .customLong("yes"), help: "Skip confirmation")
        var yes = false

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            guard forceClearPending else {
                throw ValidationError("space recover requires --force-clear-pending")
            }
            if !yes {
                FileHandle.standardError.write(Data("This clears pending recovery state. Re-run with --yes to confirm.\n".utf8))
                throw ExitCode(Int32(ErrorCode.validationError.rawValue))
            }
            let request = CLIRequestBuilder.spaceRecover()
            executeRemote(request, json: jsonFlag.json)
        }
    }
}

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window operations",
        subcommands: [Current.self, Workspace.self, Move.self, Resize.self, Set.self]
    )

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the focused window")

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "windowCurrent"), json: jsonFlag.json)
        }
    }

    struct Workspace: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a window to a virtual workspace")

        @Argument(help: "Target space ID")
        var spaceID: Int

        @OptionGroup var selector: WindowSelectorOptions
        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            let request = CLIRequestBuilder.window(
                command: "windowWorkspace",
                selector: selector.value,
                spaceID: spaceID
            )
            executeRemote(request, json: jsonFlag.json)
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move a window")

        @Option(name: .customShort("x"), help: "X position (e.g. 0%, 100pt)")
        var x: String

        @Option(name: .customShort("y"), help: "Y position")
        var y: String

        @OptionGroup var selector: WindowSelectorOptions
        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            let request = CLIRequestBuilder.window(
                command: "windowMove",
                selector: selector.value,
                x: x,
                y: y
            )
            executeRemote(request, json: jsonFlag.json)
        }
    }

    struct Resize: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resize a window")

        @Option(name: .customShort("w"), help: "Width (e.g. 50%, 800pt)")
        var width: String

        @Option(name: .customShort("h"), help: "Height")
        var height: String

        @OptionGroup var selector: WindowSelectorOptions
        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            let request = CLIRequestBuilder.window(
                command: "windowResize",
                selector: selector.value,
                width: width,
                height: height
            )
            executeRemote(request, json: jsonFlag.json)
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Move and resize a window")

        @Option(name: .customShort("x"), help: "X position")
        var x: String

        @Option(name: .customShort("y"), help: "Y position")
        var y: String

        @Option(name: .customShort("w"), help: "Width")
        var width: String

        @Option(name: .customShort("h"), help: "Height")
        var height: String

        @OptionGroup var selector: WindowSelectorOptions
        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            let request = CLIRequestBuilder.window(
                command: "windowSet",
                selector: selector.value,
                x: x,
                y: y,
                width: width,
                height: height
            )
            executeRemote(request, json: jsonFlag.json)
        }
    }
}

struct Focus: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Focus a window")

    @Option(name: .customLong("slot"), help: "Slot number in the active workspace")
    var slot: Int?

    @OptionGroup var selector: WindowSelectorOptions
    @OptionGroup var jsonFlag: JSONFlag

    func run() throws {
        let request = CLIRequestBuilder.focus(slot: slot, selector: selector.value)
        executeRemote(request, json: jsonFlag.json)
    }
}

struct Switcher: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switcher operations",
        subcommands: [List.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List switcher candidates")

        @Option(name: .customLong("include-all-spaces"), help: "Include all workspaces (true/false)")
        var includeAllSpaces: Bool = false

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            let request = CLIRequestBuilder.switcherList(includeAllSpaces: includeAllSpaces)
            executeRemote(request, json: jsonFlag.json)
        }
    }
}

if CommandLine.arguments.dropFirst() == ["-v"] {
    print(ShitsuraeCLIVersion.current)
    exit(0)
}

ShitsuraeCommand.main()
