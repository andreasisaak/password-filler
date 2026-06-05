import Foundation
import Security
import Darwin
import os.log

/// Single trust boundary for both of the Agent's IPC entrypoints.
///
/// Holds one code-signing requirement and enforces it on each channel with the
/// mechanism native to that channel:
///   - XPC: `NSXPCConnection.setCodeSigningRequirement` (kernel-enforced; the
///     peer is invalidated before any message is delivered).
///   - Unix socket: resolve the connected peer's `SecCode` from its PID and
///     check it against the requirement.
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

    private let requirement: String?
    private let compiledRequirement: SecRequirement?
    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "auth")

    public init(requirement: String? = PeerAuthorizer.defaultRequirement) {
        self.requirement = requirement
        guard let requirement else {
            self.compiledRequirement = nil
            return
        }
        var compiled: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        // The production requirement is a compile-time constant; a parse failure
        // is a programming error, not a runtime condition to tolerate.
        precondition(
            status == errSecSuccess && compiled != nil,
            "PeerAuthorizer: invalid requirement string (OSStatus \(status))"
        )
        self.compiledRequirement = compiled
    }

    /// XPC: kernel-enforced. No-op when the gate is disabled.
    public func gate(_ connection: NSXPCConnection) {
        guard let requirement else { return }
        connection.setCodeSigningRequirement(requirement)
    }

    /// Unix socket: returns `true` when the peer satisfies the requirement (or
    /// the gate is disabled), `false` otherwise. Fails closed on every error.
    ///
    /// Caveat: PID-based identity carries a PID-reuse window between `accept`
    /// and this check. The socket is already `chmod 0600` (same-UID only), so
    /// the residual risk is a same-user attacker racing PID reuse — narrow, but
    /// the reason XPC (which uses audit tokens) is the stronger of the two.
    public func authorize(socketFD: Int32) -> Bool {
        guard let compiledRequirement else { return true }
        guard let pid = peerProcessID(socketFD: socketFD) else {
            log.error("authorize: could not read peer pid")
            return false
        }
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            log.error("authorize: SecCodeCopyGuestWithAttributes failed (pid=\(pid, privacy: .public), status=\(copyStatus, privacy: .public))")
            return false
        }
        let checkStatus = SecCodeCheckValidity(code, [], compiledRequirement)
        guard checkStatus == errSecSuccess else {
            log.error("authorize: peer failed requirement (pid=\(pid, privacy: .public), status=\(checkStatus, privacy: .public))")
            return false
        }
        return true
    }

    private func peerProcessID(socketFD: Int32) -> pid_t? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        guard result == 0, pid > 0 else { return nil }
        return pid
    }
}
