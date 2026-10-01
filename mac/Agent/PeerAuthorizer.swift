import Foundation
import Security
import Darwin
import os.log

/// Who is on the other end of an accepted socket connection; decides which
/// actions `UnixSocketServer` serves (D4 authorization matrix).
public enum SocketPeer: Equatable {
    /// Gate disabled — only hermetic tests run without a requirement.
    case unrestricted
    /// `pf-nmh-bridge` spawned by a supported browser.
    case browserBridge
    /// `password-filler-mcp` (MCP server or `run` wrapper).
    case mcpClient

    /// D4 allow-lists: an action added to the server later stays closed to a
    /// peer type until it is listed here.
    static let browserBridgeActions: Set<String> = ["ping", "lookup", "list", "refresh", "config"]
    static let mcpClientActions: Set<String> = ["ping", "hosts", "run_credentials"]

    func allows(action: String) -> Bool {
        switch self {
        case .unrestricted:
            return true
        case .browserBridge:
            return Self.browserBridgeActions.contains(action)
        case .mcpClient:
            return Self.mcpClientActions.contains(action)
        }
    }
}

/// Single trust boundary for both of the Agent's IPC entrypoints.
///
/// Holds one code-signing requirement and enforces it on each channel with the
/// mechanism native to that channel:
///   - XPC: `NSXPCConnection.setCodeSigningRequirement` (kernel-enforced; the
///     peer is invalidated before any message is delivered).
///   - Unix socket: resolve the connected peer's `SecCode` from its PID, check
///     it against the requirement, then classify it by signing identifier
///     (D4); a bridge additionally needs a supported browser as parent (D25).
///
/// A `nil` requirement disables the gate (tests over anonymous listeners and
/// temp sockets connect from a differently signed runner).
public final class PeerAuthorizer {

    /// Pins peers to our Apple Team OU — not a single bundle identifier, since
    /// the Main-App and the CredProvider.appex have distinct identifiers but
    /// share the OU. `anchor apple generic` holds for both the Developer ID and
    /// Apple Development certificate chains.
    public static let defaultRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(PFMachService.teamId)\""

    /// Signing identifier of the bundled Native-Messaging bridge.
    static let bridgeIdentifier = "pf-nmh-bridge"
    /// Signing identifier of the bundled MCP server / `run` wrapper.
    static let mcpIdentifier = "password-filler-mcp"

    /// Bridge parents are third-party browsers; this only proves the parent's
    /// signature chains to Apple, the identity itself is judged by
    /// `BridgeParentPolicy`.
    private static let browserAnchorRequirement = compile("anchor apple generic")

    private let requirement: String?
    private let compiledRequirement: SecRequirement?
    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "auth")

    public init(requirement: String? = PeerAuthorizer.defaultRequirement) {
        self.requirement = requirement
        self.compiledRequirement = requirement.map(Self.compile)
    }

    /// The production requirements are compile-time constants; a parse failure
    /// is a programming error, not a runtime condition to tolerate.
    private static func compile(_ requirement: String) -> SecRequirement {
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else {
            preconditionFailure("PeerAuthorizer: invalid requirement string (OSStatus \(status))")
        }
        return compiled
    }

    /// XPC: kernel-enforced. No-op when the gate is disabled.
    public func gate(_ connection: NSXPCConnection) {
        guard let requirement else { return }
        connection.setCodeSigningRequirement(requirement)
    }

    /// Unix socket: classifies the peer by its signing identifier (D4), or
    /// returns `nil` to close the connection. Fails closed on every error.
    /// With the gate disabled every peer is `.unrestricted`.
    ///
    /// Caveat: PID-based identity carries a PID-reuse window between `accept`
    /// and this check — for the bridge's parent as well. The socket is already
    /// `chmod 0600` (same-UID only), so the residual risk is a same-user
    /// attacker racing PID reuse — narrow, but the reason XPC (which uses audit
    /// tokens) is the stronger of the two.
    public func authorize(socketFD: Int32) -> SocketPeer? {
        guard let compiledRequirement else { return .unrestricted }
        guard let pid = Self.peerProcessID(socketFD: socketFD) else {
            log.error("authorize: could not read peer pid")
            return nil
        }
        let peer = CodeIdentity.resolve(pid: pid, requirement: compiledRequirement)
        guard peer.status == errSecSuccess else {
            log.error("authorize: peer failed at \(peer.failedStep, privacy: .public) (pid=\(pid, privacy: .public), status=\(peer.status, privacy: .public))")
            return nil
        }
        switch peer.identifier {
        case Self.bridgeIdentifier:
            return isSupportedBrowserParent(ofBridge: pid) ? .browserBridge : nil
        case Self.mcpIdentifier:
            return .mcpClient
        default:
            log.error("authorize: rejected team-signed peer (pid=\(pid, privacy: .public), identifier=\(peer.identifier ?? "nil", privacy: .public))")
            return nil
        }
    }

    /// D25: the bridge is only trusted when a supported browser spawned it.
    /// A bridge whose browser already exited has been re-parented to launchd
    /// (PID 1) and is rejected — the browser respawns a fresh one (EC-1).
    private func isSupportedBrowserParent(ofBridge bridgePID: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(bridgePID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            log.error("authorize: rejected pf-nmh-bridge, could not read its parent pid (pid=\(bridgePID, privacy: .public), errno=\(errno, privacy: .public))")
            return false
        }
        let parentPID = pid_t(info.pbi_ppid)
        let parent = CodeIdentity.resolve(pid: parentPID, requirement: Self.browserAnchorRequirement)
        let verdict = BridgeParentPolicy.verdict(
            identifier: parent.identifier,
            teamIdentifier: parent.teamIdentifier,
            signatureStatus: parent.status
        )
        guard case .rejected(let reason) = verdict else { return true }
        log.error("authorize: rejected pf-nmh-bridge (pid=\(bridgePID, privacy: .public), parentPid=\(parentPID, privacy: .public), parentIdentifier=\(parent.identifier ?? "nil", privacy: .public), parentTeamId=\(parent.teamIdentifier ?? "nil", privacy: .public), status=\(parent.status, privacy: .public)): \(reason, privacy: .public)")
        return false
    }

    /// PID of the process on the other end of an accepted socket.
    static func peerProcessID(socketFD: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        guard result == 0, pid > 0 else { return nil }
        return pid
    }
}
