import XCTest
@testable import SwctxCore
import MCP

/// Wire-contract tests: the engine can be perfect while tools/list ships a
/// schema strict clients reject on load (a `title` property object at the
/// schema root is a reserved-keyword violation). These tests validate the
/// surface agents actually touch, not the engine beneath it.
final class SchemaContractTests: XCTestCase {

    /// Every advertised tool must expose a draft-07-shaped inputSchema:
    /// root type=object, a `properties` dict, `required` ⊆ property names,
    /// and each property a {type, description} object.
    func testAllToolSchemasAreValidJSONObjectSchemas() throws {
        XCTAssertEqual(MCPServer.toolList.count, 23, "tool count drifted — update expectations")
        for tool in MCPServer.toolList {
            let schema = tool.inputSchema
            guard case .object(let root) = schema else {
                return XCTFail("\(tool.name): inputSchema is not an object")
            }
            XCTAssertEqual(root["type"], .string("object"), "\(tool.name): root type must be \"object\"")
            guard case .object(let props)? = root["properties"] else {
                return XCTFail("\(tool.name): missing properties dict — clients see zero declared params")
            }
            // required ⊆ properties
            if case .array(let req)? = root["required"] {
                for r in req {
                    guard case .string(let name) = r else {
                        return XCTFail("\(tool.name): non-string required entry")
                    }
                    XCTAssertNotNil(props[name], "\(tool.name): required '\(name)' not in properties")
                }
            }
            // every property is {type: string, description: string}
            for (pname, pval) in props {
                guard case .object(let p) = pval else {
                    return XCTFail("\(tool.name).\(pname): property is not an object")
                }
                guard case .string = p["type"] else {
                    return XCTFail("\(tool.name).\(pname): missing string 'type'")
                }
                guard case .string = p["description"] else {
                    return XCTFail("\(tool.name).\(pname): missing string 'description'")
                }
            }
        }
    }

    /// Reserved JSON-Schema annotation keywords may only appear at the root
    /// as strings — never as property objects leaked by a flat layout.
    func testNoReservedKeywordHoldsAnObjectAtSchemaRoot() throws {
        let reserved = ["title", "description", "default", "examples", "$schema",
                        "type", "required", "properties", "items", "enum",
                        "additionalProperties", "format", "pattern"]
        for tool in MCPServer.toolList {
            guard case .object(let root) = tool.inputSchema else { continue }
            for key in reserved where key != "type" && key != "required" && key != "properties" {
                if let v = root[key], case .object = v {
                    XCTFail("\(tool.name): reserved keyword '\(key)' holds an object at schema root — strict clients reject the tool")
                }
            }
        }
    }

    /// put_record specifically regressed once: `title` as a sibling of
    /// `type` broke Anthropic API tool loading.
    func testPutRecordSchemaDeclaresTitleInsideProperties() throws {
        let tool = try XCTUnwrap(MCPServer.toolList.first { $0.name == "put_record" })
        guard case .object(let root) = tool.inputSchema,
              case .object(let props)? = root["properties"] else {
            return XCTFail("put_record: malformed inputSchema")
        }
        XCTAssertNotNil(props["title"], "put_record: title must be a declared property")
        XCTAssertNotNil(props["kind"])
        XCTAssertNotNil(props["payload"])
        XCTAssertNil(root["title"], "put_record: title must not leak to schema root")
    }

    /// prime must be reachable over MCP — a CLI-only card cannot be the
    /// fleet's step-0 orientation call.
    func testPrimeIsAnMCPTool() {
        XCTAssertTrue(MCPServer.toolList.contains { $0.name == "prime" },
                      "prime missing from toolList — agents cannot call it")
    }
}
