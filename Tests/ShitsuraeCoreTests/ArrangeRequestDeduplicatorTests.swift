import Foundation
import XCTest
@testable import ShitsuraeCore

final class ArrangeRequestDeduplicatorTests: XCTestCase {
    func testSuppressesDuplicateLayoutWithinWindow() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests")
            .appendingPathComponent("\(UUID().uuidString)-recent-arrange.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        var now = Date(timeIntervalSince1970: 1000)
        let deduplicator = FileBasedArrangeRequestDeduplicator(
            fileURL: fileURL,
            duplicateWindowSeconds: 2,
            now: { now }
        )

        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: nil))
        now = now.addingTimeInterval(1)
        XCTAssertTrue(deduplicator.shouldSuppress(layoutName: "default", spaceID: nil))
        now = now.addingTimeInterval(3)
        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: nil))
    }

    func testDoesNotSuppressDifferentLayout() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests")
            .appendingPathComponent("\(UUID().uuidString)-recent-arrange.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let deduplicator = FileBasedArrangeRequestDeduplicator(
            fileURL: fileURL,
            duplicateWindowSeconds: 2,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: nil))
        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "work", spaceID: nil))
    }

    func testDoesNotSuppressSameLayoutWhenSpaceIDDiffers() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shitsurae-tests")
            .appendingPathComponent("\(UUID().uuidString)-recent-arrange.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let deduplicator = FileBasedArrangeRequestDeduplicator(
            fileURL: fileURL,
            duplicateWindowSeconds: 2,
            now: { Date(timeIntervalSince1970: 1000) }
        )

        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: nil))
        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: 1))
        XCTAssertFalse(deduplicator.shouldSuppress(layoutName: "default", spaceID: 2))
    }
}
