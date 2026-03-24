import CoreGraphics
import Foundation
import XCTest
@testable import ShitsuraeCore

final class VirtualSpaceVisibilitySupportTests: XCTestCase {
    func testApplyVirtualVisibilityPlanFrameFailureDoesNotTakeExtraSnapshot() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("visibility.log")
        let logger = ShitsuraeLogger(logFileURL: logURL)

        var snapshotCalls = 0
        let hooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            setWindowFrame: { _, _, _ in false },
            listWindowsOnAllSpaces: {
                snapshotCalls += 1
                return []
            }
        )

        let window = makeWindow(windowID: 100, frame: ResolvedFrame(x: 0, y: 0, width: 400, height: 300))
        let targetFrame = ResolvedFrame(x: 100, y: 80, width: 500, height: 320)
        let plan = VirtualVisibilityPlan(
            updatedEntry: makeSlotEntry(),
            mutation: .frame(targetFrame),
            restoreFromMinimized: false,
            action: "shown"
        )

        let succeeded = applyVirtualVisibilityPlan(
            window: window,
            plan: plan,
            hooks: hooks,
            logger: logger
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(snapshotCalls, 0)

        let event = try lastLogEvent(at: logURL)
        XCTAssertEqual(event["event"] as? String, "virtual.visibility.apply.failed")
        XCTAssertNil(event["actualFrame"])
        XCTAssertNil(event["actualSpaceID"])
        XCTAssertNil(event["actualDisplayID"])
    }

    func testApplyVirtualVisibilityPlanPositionFailureDoesNotTakeExtraSnapshot() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let logURL = tempDir.appendingPathComponent("visibility.log")
        let logger = ShitsuraeLogger(logFileURL: logURL)

        var snapshotCalls = 0
        let hooks = CommandServiceRuntimeHooks(
            accessibilityGranted: { true },
            listWindows: { [] },
            focusedWindow: { nil },
            activateBundle: { _ in true },
            setFocusedWindowFrame: { _ in true },
            displays: { [] },
            runProcess: { _, _ in (0, "") },
            setWindowPosition: { _, _, _ in false },
            listWindowsOnAllSpaces: {
                snapshotCalls += 1
                return []
            }
        )

        let window = makeWindow(windowID: 101, frame: ResolvedFrame(x: 0, y: 0, width: 400, height: 300))
        let plan = VirtualVisibilityPlan(
            updatedEntry: makeSlotEntry(),
            mutation: .position(CGPoint(x: 900, y: 120)),
            restoreFromMinimized: false,
            action: "hiddenOffscreen"
        )

        let succeeded = applyVirtualVisibilityPlan(
            window: window,
            plan: plan,
            hooks: hooks,
            logger: logger
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(snapshotCalls, 0)

        let event = try lastLogEvent(at: logURL)
        XCTAssertEqual(event["event"] as? String, "virtual.visibility.apply.failed")
        XCTAssertNil(event["actualPosition"])
        XCTAssertNil(event["actualFrame"])
        XCTAssertNil(event["actualSpaceID"])
        XCTAssertNil(event["actualDisplayID"])
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-virtual-visibility-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lastLogEvent(at url: URL) throws -> [String: Any] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let line = try XCTUnwrap(content.split(separator: "\n").last)
        let data = Data(line.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeSlotEntry() -> SlotEntry {
        SlotEntry(
            layoutName: "work",
            slot: 1,
            source: .window,
            bundleID: "com.apple.TextEdit",
            definitionFingerprint: "slot-1",
            spaceID: 1,
            displayID: "display-a",
            windowID: 100
        )
    }

    private func makeWindow(windowID: UInt32, frame: ResolvedFrame) -> WindowSnapshot {
        WindowSnapshot(
            windowID: windowID,
            bundleID: "com.apple.TextEdit",
            pid: 100,
            title: "Editor",
            role: "AXWindow",
            subrole: nil,
            minimized: false,
            hidden: false,
            frame: frame,
            spaceID: 7,
            displayID: "display-a",
            isFullscreen: false,
            frontIndex: 0
        )
    }
}
