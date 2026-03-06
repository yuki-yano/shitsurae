import CoreGraphics
import XCTest
@testable import ShitsuraeCore

final class DisplayRelaySpaceSwitcherTests: XCTestCase {
    func testMoveWindowRelaysAcrossSecondaryDisplayAndBackToTargetDisplay() {
        let displays = [
            DisplayInfo(
                id: "display-primary",
                width: 5120,
                height: 2160,
                scale: 2,
                isPrimary: true,
                frame: CGRect(x: 0, y: 0, width: 5120, height: 2160),
                visibleFrame: CGRect(x: 0, y: 0, width: 5120, height: 2135)
            ),
            DisplayInfo(
                id: "display-secondary",
                width: 2624,
                height: 1696,
                scale: 2,
                isPrimary: false,
                frame: CGRect(x: -2624, y: 464, width: 2624, height: 1696),
                visibleFrame: CGRect(x: -2624, y: 464, width: 2624, height: 1647)
            ),
        ]

        var snapshot = WindowSnapshot(
            windowID: 33,
            bundleID: "org.alacritty",
            pid: 100,
            title: "Alacritty",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: ResolvedFrame(x: 10, y: 10, width: 1400, height: 900),
            spaceID: 5,
            displayID: "display-primary",
            isFullscreen: false,
            frontIndex: 0
        )

        var setFrameCalls: [(UInt32, String, ResolvedFrame)] = []
        var switchedSpaces: [Int] = []

        let switcher = DisplayRelayWindowSpaceSwitcher(
            windowProvider: {
                [snapshot]
            },
            displayProvider: { displays },
            frameSetter: { windowID, bundleID, frame in
                setFrameCalls.append((windowID, bundleID, frame))
                if setFrameCalls.count == 1 {
                    snapshot = WindowSnapshot(
                        windowID: snapshot.windowID,
                        bundleID: snapshot.bundleID,
                        pid: snapshot.pid,
                        title: snapshot.title,
                        role: snapshot.role,
                        subrole: snapshot.subrole,
                        minimized: snapshot.minimized,
                        hidden: snapshot.hidden,
                        frame: frame,
                        spaceID: 1,
                        displayID: "display-secondary",
                        isFullscreen: snapshot.isFullscreen,
                        frontIndex: snapshot.frontIndex
                    )
                } else {
                    snapshot = WindowSnapshot(
                        windowID: snapshot.windowID,
                        bundleID: snapshot.bundleID,
                        pid: snapshot.pid,
                        title: snapshot.title,
                        role: snapshot.role,
                        subrole: snapshot.subrole,
                        minimized: snapshot.minimized,
                        hidden: snapshot.hidden,
                        frame: frame,
                        spaceID: 3,
                        displayID: "display-primary",
                        isFullscreen: snapshot.isFullscreen,
                        frontIndex: snapshot.frontIndex
                    )
                }
                return true
            },
            spaceShortcutSwitcher: StubSpaceShortcutSwitcher { targetSpaceID in
                switchedSpaces.append(targetSpaceID)
                return true
            },
            sleep: { _ in }
        )

        let moved = switcher.moveWindow(
            windowID: 33,
            bundleID: "org.alacritty",
            targetDisplayID: "display-primary",
            targetSpaceID: 3,
            spacesMode: .perDisplay
        )

        XCTAssertTrue(moved)
        XCTAssertEqual(switchedSpaces, [3])
        XCTAssertEqual(setFrameCalls.count, 2)
        XCTAssertEqual(setFrameCalls.first?.1, "org.alacritty")
        XCTAssertEqual(snapshot.displayID, "display-primary")
        XCTAssertEqual(snapshot.spaceID, 3)
    }
}

private struct StubSpaceShortcutSwitcher: SpaceShortcutSwitching {
    let impl: (Int) -> Bool

    init(_ impl: @escaping (Int) -> Bool) {
        self.impl = impl
    }

    func switchToSpace(targetSpaceID: Int) -> Bool {
        impl(targetSpaceID)
    }
}
