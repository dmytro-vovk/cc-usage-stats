import XCTest
@testable import CCUsageStats

final class MCPServerTests: XCTestCase {
    private var calls = 0
    private lazy var server = MCPServer(version: "9.9.9") { [unowned self] in
        calls += 1
        return ["hello": "world"]
    }

    private func reply(_ line: String) throws -> [String: Any] {
        let out = try XCTUnwrap(server.handle(line: line), "expected a response")
        XCTAssertFalse(out.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
    }

    func testInitializeEchoesAKnownProtocolVersion() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(r["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(r["id"] as? Int, 1)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "cc-usage-stats")
        XCTAssertEqual(info["version"] as? String, "9.9.9")
    }

    func testInitializeAnswersNewestForAnUnknownVersion() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(r["id"] as? String, "a", "string ids are echoed as strings")
        XCTAssertEqual((r["result"] as? [String: Any])?["protocolVersion"] as? String, MCPServer.supportedProtocolVersions.last)
    }

    func testNotificationsAreNeverAnswered() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","method":"tools/list"}"#), "no id = notification, even for a request method")
        XCTAssertNil(server.handle(line: "   "), "blank lines are ignored")
    }

    func testPing() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        XCTAssertEqual((r["result"] as? [String: Any])?.count, 0)
    }

    func testToolsListAdvertisesReadOnlyGetUsage() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((r["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "get_usage")
        XCTAssertFalse((tools[0]["description"] as? String ?? "").isEmpty)
        let schema = try XCTUnwrap(tools[0]["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual((tools[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(calls, 0, "listing must not read usage")
    }

    func testToolsCallReturnsTheReportAsJSONText() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_usage","arguments":{}}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(body["hello"] as? String, "world")
        XCTAssertEqual(calls, 1)
    }

    func testToolTextUsesShortestNumbersAndEscapes() throws {
        let s = MCPServer(version: "1") {
            ["f": 0.4344, "i": Int64(7), "b": true, "n": NSNull(), "s": "a\"b\\c\n\u{1}", "a": [1.5, 0.0]]
        }
        let out = try XCTUnwrap(s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_usage"}}"#))
        let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let text = try XCTUnwrap(((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertEqual(text, #"{"a":[1.5,0],"b":true,"f":0.4344,"i":7,"n":null,"s":"a\"b\\c\n\u0001"}"#)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(back["s"] as? String, "a\"b\\c\n\u{1}")
    }

    func testToolsCallWithoutArgumentsWorks() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_usage"}}"#)
        XCTAssertEqual((r["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testUnknownToolIsAToolError() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}"#)
        let result = try XCTUnwrap(r["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(calls, 0)
    }

    func testUnknownMethodIsMethodNotFound() throws {
        let r = try reply(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32601)
        XCTAssertEqual(r["id"] as? Int, 6)
    }

    func testMalformedJSONIsParseErrorWithNullId() throws {
        let r = try reply("{not json")
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertTrue(r["id"] is NSNull)
    }

    func testNonObjectMessageIsInvalidRequest() throws {
        let r = try reply(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual((r["error"] as? [String: Any])?["code"] as? Int, -32600)
    }

    func testResponsesFromTheClientAreIgnored() {
        XCTAssertNil(server.handle(line: #"{"jsonrpc":"2.0","id":9,"result":{}}"#))
    }

    func testLaunchFlagDetection() {
        XCTAssertTrue(MCPServer.isRequested(arguments: ["/x/CCUsageStats", "--mcp-server"]))
        XCTAssertFalse(MCPServer.isRequested(arguments: ["/x/CCUsageStats"]))
        XCTAssertFalse(MCPServer.isRequested(arguments: ["/x/CCUsageStats", "-psn_0_123"]))
    }
}
