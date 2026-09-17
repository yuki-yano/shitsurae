import AppKit
import ApplicationServices
import Darwin
import Foundation

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
    private static let lsofTimeoutSeconds: TimeInterval = 2
    private static let processTerminationGraceSeconds: TimeInterval = 0.2

    public static func displays() -> [DisplayInfo] {
        let mainID = CGMainDisplayID()
        let screens = NSScreen.screens
        let primaryAppKitFrame = screens
            .first { screenDisplayID($0) == mainID }?
            .frame
            ?? CGRect(origin: .zero, size: screens.first?.frame.size ?? .zero)

        return screens.compactMap { screen in
            guard let displayID = screenDisplayID(screen) else { return nil }
            guard let uuidString = stableDisplayID(for: displayID) else {
                return nil
            }
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

    /// Resolves the stable display UUID used by `DisplayInfo` for an AppKit
    /// screen. UI surfaces use this to target the same physical display as
    /// Core workspace routing without comparing incompatible coordinate
    /// systems.
    public static func stableDisplayID(for screen: NSScreen) -> String? {
        guard let displayID = screenDisplayID(screen) else { return nil }
        return stableDisplayID(for: displayID)
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
    public static func launchApplication(
        request: ApplicationLaunchRequest,
        timeoutSeconds: TimeInterval = 3,
        permitsNewSideEffect: () -> Bool = { true }
    ) -> Bool {
        guard timeoutSeconds > 0, permitsNewSideEffect() else { return false }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000)
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
            guard permitsNewSideEffect(), DispatchTime.now().uptimeNanoseconds < deadline,
                  launchDetachedProcess(executable: executableURL.path, arguments: arguments) else {
                return false
            }

            return waitForRunningApplication(bundleID: request.bundleID, deadlineUptimeNS: deadline, permitsNewSideEffect: permitsNewSideEffect) {
                isApplicationRunning(bundleID: $0, workspace: workspace)
            }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        guard permitsNewSideEffect(), DispatchTime.now().uptimeNanoseconds < deadline else { return false }
        workspace.openApplication(at: appURL, configuration: configuration, completionHandler: nil)

        return waitForRunningApplication(bundleID: request.bundleID, deadlineUptimeNS: deadline, permitsNewSideEffect: permitsNewSideEffect) {
            isApplicationRunning(bundleID: $0, workspace: workspace)
        }
    }

    public static func browserProfileDirectory(bundleID: String, pid: Int) -> String? {
        guard AXReadPolicy.operationBudget?.permitsCall != false,
              ChromiumProfileSupport.supports(bundleID: bundleID),
              let lsofOutput = runProcess(
                  executable: "/usr/sbin/lsof",
                  arguments: ChromiumProfileSupport.lsofArguments(pid: pid),
                  timeoutSeconds: min(lsofTimeoutSeconds, Double(AXReadPolicy.operationBudget?.remainingBudgetMS() ?? 2_000) / 1_000)
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
        deadlineUptimeNS: UInt64? = nil,
        permitsNewSideEffect: () -> Bool = { true },
        isRunning: (String) -> Bool,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) -> Bool {
        for attempt in 0 ..< attempts {
            guard permitsNewSideEffect() else { return false }
            if let deadlineUptimeNS, DispatchTime.now().uptimeNanoseconds >= deadlineUptimeNS { return false }
            if isRunning(bundleID) {
                return true
            }

            if attempt < attempts - 1 {
                let now = DispatchTime.now().uptimeNanoseconds
                let remaining = deadlineUptimeNS.map {
                    Double($0 > now ? $0 - now : 0) / 1_000_000_000
                } ?? intervalSeconds
                guard remaining > 0 else { return false }
                sleep(min(intervalSeconds, remaining))
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

    private static func stableDisplayID(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
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
    static func runProcess(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) -> String? {
        guard timeoutSeconds > 0 else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = nil

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-process-\(UUID().uuidString).output")
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ),
              let outputHandle = try? FileHandle(forUpdating: outputURL)
        else {
            return nil
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        let termination = DispatchSemaphore(value: 0)

        process.terminationHandler = { _ in
            termination.signal()
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        do {
            try process.run()
        } catch {
            return nil
        }

        let timedOut = termination.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            let graceDeadline = DispatchTime.now() + processTerminationGraceSeconds
            if termination.wait(timeout: graceDeadline) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                let killDeadline = DispatchTime.now() + processTerminationGraceSeconds
                guard termination.wait(timeout: killDeadline) == .success else {
                    return nil
                }
            }
        }

        guard !timedOut, process.terminationStatus == 0 else {
            return nil
        }

        do {
            try outputHandle.synchronize()
            try outputHandle.seek(toOffset: 0)
            let outputData = try outputHandle.readToEnd() ?? Data()
            return String(data: outputData, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
