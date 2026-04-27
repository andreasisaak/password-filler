import Foundation

// MARK: - Mach-Service name

/// Well-known identifiers shared between the Agent and its XPC clients
/// (Main-App, CredProvider.appex, NMH-bridge).
public enum PFMachService {
    /// App-Group-prefixed Mach-Service name. Must match the `MachServices` key in
    /// `app.passwordfiller.agent.plist` exactly. No `.xpc` suffix — that convention
    /// is for XPC-Service bundle products, not LaunchAgent-hosted Mach-Services
    /// (drift log 2026-04-21 15:30, design.md D3).
    ///
    /// The `group.A5278RL7RX.app.passwordfiller` prefix is required — not just
    /// the bare Team-ID — because sandboxed clients (CredProvider.appex) may
    /// only `mach-lookup` services whose global name begins with an
    /// app-group-id they declare in `com.apple.security.application-groups`.
    /// With Team-ID-only prefix, sandboxd emitted `deny(1) mach-lookup
    /// A5278RL7RX.app.passwordfiller.agent` and the XPC connection invalidated
    /// before the first reply (Phase-5 Partial-2 live test, 2026-04-22).
    /// The non-sandboxed Main-App works under either prefix, which is why the
    /// drift only surfaced once CredProvider actually tried to reach the Agent.
    public static let name = "group.A5278RL7RX.app.passwordfiller.agent"
}

// MARK: - XPC protocol

/// XPC surface exposed by the Agent. Non-primitive replies travel as JSON-encoded
/// `Data?` to sidestep `NSSecureCoding` boilerplate for value types — the protocol
/// stays stable while the payload schemas (`AgentStatus`, `RefreshResult`) can
/// evolve as `Codable` structs.
@objc public protocol AgentServiceProtocol {
    /// Look up credentials for a hostname. `reply` delivers JSON-encoded
    /// `LookupResponse` or `nil` on no-match / error.
    func lookupCredentials(host: String, reply: @escaping (Data?) -> Void)

    /// Refresh the in-memory cache from 1Password. `reply` delivers JSON-encoded
    /// `RefreshResult`.
    func refreshCache(reply: @escaping (Data?) -> Void)

    /// Current agent status. `reply` delivers JSON-encoded `AgentStatus`.
    func getStatus(reply: @escaping (Data?) -> Void)

    /// Merged-for-display snapshot of the cache for the Main-App popover.
    /// `reply` delivers JSON-encoded `[DisplayRow]` — empty array when cache is empty.
    func listItems(reply: @escaping (Data?) -> Void)

    /// Re-read `config.json` from disk and apply the new values to the running
    /// agent (TTL takes effect immediately; `opTag` is picked up on the next
    /// refresh via the `configProvider` closure). `opAccount` changes require
    /// an Agent restart — `OpClient` captures the account at init time.
    /// `reply` delivers JSON-encoded `ReloadConfigResult`.
    func reloadConfig(reply: @escaping (Data?) -> Void)

    /// Trivial liveness check used by the extension popup.
    func ping(reply: @escaping (Bool) -> Void)

    /// Latest snapshot of `[Finding]` produced by the most recent successful refresh.
    /// `reply` delivers JSON-encoded `[Finding]` — empty array when no findings.
    /// Read from in-memory state on the Agent (no disk roundtrip), so latency is <1ms.
    func getAuditFindings(reply: @escaping (Data?) -> Void)
}

// MARK: - Wire payloads (JSON over XPC)

/// Connection state surfaced to the Main-App for icon rendering.
public enum ConnectionState: String, Codable, Sendable {
    case notConfigured
    case connected
    case locked
    case revoked
    case error
}

/// Response for a successful `lookupCredentials` call.
public struct LookupResponse: Codable, Equatable, Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Response for `refreshCache`. `success=false` means the refresh was attempted
/// but failed — the UI shows `errorMessage` verbatim (already localized on the
/// Main-App side, or a fallback in English).
public struct RefreshResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let itemCount: Int
    public let durationSeconds: Double
    public let errorMessage: String?

    public init(success: Bool, itemCount: Int, durationSeconds: Double, errorMessage: String?) {
        self.success = success
        self.itemCount = itemCount
        self.durationSeconds = durationSeconds
        self.errorMessage = errorMessage
    }
}

/// Response for `reloadConfig`. `success=false` means the config file could not
/// be read or decoded — `errorMessage` carries the reason, and `ttlDays`
/// reflects the value currently active on the Agent (unchanged on failure).
public struct ReloadConfigResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let ttlDays: Int
    public let errorMessage: String?

    public init(success: Bool, ttlDays: Int, errorMessage: String?) {
        self.success = success
        self.ttlDays = ttlDays
        self.errorMessage = errorMessage
    }
}

/// Snapshot of the Agent's state, polled by the Main-App on popover open and
/// on a 3 s / 30 s cadence.
public struct AgentStatus: Codable, Equatable, Sendable {
    public let itemCount: Int
    public let lastRefresh: Date?
    public let ttlDays: Int
    public let connectionState: ConnectionState
    /// Human-readable explanation of the last non-transient failure. Set by
    /// the refresh pipeline when it hits an error, cleared on the next
    /// successful refresh. Surfaces to the popover as the secondary line for
    /// `.error` / `.locked` / `.revoked` states so the user sees *why* the
    /// status is bad, not just that it is.
    public let errorMessage: String?

    public init(
        itemCount: Int,
        lastRefresh: Date?,
        ttlDays: Int,
        connectionState: ConnectionState,
        errorMessage: String? = nil
    ) {
        self.itemCount = itemCount
        self.lastRefresh = lastRefresh
        self.ttlDays = ttlDays
        self.connectionState = connectionState
        self.errorMessage = errorMessage
    }

    // Backwards-compatible decode for any cached payloads that predate the
    // `errorMessage` field.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.itemCount = try c.decode(Int.self, forKey: .itemCount)
        self.lastRefresh = try c.decodeIfPresent(Date.self, forKey: .lastRefresh)
        self.ttlDays = try c.decode(Int.self, forKey: .ttlDays)
        self.connectionState = try c.decode(ConnectionState.self, forKey: .connectionState)
        self.errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }

    private enum CodingKeys: String, CodingKey {
        case itemCount, lastRefresh, ttlDays, connectionState, errorMessage
    }
}

// MARK: - JSON helpers

public enum XPCPayload {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
