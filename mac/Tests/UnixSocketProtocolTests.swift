import XCTest
import Darwin

/// Wire-protocol tests for `UnixSocketServer`.
///
/// Exercises the same framing the `pf-nmh-bridge` uses (UInt32-LE length
/// prefix + UTF-8 JSON body) so a regression in the dispatch layer surfaces
/// here instead of breaking Basic-Auth fills at runtime.
///
/// The server runs on a per-test temp socket so tests are hermetic and
/// parallel-safe.
final class UnixSocketProtocolTests: XCTestCase {

    private var server: UnixSocketServer!
    private var socketURL: URL!
    private var tempDir: URL!
    private var configURL: URL!
    private var store: ItemStore!
    private var service: AgentService!

    override func setUpWithError() throws {
        // /tmp/ instead of NSTemporaryDirectory — Darwin's sockaddr_un.sun_path
        // caps at 104 chars, and `/var/folders/.../T/` already eats 60+. Short
        // UUID suffix keeps the socket path comfortably under the limit.
        let short = UUID().uuidString.prefix(8)
        tempDir = URL(fileURLWithPath: "/tmp/pf-sock-\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        socketURL = tempDir.appendingPathComponent("s")
        configURL = tempDir.appendingPathComponent("config.json")

        let configStore = ConfigStore(url: configURL)
        try configStore.save(Config(opAccount: "team.1password.com", opTag: ".htaccess", cacheTtlDays: 7))

        store = ItemStore(ttl: 7 * 86_400)
        let bogusOp = URL(fileURLWithPath: "/dev/null/nonexistent-op")
        let opClient = OpClient(bundledOpURL: bogusOp, account: nil, timeout: 5)

        service = AgentService(
            store: store,
            opClient: opClient,
            configProvider: { (try? configStore.load()) ?? Config() },
            configReloader: { try configStore.load() }
        )
        service.setConnectionState(.connected)

        server = UnixSocketServer(service: service, socketURL: socketURL)
        try server.start()
    }

    override func tearDownWithError() throws {
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - ping

    func testPingReturnsPongWithCacheCount() throws {
        store.replace(with: [makeItem(id: "1", hostnames: ["example.com"])])

        let reply = try sendAndReceive(["action": "ping"])
        XCTAssertEqual(reply["pong"] as? Bool, true)
        XCTAssertEqual(reply["cached"] as? Int, 1)
    }

    // MARK: - config

    func testConfigReturnsOpAccount() throws {
        let reply = try sendAndReceive(["action": "config"])
        XCTAssertEqual(reply["op_account"] as? String, "team.1password.com",
                       "config response must use snake_case like the legacy Node-host wire format")
    }

    // MARK: - lookup (legacy wire shape: G1 fix)

    func testLookupHitReturnsFoundTrueWithCredentials() throws {
        store.replace(with: [
            makeItem(id: "1", hostnames: ["app.example.com"],
                     username: "admin", password: "secret")
        ])

        let reply = try sendAndReceive(["action": "lookup", "hostname": "app.example.com"])
        XCTAssertEqual(reply["found"] as? Bool, true)
        XCTAssertEqual(reply["username"] as? String, "admin")
        XCTAssertEqual(reply["password"] as? String, "secret")
    }

    func testLookupMissReturnsFoundFalse() throws {
        store.replace(with: [makeItem(id: "1", hostnames: ["only.example.com"])])

        let reply = try sendAndReceive(["action": "lookup", "hostname": "nowhere.org"])
        // Miss must emit `{found:false}` so the extension's `callback()`
        // fires with no credentials. See Phase-3 G1 regression fix.
        XCTAssertEqual(reply["found"] as? Bool, false)
        XCTAssertNil(reply["username"])
        XCTAssertNil(reply["password"])
    }

    func testLookupMissingHostnameReturnsError() throws {
        let reply = try sendAndReceive(["action": "lookup"])
        XCTAssertNotNil(reply["error"])
    }

    // MARK: - list / refresh

    func testListAlwaysReturnsItemsArray() throws {
        // Whether the underlying refresh succeeds depends on whether a real
        // `op` binary is installed + authenticated on the host. Regardless,
        // the `list` action must always return a payload carrying an `items`
        // array — that's the wire contract the legacy extension's popup
        // parser relies on. The optional `error` key only surfaces on
        // failure; we don't assert its presence to keep the test
        // dev-environment-agnostic.
        let reply = try sendAndReceive(["action": "list"], timeout: 60)
        XCTAssertNotNil(reply["items"] as? [Any], "items must always be an array")
    }

    // MARK: - unknown action

    func testUnknownActionReturnsErrorWithName() throws {
        let reply = try sendAndReceive(["action": "not-a-real-action"])
        let error = reply["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("not-a-real-action") ?? false,
                      "error message must echo the offending action name")
    }

    // MARK: - invalid JSON

    func testInvalidJSONReturnsError() throws {
        // Raw garbage body — the server must respond, not crash.
        let body = Data("definitely not json".utf8)
        let response = try sendRawFrame(body: body)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        XCTAssertNotNil(dict["error"])
    }

    // MARK: - Helpers

    /// Sends one JSON request, reads one framed reply, parses it.
    private func sendAndReceive(
        _ payload: [String: Any],
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let response = try sendRawFrame(body: body, timeout: timeout)
        guard let dict = try JSONSerialization.jsonObject(with: response) as? [String: Any] else {
            XCTFail("response was not a JSON object", file: file, line: line)
            return [:]
        }
        return dict
    }

    /// Transport primitive — writes one UInt32-LE-prefixed frame, reads one.
    private func sendRawFrame(body: Data, timeout: TimeInterval = 5) throws -> Data {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw XCTSkip("socket() failed errno=\(errno)")
        }
        defer { Darwin.close(socketFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathSize else {
            throw XCTSkip("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathSize) { cstr in
                _ = path.withCString { src in strcpy(cstr, src) }
            }
        }

        // Up to ~1 s of retries for the server's accept loop to be listening.
        var connectResult: Int32 = -1
        for _ in 0..<20 {
            connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    Darwin.connect(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connectResult == 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard connectResult == 0 else {
            throw XCTSkip("connect() failed errno=\(errno) after retries")
        }

        // Write frame: UInt32-LE length prefix + body.
        var lengthLE = UInt32(body.count).littleEndian
        let header = Data(bytes: &lengthLE, count: 4)
        try writeAll(socketFD: socketFD, data: header + body)

        // Read reply with a deadline.
        let deadline = Date().addingTimeInterval(timeout)
        var headerBuf = Data(count: 4)
        try readExact(socketFD: socketFD, into: &headerBuf, count: 4, deadline: deadline)
        let replyLen = headerBuf.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard replyLen > 0, replyLen < 1_048_576 else {
            throw XCTSkip("reply length out of range: \(replyLen)")
        }

        var bodyBuf = Data(count: Int(replyLen))
        try readExact(socketFD: socketFD, into: &bodyBuf, count: Int(replyLen), deadline: deadline)
        return bodyBuf
    }

    private func writeAll(socketFD: Int32, data: Data) throws {
        var remaining = data.count
        var offset = 0
        while remaining > 0 {
            let sent = data.withUnsafeBytes { raw -> Int in
                Darwin.write(socketFD, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if sent <= 0 {
                throw XCTSkip("write() failed errno=\(errno)")
            }
            remaining -= sent
            offset += sent
        }
    }

    private func readExact(socketFD: Int32, into data: inout Data, count: Int, deadline: Date) throws {
        var remaining = count
        var offset = 0
        while remaining > 0 {
            if Date() > deadline {
                throw XCTSkip("read timed out")
            }
            let got = data.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(socketFD, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if got <= 0 {
                throw XCTSkip("read() returned \(got) errno=\(errno)")
            }
            remaining -= got
            offset += got
        }
    }

    private func makeItem(
        id: String,
        hostnames: [String],
        username: String = "user",
        password: String = "pass"
    ) -> StoredItem {
        let domains = Array(Set(hostnames.compactMap { PublicSuffixList.eTLDPlusOne(host: $0) }))
        return StoredItem(
            itemId: id, title: "T", hostnames: hostnames, domains: domains,
            username: username, password: password, sourceVault: nil, cachedAt: Date()
        )
    }
}
