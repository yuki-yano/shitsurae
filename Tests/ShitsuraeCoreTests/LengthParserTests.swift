import Testing
@testable import ShitsuraeCore

@Suite("LengthParser")
struct LengthParserTests {
    @Test func parsesPercent() throws {
        let parsed = try LengthParser.parse("50%")
        #expect(parsed == ParsedLength(value: 50, unit: .percent))
        #expect(parsed.resolve(dimension: 1000, scale: 2) == 500)
    }

    @Test func parsesRatio() throws {
        let parsed = try LengthParser.parse("0.25r")
        #expect(parsed == ParsedLength(value: 0.25, unit: .ratio))
        #expect(parsed.resolve(dimension: 800, scale: 1) == 200)
    }

    @Test func parsesPt() throws {
        #expect(try LengthParser.parse("12pt") == ParsedLength(value: 12, unit: .pt))
        #expect(try LengthParser.parse("12") == ParsedLength(value: 12, unit: .pt))
    }

    @Test func parsesPx() throws {
        let parsed = try LengthParser.parse("100px")
        #expect(parsed == ParsedLength(value: 100, unit: .px))
        #expect(parsed.resolve(dimension: 0, scale: 2) == 50)
    }

    @Test func rejectsOutOfRangePercent() {
        #expect(throws: ShitsuraeError.self) {
            try LengthParser.parse("120%")
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: ShitsuraeError.self) {
            try LengthParser.parse("abc")
        }
    }
}
