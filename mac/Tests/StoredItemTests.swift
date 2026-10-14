import XCTest

final class StoredItemTests: XCTestCase {

    func testDecodingSnapshotRederivesDomainsWithCurrentSuffixList() throws {
        // Snapshots written up to v1.5.0 carry domains from the old
        // hand-curated suffix set, which gave every Heroku tenant the shared
        // domain `herokuapp.com`. Decoding must derive them again from the
        // hostnames instead of trusting the persisted value.
        let snapshot = #"""
        [{"itemId":"1","title":"T","hostnames":["kunde.herokuapp.com"],"domains":["herokuapp.com"],
          "username":"u","password":"p","cachedAt":"2026-10-01T10:00:00Z"}]
        """#

        let items = try JSONDecoder.iso8601.decode([StoredItem].self, from: Data(snapshot.utf8))

        XCTAssertEqual(items.map(\.domains), [["kunde.herokuapp.com"]])
    }

    func testDomainsAreDerivedDeduplicatedAndSorted() {
        let item = StoredItem.example(hostnames: ["www.example.com", "kunde.herokuapp.com", "app.example.com", "localhost"])

        XCTAssertEqual(item.domains, ["example.com", "kunde.herokuapp.com"])
    }
}
