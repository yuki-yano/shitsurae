import Foundation

public enum WindowEligibility {
    /// The AX subrole of a normal, movable/resizable top-level window. Chrome's
    /// remote-debug / automation popups, DevTools panels, alerts and other
    /// dialogs report a *different* subrole (AXDialog / AXSystemDialog /
    /// AXFloatingWindow / AXUnknown). Those windows refuse AX geometry writes,
    /// so managing them pins convergence forever and drags every space switch
    /// through the full retry budget — exclude them up front.
    public static let standardWindowSubrole = "AXStandardWindow"

    public enum Classification: Equatable, Sendable {
        /// A confirmed ordinary top-level window that is safe to mutate.
        case manageable
        /// A confirmed sheet, dialog, popup, helper UI, or otherwise
        /// non-manageable companion surface.
        case companion
        /// The current observation lacks enough AX evidence to decide. This
        /// state must never authorize adoption, mutation, or pruning.
        case unknown
    }

    public static func classification(of window: WindowSnapshot) -> Classification {
        guard window.isAXBacked else {
            return .unknown
        }

        // Any observed contradiction is enough to classify a companion even
        // if another attribute failed in the same pass.
        if let role = window.role, role != "AXWindow" {
            return .companion
        }
        if let subrole = window.subrole, subrole != standardWindowSubrole {
            return .companion
        }
        if window.modal == true {
            return .companion
        }

        // A normal window is manageable only when all three AX attributes
        // were observed, including an explicit false modal value.
        guard window.role == "AXWindow",
              window.subrole == standardWindowSubrole,
              window.modal == false
        else {
            return .unknown
        }

        guard !window.bundleID.hasPrefix("com.yuki-yano.shitsurae") else {
            return .companion
        }
        guard !window.bundleID.contains(".xpc.") else {
            return .companion
        }

        if window.title.isEmpty {
            let area = window.frame.width * window.frame.height
            if window.frame.width < 120 || window.frame.height < 120 || area < 40_000 {
                return .companion
            }
        }

        return .manageable
    }

    public static func isManageableForVirtualWorkspace(_ window: WindowSnapshot) -> Bool {
        classification(of: window) == .manageable && !window.geometryBlocked
    }

    /// The state-bearing window for a focus event. An ordinary focused window
    /// maps to itself. A definite companion (for example a Chrome confirmation
    /// sheet) maps to the frontmost manageable window owned by the same exact
    /// process generation. Unknown observations never project.
    public static func manageableMainWindow(
        for focusedWindow: WindowSnapshot,
        mainIdentity: WindowIdentity?,
        in windows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        switch classification(of: focusedWindow) {
        case .manageable:
            return focusedWindow
        case .unknown:
            return nil
        case .companion:
            return exactManageableMainWindow(
                for: focusedWindow,
                mainIdentity: mainIdentity,
                in: windows
            )
        }
    }

    /// A main window that must not receive geometry or workspace membership
    /// writes while a companion or unknown surface has focus. Unlike tracking
    /// projection, unknown focused windows also block their exact AX main.
    public static func geometryBlockedMainWindow(
        for focusedWindow: WindowSnapshot,
        mainIdentity: WindowIdentity?,
        in windows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        switch classification(of: focusedWindow) {
        case .manageable:
            return nil
        case .companion, .unknown:
            return exactManageableMainWindow(
                for: focusedWindow,
                mainIdentity: mainIdentity,
                in: windows
            )
        }
    }

    public static func geometryCandidates(in observation: WindowObservation) -> [WindowSnapshot] {
        let blockedIdentities = geometryBlockedIdentities(in: observation)
        return observation.inventory.windows.filter { window in
            classification(of: window) == .manageable
                && !blockedIdentities.contains(window.identity)
        }
    }

    public static func geometryBlockedIdentities(in observation: WindowObservation) -> Set<WindowIdentity> {
        var blockedIdentities = Set(
            observation.inventory.windows.compactMap { window in
                window.geometryBlocked ? window.identity : nil
            }
        )
        // Live inventories already carry the per-process AX focus/main block.
        // The observation-derived check also keeps lightweight WindowControl
        // implementations conservative when they do not assemble AX metadata.
        guard let focusedIdentity = observation.focusedIdentity else {
            return blockedIdentities
        }
        if let focusedWindow = observation.inventory.windows.first(where: {
            $0.identity == focusedIdentity
        }), let blocked = geometryBlockedMainWindow(
            for: focusedWindow,
            mainIdentity: observation.mainIdentity,
            in: observation.inventory.windows
        ) {
            blockedIdentities.insert(blocked.identity)
            return blockedIdentities
        }

        // The AX focus query can observe a newly-created sheet immediately
        // after the inventory pass. If that exact focused identity is absent,
        // the only safe interpretation is to protect the exact AX main for
        // this pass.
        if let mainIdentity = observation.mainIdentity,
           focusedIdentity != mainIdentity,
           focusedIdentity.pid == mainIdentity.pid,
           focusedIdentity.processStartTime == mainIdentity.processStartTime,
           focusedIdentity.bundleID == mainIdentity.bundleID,
           observation.inventory.windows.contains(where: {
               $0.identity == mainIdentity && classification(of: $0) == .manageable
           })
        {
            blockedIdentities.insert(mainIdentity)
        }
        return blockedIdentities
    }

    private static func exactManageableMainWindow(
        for focusedWindow: WindowSnapshot,
        mainIdentity: WindowIdentity?,
        in windows: [WindowSnapshot]
    ) -> WindowSnapshot? {
        guard let mainIdentity,
              mainIdentity.pid == focusedWindow.pid,
              mainIdentity.processStartTime == focusedWindow.processStartTime,
              mainIdentity.bundleID == focusedWindow.bundleID,
              let main = windows.first(where: { $0.identity == mainIdentity }),
              classification(of: main) == .manageable
        else {
            return nil
        }
        return main
    }
}
