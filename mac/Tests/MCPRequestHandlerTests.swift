import XCTest

/// Covers the JSON-RPC side of `password-filler-mcp` (design.md D5): handshake
/// versions, notifications, the one tool, and every error code.
final class MCPRequestHandlerTests: XCTestCase {

    private func handler(hosts: @escaping () throws -> [String] = { ["a.example.com", "b.example.org"] }) -> MCPRequestHandler {
        MCPRequestHandler(serverVersion: "9.9.9", hosts: hosts)
    }

    // MARK: - initialize

    func testInitializeEchoesEverySupportedVersion() throws {
        for version in MCPRequestHandler.supportedProtocolVersions {
            let result = try XCTUnwrap(response(to: initialize(version: version))["result"] as? [String: Any])
            XCTAssertEqual(result["protocolVersion"] as? String, version)
        }
    }

    func testInitializeFallsBackToLatestForUnknownVersion() throws {
        let result = try XCTUnwrap(response(to: initialize(version: "2026-07-28"))["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
    }

    func testInitializeAnnouncesServerToolsAndInstructions() throws {
        let result = try XCTUnwrap(response(to: initialize(version: "2025-06-18"))["result"] as? [String: Any])
        XCTAssertEqual(result["serverInfo"] as? NSDictionary,
                       ["name": "password-filler", "title": "Password Filler", "version": "9.9.9"])
        XCTAssertEqual(result["capabilities"] as? NSDictionary, ["tools": ["listChanged": false]])
        XCTAssertEqual(result["instructions"] as? String, MCPInstructions.text)
    }

    // MARK: - notifications, ping, tools/list

    func testNotificationsAreNeverAnswered() {
        XCTAssertNil(handler().handle(line: line(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        XCTAssertNil(handler().handle(line: line(["jsonrpc": "2.0", "method": "ping"])))
    }

    func testPingReturnsEmptyResult() throws {
        let reply = try response(to: ["jsonrpc": "2.0", "id": "p-1", "method": "ping"])
        XCTAssertEqual(reply as NSDictionary, ["jsonrpc": "2.0", "id": "p-1", "result": [String: Any]()])
    }

    func testToolsListReturnsExactlyListHosts() throws {
        let result = try XCTUnwrap(response(to: request("tools/list"))["result"] as? [String: Any])
        XCTAssertEqual(result as NSDictionary, ["tools": [MCPRequestHandler.listHostsTool]])
    }

    // MARK: - tools/call

    func testListHostsReturnsOneHostPerLine() throws {
        let result = try callListHosts(handler())
        XCTAssertEqual(result as NSDictionary,
                       ["content": [["type": "text", "text": "a.example.com\nb.example.org"]], "isError": false])
    }

    func testListHostsWithEmptyCacheTellsToRefresh() throws {
        let result = try callListHosts(handler(hosts: { [] }))
        XCTAssertEqual(result as NSDictionary, ["content": [["type": "text",
            "text": "No entries in the cache. Ask the user to click Refresh in the Password Filler menu bar."]], "isError": false])
    }

    func testListHostsReportsAgentErrorsAsToolErrors() throws {
        for error in [AgentClientError.disabled, .unreachable, .forbidden] {
            let result = try callListHosts(handler(hosts: { throw error }))
            XCTAssertEqual(result as NSDictionary,
                           ["content": [["type": "text", "text": MCPInstructions.message(for: error)]], "isError": true],
                           "\(error)")
        }
    }

    // MARK: - errors

    func testUnknownMethodIsMethodNotFound() throws {
        XCTAssertEqual(try errorCode(request("resources/list")), -32601)
    }

    func testUnknownToolIsInvalidParams() throws {
        XCTAssertEqual(try errorCode(request("tools/call", params: ["name": "get_password"])), -32602)
    }

    func testListHostsWithArgumentsIsInvalidParams() throws {
        XCTAssertEqual(try errorCode(request("tools/call", params: ["name": "list_hosts", "arguments": ["host": "x"]])), -32602)
    }

    func testMalformedJSONIsParseErrorWithNullID() throws {
        let reply = try XCTUnwrap(handler().handle(line: Data("{not json".utf8)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertTrue(object["id"] is NSNull)
        XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testResponsesNeverContainARawNewline() throws {
        let reply = try XCTUnwrap(handler().handle(line: line(request("tools/call", params: ["name": "list_hosts"]))))
        XCTAssertFalse(reply.contains(0x0A), "a raw newline would split the message on the stdio transport")
    }

    // MARK: - Helpers

    private func initialize(version: String) -> [String: Any] {
        request("initialize", params: ["protocolVersion": version, "capabilities": [String: Any](),
                                       "clientInfo": ["name": "fake-client", "version": "0"]])
    }

    private func request(_ method: String, params: [String: Any]? = nil) -> [String: Any] {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method]
        object["params"] = params
        return object
    }

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func response(to object: [String: Any], handler: MCPRequestHandler? = nil) throws -> [String: Any] {
        let reply = try XCTUnwrap((handler ?? self.handler()).handle(line: line(object)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
    }

    private func callListHosts(_ handler: MCPRequestHandler) throws -> [String: Any] {
        let reply = try response(to: request("tools/call", params: ["name": "list_hosts"]), handler: handler)
        return try XCTUnwrap(reply["result"] as? [String: Any])
    }

    private func errorCode(_ object: [String: Any]) throws -> Int? {
        (try response(to: object)["error"] as? [String: Any])?["code"] as? Int
    }
}
