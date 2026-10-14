import Foundation
import Security

public enum BridgeParentVerdict: Equatable {
    case allowed
    case rejected(reason: String)
}

/// D25: decides whether the parent process of a connecting `pf-nmh-bridge` is
/// a supported browser.
///
/// Without this rule any process of the user could spawn the signed bridge
/// and ask the Agent for plaintext credentials via `lookup` — the bridge
/// itself passes the Team-ID gate no matter who started it. Browsers spawn
/// the bridge directly from their main process, so the parent's signing
/// identifier and Team ID must match one entry of `SupportedBrowsers` exactly.
///
/// A hurdle, not a security boundary: a deliberately malicious same-user
/// process can fork the bridge and then `exec` a real browser binary under
/// the same PID, which this rule cannot tell apart from a genuine spawn.
///
/// The Security-framework calls live in `PeerAuthorizer`; this function only
/// judges their results so every branch is unit-testable.
public enum BridgeParentPolicy {

    /// - Parameters:
    ///   - identifier: signing identifier of the parent, `nil` when unreadable.
    ///   - teamIdentifier: Team ID of the parent, `nil` for Apple platform
    ///     binaries (launchd, shells) or when unreadable.
    ///   - signatureStatus: result of resolving the parent's code and checking
    ///     it against `anchor apple generic`.
    public static func verdict(identifier: String?, teamIdentifier: String?, signatureStatus: OSStatus) -> BridgeParentVerdict {
        guard signatureStatus == errSecSuccess else {
            return .rejected(reason: "parent signature check failed (OSStatus \(signatureStatus))")
        }
        guard let identifier else {
            return .rejected(reason: "parent has no signing identifier")
        }
        guard let teamIdentifier else {
            return .rejected(reason: "parent \(identifier) has no Team ID")
        }
        // Browsers sign with their bundle identifier as signing identifier.
        let parent = BrowserIdentity(bundleIdentifier: identifier, teamIdentifier: teamIdentifier)
        guard SupportedBrowsers.all.contains(parent) else {
            return .rejected(reason: "parent \(identifier) (Team ID \(teamIdentifier)) is not a supported browser")
        }
        return .allowed
    }
}
