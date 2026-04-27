import Foundation
import AuthenticationServices
import os.log

/// Syncs the Agent's cached hostnames to `ASCredentialIdentityStore.shared` so
/// that Safari's native Basic-Auth dialog shows "Password Filler…" as an option.
///
/// Credentials never leave the Agent — the store only holds
/// `(recordIdentifier, serviceIdentifier.domain)` pairs. The CredProvider.appex
/// then XPCs back to the Agent to fetch the actual username/password at fill time.
public final class IdentityStoreUpdater {

    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "identity-store")

    public init() {}

    /// Full diff: save identities for `hosts` not yet in the store, remove any
    /// identities whose `recordIdentifier` belongs to this app but whose host is
    /// no longer in the cache.
    public func update(hosts: Set<String>, items: [StoredItem]) throws {
        let store = ASCredentialIdentityStore.shared
        guard fetchIsEnabled(store) else {
            log.debug("CredProvider not enabled; skipping identity-store update")
            return
        }

        let newIdentities = items.flatMap { item -> [ASPasswordCredentialIdentity] in
            item.hostnames.map { host in
                let service = ASCredentialServiceIdentifier(identifier: host, type: .domain)
                return ASPasswordCredentialIdentity(
                    serviceIdentifier: service,
                    user: item.username,
                    recordIdentifier: "\(item.itemId):\(host)"
                )
            }
        }

        // Replace is idempotent and covers both add + remove paths in one call.
        // Using `replaceCredentialIdentities` avoids us having to enumerate the
        // existing store (the API does not expose a list operation).
        try await_replace(store, identities: newIdentities)
        log.info("Identity-store updated: \(newIdentities.count, privacy: .public) hosts")
    }

    // MARK: - Blocking bridges (keep call sites synchronous — the refresh pipeline
    // already runs off the XPC reply thread, and ASCredentialIdentityStore's
    // completion-handler callbacks are hostile to structured concurrency inside
    // a LaunchAgent-hosted CLI on macOS 14.)

    private func fetchIsEnabled(_ store: ASCredentialIdentityStore) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isEnabled = false
        store.getState { state in
            isEnabled = state.isEnabled
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return isEnabled
    }

    private func await_replace(
        _ store: ASCredentialIdentityStore,
        identities: [ASPasswordCredentialIdentity]
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var callError: Error?
        store.replaceCredentialIdentities(identities) { success, error in
            if !success, let error { callError = error }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        if let callError { throw callError }
    }
}
