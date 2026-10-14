import XCTest

final class SharedHostKeychainTests: XCTestCase {

    func testPayloadWithoutSchemeIsRejected() {
        // Entries written by v1.5.0 carry no scheme. Decoding must fail so the
        // CredProvider treats them as a keychain miss instead of filling a
        // host whose request might have been plain HTTP.
        let legacy = #"{"host":"staging.example.com","ts":1760000000}"#

        XCTAssertThrowsError(
            try JSONDecoder().decode(SharedHostKeychain.Payload.self, from: Data(legacy.utf8))
        )
    }

    func testPayloadRoundTripKeepsScheme() throws {
        let payload = SharedHostKeychain.Payload(host: "staging.example.com", scheme: "http", ts: 1_760_000_000)

        let decoded = try JSONDecoder().decode(
            SharedHostKeychain.Payload.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(decoded, payload)
    }

    func testNonHTTPSObservationBlocksFillForThatHostOnly() {
        let plainHTTP = SharedHostKeychain.Payload(host: "staging.example.com", scheme: "http")
        let noScheme = SharedHostKeychain.Payload(host: "staging.example.com", scheme: "")
        let https = SharedHostKeychain.Payload(host: "staging.example.com", scheme: "https")

        XCTAssertTrue(plainHTTP.blocksFill(forHost: "staging.example.com"))
        XCTAssertTrue(noScheme.blocksFill(forHost: "staging.example.com"))
        XCTAssertFalse(https.blocksFill(forHost: "staging.example.com"))
        XCTAssertFalse(plainHTTP.blocksFill(forHost: "other.example.com"))
    }
}
