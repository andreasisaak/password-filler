import Foundation

public enum AuditStoreError: Error, Equatable {
    case decodeFailed(String)
    case writeFailed(String)
}

/// On-disk snapshot of the latest `[Finding]`, persisted next to `config.json`.
///
/// Plain JSON — findings carry only item titles, vault names, and defect codes,
/// never user/password values — so encryption would be ceremony without payoff.
/// Writes are atomic (temp file + rename), matching `ConfigStore`.
public final class AuditStore {

    public static var defaultURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return support
            .appendingPathComponent("passwordfiller", isDirectory: true)
            .appendingPathComponent("audit-findings.json", isDirectory: false)
    }

    public let url: URL

    /// Latest findings — populated by `load()` on init by callers, replaced by `save(_:)`.
    public private(set) var current: [Finding] = []

    public init(url: URL = AuditStore.defaultURL) {
        self.url = url
    }

    // MARK: - Persistence

    public func save(_ findings: [Finding]) throws {
        let file = PersistedFile(
            version: 1,
            generatedAt: Date(),
            findings: findings
        )
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(file)
            let tmp = parent.appendingPathComponent(".audit-findings.json.tmp-\(UUID().uuidString)")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            throw AuditStoreError.writeFailed(String(describing: error))
        }
        current = findings
    }

    @discardableResult
    public func load() throws -> [Finding] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            current = []
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try Self.decoder.decode(LoadFile.self, from: data)
            let resolved = loaded.findings.compactMap(\.resolved)
            current = resolved
            return resolved
        } catch {
            throw AuditStoreError.decodeFailed(String(describing: error))
        }
    }

    // MARK: - Wire format

    private struct PersistedFile: Encodable {
        let version: Int
        let generatedAt: Date
        let findings: [Finding]
    }

    /// Decoding-side mirror — uses `TolerantDefect` so a single unknown
    /// `defects[].type` value (added by a future version) doesn't reject the
    /// whole file. Findings that end up with zero recognised defects are
    /// dropped during `resolved`.
    private struct LoadFile: Decodable {
        let version: Int
        let generatedAt: Date
        let findings: [LoadFinding]
    }

    private struct LoadFinding: Decodable {
        let id: String
        let title: String
        let vaults: [String]
        let defects: [TolerantDefect]
        let detectedAt: Date

        var resolved: Finding? {
            let real = defects.compactMap(\.value)
            guard !real.isEmpty else { return nil }
            return Finding(
                id: id,
                title: title,
                vaults: vaults,
                defects: real,
                detectedAt: detectedAt
            )
        }
    }

    private struct TolerantDefect: Decodable {
        let value: Defect?
        init(from decoder: Decoder) throws {
            self.value = try? Defect(from: decoder)
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
