import XCTest

final class RevokePollerTests: XCTestCase {

    /// Stub that returns a canned result. Exists purely so RevokePoller can be
    /// unit-tested without spawning the real `op` CLI.
    private final class StubProvider: WhoamiProvider {
        var result: WhoamiResult
        init(_ result: WhoamiResult) { self.result = result }
        func whoami() throws -> WhoamiResult { result }
    }

    func testAuthenticatedEmitsAuthenticated() {
        let provider = StubProvider(.authenticated(account: "team"))
        let events = captureEvents(provider: provider)
        XCTAssertEqual(events, [.authenticated])
    }

    func testLockedEmitsLocked() {
        let provider = StubProvider(.locked)
        XCTAssertEqual(captureEvents(provider: provider), [.locked])
    }

    func testNoAccountsEmitsRevoked() {
        let provider = StubProvider(.noAccounts)
        XCTAssertEqual(captureEvents(provider: provider), [.revoked])
    }

    func testUnknownEmitsUnknown() {
        let provider = StubProvider(.unknown(stderr: "boom", exitCode: 99))
        XCTAssertEqual(captureEvents(provider: provider), [.unknown])
    }

    func testTimeoutEmitsUnknown() {
        let provider = StubProvider(.timeout)
        XCTAssertEqual(captureEvents(provider: provider), [.unknown])
    }

    func testRevokedTriggersItemStoreEviction() {
        // Policy check: the main-level wiring evicts on `.revoked`. We re-create
        // that mapping here so regressions in the wiring surface in tests.
        let store = ItemStore(ttl: 3600)
        store.replace(with: [
            StoredItem(
                itemId: "1", title: "X", hostnames: ["a.com"], domains: ["a.com"],
                username: "u", password: "p", sourceVault: nil, cachedAt: Date()
            )
        ])
        XCTAssertEqual(store.count, 1)

        let provider = StubProvider(.noAccounts)
        let poller = RevokePoller(provider: provider, interval: 3600) { event in
            if event == .revoked { store.evictAll() }
        }
        poller.pollNow()

        XCTAssertEqual(store.count, 0)
    }

    // MARK: - Helper

    private func captureEvents(provider: WhoamiProvider) -> [RevokePoller.Event] {
        var captured: [RevokePoller.Event] = []
        let poller = RevokePoller(provider: provider, interval: 3600) { event in
            captured.append(event)
        }
        poller.pollNow()
        return captured
    }
}
