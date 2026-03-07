import Carbon.HIToolbox
import XCTest
@testable import ShitsuraeCore

final class KeyboardKeyTests: XCTestCase {
    func testOverlayCommandKeyNameResolvesLeftBracketKeyCode() {
        XCTAssertEqual(overlayCommandKeyName(forKeyCode: Int(kVK_ANSI_LeftBracket)), "[")
    }

    func testOverlayCommandKeyNameResolvesEscapeKeyCode() {
        XCTAssertEqual(overlayCommandKeyName(forKeyCode: Int(kVK_Escape)), "esc")
    }

    func testKeyCodeResolvesLeftBracketKeyName() {
        XCTAssertEqual(keyCode(for: "["), Int(kVK_ANSI_LeftBracket))
    }
}
