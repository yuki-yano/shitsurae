import Foundation
import Yams

enum ConfigSchemaValidator {
    private indirect enum Schema: Sendable {
        case scalar
        case opaque
        case sequence(Schema)
        case mapping(fields: [String: Schema], dynamicValues: Schema? = nil)
    }

    static func validate(node: Node, sourcePath: String) -> [ValidateErrorItem] {
        var errors: [ValidateErrorItem] = []
        validate(
            node: node,
            schema: rootSchema,
            keyPath: [],
            sourcePath: sourcePath,
            errors: &errors
        )
        return errors
    }

    private static func validate(
        node: Node,
        schema: Schema,
        keyPath: [String],
        sourcePath: String,
        errors: inout [ValidateErrorItem]
    ) {
        switch schema {
        case .scalar, .opaque:
            return

        case let .sequence(elementSchema):
            guard case let .sequence(sequence) = node else { return }
            for element in sequence {
                validate(
                    node: element,
                    schema: elementSchema,
                    keyPath: keyPath,
                    sourcePath: sourcePath,
                    errors: &errors
                )
            }

        case let .mapping(fields, dynamicValues):
            guard case let .mapping(mapping) = node else { return }
            for (keyNode, valueNode) in mapping {
                guard let key = keyNode.string else { continue }
                if let childSchema = fields[key] ?? dynamicValues {
                    validate(
                        node: valueNode,
                        schema: childSchema,
                        keyPath: keyPath + [key],
                        sourcePath: sourcePath,
                        errors: &errors
                    )
                    continue
                }

                errors.append(
                    ValidateErrorItem(
                        code: .validationError,
                        path: sourcePath,
                        line: keyNode.mark?.line,
                        column: keyNode.mark?.column,
                        message: "unknown config key: \((keyPath + [key]).joined(separator: "."))"
                    )
                )
            }
        }
    }

    private static let scalarSequence = Schema.sequence(.scalar)
    private static let hotkey = Schema.mapping(fields: [
        "key": .scalar,
        "modifiers": scalarSequence,
    ])
    private static let indexedHotkey = Schema.mapping(fields: [
        "key": .scalar,
        "modifiers": scalarSequence,
        "slot": .scalar,
    ])
    private static let titleMatcher = Schema.mapping(fields: [
        "equals": .scalar,
        "contains": .scalar,
        "regex": .scalar,
    ])
    private static let windowMatch = Schema.mapping(fields: [
        "bundleID": .scalar,
        "title": titleMatcher,
        "role": .scalar,
        "subrole": .scalar,
        "profile": .scalar,
        "excludeTitleRegex": .scalar,
        "index": .scalar,
    ])
    private static let frame = Schema.mapping(fields: [
        "x": .scalar,
        "y": .scalar,
        "width": .scalar,
        "height": .scalar,
    ])
    private static let window = Schema.mapping(fields: [
        "match": windowMatch,
        "slot": .scalar,
        "launch": .scalar,
        "frame": frame,
    ])
    private static let display = Schema.mapping(fields: [
        "monitor": .scalar,
        "id": .scalar,
        "width": .scalar,
        "height": .scalar,
    ])
    private static let space = Schema.mapping(fields: [
        "spaceID": .scalar,
        "display": display,
        "windows": .sequence(window),
    ])
    private static let layout = Schema.mapping(fields: [
        "initialFocus": .mapping(fields: ["slot": .scalar]),
        "spaces": .sequence(space),
    ])
    private static let ignoreWindow = Schema.mapping(fields: [
        "bundleID": .scalar,
        "titleRegex": .scalar,
        "role": .scalar,
        "subrole": .scalar,
        "minimized": .scalar,
        "hidden": .scalar,
    ])
    private static let ignoreRuleSet = Schema.mapping(fields: [
        "apps": scalarSequence,
        "windows": .sequence(ignoreWindow),
    ])
    private static let globalAction = Schema.mapping(fields: [
        "type": .scalar,
        "x": .scalar,
        "y": .scalar,
        "width": .scalar,
        "height": .scalar,
        "preset": .scalar,
    ])
    private static let globalActionShortcut = Schema.mapping(fields: [
        "key": .scalar,
        "modifiers": scalarSequence,
        "action": globalAction,
    ])
    private static let shortcuts = Schema.mapping(fields: [
        "focusBySlot": .sequence(indexedHotkey),
        "moveCurrentWindowToSpace": .sequence(indexedHotkey),
        "switchVirtualSpace": .sequence(indexedHotkey),
        "nextWindow": hotkey,
        "prevWindow": hotkey,
        "cycle": .mapping(fields: [
            "mode": .scalar,
            "quickKeys": .scalar,
            "acceptKeys": scalarSequence,
            "cancelKeys": scalarSequence,
        ]),
        "switcher": .mapping(fields: [
            "trigger": hotkey,
            "quickKeys": .scalar,
            "acceptKeys": scalarSequence,
            "cancelKeys": scalarSequence,
        ]),
        "globalActions": .sequence(globalActionShortcut),
        "disabledInApps": .mapping(fields: [:], dynamicValues: scalarSequence),
        "focusBySlotEnabledInApps": .mapping(fields: [:], dynamicValues: .scalar),
        "cycleExcludedApps": scalarSequence,
        "switcherExcludedApps": scalarSequence,
    ])
    private static let rootSchema = Schema.mapping(fields: [
        "app": .mapping(fields: ["launchAtLogin": .scalar]),
        "ignore": .mapping(fields: [
            "apply": ignoreRuleSet,
            "focus": ignoreRuleSet,
        ]),
        "overlay": .mapping(fields: ["showThumbnails": .scalar]),
        "monitors": .mapping(fields: [
            "primary": .mapping(fields: ["id": .scalar]),
            "secondary": .mapping(fields: ["id": .scalar]),
        ]),
        "layouts": .mapping(fields: [:], dynamicValues: layout),
        "shortcuts": shortcuts,
        "mode": .mapping(fields: [
            "followFocus": .scalar,
            "space": .opaque,
        ]),
        // Kept in the schema so the dedicated removed-key diagnostic from
        // ShitsuraeConfigFile remains more actionable than "unknown key".
        "executionPolicy": .opaque,
    ])
}
