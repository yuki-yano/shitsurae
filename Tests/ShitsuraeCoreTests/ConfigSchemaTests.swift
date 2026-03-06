import Foundation
import XCTest

final class ConfigSchemaTests: XCTestCase {
    func testConfigSchemaExistsAndIncludesSpaceMoveMethodDefinitions() throws {
        let schemaURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("schemas/shitsurae-config.schema.json")

        let data = try Data(contentsOf: schemaURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
        XCTAssertEqual(
            root["$id"] as? String,
            "https://raw.githubusercontent.com/yuki-yano/shitsurae/main/schemas/shitsurae-config.schema.json"
        )

        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let layouts = try XCTUnwrap(properties["layouts"] as? [String: Any])
        let patternProperties = try XCTUnwrap(layouts["patternProperties"] as? [String: Any])
        XCTAssertNotNil(patternProperties["^[A-Za-z0-9._-]+$"])

        let defs = try XCTUnwrap(root["$defs"] as? [String: Any])
        let executionPolicy = try XCTUnwrap(defs["executionPolicy"] as? [String: Any])
        let executionPolicyProperties = try XCTUnwrap(executionPolicy["properties"] as? [String: Any])
        XCTAssertNotNil(executionPolicyProperties["spaceMoveMethod"])

        let spaceMoveMethodInApps = try XCTUnwrap(executionPolicyProperties["spaceMoveMethodInApps"] as? [String: Any])
        let additionalProperties = try XCTUnwrap(spaceMoveMethodInApps["additionalProperties"] as? [String: Any])
        XCTAssertEqual(additionalProperties["$ref"] as? String, "#/$defs/spaceMoveMethod")
    }
}
