import AppKit
import ApplicationServices
import Foundation

public struct DisplayInfo: Codable, Equatable {
    public let id: String
    public let width: Int
    public let height: Int
    public let scale: Double
    public let isPrimary: Bool
    public let frame: CGRect
    public let visibleFrame: CGRect
}

public struct SupportedBuildCatalog: Codable {
    public struct BuildEntry: Codable {
        public let productVersion: String
        public let productBuildVersion: String
        public let status: String
    }

    public let allowStatusesForRuntime: [String]
    public let builds: [BuildEntry]
}

public enum SystemProbe {
    public static func displays() -> [DisplayInfo] {
        let mainID = NSScreen.main.flatMap(screenDisplayID)

        return NSScreen.screens.compactMap { screen in
            guard let displayID = screenDisplayID(screen) else { return nil }
            guard let uuidRef = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
                return nil
            }
            let uuidString = (CFUUIDCreateString(nil, uuidRef) as String?) ?? "unknown"
            let mode = CGDisplayCopyDisplayMode(displayID)

            let width = mode.map { Int($0.pixelWidth) } ?? Int(screen.frame.width * screen.backingScaleFactor)
            let height = mode.map { Int($0.pixelHeight) } ?? Int(screen.frame.height * screen.backingScaleFactor)

            return DisplayInfo(
                id: uuidString,
                width: width,
                height: height,
                scale: screen.backingScaleFactor,
                isPrimary: mainID == displayID,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        .sorted { $0.id < $1.id }
    }

    public static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func screenRecordingGranted() -> Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    public static func currentBuildVersion() -> String? {
        guard let result = runProcess(
            executable: "/usr/bin/sw_vers",
            arguments: ["-buildVersion"]
        ) else {
            return nil
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func supportedBackendAvailable(catalogURL: URL) -> (Bool, String?) {
        guard let data = try? Data(contentsOf: catalogURL) else {
            return (false, "catalogNotFound")
        }

        guard let catalog = try? JSONDecoder().decode(SupportedBuildCatalog.self, from: data) else {
            return (false, "catalogDecodeFailed")
        }

        guard let build = currentBuildVersion() else {
            return (false, "buildVersionUnavailable")
        }

        let allowStatuses = Set(catalog.allowStatusesForRuntime)
        let allowedBuilds = Set(
            catalog.builds
                .filter { allowStatuses.contains($0.status) }
                .map(\.productBuildVersion)
        )

        if allowedBuilds.contains(build) {
            return (true, nil)
        }
        return (false, "unsupportedOSBuild")
    }

    public static func actualSpacesMode() -> SpacesMode? {
        guard let raw = runProcess(executable: "/usr/bin/defaults", arguments: ["read", "com.apple.spaces", "spans-displays"]) else {
            return nil
        }

        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "1" {
            return .global
        }
        if value == "0" {
            return .perDisplay
        }
        return nil
    }

    @discardableResult
    public static func launchApplication(bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        if isApplicationRunning(bundleID: bundleID, workspace: workspace) {
            return true
        }

        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        return waitForRunningApplication(bundleID: bundleID) {
            isApplicationRunning(bundleID: $0, workspace: workspace)
        }
    }

    static func waitForRunningApplication(
        bundleID: String,
        attempts: Int = 30,
        intervalSeconds: TimeInterval = 0.1,
        isRunning: (String) -> Bool,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> Bool {
        for attempt in 0 ..< attempts {
            if isRunning(bundleID) {
                return true
            }

            if attempt < attempts - 1 {
                sleep(intervalSeconds)
            }
        }

        return false
    }

    private static func isApplicationRunning(bundleID: String, workspace: NSWorkspace) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            return true
        }

        return workspace.runningApplications.contains(where: { $0.bundleIdentifier == bundleID })
    }

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
