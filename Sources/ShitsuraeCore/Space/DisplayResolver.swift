import Foundation

/// Resolves which physical display hosts a layout (one host display per
/// layout, declared as `layouts.<name>.display`).
///
/// Resolution order:
/// 1. explicit `display.id`
/// 2. `display.monitor` alias, mapped through the `monitors` config section
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

        if let alias = definition.monitor {
            if let display = display(for: alias, config: config, displays: displays) {
                if definition.width != nil || definition.height != nil {
                    return matchesResolution(display, definition: definition) ? display : nil
                }
                return display
            }
            return nil
        }

        if definition.width != nil || definition.height != nil {
            let matches = displays.filter { matchesResolution($0, definition: definition) }
            return matches.count == 1 ? matches[0] : nil
        }

        return nil
    }

    public static func display(
        for alias: String,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        guard let target = config?.monitors?[alias] else {
            return nil
        }
        return resolve(target: target, displays: displays)
    }

    public static func resolve(
        target: MonitorTargetDefinition,
        displays: [DisplayInfo]
    ) -> DisplayInfo? {
        if let id = target.id {
            return displays.first(where: { $0.id == id })
        }
        if target.primary == true {
            return primaryDisplay(displays)
        }
        if target.width != nil || target.height != nil {
            let matches = displays.filter {
                matchesResolution(
                    $0,
                    width: target.width,
                    height: target.height
                )
            }
            return matches.count == 1 ? matches[0] : nil
        }
        return nil
    }

    public static func alias(
        for displayID: String,
        config: ShitsuraeConfig?,
        displays: [DisplayInfo]
    ) -> String? {
        config?.monitors?.targets.keys.sorted().first { alias in
            display(for: alias, config: config, displays: displays)?.id == displayID
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

    private static func matchesResolution(
        _ display: DisplayInfo,
        width: Int?,
        height: Int?
    ) -> Bool {
        if let width, display.width != width {
            return false
        }
        if let height, display.height != height {
            return false
        }
        return true
    }
}
