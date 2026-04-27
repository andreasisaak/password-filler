import Foundation
import CryptoKit
import Security
import os.log

/// On-disk cache for the Agent's `[StoredItem]` snapshot, encrypted with an
/// AES-256-GCM key that lives in the system Keychain.
///
/// Design choices (see research notes 2026-04-23):
///   - **Blob on disk, key in Keychain**. Apple Developer Docs and the 2025
///     Keychain Best Practices guidance are explicit that the Keychain is
///     for credentials, not 10 KB JSON blobs (`errSecDataTooLarge` risk).
///     The canonical pattern is to generate a SymmetricKey, stash it as a
///     generic-password Keychain item, and seal the blob via AES.GCM into a
///     regular file in `~/Library/Application Support/passwordfiller/`.
///   - **`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`** on the key item.
///     `ThisDeviceOnly` keeps the key out of iCloud Keychain sync and
///     Time Machine restores onto a different machine — the on-disk blob is
///     worthless without the matching key, which never leaves this Mac.
///   - **`kSecUseDataProtectionKeychain=true`** (not the legacy file-based
///     keychain) so the same code path works on future iOS targets and the
///     key is Data-Protection-class-guarded by the Secure Enclave on Apple
///     Silicon.
///   - **No Access-Control-List with biometric requirement**. A LaunchAgent
///     is headless — a Touch-ID-gated key would deadlock the Agent at boot
///     with no UI to show the prompt. The User-Login-Password + Secure
///     Enclave attestation of the Agent's code signature is the defense in
///     depth we rely on.
///
/// Threat model coverage:
///   - Offline disk theft / APFS-image extraction → blob is AES-GCM, key
///     only accessible after User-Login unlock. Safe (same bar as 1Password
///     Desktop's own `1password.sqlite`).
///   - Time Machine / iCloud backup → key is `ThisDeviceOnly`; restoring
///     the blob to another Mac yields unopenable ciphertext.
///   - Another user on the same Mac → Keychain item is login-keychain
///     scoped; other accounts see neither the key nor the file.
///   - Malware on the unlocked Mac with user privileges → can in principle
///     read both. This is identical to every other local password manager
///     (1P included) and out of scope for a disk-at-rest control.
public final class PersistentCache: @unchecked Sendable {

    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "persistent-cache")
    private let fileURL: URL

    /// Keychain item identifiers. `service` is the logical namespace, `account`
    /// distinguishes the cache-key from any other secret this app might store
    /// in the future. Both are user-visible in Keychain Access.app.
    private let service = "app.passwordfiller.agent"
    private let account = "cache-encryption-key"
    /// Team-ID-prefixed access group that matches the `keychain-access-groups`
    /// entitlement on the Agent helper-app, authorized by the Developer ID
    /// provisioning profile's `A5278RL7RX.*` wildcard.
    private let accessGroup = "A5278RL7RX.app.passwordfiller"

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.fileURL = base
                .appendingPathComponent("passwordfiller", isDirectory: true)
                .appendingPathComponent("cache.bin")
        }
    }

    // MARK: - Public API

    /// Encrypt + write the current item snapshot. Creates the parent directory
    /// if missing. Atomic-replace semantics via `.atomic` so a crash mid-write
    /// never leaves a truncated cache file behind.
    public func persist(items: [StoredItem]) {
        do {
            let key = try loadOrCreateKey()
            let plaintext = try JSONEncoder.iso8601.encode(items)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                log.error("AES.GCM.seal produced no combined data — nonce missing?")
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try combined.write(to: fileURL, options: [.atomic])
            log.info("persisted \(items.count, privacy: .public) items (\(combined.count, privacy: .public) bytes)")
        } catch {
            log.error("persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Decrypt + return the previously persisted snapshot. Returns an empty
    /// array on first run, missing key, or any decode error — the caller
    /// treats "no cache" the same as "fresh install".
    public func load() -> [StoredItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log.info("no cache file on disk — fresh start")
            return []
        }
        do {
            let key = try loadOrCreateKey()
            let combined = try Data(contentsOf: fileURL)
            let sealed = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(sealed, using: key)
            let items = try JSONDecoder.iso8601.decode([StoredItem].self, from: plaintext)
            log.info("loaded \(items.count, privacy: .public) items from cache")
            return items
        } catch {
            log.error("load failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Delete both the on-disk blob and the Keychain key. Used by the
    /// settings-window "Logout" button — gives the user an explicit way to
    /// forget everything this Agent has ever cached from 1Password.
    public func wipe() {
        try? FileManager.default.removeItem(at: fileURL)
        SecItemDelete(baseQuery as CFDictionary)
        log.info("wiped cache file and keychain key")
    }

    /// Shared attribute set used by every SecItem call — identifies the key by
    /// service+account within the Team-ID-prefixed access group, and opts into
    /// the Data-Protection Keychain for Secure-Enclave-hardened storage.
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    // MARK: - Keychain helpers

    private func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try readKey() {
            return existing
        }
        let fresh = SymmetricKey(size: .bits256)
        try writeKey(fresh)
        log.info("generated new AES-256 cache key")
        return fresh
    }

    private func readKey() throws -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedResultType
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    private func writeKey(_ key: SymmetricKey) throws {
        let raw = key.withUnsafeBytes { Data(Array($0)) }
        var attrs = baseQuery
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attrs[kSecValueData as String] = raw
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        case unexpectedResultType

        var description: String {
            switch self {
            case .status(let s): return "Keychain OSStatus \(s)"
            case .unexpectedResultType: return "Keychain returned non-Data result"
            }
        }
    }
}

// MARK: - JSON codec helpers with ISO8601 dates

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
