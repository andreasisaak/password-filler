import CryptoKit
import Foundation

/// A single defective `.htaccess`-tagged 1Password item, surfaced by `AuditChecker`.
///
/// One `Finding` represents a *logical* item — when the same item appears in multiple
/// vaults with identical credentials, the merge-twin collapses to a single `Finding`
/// with all source vaults listed, mirroring `ItemStore.mergedForDisplay`.
public struct Finding: Codable, Hashable, Identifiable {
    /// Stable hash of `(title, sortedVaults)` only — defects are deliberately excluded
    /// so the ID does not change after the user fixes a defect.
    public let id: String
    public let title: String
    /// Source vaults, sorted ascending. At least one element.
    public let vaults: [String]
    /// At least one element. A `Finding` with zero defects is never persisted.
    public let defects: [Defect]
    public let detectedAt: Date

    public init(
        id: String,
        title: String,
        vaults: [String],
        defects: [Defect],
        detectedAt: Date
    ) {
        self.id = id
        self.title = title
        self.vaults = vaults
        self.defects = defects
        self.detectedAt = detectedAt
    }

    /// Stable identity: 16-char hex prefix of SHA-256 over `title|sortedVaults`.
    public static func makeId(title: String, vaults: [String]) -> String {
        let key = "\(title)|\(vaults.sorted().joined(separator: ","))"
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// Defects that prevent the Agent from autofilling an item — typed so the wire format
/// is stable across renames and the UI layer can localize freely.
public enum Defect: Hashable, Sendable {
    case noWebsite
    case noUsername
    case noPassword
    /// Item has a section matching the htaccess regex, but no STRING field with a value.
    /// Agent silently falls back to top-level fields → likely wrong credentials.
    case sectionBrokenUsername
    /// Item has a section matching the htaccess regex, but no CONCEALED field with a value
    /// (e.g. password stored as a plain Text field). Same silent-fallback effect.
    case sectionBrokenPassword
    /// Same `(title, hostnames-set)` exists in another vault with diverging credentials.
    case vaultDuplicate(otherTitle: String, otherVaults: [String], hostnameCount: Int)
    /// A different item shares one or more hostnames — Agent's URL match becomes ambiguous.
    case hostnameCollision(otherTitle: String, otherVaults: [String], hostnames: [String])
}

extension Defect: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case otherTitle, otherVaults, hostnameCount, hostnames
    }

    private enum Kind: String, Codable {
        case noWebsite, noUsername, noPassword
        case sectionBrokenUsername, sectionBrokenPassword
        case vaultDuplicate, hostnameCollision
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noWebsite:               try c.encode(Kind.noWebsite, forKey: .type)
        case .noUsername:              try c.encode(Kind.noUsername, forKey: .type)
        case .noPassword:              try c.encode(Kind.noPassword, forKey: .type)
        case .sectionBrokenUsername:   try c.encode(Kind.sectionBrokenUsername, forKey: .type)
        case .sectionBrokenPassword:   try c.encode(Kind.sectionBrokenPassword, forKey: .type)
        case let .vaultDuplicate(t, v, n):
            try c.encode(Kind.vaultDuplicate, forKey: .type)
            try c.encode(t, forKey: .otherTitle)
            try c.encode(v, forKey: .otherVaults)
            try c.encode(n, forKey: .hostnameCount)
        case let .hostnameCollision(t, v, h):
            try c.encode(Kind.hostnameCollision, forKey: .type)
            try c.encode(t, forKey: .otherTitle)
            try c.encode(v, forKey: .otherVaults)
            try c.encode(h, forKey: .hostnames)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .noWebsite:               self = .noWebsite
        case .noUsername:              self = .noUsername
        case .noPassword:              self = .noPassword
        case .sectionBrokenUsername:   self = .sectionBrokenUsername
        case .sectionBrokenPassword:   self = .sectionBrokenPassword
        case .vaultDuplicate:
            self = .vaultDuplicate(
                otherTitle: try c.decode(String.self, forKey: .otherTitle),
                otherVaults: try c.decode([String].self, forKey: .otherVaults),
                hostnameCount: try c.decode(Int.self, forKey: .hostnameCount)
            )
        case .hostnameCollision:
            self = .hostnameCollision(
                otherTitle: try c.decode(String.self, forKey: .otherTitle),
                otherVaults: try c.decode([String].self, forKey: .otherVaults),
                hostnames: try c.decode([String].self, forKey: .hostnames)
            )
        }
    }
}
