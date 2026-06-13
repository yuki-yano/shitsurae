import Foundation

/// Point-in-time view of one on-screen window, built from
/// CGWindowListCopyWindowInfo plus an AX batch query for the minimized state.
///
/// v2 changes from v1:
/// - `minimized` carries the real AX value (v1 hardcoded `false`, which broke
///   visibility convergence for manually minimized windows).
/// - no native `spaceID` — virtual workspace membership lives in RuntimeState,
///   not on the snapshot.
public struct WindowSnapshot: Codable, Equatable, Sendable {
    public let windowID: UInt32
    public let bundleID: String
    public let pid: Int
    public let title: String
    public let role: String
    public let subrole: String?
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
        title: String,
        role: String = "AXWindow",
        subrole: String? = nil,
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
        self.title = title
        self.role = role
        self.subrole = subrole
        self.minimized = minimized
        self.hidden = hidden
        self.frame = frame
        self.displayID = displayID
        self.profileDirectory = profileDirectory
        self.isFullscreen = isFullscreen
        self.frontIndex = frontIndex
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
