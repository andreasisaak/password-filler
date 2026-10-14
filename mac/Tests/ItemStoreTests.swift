import XCTest

final class ItemStoreTests: XCTestCase {

    // MARK: - URL matching

    func testExactHostnameMatch() {
        let store = ItemStore(ttl: 3600)
        let item = StoredItem.example(id: "1", title: "Server A", hostnames: ["app.example.com"])
        store.replace(with: [item])

        XCTAssertEqual(store.lookup(hostname: "app.example.com")?.itemId, "1")
    }

    func testUniqueSuffixMatch() {
        let store = ItemStore(ttl: 3600)
        let item = StoredItem.example(id: "1", title: "Server A", hostnames: ["example.com"])
        store.replace(with: [item])

        XCTAssertEqual(store.lookup(hostname: "foo.example.com")?.itemId, "1")
    }

    func testNoMatchReturnsNil() {
        let store = ItemStore(ttl: 3600)
        let item = StoredItem.example(id: "1", title: "Server A", hostnames: ["example.com"])
        store.replace(with: [item])

        XCTAssertNil(store.lookup(hostname: "nonexistent.org"))
    }

    func testMultiCandidateSharedSuffixTiebreak() {
        // Two items share base domain `example.com` but one has `staging.example.com`
        // which is a closer suffix match than bare `example.com`.
        let store = ItemStore(ttl: 3600)
        let generic = StoredItem.example(id: "generic", title: "Generic", hostnames: ["example.com"])
        let staging = StoredItem.example(id: "staging", title: "Staging", hostnames: ["staging.example.com"])
        store.replace(with: [generic, staging])

        XCTAssertEqual(
            store.lookup(hostname: "app.staging.example.com")?.itemId,
            "staging",
            "closer suffix match should win"
        )
    }

    func testSubdomainDepthTiebreak() {
        // Two candidates share eTLD+1 and no label beyond it; tiebreak by matching
        // subdomain depth. Request `foo.example.com` has depth 1; only the item with
        // a depth-1 stored hostname wins.
        let store = ItemStore(ttl: 3600)
        let sameDepth = StoredItem.example(id: "sameDepth", title: "Same", hostnames: ["bar.example.com"])
        let deeper = StoredItem.example(id: "deeper", title: "Deeper", hostnames: ["a.b.example.com"])
        store.replace(with: [sameDepth, deeper])

        XCTAssertEqual(
            store.lookup(hostname: "foo.example.com")?.itemId,
            "sameDepth",
            "matching subdomain depth should win when shared-suffix scores tie"
        )
    }

    func testAmbiguousReturnsNil() {
        // Two items share the same depth and no shared suffix beyond base domain.
        let store = ItemStore(ttl: 3600)
        let first = StoredItem.example(id: "a", title: "A", hostnames: ["one.example.com"])
        let second = StoredItem.example(id: "b", title: "B", hostnames: ["two.example.com"])
        store.replace(with: [first, second])

        XCTAssertNil(
            store.lookup(hostname: "foo.example.com"),
            "ambiguous match with no tiebreak winner should return nil"
        )
    }

    func testHostnameCaseInsensitive() {
        let store = ItemStore(ttl: 3600)
        let item = StoredItem.example(id: "1", title: "Server", hostnames: ["app.example.com"])
        store.replace(with: [item])

        XCTAssertEqual(store.lookup(hostname: "APP.Example.COM")?.itemId, "1")
    }

    func testWildcardHostnameFallsThroughToSuffixMatch() {
        // A 1Password URL field like `https://*.example.com/` lands in
        // `hostnames` as the literal string `*.example.com` (see
        // `PublicSuffixList.hostname(from:)`). Matching treats `*` as an
        // ordinary character — no glob expansion — so real browser requests
        // (which never contain `*`) match via the suffix rule instead:
        // `eTLDPlusOne("*.example.com") == "example.com"`, making the stored
        // item the unique suffix candidate for `app.example.com`. If someone
        // ever teaches ItemStore to expand wildcards, this test must be
        // updated deliberately.
        let store = ItemStore(ttl: 3600)
        let wildcard = StoredItem.example(id: "w", title: "Wildcard", hostnames: ["*.example.com"])
        store.replace(with: [wildcard])

        XCTAssertEqual(
            store.lookup(hostname: "app.example.com")?.itemId,
            "w",
            "wildcard-style entry should match via suffix rule, not glob expansion"
        )
    }

    func testForeignTenantOnSharedPlatformGetsNoCredentials() {
        // Anyone can create `<random>.cloudfront.net` or `<name>.herokuapp.com`
        // and answer with a 401. The suffix stage must not treat the platform
        // domain as a shared base domain and fill the only stored tenant.
        let store = ItemStore(ttl: 3600)
        let cloudFront = StoredItem.example(id: "cf", title: "CDN", hostnames: ["d111111abcdef8.cloudfront.net"])
        let heroku = StoredItem.example(id: "heroku", title: "Heroku", hostnames: ["kunde-staging.herokuapp.com"])
        store.replace(with: [cloudFront, heroku])

        XCTAssertNil(store.lookup(hostname: "attacker123.cloudfront.net"))
        XCTAssertNil(store.lookup(hostname: "evil.herokuapp.com"))
        XCTAssertEqual(store.lookup(hostname: "d111111abcdef8.cloudfront.net")?.itemId, "cf")
    }

    // MARK: - TTL

    func testTTLEvictsOnRead() {
        let store = ItemStore(ttl: 60) // 1 minute TTL
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let item = StoredItem.example(id: "1", title: "Stale", hostnames: ["example.com"], cachedAt: cachedAt)
        store.replace(with: [item])

        let freshNow = cachedAt.addingTimeInterval(30)
        let staleNow = cachedAt.addingTimeInterval(120)

        XCTAssertEqual(store.lookup(hostname: "example.com", now: freshNow)?.itemId, "1")
        XCTAssertNil(store.lookup(hostname: "example.com", now: staleNow))
    }

    func testTTLMutationTakesEffectImmediately() {
        // Simulates the reloadConfig path: user lowers the TTL in Settings, the
        // Agent reassigns ItemStore.ttl, and the next lookup prunes entries
        // that are now out of window.
        let store = ItemStore(ttl: 7 * 86_400) // Start at default 7-day window
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let item = StoredItem.example(id: "1", title: "X", hostnames: ["example.com"], cachedAt: cachedAt)
        store.replace(with: [item])

        let twoDaysLater = cachedAt.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store.lookup(hostname: "example.com", now: twoDaysLater)?.itemId, "1")

        // Shrink TTL to 1 day — the 2-day-old entry is now stale and must go.
        store.ttl = 1 * 86_400
        XCTAssertNil(store.lookup(hostname: "example.com", now: twoDaysLater))
    }

    func testTTLDoesNotEvictWithinWindow() {
        let store = ItemStore(ttl: 3600)
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let item = StoredItem.example(id: "1", title: "Fresh", hostnames: ["example.com"], cachedAt: cachedAt)
        store.replace(with: [item])

        let now = cachedAt.addingTimeInterval(1800) // 30 min later, TTL is 60 min
        XCTAssertEqual(store.lookup(hostname: "example.com", now: now)?.itemId, "1")
    }

    // MARK: - Merge display

    func testMergeIdenticalItemsFromTwoVaults() {
        let store = ItemStore(ttl: 3600)
        let sharedVault = StoredItem.example(
            id: "a", title: "Demo Item",
            hostnames: ["app.example.com"],
            username: "admin", password: "pw",
            sourceVault: "Shared"
        )
        let privateVault = StoredItem.example(
            id: "b", title: "Demo Item",
            hostnames: ["app.example.com"],
            username: "admin", password: "pw",
            sourceVault: "Private"
        )
        store.replace(with: [sharedVault, privateVault])

        let rows = store.mergedForDisplay()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceVaults.sorted(), ["Private", "Shared"])
    }

    func testMergeDoesNotCollapseDifferentCredentials() {
        let store = ItemStore(ttl: 3600)
        let firstCred = StoredItem.example(
            id: "a", title: "Same Title",
            hostnames: ["example.com"],
            username: "u1", password: "p1",
            sourceVault: "V1"
        )
        let secondCred = StoredItem.example(
            id: "b", title: "Same Title",
            hostnames: ["example.com"],
            username: "u2", password: "p2",
            sourceVault: "V2"
        )
        store.replace(with: [firstCred, secondCred])

        let rows = store.mergedForDisplay()
        XCTAssertEqual(rows.count, 2, "Different credentials must not merge")
    }

    func testDisplaySortedByTitleCaseInsensitive() {
        let store = ItemStore(ttl: 3600)
        let zeta = StoredItem.example(id: "1", title: "zeta", hostnames: ["z.de"])
        let alpha = StoredItem.example(id: "2", title: "Alpha", hostnames: ["a.de"])
        let mike = StoredItem.example(id: "3", title: "mike", hostnames: ["m.de"])
        store.replace(with: [zeta, alpha, mike])

        let rows = store.mergedForDisplay()
        XCTAssertEqual(rows.map(\.title), ["Alpha", "mike", "zeta"])
    }

    // MARK: - Credential extraction

    func testSectionMatchWinsOverTopLevel() {
        let fields: [Field] = [
            Field(id: "username", type: "STRING", value: "top_user", section: nil),
            Field(id: "password", type: "CONCEALED", value: "top_pw", section: nil),
            Field(id: "x", type: "STRING", value: "section_user",
                  section: FieldSection(id: "s1", label: "htaccess Access")),
            Field(id: "y", type: "CONCEALED", value: "section_pw",
                  section: FieldSection(id: "s1", label: "htaccess Access"))
        ]
        let creds = ItemStore.extractCredentials(from: fields)
        XCTAssertEqual(creds?.username, "section_user")
        XCTAssertEqual(creds?.password, "section_pw")
    }

    func testTopLevelFallback() {
        let fields: [Field] = [
            Field(id: "username", type: "STRING", value: "u", section: nil),
            Field(id: "password", type: "CONCEALED", value: "p", section: nil)
        ]
        let creds = ItemStore.extractCredentials(from: fields)
        XCTAssertEqual(creds?.username, "u")
        XCTAssertEqual(creds?.password, "p")
    }

    func testSectionPatternVariants() {
        // The legacy regex accepts `htaccess`, `basicauth`, `basic auth`, `basic-auth`,
        // `htpasswd`, `webuser`. Test each.
        let variants = ["htaccess access", "BasicAuth", "basic auth", "basic-auth", "htpasswd", "webuser"]
        for label in variants {
            let fields: [Field] = [
                Field(id: "u", type: "STRING", value: "user", section: FieldSection(id: "s", label: label)),
                Field(id: "p", type: "CONCEALED", value: "pw", section: FieldSection(id: "s", label: label))
            ]
            let creds = ItemStore.extractCredentials(from: fields)
            XCTAssertNotNil(creds, "Section label '\(label)' should match")
        }
    }

    func testNoMatchReturnsNoCredentials() {
        let fields: [Field] = [
            Field(id: "irrelevant", type: "STRING", value: "x",
                  section: FieldSection(id: "s", label: "notes"))
        ]
        XCTAssertNil(ItemStore.extractCredentials(from: fields))
    }

    func testEmptyValuesAreRejected() {
        let fields: [Field] = [
            Field(id: "username", type: "STRING", value: "", section: nil),
            Field(id: "password", type: "CONCEALED", value: "pw", section: nil)
        ]
        XCTAssertNil(ItemStore.extractCredentials(from: fields))
    }

    // MARK: - Hostname extraction

    func testExtractHostnamesDeduplicates() {
        let urls = [
            URLEntry(href: "https://app.example.com/"),
            URLEntry(href: "https://APP.Example.com/other"),
            URLEntry(href: "https://other.example.com/")
        ]
        XCTAssertEqual(
            ItemStore.extractHostnames(from: urls),
            ["app.example.com", "other.example.com"]
        )
    }

    func testExtractHostnamesSkipsInvalid() {
        let urls = [
            URLEntry(href: "https://good.example.com/"),
            URLEntry(href: "not a url")
        ]
        XCTAssertEqual(ItemStore.extractHostnames(from: urls), ["good.example.com"])
    }

    // MARK: - sharedSuffixLength

    func testSharedSuffixLengthBasic() {
        XCTAssertEqual(ItemStore.sharedSuffixLength("a.example.com", "b.example.com"), 2)
        XCTAssertEqual(ItemStore.sharedSuffixLength("a.example.com", "a.example.com"), 3)
        XCTAssertEqual(ItemStore.sharedSuffixLength("example.com", "other.org"), 0)
    }
}
