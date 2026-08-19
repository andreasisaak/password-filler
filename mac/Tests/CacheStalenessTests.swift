import XCTest

/// Covers `AgentStatus.isCacheExpired` — the derivation behind the Main-App's
/// "cache expired — refresh required" escalation (menu-bar warning icon,
/// popover status row, transition-edge user notification).
final class CacheStalenessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func status(
        itemCount: Int,
        lastRefresh: Date?,
        ttlDays: Int = 7,
        ttlSeconds: Int? = nil,
        connectionState: ConnectionState = .connected
    ) -> AgentStatus {
        AgentStatus(
            itemCount: itemCount,
            lastRefresh: lastRefresh,
            ttlDays: ttlDays,
            ttlSeconds: ttlSeconds,
            connectionState: connectionState
        )
    }

    func testConnectedEmptyCachePastTtlIsExpired() {
        let subject = status(itemCount: 0, lastRefresh: now.addingTimeInterval(-8 * 86_400))
        XCTAssertTrue(subject.isCacheExpired(now: now))
    }

    func testExactTtlBoundaryIsExpired() {
        // TTL eviction fires at `cachedAt + ttl`, so the derived state must
        // flip at exactly one full TTL window — not one second later.
        let subject = status(itemCount: 0, lastRefresh: now.addingTimeInterval(-7 * 86_400))
        XCTAssertTrue(subject.isCacheExpired(now: now))
    }

    func testRecentEmptyRefreshIsNotExpired() {
        // A refresh that legitimately produced zero items (op_tag matches
        // nothing) is a configuration problem, not an expired cache.
        let subject = status(itemCount: 0, lastRefresh: now.addingTimeInterval(-3_600))
        XCTAssertFalse(subject.isCacheExpired(now: now))
    }

    func testPopulatedCacheIsNotExpired() {
        let subject = status(itemCount: 12, lastRefresh: now.addingTimeInterval(-8 * 86_400))
        XCTAssertFalse(subject.isCacheExpired(now: now))
    }

    func testCustomTtlIsRespected() {
        let twoDaysAgo = now.addingTimeInterval(-2 * 86_400)
        XCTAssertTrue(status(itemCount: 0, lastRefresh: twoDaysAgo, ttlDays: 1).isCacheExpired(now: now))
        XCTAssertFalse(status(itemCount: 0, lastRefresh: twoDaysAgo, ttlDays: 3).isCacheExpired(now: now))
    }

    func testNonConnectedStatesNeverDeriveExpired() {
        for state in [ConnectionState.locked, .revoked, .notConfigured, .error] {
            let subject = status(
                itemCount: 0,
                lastRefresh: now.addingTimeInterval(-8 * 86_400),
                connectionState: state
            )
            XCTAssertFalse(
                subject.isCacheExpired(now: now),
                "\(state) has its own icon and copy — the expired escalation must not shadow it"
            )
        }
    }

    func testMissingLastRefreshIsNotExpired() {
        let subject = status(itemCount: 0, lastRefresh: nil)
        XCTAssertFalse(subject.isCacheExpired(now: now))
    }

    func testTtlSecondsOverridesTruncatedTtlDays() {
        // The `cache_ttl_minutes` debug override yields ttlDays == 0 with the
        // real TTL only in ttlSeconds — 31 minutes past a 30-minute TTL is
        // expired, 10 minutes in is not.
        let thirtyMinutes = 30 * 60
        let pastTtl = status(
            itemCount: 0,
            lastRefresh: now.addingTimeInterval(-31 * 60),
            ttlDays: 0,
            ttlSeconds: thirtyMinutes
        )
        XCTAssertTrue(pastTtl.isCacheExpired(now: now))
        let withinTtl = status(
            itemCount: 0,
            lastRefresh: now.addingTimeInterval(-10 * 60),
            ttlDays: 0,
            ttlSeconds: thirtyMinutes
        )
        XCTAssertFalse(withinTtl.isCacheExpired(now: now))
    }
}
