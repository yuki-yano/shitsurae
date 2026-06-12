import Foundation

/// Resolves which physical display hosts a layout (v2.0: one host display per
/// layout; per-display workspaces are the planned multi-display extension).
///
/// Resolution order:
/// 1. explicit `display.id` on the layout's spaces
/// 2. `display.monitor` role, mapped through the `monitors` config section
///    when present (e.g. monitors.primary.id pins the role to a display UUID)
/// 3. resolution (width/height) condition
/// 4. fallback: the primary display
public enum DisplayResolver {
    public static func hostDisplay(
        layout: LayoutDefinition,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        guard !displays.isEmpty else {
            return nil
        }

        let definition = layout.spaces.compactMap(\.display).first

        if let resolved = resolve(definition: definition, config: config, displays: displays) {
            return resolved
        }

        return primaryDisplay(displays)
    }

    public static func resolve(
        definition: DisplayDefinition?,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        guard let definition else {
            return nil
        }

        if let id = definition.id {
            return displays.first(where: { $0.id == id })
        }

        if let role = definition.monitor {
            if let display = display(for: role, config: config, displays: displays) {
                if definition.width != nil || definition.height != nil {
                    return matchesResolution(display, definition: definition) ? display : nil
                }
                return display
            }
            return nil
        }

        if definition.width != nil || definition.height != nil {
            return displays.first(where: { matchesResolution($0, definition: definition) })
        }

        return nil
    }

    public static func display(
        for role: MonitorRole,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        let target: MonitorTargetDefinition?
        switch role {
        case .primary:
            target = config?.monitors?.primary
        case .secondary:
            target = config?.monitors?.secondary
        }

        if let id = target?.id {
            return displays.first(where: { $0.id == id })
        }

        switch role {
        case .primary:
            return primaryDisplay(displays)
        case .secondary:
            return displays
                .filter { !$0.isPrimary }
                .sorted { $0.id < $1.id }
                .first
        }
    }

    static func primaryDisplay(_ displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first(where: \.isPrimary) ?? displays.sorted { $0.id < $1.id }.first
    }

    static func matchesResolution(_ display: DisplayInfo, definition: DisplayDefinition) -> Bool {
        if let width = definition.width, display.width != width {
            return false
        }
        if let height = definition.height, display.height != height {
            return false
        }
        return true
    }
}
