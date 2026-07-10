import Foundation

public enum WindowEligibility {
    /// The AX subrole of a normal, movable/resizable top-level window. Chrome's
    /// remote-debug / automation popups, DevTools panels, alerts and other
    /// dialogs report a *different* subrole (AXDialog / AXSystemDialog /
    /// AXFloatingWindow / AXUnknown). Those windows refuse AX geometry writes,
    /// so managing them pins convergence forever and drags every space switch
    /// through the full retry budget — exclude them up front.
    public static let standardWindowSubrole = "AXStandardWindow"

    public static func isManageableForVirtualWorkspace(_ window: WindowSnapshot) -> Bool {
        guard window.isAXBacked else {
            return false
        }
        guard window.role == "AXWindow" else {
            return false
        }
        // A known non-standard subrole means a dialog/popup/panel we must not
        // manage. `nil` means the subrole could not be resolved (AX query
        // failed / not populated) — keep managing it rather than regress.
        if let subrole = window.subrole, subrole != standardWindowSubrole {
            return false
        }
        guard !window.bundleID.hasPrefix("com.yuki-yano.shitsurae") else {
            return false
        }
        guard !window.bundleID.contains(".xpc.") else {
            return false
        }

        if window.title.isEmpty {
            let area = window.frame.width * window.frame.height
            if window.frame.width < 120 || window.frame.height < 120 || area < 40_000 {
                return false
            }
        }

        return true
    }
}
