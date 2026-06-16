import Foundation

public enum WindowEligibility {
    public static func isManageableForVirtualWorkspace(_ window: WindowSnapshot) -> Bool {
        guard window.role == "AXWindow" else {
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
