import Foundation

/// Code identity of one running `pf-nmh-bridge` process, as resolved from
/// its PID through the Security framework (`SecCodeCopyGuestWithAttributes`).
public struct RunningBridgeIdentity: Equatable {
    public let processID: pid_t
    /// cdhash of the code the process runs, or `nil` when the lookup failed —
    /// the executable was deleted or replaced by different code on disk.
    public let cdhash: Data?
    /// `errSecSuccess` when `cdhash` is set; the failing `OSStatus` otherwise.
    public let lookupStatus: OSStatus

    public init(processID: pid_t, cdhash: Data?, lookupStatus: OSStatus) {
        self.processID = processID
        self.cdhash = cdhash
        self.lookupStatus = lookupStatus
    }
}

public enum BridgeVerdict: Equatable {
    case current
    case stale(reason: String)
}

/// D24: decides which running bridges no longer match the bridge shipped in
/// the current bundle.
///
/// Chrome, Firefox and Brave keep a Native-Messaging host alive for as long as
/// the browser runs, so an app update (Sparkle, DMG drag-drop, dev build)
/// swaps the bundle underneath the old bridge process. Once the old bundle is
/// gone, the Agent's `PeerAuthorizer` can no longer resolve that process's
/// code identity and rejects it — every lookup fails and the toolbar badge
/// stays red until the browser is restarted. The Main-App terminates those
/// bridges on launch; the browser then respawns a fresh one on its next
/// request.
public enum BridgeStaleness {

    /// A bridge is current iff its identity resolved and its cdhash equals the
    /// cdhash of the bridge on disk in the running bundle. A byte-identical
    /// copy at another path counts as current — the Agent accepts it too.
    public static func verdict(for bridge: RunningBridgeIdentity, currentCdhash: Data) -> BridgeVerdict {
        guard let cdhash = bridge.cdhash else {
            return .stale(reason: "code identity lookup failed (OSStatus \(bridge.lookupStatus))")
        }
        guard cdhash == currentCdhash else {
            return .stale(reason: "cdhash differs from bundled bridge")
        }
        return .current
    }
}
