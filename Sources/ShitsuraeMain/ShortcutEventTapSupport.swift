@preconcurrency import AppKit
import Foundation
import ShitsuraeCore

func eventMatchesHotkey(event: CGEvent, key: String, modifiers: [String]) -> Bool {
    guard let expectedKeyCode = keyCode(for: key) else {
        return false
    }

    let actualKeyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    guard actualKeyCode == expectedKeyCode else {
        return false
    }

    let expected = Set(modifiers.map { $0.lowercased() })
    return eventModifierSet(flags: event.flags) == expected
}

func eventModifierSet(flags: CGEventFlags) -> Set<String> {
    var result = Set<String>()
    if flags.contains(.maskCommand) {
        result.insert("cmd")
    }
    if flags.contains(.maskShift) {
        result.insert("shift")
    }
    if flags.contains(.maskControl) {
        result.insert("ctrl")
    }
    if flags.contains(.maskAlternate) {
        result.insert("alt")
    }
    if flags.contains(.maskSecondaryFn) {
        result.insert("fn")
    }
    return result
}

func normalizedKey(from event: CGEvent) -> String {
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if let key = overlayCommandKeyName(forKeyCode: keyCode) {
        return key
    }

    var chars = [UniChar](repeating: 0, count: 4)
    var length: Int = 0
    event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
    guard length > 0 else { return "" }
    return String(utf16CodeUnits: chars, count: length).lowercased()
}
