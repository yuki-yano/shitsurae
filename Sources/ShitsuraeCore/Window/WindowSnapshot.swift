import Darwin
import Foundation

/// Kernel process start time in microseconds since the Unix epoch. PID and
/// bundle ID can both be reused; this token distinguishes process instances.
public enum ProcessGenerationResolver {
    public static func startTime(pid: Int) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        let seconds = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        guard !seconds.overflow else { return nil }
        let micros = seconds.partialValue.addingReportingOverflow(UInt64(info.pbi_start_tvusec))
        return micros.overflow ? nil : micros.partialValue
    }
}

/// Stable identity for one live window within a process lifetime. Every
/// cross-enumeration decision must keep all four fields; a CGWindowID alone
/// can be reused by another process after its previous owner closes.
public struct WindowIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int
    public let processStartTime: UInt64
    public let windowID: UInt32
    public let bundleID: String

    public init(pid: Int, processStartTime: UInt64, windowID: UInt32, bundleID: String) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.windowID = windowID
        self.bundleID = bundleID
    }

    public var handle: WindowHandle {
        WindowHandle(pid: pid, processStartTime: processStartTime, windowID: windowID)
    }
}

/// The part of CG window identity available before AppKit can resolve the
/// owning bundle. It is used only as a conservative liveness proof; actual
/// assignment and every mutation still require the complete WindowIdentity.
public struct WindowHandle: Equatable, Hashable, Sendable {
    public let pid: Int
    /// nil means the raw CG record's owner generation could not be proven;
    /// liveness checks must then fail closed.
    public let processStartTime: UInt64?
    public let windowID: UInt32

    public init(pid: Int, processStartTime: UInt64?, windowID: UInt32) {
        self.pid = pid
        self.processStartTime = processStartTime
        self.windowID = windowID
    }
}

/// One full CG inventory pass. `unavailable` is deliberately distinct from
/// an authoritative empty list: persisted exact bindings may only be released
/// after an available inventory proves their window disappeared.
public struct WindowInventory: Equatable, Sendable {
    public let windows: [WindowSnapshot]
    /// Every raw CG PID+windowID observed in the pass, including records that
    /// cannot become a WindowSnapshot because bundle resolution or bounds
    /// parsing failed. Dropping those records must not release a live binding.
    public let liveWindowHandles: Set<WindowHandle>
    public let isAuthoritative: Bool

    private init(
        windows: [WindowSnapshot],
        liveWindowHandles: Set<WindowHandle>,
        isAuthoritative: Bool
    ) {
        self.windows = windows
        self.liveWindowHandles = liveWindowHandles
        self.isAuthoritative = isAuthoritative
    }

    public static func available(
        _ windows: [WindowSnapshot],
        liveWindowHandles: Set<WindowHandle>? = nil
    ) -> WindowInventory {
        WindowInventory(
            windows: windows,
            liveWindowHandles: liveWindowHandles ?? Set(windows.map(\.handle)),
            isAuthoritative: true
        )
    }

    public static let unavailable = WindowInventory(
        windows: [],
        liveWindowHandles: [],
        isAuthoritative: false
    )

    /// Conservative exact-identity liveness. A raw handle with no assembled
    /// snapshot is unknown/alive; a snapshot proving that the same handle now
    /// belongs to a different bundle is authoritative handle reuse, not the
    /// old window.
    public func mayContain(_ identity: WindowIdentity) -> Bool {
        guard isAuthoritative else { return true }
        let samePIDAndWindow = windows.filter {
            $0.pid == identity.pid && $0.windowID == identity.windowID
        }
        if !samePIDAndWindow.isEmpty {
            return samePIDAndWindow.contains { $0.identity == identity }
        }
        let rawMatches = liveWindowHandles.filter {
            $0.pid == identity.pid && $0.windowID == identity.windowID
        }
        return rawMatches.contains {
            $0.processStartTime == nil || $0.processStartTime == identity.processStartTime
        }
    }
}

/// Full inventory and the frontmost application's exact focused identity,
/// sampled as one focus-event observation.
public struct WindowObservation: Equatable, Sendable {
    public let inventory: WindowInventory
    public let focusedIdentity: WindowIdentity?

    public init(inventory: WindowInventory, focusedIdentity: WindowIdentity?) {
        self.inventory = inventory
        self.focusedIdentity = focusedIdentity
    }
}

/// Point-in-time view of one on-screen window, built from
/// CGWindowListCopyWindowInfo plus an AX batch query for window identity and
/// attributes that Core Graphics does not expose.
///
/// Important semantics:
/// - `minimized` carries the real AX value (v1 hardcoded `false`, which broke
///   visibility convergence for manually minimized windows).
/// - no native `spaceID` — virtual workspace membership lives in RuntimeState,
///   not on the snapshot.
/// - `isAXBacked` distinguishes real AX windows from CG-only auxiliary
///   surfaces, which must not participate in virtual workspaces.
public struct WindowSnapshot: Equatable, Sendable {
    public let windowID: UInt32
    public let bundleID: String
    public let pid: Int
    public let processStartTime: UInt64
    public let title: String
    public let role: String
    public let subrole: String?
    /// Whether this CG window has a matching entry in its owning process's
    /// `kAXWindowsAttribute`. CG can expose auxiliary surfaces that are not
    /// actual AX windows; those surfaces must never be managed.
    ///
    /// `false` is NOT proof of a CG-only surface: a transient AX failure, a
    /// window parked on another native Space, or a minimized/hidden window an
    /// app stops reporting all look identical here. Treat `false` as "not
    /// manageable this pass" only — never as grounds for discarding persisted
    /// state bound to the window.
    public let isAXBacked: Bool
    public let minimized: Bool
    public let hidden: Bool
    public let frame: ResolvedFrame
    /// Stable display identifier (display UUID) of the display this window
    /// currently overlaps the most, if any.
    public let displayID: String?
    public let profileDirectory: String?
    public let isFullscreen: Bool
    /// Z-order index from CGWindowList enumeration (0 = frontmost). Stable
    /// within one snapshot batch only; never persist it.
    public let frontIndex: Int

    public init(
        windowID: UInt32,
        bundleID: String,
        pid: Int,
        processStartTime: UInt64,
        title: String,
        role: String = "AXWindow",
        subrole: String? = nil,
        isAXBacked: Bool,
        minimized: Bool,
        hidden: Bool,
        frame: ResolvedFrame,
        displayID: String?,
        profileDirectory: String? = nil,
        isFullscreen: Bool,
        frontIndex: Int
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.pid = pid
        self.processStartTime = processStartTime
        self.title = title
        self.role = role
        self.subrole = subrole
        self.isAXBacked = isAXBacked
        self.minimized = minimized
        self.hidden = hidden
        self.frame = frame
        self.displayID = displayID
        self.profileDirectory = profileDirectory
        self.isFullscreen = isFullscreen
        self.frontIndex = frontIndex
    }

    public var identity: WindowIdentity {
        WindowIdentity(
            pid: pid,
            processStartTime: processStartTime,
            windowID: windowID,
            bundleID: bundleID
        )
    }

    public var handle: WindowHandle {
        WindowHandle(pid: pid, processStartTime: processStartTime, windowID: windowID)
    }
}

public enum WindowInteractionResult: Equatable, Sendable {
    case success
    case permissionDenied
    case failed

    public var isSuccess: Bool {
        self == .success
    }
}
