import XCTest
@testable import ShitsuraeCore

final class WindowMatchEngineTests: XCTestCase {
    func testSelectByTitleContainsAndFrontOrder() {
        let rule = WindowMatchRule(
            bundleID: "com.example.app",
            title: TitleMatcher(equals: nil, contains: "Main", regex: nil),
            role: "AXWindow",
            subrole: nil,
            excludeTitleRegex: nil,
            index: nil
        )

        let first = window(id: 10, title: "Main - 2", frontIndex: 1)
        let second = window(id: 9, title: "Main - 1", frontIndex: 0)
        let selected = WindowMatchEngine.select(rule: rule, candidates: [first, second])

        XCTAssertEqual(selected?.windowID, 9)
    }

    func testSelectByIndex() {
        let rule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: nil,
            index: 2
        )

        let selected = WindowMatchEngine.select(
            rule: rule,
            candidates: [
                window(id: 1, title: "A", frontIndex: 0),
                window(id: 2, title: "B", frontIndex: 1),
                window(id: 3, title: "C", frontIndex: 2),
            ]
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    func testExcludeTitleRegex() {
        let rule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: "Settings",
            index: nil
        )

        let selected = WindowMatchEngine.select(
            rule: rule,
            candidates: [
                window(id: 1, title: "Settings", frontIndex: 0),
                window(id: 2, title: "Editor", frontIndex: 1),
            ]
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    func testSelectByProfileDirectory() {
        let rule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: "Profile 1",
            excludeTitleRegex: nil,
            index: nil
        )

        let selected = WindowMatchEngine.select(
            rule: rule,
            candidates: [
                window(id: 1, title: "Work", frontIndex: 0, profileDirectory: "Default"),
                window(id: 2, title: "Personal", frontIndex: 1, profileDirectory: "Profile 1"),
            ]
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    func testSelectPrefersWindowWithSpaceAndNonEmptyTitleOverAuxiliaryWindows() {
        let rule = WindowMatchRule(
            bundleID: "com.example.app",
            title: nil,
            role: nil,
            subrole: nil,
            profile: nil,
            excludeTitleRegex: nil,
            index: nil
        )

        let selected = WindowMatchEngine.select(
            rule: rule,
            candidates: [
                window(id: 1, title: "", frontIndex: 0, width: 2624, height: 54, spaceID: nil),
                window(id: 2, title: "Main Window", frontIndex: 10, width: 3550, height: 2111, spaceID: 3),
            ]
        )

        XCTAssertEqual(selected?.windowID, 2)
    }

    private func window(
        id: UInt32,
        title: String,
        frontIndex: Int,
        width: Double = 100,
        height: Double = 100,
        spaceID: Int? = 1,
        profileDirectory: String? = nil
    ) -> WindowSnapshot {
        WindowSnapshot(
            windowID: id,
            bundleID: "com.example.app",
            pid: 100,
            title: title,
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 0, y: 0, width: width, height: height),
            spaceID: spaceID,
            displayID: "display-1",
            profileDirectory: profileDirectory,
            isFullscreen: false,
            frontIndex: frontIndex
        )
    }
}
