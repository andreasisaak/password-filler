import XCTest

/// Covers the D4 authorization matrix in `UnixSocketServer.dispatch` — which
/// socket actions each `SocketPeer` may call. Drives `dispatch` directly
/// because a real `.browserBridge` / `.mcpClient` peer needs a signed binary.
final class SocketDispatchMatrixTests: XCTestCase {

    private var server: UnixSocketServer!
    private var store: ItemStore!

    override func setUp() {
        store = ItemStore(ttl: 7 * 86_400)
        store.replace(with: [
            StoredItem.example(hostnames: ["app.example.com"], username: "admin", password: "secret")
        ])
        let config = Config(opAccount: "team.1password.com", opTag: ".htaccess", cacheTtlDays: 7)
        let service = AgentService(
            store: store,
            opClient: OpClient(bundledOpURL: URL(fileURLWithPath: "/dev/null/nonexistent-op"), timeout: 5),
            configProvider: { config },
            configReloader: { config }
        )
        // Never started: dispatch needs no socket.
        server = UnixSocketServer(service: service, authorizer: PeerAuthorizer(requirement: nil))
    }

    // MARK: - .browserBridge

    func testBrowserBridgeLookupReturnsCredentials() throws {
        let reply = try dispatch(["action": "lookup", "hostname": "app.example.com"], as: .browserBridge)
        XCTAssertEqual(reply as NSDictionary, ["found": true, "username": "admin", "password": "secret"])
    }

    func testBrowserBridgeConfigReturnsAccount() throws {
        let reply = try dispatch(["action": "config"], as: .browserBridge)
        XCTAssertEqual(reply as NSDictionary, ["op_account": "team.1password.com"])
    }

    func testBrowserBridgePingReturnsPong() throws {
        let reply = try dispatch(["action": "ping"], as: .browserBridge)
        XCTAssertEqual(reply as NSDictionary, ["pong": true, "cached": 1])
    }

    // MARK: - .mcpClient

    func testMCPClientPingReturnsPong() throws {
        let reply = try dispatch(["action": "ping"], as: .mcpClient)
        XCTAssertEqual(reply as NSDictionary, ["pong": true, "cached": 1])
    }

    func testMCPClientIsForbiddenEveryActionButPing() throws {
        let requests: [[String: Any]] = [
            ["action": "lookup", "hostname": "app.example.com"],
            ["action": "list"],
            ["action": "refresh"],
            ["action": "config"],
            ["action": "not_an_action"],
        ]
        for request in requests {
            let reply = try dispatch(request, as: .mcpClient)
            XCTAssertEqual(reply as NSDictionary, ["error": "forbidden"], "\(request)")
        }
        XCTAssertEqual(store.count, 1, "a forbidden list/refresh must not touch the cache")
    }

    // MARK: - Helpers

    private func dispatch(_ request: [String: Any], as peer: SocketPeer) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: request)
        let response = server.dispatch(request: body, peer: peer, processID: 4242)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }
}
