import Foundation

// MARK: - 1Password CLI JSON decoding

/// Summary returned by `op item list --format=json` (subset of fields we use).
public struct ItemSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let urls: [URLEntry]?
    public let vault: VaultRef?

    public init(id: String, title: String, urls: [URLEntry]?, vault: VaultRef?) {
        self.id = id
        self.title = title
        self.urls = urls
        self.vault = vault
    }
}

/// Full item returned by `op item get <id> --format=json`.
public struct FullItem: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let urls: [URLEntry]?
    public let fields: [Field]?
    public let vault: VaultRef?

    public init(id: String, title: String, urls: [URLEntry]?, fields: [Field]?, vault: VaultRef?) {
        self.id = id
        self.title = title
        self.urls = urls
        self.fields = fields
        self.vault = vault
    }
}

public struct URLEntry: Codable, Equatable, Sendable {
    public let href: String

    public init(href: String) {
        self.href = href
    }
}

public struct VaultRef: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?

    public init(id: String?, name: String?) {
        self.id = id
        self.name = name
    }
}

public struct Field: Codable, Equatable, Sendable {
    public let id: String?
    public let type: String?
    public let value: String?
    public let section: FieldSection?

    public init(id: String?, type: String?, value: String?, section: FieldSection?) {
        self.id = id
        self.type = type
        self.value = value
        self.section = section
    }
}

public struct FieldSection: Codable, Equatable, Sendable {
    public let id: String?
    public let label: String?

    public init(id: String?, label: String?) {
        self.id = id
        self.label = label
    }
}

// MARK: - Domain types

/// Credentials extracted from a 1Password item — the minimum we hand to the Basic-Auth dialog.
public struct Credentials: Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// An item as it lives in the Agent cache. `sourceVaults` is populated when merging identical
/// items from multiple vaults (see `ItemStore.mergedForDisplay`).
public struct StoredItem: Codable, Equatable, Sendable {
    public let itemId: String
    public let title: String
    public let hostnames: [String]
    /// eTLD+1 domains derived from `hostnames`, deduplicated.
    public let domains: [String]
    public let username: String
    public let password: String
    public let sourceVault: String?
    public let cachedAt: Date

    public init(
        itemId: String,
        title: String,
        hostnames: [String],
        domains: [String],
        username: String,
        password: String,
        sourceVault: String?,
        cachedAt: Date
    ) {
        self.itemId = itemId
        self.title = title
        self.hostnames = hostnames
        self.domains = domains
        self.username = username
        self.password = password
        self.sourceVault = sourceVault
        self.cachedAt = cachedAt
    }
}

/// Merged-for-display row. Multiple `StoredItem`s collapse into one row when their
/// (title, hostnames-set, username, password) are identical — only `sourceVaults` differs.
///
/// `Codable` conformance is load-bearing for the XPC `listItems` reply path —
/// the Main-App popover decodes `[DisplayRow]` from the agent over the same
/// JSON-in-Data? wire convention used by `AgentStatus` / `RefreshResult`.
public struct DisplayRow: Codable, Equatable, Sendable {
    public let title: String
    public let hostnames: [String]
    public let domains: [String]
    public let sourceVaults: [String]
    /// Back-reference to the first underlying item id (for UI interactions).
    public let primaryItemId: String

    public init(
        title: String,
        hostnames: [String],
        domains: [String],
        sourceVaults: [String],
        primaryItemId: String
    ) {
        self.title = title
        self.hostnames = hostnames
        self.domains = domains
        self.sourceVaults = sourceVaults
        self.primaryItemId = primaryItemId
    }
}
