import Foundation

/// MCP over stdio (newline-delimited JSON-RPC 2.0), legacy `initialize`
/// handshake — design.md D5. Pure: one input line in, at most one output line
/// out (without the trailing newline). Notifications are never answered.
struct MCPRequestHandler {

    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let serverVersion: String
    /// Hostnames from the Agent; throws `AgentClientError`.
    let hosts: () throws -> [String]

    func handle(line: Data) -> Data? {
        let message: Any
        do {
            message = try JSONSerialization.jsonObject(with: line)
        } catch {
            return encodeError(id: NSNull(), code: -32700, message: "Parse error: \(error.localizedDescription)")
        }
        guard let request = message as? [String: Any] else {
            return encodeError(id: NSNull(), code: -32600, message: "Invalid Request: expected a JSON object")
        }
        let id = request["id"]
        guard let method = request["method"] as? String else {
            // A response to a request we never send, or garbage: nothing to answer.
            guard let id, request["result"] == nil, request["error"] == nil else { return nil }
            return encodeError(id: id, code: -32600, message: "Invalid Request: missing method")
        }
        guard let id else { return nil }

        switch method {
        case "initialize":
            return encodeResult(id: id, initializeResult(params: request["params"] as? [String: Any]))
        case "ping":
            return encodeResult(id: id, [String: Any]())
        case "tools/list":
            return encodeResult(id: id, ["tools": [Self.listHostsTool]])
        case "tools/call":
            return callTool(id: id, params: request["params"] as? [String: Any])
        default:
            return encodeError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Methods

    private func initializeResult(params: [String: Any]?) -> [String: Any] {
        let requested = params?["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "password-filler", "title": "Password Filler", "version": serverVersion],
            "instructions": MCPInstructions.text,
        ]
    }

    private func callTool(id: Any, params: [String: Any]?) -> Data {
        guard let name = params?["name"] as? String else {
            return encodeError(id: id, code: -32602, message: "Invalid params: missing tool name")
        }
        guard name == "list_hosts" else {
            return encodeError(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
        if let arguments = params?["arguments"] as? [String: Any], !arguments.isEmpty {
            return encodeError(id: id, code: -32602, message: "list_hosts takes no arguments")
        }
        do {
            let hosts = try hosts()
            let text = hosts.isEmpty
                ? "No entries in the cache. Ask the user to click Refresh in the Password Filler menu bar."
                : hosts.joined(separator: "\n")
            return encodeResult(id: id, toolResult(text: text, isError: false))
        } catch let error as AgentClientError {
            return encodeResult(id: id, toolResult(text: MCPInstructions.message(for: error), isError: true))
        } catch {
            return encodeResult(id: id, toolResult(text: "list_hosts failed: \(error)", isError: true))
        }
    }

    private func toolResult(text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    static let listHostsTool: [String: Any] = [
        "name": "list_hosts",
        "title": "List htaccess hosts",
        "description": "Hostnames for which Password Filler has HTTP Basic Auth credentials. Returns hostnames only, never credentials.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": ["readOnlyHint": true, "openWorldHint": false],
    ]

    // MARK: - Encoding

    private func encodeResult(id: Any, _ result: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encodeError(id: Any, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// Compact JSON never contains a raw newline — strings escape it — so the
    /// line framing of the stdio transport holds.
    private func encode(_ object: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        } catch {
            preconditionFailure("MCP response not JSON-serializable: \(error)")
        }
    }
}
