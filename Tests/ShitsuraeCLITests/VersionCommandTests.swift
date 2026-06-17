import Foundation
import Testing

@Suite("shitsurae CLI version")
struct VersionCommandTests {
    @Test func versionFlagPrintsProjectVersion() throws {
        let version = try String(contentsOfFile: "VERSION", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try runCLI(arguments: ["--version"])

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == version)
        #expect(result.standardError.isEmpty)
    }

    @Test func shortVersionFlagPrintsProjectVersion() throws {
        let version = try String(contentsOfFile: "VERSION", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let result = try runCLI(arguments: ["-v"])

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == version)
        #expect(result.standardError.isEmpty)
    }

    private func runCLI(arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try cliExecutableURL()
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            standardError: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func cliExecutableURL() throws -> URL {
        let candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/shitsurae-cli")

        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw CLIExecutableError.notFound(candidate.path)
    }
}

private struct ProcessResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

private enum CLIExecutableError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case let .notFound(path):
            return "missing shitsurae-cli executable at \(path)"
        }
    }
}
