import XCTest

/// Integration tests for the `AgentService` XPC surface.
///
/// Uses `NSXPCListener.anonymous()` so no Mach-Service registration is needed —
/// the test bundle runs as a standalone xctest binary (no `.app` host, see
/// `project.yml`), and a Mach-Service lookup would require a live LaunchAgent
/// plus an installed `/Library/LaunchAgents/*.plist`. Anonymous listeners work
/// in-process and verify the exact same protocol / encoding path the real
/// Main-App hits.
///
/// The `AgentService` is constructed with a real `OpClient` pointed at a
/// bogus binary path. That means `refreshCache` deterministically fails
/// fast with `binaryNotFound` — we exercise the error path, not the real
/// 1Password CLI.
final class AgentXPCIntegrationTests: XCTestCase {

    private var listener: NSXPCListener!
    private var service: AgentService!
    private var store: ItemStore!
    private var auditStore: AuditStore!
    private var connection: NSXPCConnection!
    private var tempURL: URL!
    private var auditURL: URL!

    override func setUpWithError() throws {
        // Config persisted to a throwaway file so `reloadConfig` has something
        // concrete to re-read.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-xpc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempURL = tmp.appendingPathComponent("config.json")
        auditURL = tmp.appendingPathComponent("audit-findings.json")

        let configStore = ConfigStore(url: tempURL)
        try configStore.save(Config(opAccount: "team.1password.com", opTag: ".htaccess", cacheTtlDays: 7))

        store = ItemStore(ttl: 7 * 86_400)
        auditStore = AuditStore(url: auditURL)
        let bogusOp = URL(fileURLWithPath: "/dev/null/nonexistent-op")
        let opClient = OpClient(bundledOpURL: bogusOp, account: nil, timeout: 5)

        service = AgentService(
            store: store,
            opClient: opClient,
            configProvider: { (try? configStore.load()) ?? Config() },
            configReloader: { try configStore.load() },
            identityUpdater: nil,
            auditStore: auditStore
        )
        service.setConnectionState(.connected)

        listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()

        connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: AgentServiceProtocol.self)
        connection.resume()
    }

    override func tearDownWithError() throws {
        connection?.invalidate()
        listener?.invalidate()
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func proxy(file: StaticString = #filePath, line: UInt = #line) throws -> AgentServiceProtocol {
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            XCTFail("XPC proxy error: \(error)", file: file, line: line)
        }) as? AgentServiceProtocol else {
            throw XCTSkip("remoteObjectProxy did not conform to AgentServiceProtocol")
        }
        return remote
    }

    /// Runs an XPC reply-block and blocks the test thread until it fires.
    /// Keeps tests readable despite the async-reply protocol.
    private func awaitReply<T>(
        timeout: TimeInterval = 10,
        _ body: (@escaping (T) -> Void) -> Void
    ) throws -> T {
        let expectation = expectation(description: "xpc reply")
        nonisolated(unsafe) var captured: T?
        body { value in
            captured = value
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
        guard let captured else {
            throw XCTSkip("XPC reply did not arrive within \(timeout)s")
        }
        return captured
    }

    // MARK: - ping

    func testPingReturnsTrue() throws {
        let proxy = try self.proxy()
        let pong: Bool = try awaitReply { reply in proxy.ping(reply: reply) }
        XCTAssertTrue(pong)
    }

    // MARK: - getStatus

    func testGetStatusReturnsAgentStatus() throws {
        store.replace(with: [makeItem(id: "1", hostnames: ["example.com"])])
        service.setConnectionState(.connected)

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.getStatus(reply: reply) }
        let status = try XCTUnwrap(XPCPayload.decode(AgentStatus.self, from: data))

        XCTAssertEqual(status.itemCount, 1)
        XCTAssertEqual(status.connectionState, .connected)
        XCTAssertEqual(status.ttlDays, 7)
        XCTAssertNotNil(status.lastRefresh)
    }

    func testGetStatusSurfacesLastErrorMessage() throws {
        service.setConnectionState(.error)
        service.setLastErrorMessage("op exit 6: network unreachable")

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.getStatus(reply: reply) }
        let status = try XCTUnwrap(XPCPayload.decode(AgentStatus.self, from: data))

        XCTAssertEqual(status.connectionState, .error)
        XCTAssertEqual(status.errorMessage, "op exit 6: network unreachable")
    }

    // MARK: - lookupCredentials

    func testLookupCredentialsHit() throws {
        store.replace(with: [
            makeItem(id: "1", hostnames: ["app.example.com"], username: "admin", password: "secret")
        ])

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in
            proxy.lookupCredentials(host: "app.example.com", reply: reply)
        }
        let response = try XCTUnwrap(XPCPayload.decode(LookupResponse.self, from: data))

        XCTAssertEqual(response.username, "admin")
        XCTAssertEqual(response.password, "secret")
    }

    func testLookupCredentialsMissReturnsNil() throws {
        store.replace(with: [makeItem(id: "1", hostnames: ["one.example.com"])])

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in
            proxy.lookupCredentials(host: "unmatched.org", reply: reply)
        }
        XCTAssertNil(data, "miss must return nil payload so the wire stays decoder-friendly")
    }

    // MARK: - listItems

    func testListItemsReturnsDisplayRows() throws {
        store.replace(with: [
            makeItem(id: "1", title: "Beta", hostnames: ["b.example.com"]),
            makeItem(id: "2", title: "Alpha", hostnames: ["a.example.com"])
        ])

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.listItems(reply: reply) }
        let rows = try XCTUnwrap(XPCPayload.decode([DisplayRow].self, from: data))

        XCTAssertEqual(rows.map(\.title), ["Alpha", "Beta"],
                       "listItems must return rows sorted by title")
    }

    func testListItemsEmptyStoreReturnsEmptyArray() throws {
        store.evictAll()

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.listItems(reply: reply) }
        let rows = try XCTUnwrap(XPCPayload.decode([DisplayRow].self, from: data))

        XCTAssertEqual(rows.count, 0)
    }

    // MARK: - refreshCache

    func testRefreshCacheReturnsRefreshResultPayload() throws {
        // We deliberately don't assert on `result.success` — whether the
        // refresh succeeds depends on whether a real `op` binary is installed
        // and authenticated on the host running the test. The coverage value
        // here is the wire-shape: a refreshCache XPC call must always reply
        // with a decodable RefreshResult payload.
        let proxy = try self.proxy()
        let data: Data? = try awaitReply(timeout: 60) { reply in proxy.refreshCache(reply: reply) }
        let result = try XCTUnwrap(XPCPayload.decode(RefreshResult.self, from: data))
        XCTAssertGreaterThanOrEqual(result.itemCount, 0)
        XCTAssertGreaterThanOrEqual(result.durationSeconds, 0)
    }

    // MARK: - reloadConfig

    func testReloadConfigAppliesNewTTL() throws {
        // Persist a new TTL to disk, then ask the agent to reload.
        let newConfig = Config(
            opAccount: "team.1password.com", opTag: ".htaccess",
            cacheTtlDays: 14, autoStart: true, autoRefreshOnStart: true
        )
        try ConfigStore(url: tempURL).save(newConfig)

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.reloadConfig(reply: reply) }
        let result = try XCTUnwrap(XPCPayload.decode(ReloadConfigResult.self, from: data))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.ttlDays, 14)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(store.ttl, TimeInterval(14 * 86_400),
                       "ItemStore.ttl must be mutated in the same call")
    }

    func testReloadConfigReportsFailureWhenFileUnreadable() throws {
        // Overwrite the file with garbage so JSONDecoder throws on reload.
        try Data("this is not JSON".utf8).write(to: tempURL)

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.reloadConfig(reply: reply) }
        let result = try XCTUnwrap(XPCPayload.decode(ReloadConfigResult.self, from: data))

        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.errorMessage)
        // ttlDays reflects the *currently active* store TTL, not the failed one.
        XCTAssertEqual(result.ttlDays, Int(store.ttl / 86_400))
    }

    // MARK: - getAuditFindings

    func testGetAuditFindingsEmptyByDefault() throws {
        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.getAuditFindings(reply: reply) }
        let findings = try XCTUnwrap(XPCPayload.decode([Finding].self, from: data))
        XCTAssertEqual(findings, [])
    }

    func testGetAuditFindingsReturnsPersistedFindings() throws {
        // Pre-populate via the AuditStore the service is already wired to.
        let f = Finding(
            id: Finding.makeId(title: "X", vaults: ["Shared"]),
            title: "X",
            vaults: ["Shared"],
            defects: [.noUsername],
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try auditStore.save([f])

        let proxy = try self.proxy()
        let data: Data? = try awaitReply { reply in proxy.getAuditFindings(reply: reply) }
        let findings = try XCTUnwrap(XPCPayload.decode([Finding].self, from: data))

        XCTAssertEqual(findings, [f])
    }

    // MARK: - Audit-hook defensive behaviour

    func testAuditHookFailureLeavesItemStoreAndLookupsIntact() throws {
        // AuditStore pointed at a path under a *file* (not a directory) — `save`
        // can't create the parent dir, so the write throws. The hook MUST swallow
        // that error and leave the rest of the agent's state alone.
        let parentFile = tempURL.deletingLastPathComponent()
            .appendingPathComponent("blocking-file")
        try Data("not a dir".utf8).write(to: parentFile)
        let badURL = parentFile.appendingPathComponent("audit-findings.json")
        let badAuditStore = AuditStore(url: badURL)

        let configStore = ConfigStore(url: tempURL)
        let isolatedService = AgentService(
            store: store,
            opClient: OpClient(bundledOpURL: URL(fileURLWithPath: "/dev/null/nonexistent-op"),
                               account: nil, timeout: 5),
            configProvider: { (try? configStore.load()) ?? Config() },
            configReloader: { try configStore.load() },
            identityUpdater: nil,
            auditStore: badAuditStore
        )

        // Pre-load the ItemStore so we can prove lookups still work after the
        // hook misfires.
        let item = makeItem(id: "1", hostnames: ["app.example.com"], username: "u", password: "p")
        store.replace(with: [item])

        // Sentinel input that would normally produce a `noWebsite` finding —
        // proves the hook *tried* to do work, not that it short-circuited.
        let summary = ItemSummary(
            id: "url-less",
            title: "URL-less",
            urls: nil,
            vault: VaultRef(id: nil, name: "Shared")
        )

        // The whole point: this call must not throw or crash.
        isolatedService.runAuditHook(urlLessSummaries: [summary], rawItems: [])

        // ItemStore untouched.
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.lookup(hostname: "app.example.com")?.username, "u")
        // AuditStore.current did not get populated — the save failed so the
        // in-memory state stays consistent with the on-disk state (still empty).
        XCTAssertTrue(badAuditStore.current.isEmpty)
    }

    // MARK: - Helpers

    private func makeItem(
        id: String,
        title: String = "T",
        hostnames: [String],
        username: String = "user",
        password: String = "pass"
    ) -> StoredItem {
        let domains = Array(Set(hostnames.compactMap { PublicSuffixList.eTLDPlusOne(host: $0) }))
        return StoredItem(
            itemId: id, title: title, hostnames: hostnames, domains: domains,
            username: username, password: password, sourceVault: nil, cachedAt: Date()
        )
    }
}
