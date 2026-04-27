import XCTest

final class AuditCheckerTests: XCTestCase {

    // MARK: - URL-less items

    func testNoWebsiteFromUrlLessSummary() throws {
        let summary = try decodeSummary("""
        {
          "id": "abc",
          "title": "URL-less Item",
          "urls": null,
          "vault": { "id": "v1", "name": "Shared" }
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [summary], rawItems: [])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].title, "URL-less Item")
        XCTAssertEqual(findings[0].vaults, ["Shared"])
        XCTAssertEqual(findings[0].defects, [.noWebsite])
    }

    // MARK: - Credential-shape defects

    func testNoUsername() throws {
        // Top-level password only, no section, no top-level username.
        let item = try decodeFullItem("""
        {
          "id": "i1",
          "title": "Pass-only",
          "urls": [{ "href": "https://example.com" }],
          "vault": { "id": "v1", "name": "Shared" },
          "fields": [
            { "id": "password", "type": "CONCEALED", "value": "secret", "section": null }
          ]
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [item])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].defects, [.noUsername])
    }

    func testNoPassword() throws {
        let item = try decodeFullItem("""
        {
          "id": "i1",
          "title": "User-only",
          "urls": [{ "href": "https://example.com" }],
          "vault": { "id": "v1", "name": "Shared" },
          "fields": [
            { "id": "username", "type": "STRING", "value": "u", "section": null }
          ]
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [item])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].defects, [.noPassword])
    }

    // MARK: - Section-shape defects

    func testSectionBrokenUsername_OnlyConcealedInSection() throws {
        // Section present (CONCEALED password OK), but no STRING in section.
        let item = try decodeFullItem("""
        {
          "id": "i1",
          "title": "Broken User",
          "urls": [{ "href": "https://example.com" }],
          "vault": { "id": "v1", "name": "Shared" },
          "fields": [
            { "id": "f1", "type": "CONCEALED", "value": "p1",
              "section": { "id": "s1", "label": "htaccess" } }
          ]
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [item])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].defects, [.sectionBrokenUsername])
    }

    func testSectionBrokenPassword_PasswordAsTextField() throws {
        // The real Production bug we want to catch: section present, STRING for user OK,
        // but the password is stored as a plain STRING (not CONCEALED).
        // Must NOT collapse to `.noPassword`.
        let item = try decodeFullItem("""
        {
          "id": "i1",
          "title": "Broken Pass",
          "urls": [{ "href": "https://example.com" }],
          "vault": { "id": "v1", "name": "Shared" },
          "fields": [
            { "id": "f1", "type": "STRING", "value": "user1",
              "section": { "id": "s1", "label": "htaccess" } },
            { "id": "f2", "type": "STRING", "value": "pwd-as-text",
              "section": { "id": "s1", "label": "htaccess" } }
          ]
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [item])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].defects, [.sectionBrokenPassword])
    }

    // MARK: - Cross-item collisions

    func testVaultDuplicateWithDivergingCredentials() throws {
        // Same title + same hostnames, different creds → vaultDuplicate (each side).
        let a = try decodeFullItem(fullItemJSON(
            id: "a", title: "ExampleCorp",
            host: "auth.example.com",
            user: "u1", pass: "p1",
            vault: "Shared"
        ))
        let b = try decodeFullItem(fullItemJSON(
            id: "b", title: "ExampleCorp",
            host: "auth.example.com",
            user: "u1", pass: "p2",
            vault: "Private"
        ))
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [a, b])
        XCTAssertEqual(findings.count, 2)
        for finding in findings {
            XCTAssertEqual(finding.title, "ExampleCorp")
            XCTAssertEqual(finding.defects.count, 1)
            switch finding.defects[0] {
            case let .vaultDuplicate(otherTitle, _, hostnameCount):
                XCTAssertEqual(otherTitle, "ExampleCorp")
                XCTAssertEqual(hostnameCount, 1)
            default:
                XCTFail("Expected vaultDuplicate, got \(finding.defects[0])")
            }
        }
    }

    func testHostnameCollisionDifferentTitles() throws {
        // Different titles share a hostname → hostnameCollision (each side).
        let a = try decodeFullItem(fullItemJSON(
            id: "a", title: "ExampleCorp Frontend",
            host: "www.example.com",
            user: "u1", pass: "p1",
            vault: "Shared"
        ))
        let b = try decodeFullItem(fullItemJSON(
            id: "b", title: "ExampleCorp Backend",
            host: "www.example.com",
            user: "u2", pass: "p2",
            vault: "Shared"
        ))
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [a, b])
        XCTAssertEqual(findings.count, 2)
        for finding in findings {
            XCTAssertEqual(finding.defects.count, 1)
            switch finding.defects[0] {
            case let .hostnameCollision(_, _, hostnames):
                XCTAssertEqual(hostnames, ["www.example.com"])
            default:
                XCTFail("Expected hostnameCollision, got \(finding.defects[0])")
            }
        }
    }

    // MARK: - Merge-twin (must NOT be a defect)

    func testMergeTwinIdenticalCredsIsNotADefect() throws {
        let a = try decodeFullItem(fullItemJSON(
            id: "a", title: "TwinItem",
            host: "twin.example.com",
            user: "u", pass: "p",
            vault: "Shared"
        ))
        let b = try decodeFullItem(fullItemJSON(
            id: "b", title: "TwinItem",
            host: "twin.example.com",
            user: "u", pass: "p",
            vault: "Private"
        ))
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [a, b])
        XCTAssertTrue(findings.isEmpty, "Merge-twin with identical creds must not produce a defect")
    }

    // MARK: - Empty input

    func testEmptyInputProducesNoFindings() throws {
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [])
        XCTAssertEqual(findings, [])
    }

    // MARK: - URL-bearing item with unparseable URL → noWebsite

    func testItemWithOnlyUnparseableUrlGetsNoWebsite() throws {
        // `*.example.com` with no scheme is not parseable by URL(string:) — `extractHostnames`
        // drops it, so the audit reports `noWebsite` (which matches the Agent's actual view).
        let item = try decodeFullItem("""
        {
          "id": "i1",
          "title": "Wildcard-only",
          "urls": [{ "href": "*.example.com" }],
          "vault": { "id": "v1", "name": "Shared" },
          "fields": [
            { "id": "username", "type": "STRING", "value": "u", "section": null },
            { "id": "password", "type": "CONCEALED", "value": "p", "section": null }
          ]
        }
        """)
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [item])
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].defects, [.noWebsite])
    }

    // MARK: - Sort order

    func testFindingsSortedByTitleCaseInsensitive() throws {
        let bee = try decodeFullItem(fullItemJSON(
            id: "1", title: "bee",
            host: "bee.example.com",
            user: nil, pass: nil,
            vault: "Shared"
        ))
        let Apple = try decodeFullItem(fullItemJSON(
            id: "2", title: "Apple",
            host: "apple.example.com",
            user: nil, pass: nil,
            vault: "Shared"
        ))
        let findings = try AuditChecker.analyze(urlLessSummaries: [], rawItems: [bee, Apple])
        XCTAssertEqual(findings.map(\.title), ["Apple", "bee"])
    }

    // MARK: - Stable Finding.id

    func testFindingIdStableAcrossDefectsChange() {
        // Same title + same vaults → same id, no matter what defects are attached.
        let id1 = Finding.makeId(title: "X", vaults: ["A", "B"])
        let id2 = Finding.makeId(title: "X", vaults: ["B", "A"])  // unsorted input
        XCTAssertEqual(id1, id2, "ID must depend on sorted vaults, not insertion order")
    }
}

// MARK: - Helpers

private func decodeSummary(_ json: String) throws -> ItemSummary {
    try JSONDecoder().decode(ItemSummary.self, from: Data(json.utf8))
}

private func decodeFullItem(_ json: String) throws -> FullItem {
    try JSONDecoder().decode(FullItem.self, from: Data(json.utf8))
}

/// Build a minimal valid `op item get`-shaped JSON with a top-level user/pass
/// (no section). Pass `nil` to omit the corresponding field entirely.
private func fullItemJSON(
    id: String,
    title: String,
    host: String,
    user: String?,
    pass: String?,
    vault: String
) -> String {
    var fields: [String] = []
    if let user {
        fields.append(#"{"id":"username","type":"STRING","value":"\#(user)","section":null}"#)
    }
    if let pass {
        fields.append(#"{"id":"password","type":"CONCEALED","value":"\#(pass)","section":null}"#)
    }
    return """
    {
      "id": "\(id)",
      "title": "\(title)",
      "urls": [{ "href": "https://\(host)" }],
      "vault": { "id": "v", "name": "\(vault)" },
      "fields": [\(fields.joined(separator: ","))]
    }
    """
}
