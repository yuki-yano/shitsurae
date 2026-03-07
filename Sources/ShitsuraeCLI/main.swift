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
    static let configuration = CommandConfiguration(abstract: "Apply a layout")

    @Argument(help: "layout name")
    var layoutName: String

    @Flag(name: .long, help: "dry run")
    var dryRun = false

    @Flag(name: .long, help: "verbose logs")
    var verbose = false

    @Flag(name: .long, help: "JSON output")
    var json = false

    @Option(name: .long, help: "only arrange the specified spaceID in the layout")
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
                slot: nil,
                includeAllSpaces: nil,
                x: nil,
                y: nil,
                width: nil,
                height: nil
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
            executeRemote(
                AgentCommandRequest(
                    command: .layoutsList,
                    json: nil,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
                    x: nil,
                    y: nil,
                    width: nil,
                    height: nil
                )
            )
        }
    }
}

struct Validate: ParsableCommand {
    @Flag(name: .long, help: "JSON output")
    var json = false

    mutating func run() throws {
        executeRemote(
            AgentCommandRequest(
                command: .validate,
                json: json,
                dryRun: nil,
                verbose: nil,
                layoutName: nil,
                slot: nil,
                includeAllSpaces: nil,
                x: nil,
                y: nil,
                width: nil,
                height: nil
            )
        )
    }
}

struct Diagnostics: ParsableCommand {
    @Flag(name: .long, help: "JSON output")
    var json = false

    mutating func run() throws {
        executeRemote(
            AgentCommandRequest(
                command: .diagnostics,
                json: json,
                dryRun: nil,
                verbose: nil,
                layoutName: nil,
                slot: nil,
                includeAllSpaces: nil,
                x: nil,
                y: nil,
                width: nil,
                height: nil
            )
        )
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
                json: nil,
                dryRun: nil,
                verbose: nil,
                layoutName: nil,
                slot: slot,
                includeAllSpaces: nil,
                x: nil,
                y: nil,
                width: nil,
                height: nil,
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
        subcommands: [Current.self, Move.self, Resize.self, Set.self]
    )

    struct Current: ParsableCommand {
        @Flag(name: .long, help: "JSON output")
        var json = false

        mutating func run() throws {
            executeRemote(
                AgentCommandRequest(
                    command: .windowCurrent,
                    json: json,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
                    x: nil,
                    y: nil,
                    width: nil,
                    height: nil
                )
            )
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
                    json: nil,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
                    x: parseLength(x),
                    y: parseLength(y),
                    width: nil,
                    height: nil,
                    windowID: windowID,
                    bundleID: bundleID,
                    windowTitle: title
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
                    json: nil,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
                    x: nil,
                    y: nil,
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
                    json: nil,
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: nil,
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

        @Option(name: .long, help: "true|false")
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
                    dryRun: nil,
                    verbose: nil,
                    layoutName: nil,
                    slot: nil,
                    includeAllSpaces: parsed,
                    x: nil,
                    y: nil,
                    width: nil,
                    height: nil
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
