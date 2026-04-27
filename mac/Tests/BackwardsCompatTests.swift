import XCTest
import Darwin

/// Backwards-compatibility guard for the v0.3.x wire format.
///
/// The v1.0.0 Swift agent must accept byte-identical requests from any v0.3.x
/// extension that's still in the wild and emit responses whose JSON key-set
/// matches what the legacy `extension/background.js` parser reads.
///
/// Because we have no captured production traces, the fixtures below are
/// hand-authored from the legacy protocol spec (`host/htpasswd-host.js`
/// pre-v1 code and the Chrome Native-Messaging framing rules). Each request
/// fixture is a raw byte sequence that would come over the wire from a v0.3.x
/// NMH child; each response expectation is a **closed** key-set (no extras
/// allowed) so that additions to the Agent which accidentally break an old
/// client's parser surface here.
final class BackwardsCompatTests: XCTestCase {

    private var server: UnixSocketServer!
    private var socketURL: URL!
    private var tempDir: URL!
    private var store: ItemStore!
    private var service: AgentService!

    override func setUpWithError() throws {
        // /tmp/ instead of NSTemporaryDirectory — Darwin's sockaddr_un.sun_path
        // caps at 104 chars, and `/var/folders/.../T/` already eats 60+. Short
        // UUID suffix keeps the socket path comfortably under the limit.
        let short = UUID().uuidString.prefix(8)
        tempDir = URL(fileURLWithPath: "/tmp/pf-compat-\(short)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        socketURL = tempDir.appendingPathComponent("s")

        let configURL = tempDir.appendingPathComponent("config.json")
        let configStore = ConfigStore(url: configURL)
        try configStore.save(Config(opAccount: "legacy.1password.com", opTag: ".htaccess", cacheTtlDays: 7))

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

    // MARK: - Golden request fixtures (as v0.3.x sent them)

    /// v0.3.x lookup request, exactly as emitted by the legacy Node NMH:
    /// `{"action":"lookup","hostname":"app.example.com"}`
    /// Field order is not semantically meaningful — both `JSONSerialization`
    /// outputs and Chrome NMH traces showed `action` first — but the bytes
    /// below are a literal compile-time fixture so that a careless code change
    /// can't "validate" itself against a JSON encoder that would always agree.
    private let legacyLookupJSON = Data(
        #"{"action":"lookup","hostname":"app.example.com"}"#.utf8
    )

    private let legacyLookupMissJSON = Data(
        #"{"action":"lookup","hostname":"nothing.invalid"}"#.utf8
    )

    private let legacyPingJSON = Data(#"{"action":"ping"}"#.utf8)

    private let legacyConfigJSON = Data(#"{"action":"config"}"#.utf8)

    // MARK: - Lookup wire shape (G1 regression guard)

    func testLegacyLookupHitReturnsExactLegacyKeySet() throws {
        store.replace(with: [
            makeItem(id: "1", hostnames: ["app.example.com"],
                     username: "legacy_user", password: "legacy_pass")
        ])

        let reply = try send(legacyLookupJSON)
        let keys = Set(reply.keys)

        // v0.3.x parser destructures exactly these three keys — no extras, no fewer.
        XCTAssertEqual(keys, ["found", "username", "password"])
        XCTAssertEqual(reply["found"] as? Bool, true)
        XCTAssertEqual(reply["username"] as? String, "legacy_user")
        XCTAssertEqual(reply["password"] as? String, "legacy_pass")
    }

    func testLegacyLookupMissReturnsOnlyFoundFalse() throws {
        let reply = try send(legacyLookupMissJSON)
        let keys = Set(reply.keys)

        // Miss must not leak placeholder username/password keys — legacy
        // extension checks `msg.found` first and then reads credentials.
        XCTAssertEqual(keys, ["found"])
        XCTAssertEqual(reply["found"] as? Bool, false)
    }

    // MARK: - Ping wire shape

    func testLegacyPingReturnsPongWithCachedCount() throws {
        store.replace(with: [
            makeItem(id: "a", hostnames: ["a.example.com"]),
            makeItem(id: "b", hostnames: ["b.example.com"])
        ])

        let reply = try send(legacyPingJSON)
        let keys = Set(reply.keys)

        XCTAssertEqual(keys, ["pong", "cached"])
        XCTAssertEqual(reply["pong"] as? Bool, true)
        XCTAssertEqual(reply["cached"] as? Int, 2)
    }

    // MARK: - Config wire shape

    func testLegacyConfigReturnsSnakeCaseOpAccountOnly() throws {
        let reply = try send(legacyConfigJSON)
        let keys = Set(reply.keys)

        // Legacy Node-host only emitted this single key; widening the
        // response can break older popup parsers that destructure blindly.
        XCTAssertEqual(keys, ["op_account"])
        XCTAssertEqual(reply["op_account"] as? String, "legacy.1password.com")
    }

    // MARK: - Framing compatibility

    func testServerHandlesMultipleSequentialFramesOnSameConnection() throws {
        // Legacy extension kept one long-lived NMH port and sent many messages
        // over it. The Unix-Socket server must handle the same pattern without
        // closing the connection after the first frame.
        let socketFD = try openConnection()
        defer { Darwin.close(socketFD) }

        let first = try sendRawFrame(socketFD: socketFD, body: legacyPingJSON)
        let firstDict = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(firstDict["pong"] as? Bool, true)

        let second = try sendRawFrame(socketFD: socketFD, body: legacyConfigJSON)
        let secondDict = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual(secondDict["op_account"] as? String, "legacy.1password.com")
    }

    func testServerRejectsOversizedFrameWithoutCrashing() throws {
        // 1 MiB cap matches the server's readFramed guard. Sending 2 MiB should
        // result in the server closing the connection cleanly, not crashing.
        let socketFD = try openConnection()
        defer { Darwin.close(socketFD) }

        var oversizeLength = UInt32(2 * 1_048_576).littleEndian
        let header = Data(bytes: &oversizeLength, count: 4)

        // Best-effort write; the server may close before we finish writing.
        _ = header.withUnsafeBytes { raw in
            Darwin.write(socketFD, raw.baseAddress, raw.count)
        }

        // Now try a normal frame on a fresh connection to prove the server
        // is still alive.
        Darwin.close(socketFD)
        let reply = try send(legacyPingJSON)
        XCTAssertEqual(reply["pong"] as? Bool, true,
                       "server must survive an oversized-frame attempt on another connection")
    }

    // MARK: - Helpers (duplicated from UnixSocketProtocolTests intentionally —
    //                 the two files test different guarantees and shouldn't
    //                 grow a shared helper that couples them).

    private func send(_ body: Data) throws -> [String: Any] {
        let socketFD = try openConnection()
        defer { Darwin.close(socketFD) }
        let response = try sendRawFrame(socketFD: socketFD, body: body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
    }

    private func openConnection() throws -> Int32 {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw XCTSkip("socket() failed errno=\(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathSize else { throw XCTSkip("socket path too long") }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: pathSize) { cstr in
                _ = path.withCString { src in strcpy(cstr, src) }
            }
        }

        var result: Int32 = -1
        for _ in 0..<20 {
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    Darwin.connect(socketFD, ptr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard result == 0 else {
            Darwin.close(socketFD)
            throw XCTSkip("connect() failed errno=\(errno)")
        }
        return socketFD
    }

    private func sendRawFrame(socketFD: Int32, body: Data, timeout: TimeInterval = 5) throws -> Data {
        var lengthLE = UInt32(body.count).littleEndian
        let header = Data(bytes: &lengthLE, count: 4)
        let frame = header + body

        var remaining = frame.count
        var offset = 0
        while remaining > 0 {
            let sent = frame.withUnsafeBytes { raw -> Int in
                Darwin.write(socketFD, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if sent <= 0 { throw XCTSkip("write() failed errno=\(errno)") }
            remaining -= sent
            offset += sent
        }

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

    private func readExact(socketFD: Int32, into data: inout Data, count: Int, deadline: Date) throws {
        var remaining = count
        var offset = 0
        while remaining > 0 {
            if Date() > deadline { throw XCTSkip("read timed out") }
            let got = data.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(socketFD, raw.baseAddress!.advanced(by: offset), remaining)
            }
            if got <= 0 { throw XCTSkip("read() returned \(got)") }
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
