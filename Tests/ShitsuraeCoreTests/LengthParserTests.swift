import XCTest
@testable import ShitsuraeCore

final class LengthParserTests: XCTestCase {
    func testParsePercentAndRatio() throws {
        let percent = try LengthParser.parse("50%")
        XCTAssertEqual(percent.unit, .percent)
        XCTAssertEqual(percent.value, 50)

        let ratio = try LengthParser.parse("0.5r")
        XCTAssertEqual(ratio.unit, .ratio)
        XCTAssertEqual(ratio.value, 0.5)
    }

    func testParsePxRoundToPoint() throws {
        let px = try LengthParser.parse("2560px")
        XCTAssertEqual(px.resolve(dimension: 0, scale: 2.0), 1280)
    }

    func testPercentOutOfRangeThrows() {
        XCTAssertThrowsError(try LengthParser.parse("100.1%"))
        XCTAssertThrowsError(try LengthParser.parse("-0.1%"))
    }

    func testRatioOutOfRangeThrows() {
        XCTAssertThrowsError(try LengthParser.parse("1.1r"))
        XCTAssertThrowsError(try LengthParser.parse("-0.1r"))
    }

    func testResolveFrameValidation() throws {
        let frame = FrameDefinition(
            x: .expression("0%"),
            y: .expression("0%"),
            width: .expression("100%"),
            height: .expression("100%")
        )

        let resolved = try LengthParser.resolveFrame(
            frame,
            basis: CGRect(x: 0, y: 0, width: 1000, height: 500),
            scale: 2
        )

        XCTAssertEqual(resolved.x, 0)
        XCTAssertEqual(resolved.y, 0)
        XCTAssertEqual(resolved.width, 1000)
        XCTAssertEqual(resolved.height, 500)
    }
}
