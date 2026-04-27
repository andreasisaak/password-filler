import Foundation

// MARK: - Shared Keychain (Safari URL handoff)
//
// SafariExt.appex writes the currently-observed URL into a Generic-Password
// keychain entry under the Team-ID-prefixed access-group (both appexes carry
// `keychain-access-groups` entitlement for `A5278RL7RX.app.passwordfiller`).
// CredProvider.appex reads the same entry the moment Safari's Basic-Auth
// dialog invokes `prepareCredentialList(for: [])` with empty identifiers —
// that's the only path Safari takes for a native `401 WWW-Authenticate`
// challenge, and it is the only way we can tell which host the user is
// trying to authenticate against without Safari telling us.
//
// The entry is a single JSON blob `{host, ts}` (serialised UTF-8 bytes), and
// stale entries beyond `maxFreshnessSeconds` are ignored so that a stale
// write from a previous tab never leaks into a new dialog.
//
// This type is source-shared between CredProvider (reader) and SafariExt
// (writer, arriving in Phase-5 partial-2). Both compile against the same
// `Shared/` group via project.yml, so the wire format stays in lock-step.

public enum SharedHostKeychain {

    /// Access-group prefix for `SecItem*` queries. Must exactly match the
    /// `keychain-access-groups` entitlement value in both .appex bundles.
    public static let accessGroup = "A5278RL7RX.app.passwordfiller"

    /// `kSecAttrService` — scopes the entry to our observed-host handoff so
    /// unrelated apps sharing the access-group (there are none today, but it
    /// is defensive) cannot collide on the Generic-Password slot.
    public static let service = "app.passwordfiller.observedHost"

    /// `kSecAttrAccount` — only one active observed host at a time, so a
    /// fixed account name works and saves us from enumerating entries.
    public static let account = "current"

    /// Entries older than this are treated as missing. 300 s matches the
    /// spike's `maxFreshness` — comfortably wider than the time between
    /// Safari showing the Basic-Auth dialog and the user clicking "Password
    /// Filler", yet narrow enough that a URL written for a previous tab is
    /// not reused when the user navigates elsewhere.
    public static let maxFreshnessSeconds: TimeInterval = 300

    /// Wire payload written to the keychain entry. Both appexes encode/decode
    /// via the same struct so a schema change breaks the build, not the
    /// runtime.
    public struct Payload: Codable, Equatable, Sendable {
        public let host: String
        public let ts: TimeInterval

        public init(host: String, ts: TimeInterval = Date().timeIntervalSince1970) {
            self.host = host
            self.ts = ts
        }

        public var age: TimeInterval {
            Date().timeIntervalSince1970 - ts
        }

        public var isFresh: Bool {
            age <= SharedHostKeychain.maxFreshnessSeconds
        }
    }
}
