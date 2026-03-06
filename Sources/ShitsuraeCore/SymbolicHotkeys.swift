import Darwin
import Foundation

public enum NativeSymbolicHotKey: Int32, CaseIterable, Sendable {
    case commandTab = 1
    case commandShiftTab = 2
    case commandKeyAboveTab = 6
}

public enum SymbolicHotKeyController {
    public static let commandTabGroup: [NativeSymbolicHotKey] = [.commandTab, .commandShiftTab]

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
}
