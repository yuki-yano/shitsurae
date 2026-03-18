import Darwin
import Carbon.HIToolbox
import Foundation

public enum NativeSymbolicHotKey: Int32, CaseIterable, Sendable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
    case switchToDesktop1 = 118
    case switchToDesktop2 = 119
    case switchToDesktop3 = 120
    case switchToDesktop4 = 121
    case switchToDesktop5 = 122
    case switchToDesktop6 = 123
    case switchToDesktop7 = 124
    case switchToDesktop8 = 125
    case switchToDesktop9 = 126
}

public struct NativeSymbolicHotKeyBinding: Equatable {
    public let keyCode: Int
    public let modifiers: UInt32
    public let enabled: Bool
}

public enum SymbolicHotKeyController {
    public static let commandTabGroup: [NativeSymbolicHotKey] = [.commandTab, .commandShiftTab]
    public static let desktopSwitchGroup: [NativeSymbolicHotKey] = [
        .switchToDesktop1,
        .switchToDesktop2,
        .switchToDesktop3,
        .switchToDesktop4,
        .switchToDesktop5,
        .switchToDesktop6,
        .switchToDesktop7,
        .switchToDesktop8,
        .switchToDesktop9,
    ]

    private typealias CGSSetSymbolicHotKeyEnabledFn = @convention(c) (Int32, Bool) -> Int32

    private nonisolated(unsafe) static let skyLightHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )

    private static let setSymbolicHotKeyEnabled: CGSSetSymbolicHotKeyEnabledFn? = {
        guard let skyLightHandle,
              let symbol = dlsym(skyLightHandle, "CGSSetSymbolicHotKeyEnabled")
        else {
            return nil
        }
        return unsafeBitCast(symbol, to: CGSSetSymbolicHotKeyEnabledFn.self)
    }()

    @discardableResult
    public static func setEnabled(_ isEnabled: Bool, hotKeys: [NativeSymbolicHotKey]) -> Bool {
        guard let setSymbolicHotKeyEnabled else {
            return false
        }

        for hotKey in hotKeys {
            _ = setSymbolicHotKeyEnabled(hotKey.rawValue, isEnabled)
        }
        return true
    }

    public static func nativeDesktopHotKeysToDisable(
        switchVirtualSpace: [Int: HotkeyDefinition],
        moveCurrentWindowToSpace: [Int: HotkeyDefinition],
        symbolicHotKeyDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")
    ) -> Set<NativeSymbolicHotKey> {
        Set(desktopSwitchGroup.filter { hotKey in
            guard let desktopIndex = desktopIndex(for: hotKey),
                  let binding = binding(for: hotKey, symbolicHotKeyDomain: symbolicHotKeyDomain)
            else {
                return false
            }

            let candidateDefinitions = [
                switchVirtualSpace[desktopIndex],
                moveCurrentWindowToSpace[desktopIndex],
            ].compactMap { $0 }

            return candidateDefinitions.contains { definition in
                guard let expectedKeyCode = keyCode(for: definition.key) else {
                    return false
                }
                return binding.enabled
                    && binding.keyCode == expectedKeyCode
                    && binding.modifiers == symbolicHotKeyModifiers(definition.modifiers)
            }
        })
    }

    public static func binding(
        for hotKey: NativeSymbolicHotKey,
        symbolicHotKeyDomain: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")
    ) -> NativeSymbolicHotKeyBinding? {
        guard let symbolicHotKeys = symbolicHotKeyDomain?["AppleSymbolicHotKeys"] as? [String: Any],
              let rawEntry = symbolicHotKeys[String(hotKey.rawValue)] as? [String: Any]
        else {
            return nil
        }

        let enabled = boolValue(rawEntry["enabled"])
        guard let value = rawEntry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = intValue(parameters[1]),
              let modifiers = intValue(parameters[2])
        else {
            return nil
        }

        return NativeSymbolicHotKeyBinding(
            keyCode: keyCode,
            modifiers: UInt32(modifiers),
            enabled: enabled
        )
    }

    private static func desktopIndex(for hotKey: NativeSymbolicHotKey) -> Int? {
        switch hotKey {
        case .switchToDesktop1: return 1
        case .switchToDesktop2: return 2
        case .switchToDesktop3: return 3
        case .switchToDesktop4: return 4
        case .switchToDesktop5: return 5
        case .switchToDesktop6: return 6
        case .switchToDesktop7: return 7
        case .switchToDesktop8: return 8
        case .switchToDesktop9: return 9
        default: return nil
        }
    }

    private static func symbolicHotKeyModifiers(_ modifiers: [String]) -> UInt32 {
        var result: UInt32 = 0
        for modifier in modifiers {
            switch modifier.lowercased() {
            case "cmd":
                result |= UInt32(cmdKey)
            case "shift":
                result |= UInt32(shiftKey)
            case "ctrl":
                result |= UInt32(controlKey)
            case "alt":
                result |= UInt32(optionKey)
            case "fn":
                result |= UInt32(kEventKeyModifierFnMask)
            default:
                break
            }
        }
        return result
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber:
            return number.boolValue
        case let bool as Bool:
            return bool
        default:
            return false
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        default:
            return nil
        }
    }
}
