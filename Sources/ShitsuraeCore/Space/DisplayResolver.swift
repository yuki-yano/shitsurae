import Foundation

/// Resolves which physical display hosts a layout (one host display per
/// layout, declared as `layouts.<name>.display`).
///
/// Resolution order:
/// 1. explicit `display.id`
/// 2. `display.monitor` role, mapped through the `monitors` config section
///    when present (e.g. monitors.primary.id pins the role to a display UUID)
/// 3. resolution (width/height) condition
/// 4. no declaration only: the primary display
///
/// A layout WITH a display declaration resolves to nil when the declared
/// display is absent — it must never fall back to the primary display, or an
/// arrange during disconnect would replace the primary workspace and the
/// dormant/restore semantics would collapse.
public enum DisplayResolver {
    public static func hostDisplay(
        layout: LayoutDefinition,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        guard !displays.isEmpty else {
            return nil
        }

        guard let definition = layout.display, !isEmpty(definition) else {
            return primaryDisplay(displays)
        }

        return resolve(definition: definition, config: config, displays: displays)
    }

    static func isEmpty(_ definition: DisplayDefinition) -> Bool {
        definition.monitor == nil
            && definition.id == nil
            && definition.width == nil
            && definition.height == nil
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
