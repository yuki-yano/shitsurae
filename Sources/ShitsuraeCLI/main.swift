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
        FileHandle.standardError.write(Data("error: Shitsurae.app is not reachable (launch failed?)\n".utf8))
        exit(Int32(ErrorCode.backendUnavailable.rawValue))
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(Int32(ErrorCode.ipcCommunicationError.rawValue))
    }
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

    @Option(name: .customLong("bundle-id"), help: "Target application bundle ID")
    var bundleID: String?

    @Option(name: .customLong("title"), help: "Window title substring (with --bundle-id)")
    var title: String?

    func apply(to request: inout CommandRequest) {
        request.windowID = windowID
        request.bundleID = bundleID
        request.title = title
    }
}

struct ShitsuraeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shitsurae",
        abstract: "Virtual desktop window manager for macOS",
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
    static let configuration = CommandConfiguration(abstract: "Apply a layout")

    @Argument(help: "Layout name")
    var layout: String

    @Flag(name: .customLong("dry-run"), help: "Show the plan without applying")
    var dryRun = false

    @Flag(name: .customLong("state-only"), help: "Update runtime state only")
    var stateOnly = false

    @Option(name: .customLong("space"), help: "Apply only this virtual space")
    var space: Int?

    @OptionGroup var jsonFlag: JSONFlag

    func run() throws {
        var request = CommandRequest(command: "arrange")
        request.layout = layout
        request.dryRun = dryRun ? true : nil
        request.stateOnly = stateOnly ? true : nil
        request.spaceID = space
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

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "spaceList"), json: jsonFlag.json)
        }
    }

    struct Current: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the active virtual workspace")

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            executeRemote(CommandRequest(command: "spaceCurrent"), json: jsonFlag.json)
        }
    }

    struct Switch: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch the active virtual workspace")

        @Argument(help: "Target space ID")
        var spaceID: Int

        @Flag(name: .customLong("reconcile"), help: "Force visibility reconciliation")
        var reconcile = false

        @OptionGroup var jsonFlag: JSONFlag

        func run() throws {
            var request = CommandRequest(command: "spaceSwitch")
            request.spaceID = spaceID
            request.reconcile = reconcile ? true : nil
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
            var request = CommandRequest(command: "spaceRecover")
            request.forceClearPending = true
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
            var request = CommandRequest(command: "windowWorkspace")
            request.spaceID = spaceID
            selector.apply(to: &request)
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
            var request = CommandRequest(command: "windowMove")
            request.x = x
            request.y = y
            selector.apply(to: &request)
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
            var request = CommandRequest(command: "windowResize")
            request.width = width
            request.height = height
            selector.apply(to: &request)
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
            var request = CommandRequest(command: "windowSet")
            request.x = x
            request.y = y
            request.width = width
            request.height = height
            selector.apply(to: &request)
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
        var request = CommandRequest(command: "focus")
        request.slot = slot
        selector.apply(to: &request)
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
            var request = CommandRequest(command: "switcherList")
            request.includeAllSpaces = includeAllSpaces
            executeRemote(request, json: jsonFlag.json)
        }
    }
}

ShitsuraeCommand.main()
