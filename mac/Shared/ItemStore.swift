import Foundation

/// Regex used by both the legacy Node-host and the Agent to identify
/// "htaccess / Basic-Auth / htpasswd / webuser" sections within a 1Password item.
private let sectionPattern: NSRegularExpression = {
    let pattern = #"(htaccess|basicauth|basic.?auth|htpasswd|webuser)"#
    // `dotMatchesLineSeparators` is irrelevant here; `caseInsensitive` matches `/…/i`.
    return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}()

/// In-memory cache of 1Password htaccess items + the URL-matching state machine.
///
/// All operations are synchronous and thread-safe via a single lock — contention is
/// negligible at our scale (< 100 items, handful of lookups per minute).
public final class ItemStore: @unchecked Sendable {

    private let lock = NSLock()
    private var items: [StoredItem] = []
    private var lastRefreshedAt: Date?
    private let persistence: PersistentCache?

    /// TTL in seconds. Enforced lazily on `lookup` / `allItems`.
    public var ttl: TimeInterval

    /// Initializer used by tests and callers that don't want disk persistence.
    public init(ttl: TimeInterval = 7 * 24 * 3600) {
        self.ttl = ttl
        self.persistence = nil
    }

    /// Production initializer: on construction, eagerly loads the last
    /// encrypted snapshot from disk so the Agent comes up "warm" after a
    /// reboot — no 1Password Touch-ID prompt needed before Basic-Auth
    /// lookups work again. Every subsequent `replace()` writes the new
    /// snapshot back to disk, atomically.
    public init(ttl: TimeInterval = 7 * 24 * 3600, persistence: PersistentCache) {
        self.ttl = ttl
        self.persistence = persistence
        let preloaded = persistence.load()
        if !preloaded.isEmpty {
            self.items = preloaded
            // Use the newest `cachedAt` as the effective "last refresh" so the
            // popover's relative-time display ("vor 2 Stunden") survives
            // reboot without needing a separate persisted timestamp.
            self.lastRefreshedAt = preloaded.map(\.cachedAt).max()
        }
    }

    // MARK: - Mutation

    public func replace(with newItems: [StoredItem]) {
        lock.lock()
        items = newItems
        lastRefreshedAt = Date()
        let snapshot = items
        lock.unlock()
        persistence?.persist(items: snapshot)
    }

    public func evictAll() {
        lock.lock()
        items.removeAll()
        lock.unlock()
        persistence?.wipe()
    }

    // MARK: - Accessors

    public var lastRefresh: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastRefreshedAt
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return items.count
    }

    public func allItems(now: Date = Date()) -> [StoredItem] {
        lock.lock(); defer { lock.unlock() }
        pruneExpired(now: now)
        return items
    }

    // MARK: - Lookup (3-stage match)

    /// Returns the best-matching item for a hostname, or `nil` if:
    ///   - no candidate matches, OR
    ///   - multiple candidates tie with no tiebreak winner (ambiguous → silent fail).
    ///
    /// Ported 1:1 from `host/htpasswd-host.js:254-335` (see git commit 49ec061).
    public func lookup(hostname rawHost: String, now: Date = Date()) -> StoredItem? {
        let host = rawHost.lowercased()
        lock.lock(); defer { lock.unlock() }
        pruneExpired(now: now)

        // 1. Exact hostname match.
        if let exact = items.first(where: { $0.hostnames.contains(host) }) {
            return exact
        }

        // 2. Domain-suffix match.
        guard let requestDomain = PublicSuffixList.eTLDPlusOne(host: host) else {
            return nil
        }

        let candidates = items.filter { item in
            item.hostnames.contains { stored in
                PublicSuffixList.eTLDPlusOne(host: stored) == requestDomain
            }
        }

        if candidates.count == 1 {
            return candidates[0]
        }
        if candidates.isEmpty {
            return nil
        }

        // Multi-candidate: shared-suffix-length scoring.
        let baseDomainParts = requestDomain.split(separator: ".").count
        let requestDepth = host.split(separator: ".").count - baseDomainParts

        var bestMatch: StoredItem?
        var bestScore = 0

        for item in candidates {
            for stored in item.hostnames {
                let score = Self.sharedSuffixLength(host, stored)
                if score > bestScore {
                    bestScore = score
                    bestMatch = item
                }
            }
        }

        // Clear winner: must share more labels than just the base domain.
        if let bestMatch, bestScore > baseDomainParts {
            return bestMatch
        }

        // Tiebreaker: exactly one candidate has a hostname at the same subdomain depth.
        var depthMatch: StoredItem?
        for item in candidates {
            let hasMatchingDepth = item.hostnames.contains { stored in
                guard PublicSuffixList.eTLDPlusOne(host: stored) == requestDomain else { return false }
                let storedDepth = stored.split(separator: ".").count - baseDomainParts
                return storedDepth == requestDepth
            }
            if hasMatchingDepth {
                if depthMatch != nil {
                    // Two candidates share the depth → ambiguous.
                    return nil
                }
                depthMatch = item
            }
        }

        return depthMatch
    }

    // MARK: - Display merge

    /// Collapses items with identical `(title, Set(hostnames), username, password)` into
    /// a single `DisplayRow` listing every source vault. Preserves input order by title.
    public func mergedForDisplay(now: Date = Date()) -> [DisplayRow] {
        let snapshot = allItems(now: now)

        struct Key: Hashable {
            let title: String
            let hostnames: [String]
            let username: String
            let password: String
        }

        var order: [Key] = []
        var groups: [Key: [StoredItem]] = [:]

        for item in snapshot {
            let key = Key(
                title: item.title,
                hostnames: item.hostnames.sorted(),
                username: item.username,
                password: item.password
            )
            if groups[key] == nil {
                order.append(key)
                groups[key] = [item]
            } else {
                groups[key]?.append(item)
            }
        }

        return order.map { key in
            let members = groups[key] ?? []
            let vaults = members.compactMap(\.sourceVault)
            return DisplayRow(
                title: key.title,
                hostnames: members.first?.hostnames ?? key.hostnames,
                domains: members.first?.domains ?? [],
                sourceVaults: vaults,
                primaryItemId: members.first?.itemId ?? ""
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: - Credential extraction (static, unit-testable)

    /// Ported 1:1 from `host/htpasswd-host.js:129-153`. Section match wins if present,
    /// even when top-level username/password fields also exist.
    public static func extractCredentials(from fields: [Field]) -> Credentials? {
        let sectionFields = fields.filter { field in
            guard let label = field.section?.label else { return false }
            let range = NSRange(label.startIndex..<label.endIndex, in: label)
            return sectionPattern.firstMatch(in: label, range: range) != nil
        }

        if !sectionFields.isEmpty {
            let usernameField = sectionFields.first { $0.type == "STRING" }
            let passwordField = sectionFields.first { $0.type == "CONCEALED" }
            if let u = usernameField?.value, let p = passwordField?.value, !u.isEmpty, !p.isEmpty {
                return Credentials(username: u, password: p)
            }
        }

        // Fallback: top-level fields (`id == "username"`, `id == "password"`, no section).
        let topUser = fields.first { $0.id == "username" && $0.section == nil }
        let topPass = fields.first { $0.id == "password" && $0.section == nil }
        if let u = topUser?.value, let p = topPass?.value, !u.isEmpty, !p.isEmpty {
            return Credentials(username: u, password: p)
        }

        return nil
    }

    /// Extracts the set of hostnames from an item's `urls` array, preserving input order.
    public static func extractHostnames(from urls: [URLEntry]?) -> [String] {
        guard let urls else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for entry in urls {
            guard let host = PublicSuffixList.hostname(from: entry.href) else { continue }
            if seen.insert(host).inserted {
                out.append(host)
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Number of shared rightmost labels between two hostnames (e.g. `a.x.com`, `b.x.com` → 2).
    public static func sharedSuffixLength(_ a: String, _ b: String) -> Int {
        let partsA = a.split(separator: ".").reversed().map(String.init)
        let partsB = b.split(separator: ".").reversed().map(String.init)
        var shared = 0
        for i in 0..<min(partsA.count, partsB.count) {
            if partsA[i] == partsB[i] {
                shared += 1
            } else {
                break
            }
        }
        return shared
    }

    private func pruneExpired(now: Date) {
        items.removeAll { item in
            now.timeIntervalSince(item.cachedAt) > ttl
        }
    }
}
