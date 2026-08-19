import Foundation

/// Derives the "cache expired — user action required" display state from an
/// `AgentStatus` snapshot.
///
/// The Agent seeds `connectionState = .connected` at launch whenever the
/// persisted cache holds items (see `Agent/main.swift`), and nothing
/// re-evaluates that seed once TTL eviction empties the store. Without this
/// derivation the popover keeps saying "Connected" with zero items while
/// Basic-Auth fills silently stop working. This is the single place where the
/// Main-App (menu-bar icon, popover status row, user notification) decides
/// that the user must trigger a manual refresh — and with it the 1Password
/// re-authentication.
extension AgentStatus {

    /// `true` when the Agent looks healthy but every cached item has aged out:
    /// connected, zero items, and the last refresh at least one full TTL
    /// window in the past. A recent refresh that legitimately produced zero
    /// items (e.g. `op_tag` matches nothing) stays `false` — that is a
    /// configuration problem, not an expired cache.
    public func isCacheExpired(now: Date = Date()) -> Bool {
        guard connectionState == .connected, itemCount == 0, let lastRefresh else {
            return false
        }
        let ttl = TimeInterval(ttlSeconds ?? ttlDays * 86_400)
        return now.timeIntervalSince(lastRefresh) >= ttl
    }
}
