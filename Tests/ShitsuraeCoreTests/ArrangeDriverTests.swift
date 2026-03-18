import XCTest
@testable import ShitsuraeCore

final class ArrangeDriverTests: XCTestCase {
    func testMoveWindowToSpaceDelegatesToDragWindowSpaceSwitcher() {
        let switcher = StubWindowSpaceSwitcher(result: true)
        let relaySwitcher = StubWindowDisplayRelaySpaceSwitcher(result: true)
        let driver = LiveArrangeDriver(windowSpaceSwitcher: switcher, displayRelaySpaceSwitcher: relaySwitcher)

        let result = driver.moveWindowToSpace(
            windowID: 123,
            bundleID: "com.example.app",
            displayID: "display-a",
            spaceID: 2,
            spacesMode: .perDisplay,
            method: .drag
        )

        XCTAssertTrue(result)
        XCTAssertEqual(switcher.calls.count, 1)
        XCTAssertEqual(switcher.calls.first?.windowID, 123)
        XCTAssertEqual(switcher.calls.first?.targetSpaceID, 2)
        XCTAssertTrue(relaySwitcher.calls.isEmpty)
    }

    func testMoveWindowToSpaceDelegatesToDisplayRelaySpaceSwitcher() {
        let switcher = StubWindowSpaceSwitcher(result: true)
        let relaySwitcher = StubWindowDisplayRelaySpaceSwitcher(result: true)
        let driver = LiveArrangeDriver(windowSpaceSwitcher: switcher, displayRelaySpaceSwitcher: relaySwitcher)

        let result = driver.moveWindowToSpace(
            windowID: 321,
            bundleID: "org.alacritty",
            displayID: "display-primary",
            spaceID: 3,
            spacesMode: .perDisplay,
            method: .displayRelay
        )

        XCTAssertTrue(result)
        XCTAssertTrue(switcher.calls.isEmpty)
        XCTAssertEqual(relaySwitcher.calls.count, 1)
        XCTAssertEqual(relaySwitcher.calls.first?.windowID, 321)
        XCTAssertEqual(relaySwitcher.calls.first?.bundleID, "org.alacritty")
        XCTAssertEqual(relaySwitcher.calls.first?.targetDisplayID, "display-primary")
        XCTAssertEqual(relaySwitcher.calls.first?.targetSpaceID, 3)
    }

    func testBackendAvailableUsesCatalog() {
        let driver = LiveArrangeDriver(
            windowSpaceSwitcher: StubWindowSpaceSwitcher(result: true),
            displayRelaySpaceSwitcher: StubWindowDisplayRelaySpaceSwitcher(result: true)
        )
        let missingURL = URL(fileURLWithPath: "/tmp/missing-catalog-\(UUID().uuidString).json")
        let availability = driver.backendAvailable(catalogURL: missingURL)
        XCTAssertEqual(availability.0, false)
        XCTAssertEqual(availability.1, "catalogNotFound")
    }

    func testSpacesIsCallable() {
        let driver = LiveArrangeDriver(
            windowSpaceSwitcher: StubWindowSpaceSwitcher(result: true),
            displayRelaySpaceSwitcher: StubWindowDisplayRelaySpaceSwitcher(result: true)
        )
        _ = driver.spaces()
    }

    func testActivateAndSleepAreCallable() {
        let driver = LiveArrangeDriver(
            windowSpaceSwitcher: StubWindowSpaceSwitcher(result: true),
            displayRelaySpaceSwitcher: StubWindowDisplayRelaySpaceSwitcher(result: true)
        )
        _ = driver.activate(bundleID: "com.example.nonexistent")
        driver.sleep(milliseconds: 1)
    }
}

private final class StubWindowSpaceSwitcher: WindowSpaceSwitching {
    struct Call {
        let windowID: UInt32
        let targetSpaceID: Int
    }

    private let result: Bool
    var calls: [Call] = []

    init(result: Bool) {
        self.result = result
    }

    func moveWindow(windowID: UInt32, targetSpaceID: Int) -> Bool {
        calls.append(Call(windowID: windowID, targetSpaceID: targetSpaceID))
        return result
    }
}

private final class StubWindowDisplayRelaySpaceSwitcher: DisplayRelayWindowSpaceSwitching {
    struct Call {
        let windowID: UInt32
        let bundleID: String
        let targetDisplayID: String?
        let targetSpaceID: Int
        let spacesMode: SpacesMode
    }

    private let result: Bool
    var calls: [Call] = []

    init(result: Bool) {
        self.result = result
    }

    func moveWindow(
        windowID: UInt32,
        bundleID: String,
        targetDisplayID: String?,
        targetSpaceID: Int,
        spacesMode: SpacesMode
    ) -> Bool {
        calls.append(
            Call(
                windowID: windowID,
                bundleID: bundleID,
                targetDisplayID: targetDisplayID,
                targetSpaceID: targetSpaceID,
                spacesMode: spacesMode
            )
        )
        return result
    }
}
