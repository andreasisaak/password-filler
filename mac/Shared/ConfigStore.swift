import Foundation

/// Persistent JSON config for the Agent + Main-App.
///
/// On-disk key casing is snake_case so that legacy `config.json` files written
/// by the 0.3.x Node-host remain readable without migration scripts.
public struct Config: Codable, Equatable, Sendable {
    public var opAccount: String
    public var opTag: String
    public var cacheTtlDays: Int
    public var autoStart: Bool
    public var autoRefreshOnStart: Bool

    public init(
        opAccount: String = "",
        opTag: String = ".htaccess",
        cacheTtlDays: Int = 7,
        autoStart: Bool = true,
        autoRefreshOnStart: Bool = true
    ) {
        self.opAccount = opAccount
        self.opTag = opTag
        self.cacheTtlDays = cacheTtlDays
        self.autoStart = autoStart
        self.autoRefreshOnStart = autoRefreshOnStart
    }

    private enum CodingKeys: String, CodingKey {
        case opAccount = "op_account"
        case opTag = "op_tag"
        case cacheTtlDays = "cache_ttl_days"
        case autoStart = "auto_start"
        case autoRefreshOnStart = "auto_refresh_on_start"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Config()
        self.opAccount = try c.decodeIfPresent(String.self, forKey: .opAccount) ?? defaults.opAccount
        self.opTag = try c.decodeIfPresent(String.self, forKey: .opTag) ?? defaults.opTag
        self.cacheTtlDays = try c.decodeIfPresent(Int.self, forKey: .cacheTtlDays) ?? defaults.cacheTtlDays
        self.autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? defaults.autoStart
        self.autoRefreshOnStart = try c.decodeIfPresent(Bool.self, forKey: .autoRefreshOnStart) ?? defaults.autoRefreshOnStart
    }
}

public enum ConfigStoreError: Error, Equatable {
    case decodeFailed(String)
    case writeFailed(String)
}

/// Reads and writes `~/Library/Application Support/passwordfiller/config.json`.
/// Writes are atomic (temp file + rename). Legacy configs with only
/// `op_account` + `op_tag` decode successfully; missing keys fall back to
/// `Config()` defaults via the custom `init(from:)`.
public final class ConfigStore {

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support
            .appendingPathComponent("passwordfiller", isDirectory: true)
            .appendingPathComponent("config.json", isDirectory: false)
    }

    public let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    /// Loads and returns the config. Returns a default `Config()` if the file
    /// does not exist yet — the onboarding wizard will populate it.
    public func load() throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Config()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigStoreError.decodeFailed(String(describing: error))
        }
    }

    /// Writes the config atomically.
    public func save(_ config: Config) throws {
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try encoder.encode(config)
            let tmp = parent.appendingPathComponent(".config.json.tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            throw ConfigStoreError.writeFailed(String(describing: error))
        }
    }
}
