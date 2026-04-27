import XCTest

final class ConfigStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempURL = tmp.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    func testSaveAndLoadRoundTrip() throws {
        let store = ConfigStore(url: tempURL)
        let config = Config(
            opAccount: "team.1password.com",
            opTag: ".htaccess",
            cacheTtlDays: 14,
            autoStart: false,
            autoRefreshOnStart: true
        )
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded, config)
    }

    func testMissingFileReturnsDefaults() throws {
        let store = ConfigStore(url: tempURL)
        let loaded = try store.load()

        XCTAssertEqual(loaded.opAccount, "")
        XCTAssertEqual(loaded.opTag, ".htaccess")
        XCTAssertEqual(loaded.cacheTtlDays, 7)
        XCTAssertTrue(loaded.autoStart)
        XCTAssertTrue(loaded.autoRefreshOnStart)
    }

    func testLegacyConfigMigratesWithDefaults() throws {
        // Only the two keys the 0.3.x Node-host wrote.
        let legacy = #"""
        {
          "op_account": "team.1password.com",
          "op_tag": ".htaccess"
        }
        """#
        try legacy.write(to: tempURL, atomically: true, encoding: .utf8)

        let loaded = try ConfigStore(url: tempURL).load()
        XCTAssertEqual(loaded.opAccount, "team.1password.com")
        XCTAssertEqual(loaded.opTag, ".htaccess")
        XCTAssertEqual(loaded.cacheTtlDays, 7)
        XCTAssertTrue(loaded.autoStart)
        XCTAssertTrue(loaded.autoRefreshOnStart)
    }

    func testSaveUsesSnakeCaseOnDisk() throws {
        let store = ConfigStore(url: tempURL)
        try store.save(Config(
            opAccount: "acc", opTag: ".tag",
            cacheTtlDays: 3, autoStart: false, autoRefreshOnStart: false
        ))

        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"op_account\""))
        XCTAssertTrue(raw.contains("\"cache_ttl_days\""))
        XCTAssertTrue(raw.contains("\"auto_refresh_on_start\""))
        XCTAssertFalse(raw.contains("opAccount"))
    }

    func testAtomicWriteOverwrite() throws {
        let store = ConfigStore(url: tempURL)
        try store.save(Config(opAccount: "first"))
        try store.save(Config(opAccount: "second"))

        let loaded = try store.load()
        XCTAssertEqual(loaded.opAccount, "second")
    }
}
