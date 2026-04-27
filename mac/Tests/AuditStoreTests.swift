import XCTest

final class AuditStoreTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-audit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tempURL = tmp.appendingPathComponent("audit-findings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
    }

    // MARK: - Roundtrip

    func testSaveLoadRoundtrip() throws {
        let store = AuditStore(url: tempURL)
        let f1 = Finding(
            id: Finding.makeId(title: "Item A", vaults: ["Shared"]),
            title: "Item A",
            vaults: ["Shared"],
            defects: [.noWebsite],
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let f2 = Finding(
            id: Finding.makeId(title: "Item B", vaults: ["Private", "Shared"]),
            title: "Item B",
            vaults: ["Private", "Shared"],
            defects: [
                .sectionBrokenPassword,
                .vaultDuplicate(otherTitle: "Item B", otherVaults: ["Other"], hostnameCount: 2),
                .hostnameCollision(otherTitle: "Foo", otherVaults: ["Shared"], hostnames: ["a.com", "b.com"])
            ],
            detectedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try store.save([f1, f2])

        let fresh = AuditStore(url: tempURL)
        let loaded = try fresh.load()
        XCTAssertEqual(loaded, [f1, f2])
    }

    // MARK: - Empty overwrite

    func testEmptyOverwriteClearsStaleFindings() throws {
        let store = AuditStore(url: tempURL)
        let stale = Finding(
            id: "abc",
            title: "Stale",
            vaults: ["Shared"],
            defects: [.noPassword],
            detectedAt: Date()
        )
        try store.save([stale])

        // All defects fixed → save empty.
        try store.save([])

        let fresh = AuditStore(url: tempURL)
        XCTAssertEqual(try fresh.load(), [])
    }

    // MARK: - Atomic write resilience

    func testPartialFileDoesNotPersist() throws {
        // Simulate a half-written file that would result from a non-atomic write
        // (e.g. crash during write). Loading must throw a decodeFailed error rather than
        // silently returning corrupt data — caller is expected to fall back to [].
        let partialJSON = #"{"version":1,"generatedAt":"2026-04-27T14:30:00"#
        try partialJSON.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = AuditStore(url: tempURL)
        XCTAssertThrowsError(try store.load()) { error in
            guard case AuditStoreError.decodeFailed = error else {
                XCTFail("Expected decodeFailed, got \(error)")
                return
            }
        }
    }

    // MARK: - Forward-compat

    func testUnknownDefectTypeIsSkipped() throws {
        // A future version writes a defect with `type: "futureDefect"`. Existing
        // installs must still load the file, drop the unknown defect, and keep
        // the recognised one.
        let json = """
        {
          "version": 1,
          "generatedAt": "2026-04-27T14:30:00Z",
          "findings": [
            {
              "id": "abc",
              "title": "Mixed",
              "vaults": ["Shared"],
              "defects": [
                { "type": "noPassword" },
                { "type": "futureDefect", "extra": "stuff" }
              ],
              "detectedAt": "2026-04-27T14:30:00Z"
            }
          ]
        }
        """
        try json.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = AuditStore(url: tempURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].defects, [.noPassword])
    }

    func testFindingWithOnlyUnknownDefectsIsDropped() throws {
        // If every defect on a finding is unknown, the finding has no signal —
        // drop it entirely rather than persisting an empty-defects record.
        let json = """
        {
          "version": 1,
          "generatedAt": "2026-04-27T14:30:00Z",
          "findings": [
            {
              "id": "abc",
              "title": "AllUnknown",
              "vaults": ["Shared"],
              "defects": [
                { "type": "futureDefect" },
                { "type": "anotherFuture" }
              ],
              "detectedAt": "2026-04-27T14:30:00Z"
            },
            {
              "id": "def",
              "title": "Valid",
              "vaults": ["Shared"],
              "defects": [
                { "type": "noWebsite" }
              ],
              "detectedAt": "2026-04-27T14:30:00Z"
            }
          ]
        }
        """
        try json.write(to: tempURL, atomically: true, encoding: .utf8)

        let store = AuditStore(url: tempURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Valid")
    }

    // MARK: - File format

    func testSavedFileUsesIso8601AndExpectedShape() throws {
        let store = AuditStore(url: tempURL)
        let f = Finding(
            id: "abc",
            title: "X",
            vaults: ["V"],
            defects: [.vaultDuplicate(otherTitle: "Y", otherVaults: ["W"], hostnameCount: 3)],
            detectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save([f])

        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"version\""))
        XCTAssertTrue(raw.contains("\"generatedAt\""))
        XCTAssertTrue(raw.contains("\"findings\""))
        XCTAssertTrue(raw.contains("\"type\" : \"vaultDuplicate\""))
        XCTAssertTrue(raw.contains("\"hostnameCount\" : 3"))
    }
}
