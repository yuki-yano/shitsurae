import Foundation
import ShitsuraeCore

enum ShortcutOverlaySessionKind {
    case switcher
    case cycle
}

struct ShortcutOverlaySession {
    let kind: ShortcutOverlaySessionKind
    var candidates: [SwitcherCandidate]
    var selectedIndex: Int
    let quickKeys: String
    let acceptKeys: [String]
    let cancelKeys: [String]
    var holdModifiers: Set<String>

    mutating func advance(forward: Bool, holdModifiers: Set<String>) {
        guard !candidates.isEmpty else {
            return
        }

        selectedIndex = forward
            ? (selectedIndex + 1) % candidates.count
            : (selectedIndex - 1 + candidates.count) % candidates.count
        self.holdModifiers = holdModifiers
    }
}
