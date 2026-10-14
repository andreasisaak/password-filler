import Foundation

/// An item as it lives in the Agent cache.
public struct StoredItem: Codable, Equatable, Sendable {
    public let itemId: String
    public let title: String
    public let hostnames: [String]
    public let username: String
    public let password: String
    public let sourceVault: String?
    public let cachedAt: Date

    /// eTLD+1 domains of `hostnames`, deduplicated and sorted. Computed, so it
    /// is never persisted and always reflects the bundled Public Suffix List —
    /// a `domains` key in a snapshot from an older version is ignored on decode.
    public var domains: [String] {
        Set(hostnames.compactMap { PublicSuffixList.eTLDPlusOne(host: $0) }).sorted()
    }

    public init(
        itemId: String,
        title: String,
        hostnames: [String],
        username: String,
        password: String,
        sourceVault: String?,
        cachedAt: Date
    ) {
        self.itemId = itemId
        self.title = title
        self.hostnames = hostnames
        self.username = username
        self.password = password
        self.sourceVault = sourceVault
        self.cachedAt = cachedAt
    }
}
