import ArgumentParser
import Foundation
import ShitsuraeCore

@main
struct ShitsuraeCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shitsurae",
        abstract: "Shitsurae CLI",
        subcommands: [
            Arrange.self,
            Layouts.self,
            Validate.self,
            Display.self,
            Space.self,
            Window.self,
            Focus.self,
            Switcher.self,
            Diagnostics.self,
        ]
    )
}

private func emit(_ result: CommandResult) -> Never {
    if !result.stdout.isEmpty {
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }

    if !result.stderr.isEmpty {
        FileHandle.standardError.write(Data(result.stderr.utf8))
    }

    Foundation.exit(result.exitCode)
}

private func executeRemote(_ request: AgentCommandRequest) -> Never {
    let configPath = ConfigPathResolver.configDirectoryURL().path
    let enriched = request.withConfigDirectoryPath(configPath)
    let result = AgentXPCClient().execute(enriched)
    emit(result)
}

struct Arrange: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Apply a layout; in virtual mode omitting --space updates all workspace state and live-applies the current active workspace"
    )

    @Argument(help: "layout name")
    var layoutName: String

    @Flag(name: .long, help: "dry run; in virtual mode this is step 1 of bootstrap and the post-recovery discovery path")
    var dryRun = false

    @Flag(name: .long, help: "verbose logs")
    var verbose = false

    @Flag(name: .long, help: "JSON output")
    var json = false

    @Flag(name: .long, help: "update runtime state only without applying layout operations; in virtual mode this is 'Initialize Active Space'")
    var stateOnly = false

    @Option(name: .long, help: "only arrange the specified spaceID in the layout; omit in virtual mode to update all workspace state and live-apply the current active workspace")
    var space: Int?

    mutating func run() throws {
        executeRemote(
            AgentCommandRequest(
                command: .arrange,
                json: json,
                dryRun: dryRun,
                verbose: verbose,
                layoutName: layoutName,
                spaceID: space,
                stateOnly: stateOnly
            )
        )
    }
}

struct Layouts: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Layout related commands",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .layoutsList))
        }
    }
}

struct Validate: ParsableCommand {
    @Flag(name: .long, help: "JSON output")
    var json = false

    mutating func run() throws {
        executeRemote(AgentCommandRequest(command: .validate, json: json))
    }
}

struct Diagnostics: ParsableCommand {
    @Flag(name: .long, help: "JSON output")
    var json = false

    mutating func run() throws {
        executeRemote(AgentCommandRequest(command: .diagnostics, json: json))
    }
}

struct Display: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Display related commands",
        subcommands: [List.self, Current.self]
    )

    struct List: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .displayList, json: json))
        }
    }

    struct Current: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .displayCurrent, json: json))
        }
    }
}

struct Space: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Space related commands",
        subcommands: [List.self, Current.self, Switch.self, Recover.self]
    )

    struct List: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .spaceList, json: json))
        }
    }

    struct Current: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .spaceCurrent, json: json))
        }
    }

    struct Switch: ParsableCommand {
        @Argument(help: "target space id")
        var spaceID: Int

        @Flag(name: .long, help: "JSON output")
        var json = false

        @Flag(name: .long, help: "reconcile visibility even when the target space is already active")
        var reconcile = false

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .spaceSwitch,
                    json: json,
                    spaceID: spaceID,
                    reconcile: reconcile
                )
            )
        }
    }

    struct Recover: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Recover pending virtual-space state; force-clear is last resort and must be followed by --dry-run --json then arrange --space"
        )

        @Flag(name: .long, help: "force clear pending virtual space recovery state as a last resort; does not reconcile workspace visibility")
        var forceClearPending = false

        @Flag(name: .long, help: "confirm destructive recovery operation and accept follow-up rediscovery/reconcile work")
        var yes = false

        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .spaceRecover,
                    json: json,
                    forceClearPending: forceClearPending,
                    confirm: yes
                )
            )
        }
    }
}

struct Focus: ParsableCommand {
    @Option(name: .long, help: "slot number 1..9")
    var slot: Int?

    @Option(name: .long, help: "target window id")
    var windowID: UInt32?

    @Option(name: .long, help: "target app bundle id")
    var bundleID: String?

    @Option(name: .long, help: "target window title")
    var title: String?

    mutating func run() throws {
        executeRemote(
            AgentCommandRequest(
                command: .focus,
                slot: slot,
                windowID: windowID,
                bundleID: bundleID,
                windowTitle: title
            )
        )
    }
}

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window operations",
        subcommands: [Current.self, Workspace.self, Move.self, Resize.self, Set.self]
    )

    struct Current: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(AgentCommandRequest(command: .windowCurrent, json: json))
        }
    }

    struct Move: ParsableCommand {
        @Option(name: .long)
        var x: String

        @Option(name: .long)
        var y: String

        @Option(name: .long, help: "target window id")
        var windowID: UInt32?

        @Option(name: .long, help: "target app bundle id")
        var bundleID: String?

        @Option(name: .long, help: "target window title")
        var title: String?

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .windowMove,
                    x: parseLength(x),
                    y: parseLength(y),
                    windowID: windowID,
                    bundleID: bundleID,
                    windowTitle: title
                )
            )
        }
    }

    struct Workspace: ParsableCommand {
        @Argument(help: "target virtual workspace id")
        var spaceID: Int

        @Flag(name: .long, help: "JSON output")
        var json = false

        @Option(name: .long, help: "target window id")
        var windowID: UInt32?

        @Option(name: .long, help: "target app bundle id")
        var bundleID: String?

        @Option(name: .long, help: "target window title")
        var title: String?

        mutating func run() throws {
            let target = (windowID != nil || bundleID != nil || title != nil)
                ? WindowTargetSelector(windowID: windowID, bundleID: bundleID, title: title)
                : nil
            executeRemote(
                AgentCommandRequest(
                    command: .windowWorkspace,
                    json: json,
                    spaceID: spaceID,
                    windowID: target?.windowID,
                    bundleID: target?.bundleID,
                    windowTitle: target?.title
                )
            )
        }
    }

    struct Resize: ParsableCommand {
        @Option(name: .long)
        var w: String

        @Option(name: .long)
        var h: String

        @Option(name: .long, help: "target window id")
        var windowID: UInt32?

        @Option(name: .long, help: "target app bundle id")
        var bundleID: String?

        @Option(name: .long, help: "target window title")
        var title: String?

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .windowResize,
                    width: parseLength(w),
                    height: parseLength(h),
                    windowID: windowID,
                    bundleID: bundleID,
                    windowTitle: title
                )
            )
        }
    }

    struct Set: ParsableCommand {
        @Option(name: .long)
        var x: String

        @Option(name: .long)
        var y: String

        @Option(name: .long)
        var w: String

        @Option(name: .long)
        var h: String

        @Option(name: .long, help: "target window id")
        var windowID: UInt32?

        @Option(name: .long, help: "target app bundle id")
        var bundleID: String?

        @Option(name: .long, help: "target window title")
        var title: String?

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .windowSet,
                    x: parseLength(x),
                    y: parseLength(y),
                    width: parseLength(w),
                    height: parseLength(h),
                    windowID: windowID,
                    bundleID: bundleID,
                    windowTitle: title
                )
            )
        }
    }
}

struct Switcher: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switcher commands",
        subcommands: [List.self]
    )

    struct List: ParsableCommand {
        @Flag(name: .long)
        var json = false

        @Option(
            name: .long,
            help: "true|false; in virtual mode true lists tracked windows across the active layout, false limits output to the active virtual space"
        )
        var includeAllSpaces: String?

        mutating func run() throws {
            let parsed: Bool?
            if let includeAllSpaces {
                switch includeAllSpaces.lowercased() {
                case "true": parsed = true
                case "false": parsed = false
                default:
                    emit(CommandResult(exitCode: Int32(ErrorCode.validationError.rawValue), stderr: "--include-all-spaces must be true or false\n"))
                }
            } else {
                parsed = false
            }

            executeRemote(
                AgentCommandRequest(
                    command: .switcherList,
                    json: json,
                    includeAllSpaces: parsed,
                )
            )
        }
    }
}

private func parseLength(_ value: String) -> LengthValue {
    if let parsed = Double(value) {
        return .pt(parsed)
    }
    return .expression(value)
}
