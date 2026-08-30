import XCTest

/// Covers `BridgeStaleness.verdict` — the D24 rule the Main-App applies on
/// every launch to decide which running `pf-nmh-bridge` processes to
/// terminate so the browsers respawn a bridge from the current bundle.
final class BridgeStalenessTests: XCTestCase {

    private let bundledCdhash = Data(repeating: 0xA5, count: 20)
    private let previousReleaseCdhash = Data(repeating: 0x5A, count: 20)

    func testMatchingCdhashIsCurrent() {
        let bridge = RunningBridgeIdentity(processID: 4242, cdhash: bundledCdhash, lookupStatus: errSecSuccess)
        XCTAssertEqual(BridgeStaleness.verdict(for: bridge, currentCdhash: bundledCdhash), .current)
    }

    func testDifferentCdhashIsStale() {
        // Sparkle moves the previous bundle to the Trash, so the old bridge
        // still validates — but it runs the previous release's code.
        let bridge = RunningBridgeIdentity(processID: 4242, cdhash: previousReleaseCdhash, lookupStatus: errSecSuccess)
        XCTAssertEqual(
            BridgeStaleness.verdict(for: bridge, currentCdhash: bundledCdhash),
            .stale(reason: "cdhash differs from bundled bridge")
        )
    }

    func testFailedIdentityLookupIsStale() {
        // Bundle deleted underneath the process: SecCodeCopyGuestWithAttributes
        // fails with kPOSIXErrorENOENT (100002) — the same failure that makes
        // the Agent's PeerAuthorizer reject that bridge.
        let bridge = RunningBridgeIdentity(processID: 4242, cdhash: nil, lookupStatus: 100_002)
        XCTAssertEqual(
            BridgeStaleness.verdict(for: bridge, currentCdhash: bundledCdhash),
            .stale(reason: "code identity lookup failed (OSStatus 100002)")
        )
    }
}
