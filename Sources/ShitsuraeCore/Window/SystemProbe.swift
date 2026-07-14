import AppKit
import ApplicationServices
import Foundation

private final class ProcessOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ newValue: Data) {
        lock.lock()
        data = newValue
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runtime display description. `id` is the display UUID
/// (CGDisplayCreateUUIDFromDisplayID) — the stable DisplayKey used everywhere
/// in v2; CGDirectDisplayID changes across reconnects and must not leak out.
public struct DisplayInfo: Codable, Equatable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int
    public let scale: Double
    public let isPrimary: Bool
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(
        id: String,
        width: Int,
        height: Int,
        scale: Double,
        isPrimary: Bool,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.scale = scale
        self.isPrimary = isPrimary
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum SystemProbe {
    public static func displays() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        let screens = NSScreen.screens
        let primaryAppKitFrame = screens
            .first { screenDisplayID($0) == mainID }?
            .frame
            ?? CGRect(origin: .zero, size: screens.first?.frame.size ?? .zero)

        return screens.compactMap { screen in
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
                frame: cgGlobalRect(fromAppKit: screen.frame, primaryAppKitFrame: primaryAppKitFrame),
                visibleFrame: cgGlobalRect(
                    fromAppKit: screen.visibleFrame,
                    primaryAppKitFrame: primaryAppKitFrame
                )
            )
        }
        .sorted { $0.id < $1.id }
    }

    /// Converts AppKit's bottom-left-origin global screen coordinates into the
    /// top-left-origin global coordinates shared by CGWindow and AXPosition.
    /// DisplayInfo crosses the AppKit boundary only here; every consumer can
    /// therefore compare display and window frames without another transform.
    static func cgGlobalRect(fromAppKit rect: CGRect, primaryAppKitFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryAppKitFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    public static func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    public static func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func launchApplication(bundleID: String) -> Bool {
        launchApplication(request: ApplicationLaunchRequest(bundleID: bundleID))
    }

    @discardableResult
    public static func launchApplication(request: ApplicationLaunchRequest) -> Bool {
        let workspace = NSWorkspace.shared
        if request.profileDirectory == nil,
           isApplicationRunning(bundleID: request.bundleID, workspace: workspace)
        {
            return true
        }

        guard let appURL = workspace.urlForApplication(withBundleIdentifier: request.bundleID) else {
            return false
        }

        if let profileDirectory = request.profileDirectory,
           ChromiumProfileSupport.supports(bundleID: request.bundleID),
           let executableURL = Bundle(url: appURL)?.executableURL
        {
            let arguments = ChromiumProfileSupport.launchArguments(profileDirectory: profileDirectory)
            guard launchDetachedProcess(executable: executableURL.path, arguments: arguments) else {
                return false
            }

            return waitForRunningApplication(bundleID: request.bundleID) {
                isApplicationRunning(bundleID: $0, workspace: workspace)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        return waitForRunningApplication(bundleID: request.bundleID) {
            isApplicationRunning(bundleID: $0, workspace: workspace)
        }
    }

    public static func browserProfileDirectory(bundleID: String, pid: Int) -> String? {
        guard ChromiumProfileSupport.supports(bundleID: bundleID),
              let lsofOutput = runProcess(
                  executable: "/usr/sbin/lsof",
                  arguments: ChromiumProfileSupport.lsofArguments(pid: pid)
              )
        else {
            return nil
        }

        let localStateData = ChromiumProfileSupport
            .localStateURL(bundleID: bundleID)
            .flatMap { try? Data(contentsOf: $0) }

        return ChromiumProfileSupport.resolveUnambiguousProfileDirectory(
            bundleID: bundleID,
            lsofOutput: lsofOutput,
            localStateData: localStateData
        )
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

    private static func launchDetachedProcess(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func runProcess(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let outputReader = outputPipe.fileHandleForReading
        let errorReader = errorPipe.fileHandleForReading
        let outputData = ProcessOutputBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData.set(outputReader.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = errorReader.readDataToEndOfFile()
            group.leave()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            outputPipe.fileHandleForWriting.closeFile()
            errorPipe.fileHandleForWriting.closeFile()
            group.wait()
            return nil
        }

        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        group.wait()

        guard process.terminationStatus == 0 else {
            return nil
        }

        return String(data: outputData.get(), encoding: .utf8)
    }
}
