import Foundation

public struct RoutedSpaceSwitch: Equatable, Sendable {
    public let displayID: String
    public let layoutName: String
    public let spaceID: Int
    public let focus: SpaceSwitchFocusPolicy
    public let monitor: String?

    public init(
        displayID: String,
        layoutName: String,
        spaceID: Int,
        focus: SpaceSwitchFocusPolicy,
        monitor: String?
    ) {
        self.displayID = displayID
        self.layoutName = layoutName
        self.spaceID = spaceID
        self.focus = focus
        self.monitor = monitor
    }
}

public struct RoutedSpaceSwitchOutcome: Equatable, Sendable {
    public let target: RoutedSpaceSwitch
    public let outcome: SpaceSwitchOutcome

    public init(target: RoutedSpaceSwitch, outcome: SpaceSwitchOutcome) {
        self.target = target
        self.outcome = outcome
    }
}

public enum SpaceShortcutRoutingResult: Equatable, Sendable {
    case execute(RoutedSpaceSwitch)
    case failure(String)
}

public enum SpaceShortcutRouter {
    public static func route(
        candidates: [ResolvedSpaceSwitchShortcut],
        cursorLocation: CGPoint,
        config: ShitsuraeConfig,
        displays: [DisplayInfo],
        activeWorkspaces: [ActiveWorkspace]
    ) -> SpaceShortcutRoutingResult {
        let resolved = candidates.compactMap { candidate -> RoutedSpaceSwitch? in
            let display: DisplayInfo?
            if let monitor = candidate.monitor {
                display = DisplayResolver.display(
                    for: monitor,
                    config: config,
                    displays: displays
                )
            } else {
                display = DisplayResolver.primaryDisplay(displays)
            }
            guard let display,
                  let workspace = activeWorkspaces.first(where: { $0.displayID == display.id }),
                  let layout = config.layouts[workspace.layoutName],
                  layout.spaces.contains(where: { $0.spaceID == candidate.spaceID })
            else {
                return nil
            }
            return RoutedSpaceSwitch(
                displayID: display.id,
                layoutName: workspace.layoutName,
                spaceID: candidate.spaceID,
                focus: candidate.focus,
                monitor: candidate.monitor
            )
        }
        var executable: [RoutedSpaceSwitch] = []
        for target in resolved where !executable.contains(where: {
            $0.displayID == target.displayID
                && $0.layoutName == target.layoutName
                && $0.spaceID == target.spaceID
                && $0.focus == target.focus
        }) {
            executable.append(target)
        }

        guard !executable.isEmpty else {
            return .failure("no executable workspace switch target")
        }
        if executable.count == 1 {
            return .execute(executable[0])
        }

        guard let cursorDisplay = displays.first(where: { $0.frame.contains(cursorLocation) }) else {
            return .failure("cursor is not on a connected display with a matching shortcut")
        }
        let local = executable.filter { $0.displayID == cursorDisplay.id }
        guard local.count == 1 else {
            return .failure(
                local.isEmpty
                    ? "no matching shortcut target on the cursor display"
                    : "multiple matching shortcut targets resolve to the cursor display"
            )
        }
        return .execute(local[0])
    }
}
