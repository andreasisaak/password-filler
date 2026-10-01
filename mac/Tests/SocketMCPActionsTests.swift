import XCTest

/// Covers the socket actions behind `password-filler-mcp`: `hosts` (for the
/// MCP tool `list_hosts`) and `run_credentials` (for `run`). Both stay closed
/// until the "For AI Agents" switch (`mcp_enabled`) is on.
final class SocketMCPActionsTests: XCTestCase {

    private var server: UnixSocketServer!
    private var store: ItemStore!
    private var config = Config(opAccount: "team.1password.com", opTag: ".htaccess", cacheTtlDays: 7)

    override func setUp() {
        store = ItemStore(ttl: 7 * 86_400)
        store.replace(with: [
            makeItem(id: "1", hostnames: ["b.example.org", "a.example.com"], username: "admin", password: "secret"),
            makeItem(id: "2", hostnames: ["c.example.com", "a.example.com"], username: "other", password: "other-secret"),
        ])
        let service = AgentService(
            store: store,
            opClient: OpClient(bundledOpURL: URL(fileURLWithPath: "/dev/null/nonexistent-op"), account: nil, timeout: 5),
            configProvider: { [unowned self] in self.config },
            configReloader: { [unowned self] in self.config }
        )
        server = UnixSocketServer(service: service, authorizer: PeerAuthorizer(requirement: nil))
    }

    // MARK: - Switch off

    func testHostsIsRefusedWhileSwitchIsOff() throws {
        XCTAssertEqual(try dispatch(["action": "hosts"]) as NSDictionary, ["error": "mcp_disabled"])
    }

    func testRunCredentialsIsRefusedWhileSwitchIsOff() throws {
        let reply = try dispatch(["action": "run_credentials", "hostname": "b.example.org"])
        XCTAssertEqual(reply as NSDictionary, ["error": "mcp_disabled"])
    }

    // MARK: - Switch on

    func testHostsReturnsSortedUniqueHostnamesWithoutRefreshing() throws {
        config.mcpEnabled = true
        let lastRefreshBefore = store.lastRefresh

        let reply = try dispatch(["action": "hosts"])

        XCTAssertEqual(reply as NSDictionary, ["hosts": ["a.example.com", "b.example.org", "c.example.com"]])
        XCTAssertEqual(store.lastRefresh, lastRefreshBefore, "hosts must read the cache, never refresh it")
        XCTAssertEqual(store.count, 2)
    }

    func testRunCredentialsHitReturnsCredentials() throws {
        config.mcpEnabled = true
        let reply = try dispatch(["action": "run_credentials", "hostname": "b.example.org"])
        XCTAssertEqual(reply as NSDictionary, ["found": true, "username": "admin", "password": "secret"])
    }

    func testRunCredentialsMissReturnsFoundFalse() throws {
        config.mcpEnabled = true
        let reply = try dispatch(["action": "run_credentials", "hostname": "nowhere.net"])
        XCTAssertEqual(reply as NSDictionary, ["found": false])
    }

    func testRunCredentialsAmbiguousHostReturnsFoundFalse() throws {
        // x.example.com matches both items only via example.com, and no
        // tiebreaker separates them — the same silent miss a browser fill
        // gets (EC-2).
        config.mcpEnabled = true
        let reply = try dispatch(["action": "run_credentials", "hostname": "x.example.com"])
        XCTAssertEqual(reply as NSDictionary, ["found": false])
    }

    func testRunCredentialsWithoutHostnameIsAnError() throws {
        config.mcpEnabled = true
        XCTAssertEqual(try dispatch(["action": "run_credentials"]) as NSDictionary, ["error": "Missing hostname"])
    }

    func testBrowserBridgeIsForbiddenMCPActions() throws {
        config.mcpEnabled = true
        for action in ["hosts", "run_credentials"] {
            let reply = try dispatch(["action": action, "hostname": "b.example.org"], as: .browserBridge)
            XCTAssertEqual(reply as NSDictionary, ["error": "forbidden"], action)
        }
    }

    // MARK: - Helpers

    private func dispatch(_ request: [String: Any], as peer: SocketPeer = .mcpClient) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: request)
        let response = server.dispatch(request: body, peer: peer, processID: 4242)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func makeItem(id: String, hostnames: [String], username: String, password: String) -> StoredItem {
        let domains = Array(Set(hostnames.compactMap { PublicSuffixList.eTLDPlusOne(host: $0) }))
        return StoredItem(
            itemId: id, title: "T", hostnames: hostnames, domains: domains,
            username: username, password: password, sourceVault: nil, cachedAt: Date()
        )
    }
}
