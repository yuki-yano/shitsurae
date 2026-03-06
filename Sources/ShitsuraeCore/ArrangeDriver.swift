import Foundation

public protocol ArrangeDriver {
    func displays() -> [DisplayInfo]
    func queryWindows() -> [WindowSnapshot]
    func queryWindowsOnAllSpaces() -> [WindowSnapshot]
    func launch(bundleID: String) -> Bool
    func moveWindowToSpace(
        windowID: UInt32,
        bundleID: String,
        displayID: String?,
        spaceID: Int,
        spacesMode: SpacesMode,
        method: SpaceMoveMethod
    ) -> Bool
    func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool
    func activate(bundleID: String) -> Bool
    func sleep(milliseconds: Int)
    func accessibilityGranted() -> Bool
    func actualSpacesMode() -> SpacesMode?
    func backendAvailable(catalogURL: URL) -> (Bool, String?)
}

public struct LiveArrangeDriver: ArrangeDriver {
    private let windowSpaceSwitcher: WindowSpaceSwitching
    private let displayRelaySpaceSwitcher: DisplayRelayWindowSpaceSwitching

    public init(
        windowSpaceSwitcher: WindowSpaceSwitching? = nil,
        displayRelaySpaceSwitcher: DisplayRelayWindowSpaceSwitching? = nil
    ) {
        self.windowSpaceSwitcher = windowSpaceSwitcher ?? SimulatedWindowSpaceSwitcher()
        self.displayRelaySpaceSwitcher = displayRelaySpaceSwitcher ?? DisplayRelayWindowSpaceSwitcher()
    }

    public func displays() -> [DisplayInfo] {
        SystemProbe.displays()
    }

    public func queryWindows() -> [WindowSnapshot] {
        WindowQueryService.listWindows(displays: displays())
    }

    public func queryWindowsOnAllSpaces() -> [WindowSnapshot] {
        WindowQueryService.listWindowsOnAllSpaces(displays: displays())
    }

    public func launch(bundleID: String) -> Bool {
        SystemProbe.launchApplication(bundleID: bundleID)
    }

    public func moveWindowToSpace(
        windowID: UInt32,
        bundleID: String,
        displayID: String?,
        spaceID: Int,
        spacesMode: SpacesMode,
        method: SpaceMoveMethod
    ) -> Bool {
        switch method {
        case .drag:
            return windowSpaceSwitcher.moveWindow(windowID: windowID, targetSpaceID: spaceID)
        case .displayRelay:
            return displayRelaySpaceSwitcher.moveWindow(
                windowID: windowID,
                bundleID: bundleID,
                targetDisplayID: displayID,
                targetSpaceID: spaceID,
                spacesMode: spacesMode
            )
        }
    }

    public func setWindowFrame(windowID: UInt32, bundleID: String, frame: ResolvedFrame) -> Bool {
        _ = activate(bundleID: bundleID)
        return WindowQueryService.setWindowFrame(windowID: windowID, bundleID: bundleID, frame: frame)
    }

    public func activate(bundleID: String) -> Bool {
        WindowQueryService.activate(bundleID: bundleID)
    }

    public func sleep(milliseconds: Int) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000)
    }

    public func accessibilityGranted() -> Bool {
        SystemProbe.accessibilityGranted()
    }

    public func actualSpacesMode() -> SpacesMode? {
        SystemProbe.actualSpacesMode()
    }

    public func backendAvailable(catalogURL: URL) -> (Bool, String?) {
        SystemProbe.supportedBackendAvailable(catalogURL: catalogURL)
    }
}
