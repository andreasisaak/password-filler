import AuthenticationServices
import AppKit
import Security
import os.log

/// CredentialProvider extension — Safari's plug-in point for native Basic-Auth
/// autofill (`ASCredentialProviderExtensionCapabilities.ProvidesPasswords = YES`).
///
/// Flow (happy path, Basic-Auth dialog in Safari):
/// 1. User navigates to a page that responds `401 WWW-Authenticate: Basic …`
/// 2. Safari shows the system Basic-Auth dialog with "Password Filler" as one
///    of the provider options (wired because the Agent populates
///    `ASCredentialIdentityStore` on every refresh — see `IdentityStoreUpdater`).
/// 3. User clicks "Password Filler" — macOS invokes `prepareCredentialList(for: [])`
///    on *this* class. `serviceIdentifiers` is empty because Safari does not
///    pass the URL directly; we read it from the Shared Keychain entry the
///    SafariExt.appex wrote moments before on the `webNavigation` event.
/// 4. We XPC to the Agent for the matching credential and fill the dialog.
///
/// Two alternative paths are handled:
/// - `provideCredentialWithoutUserInteraction(for:)` fires when macOS already
///   knows the identity (the user previously picked "Password Filler" for this
///   host and the system dialog is recurring); we use the `serviceIdentifier`
///   from the request directly — no keychain round-trip.
/// - `prepareInterfaceToProvideCredential(for:)` is the "UI needed to finish
///   fill" path — for a password-only provider this is effectively the same
///   flow as `provideCredentialWithoutUserInteraction`.
///
/// Error surface:
/// - Agent unreachable → one retry after waking the Main-App, then graceful
///   `cancelRequest(.credentialIdentityNotFound)` so Safari falls back to the
///   system dialog's manual text fields.
/// - Keychain miss / stale entry → same graceful cancel.
/// - Agent returns `nil` (host not in cache) → same graceful cancel.
final class CredentialProviderViewController: ASCredentialProviderViewController {

    private let log = Logger(subsystem: "app.passwordfiller.credprovider", category: "ui")

    // Retry schedule for the F5 fallback. After waking the Main-App we give
    // launchd three shots at bringing the Mach-Service back up — 200 / 500 /
    // 1000 ms (total 1.7 s after the wake). A single 1 s shot turned out to
    // be flaky in live tests on 2026-04-22: the agent re-registered, but the
    // *first* XPC connection after `pkill` still invalidated before its
    // reply landed ("invalidated before reply") — a race between launchd's
    // Mach-port publish and the agent's run-loop being ready to service it.
    // Graduated retries ride over that race without extending the Safari
    // modal wait beyond what a human reads as "slight pause".
    private static let retryDelaysMs: [Int] = [200, 500, 1000]

    // MARK: - ASCredentialProviderViewController overrides

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        log.info("prepareCredentialList serviceIdentifiers.count=\(serviceIdentifiers.count, privacy: .public)")

        // When Safari triggers us via the Basic-Auth dialog the identifier list
        // is empty — we fall back to the URL SafariExt parked in the Shared
        // Keychain. When an IdentityStore-typed identity is invoked instead
        // (rare for Basic-Auth, common for form-fill), macOS passes the host
        // through `serviceIdentifiers[0]` and no keychain read is needed.
        let host: String?
        if let first = serviceIdentifiers.first {
            host = Self.extractHost(from: first.identifier)
            log.info("Using serviceIdentifier host (from identity-store path)")
        } else {
            host = readObservedHost()
        }

        guard let host, !host.isEmpty else {
            cancel(.credentialIdentityNotFound, reason: "no host available (empty identifiers + keychain miss)")
            return
        }

        lookupAndComplete(host: host, startedAt: startedAt)
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        log.info("provideCredentialWithoutUserInteraction")
        let identifier = credentialRequest.credentialIdentity.serviceIdentifier.identifier
        guard let host = Self.extractHost(from: identifier) else {
            cancel(.credentialIdentityNotFound, reason: "cannot extract host from \(identifier)")
            return
        }
        lookupAndComplete(host: host, startedAt: CFAbsoluteTimeGetCurrent())
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        // A password-only provider has no interactive UI to render — the
        // without-interaction path already does the work.
        provideCredentialWithoutUserInteraction(for: credentialRequest)
    }

    override func prepareInterfaceForExtensionConfiguration() {
        // No per-extension configuration UI. macOS requires a completion call
        // regardless, otherwise the "Configure…" button in System Settings
        // hangs.
        extensionContext.completeExtensionConfigurationRequest()
    }

    // MARK: - Lookup + completion

    private func lookupAndComplete(host: String, startedAt: CFAbsoluteTime) {
        let log = self.log
        lookupViaXPC(host: host) { [weak self] response, xpcMs, wokeAgent in
            guard let self else { return }
            let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            if let response {
                log.info("filled (xpc=\(xpcMs, privacy: .public)ms total=\(totalMs, privacy: .public)ms woke=\(wokeAgent, privacy: .public))")
                self.extensionContext.completeRequest(
                    withSelectedCredential: ASPasswordCredential(
                        user: response.username,
                        password: response.password
                    ),
                    completionHandler: nil
                )
            } else {
                self.cancel(.credentialIdentityNotFound,
                            reason: "agent returned nil for host (xpc=\(xpcMs)ms woke=\(wokeAgent))")
            }
        }
    }

    // MARK: - XPC client (with F5 fallback)

    /// Opens a short-lived XPC connection, calls `lookupCredentials`, and
    /// attempts exactly one `NSWorkspace.open` + retry if the first attempt
    /// fails to reach the Agent. Callback is invoked on an arbitrary thread —
    /// the caller hops to the main queue for `completeRequest` (the
    /// `extensionContext` methods are main-thread-safe).
    private func lookupViaXPC(
        host: String,
        completion: @escaping (LookupResponse?, Double, Bool) -> Void
    ) {
        let xpcStart = CFAbsoluteTimeGetCurrent()
        attemptLookup(host: host) { [weak self] response, didSucceed in
            guard let self else { return }
            if didSucceed {
                let elapsed = (CFAbsoluteTimeGetCurrent() - xpcStart) * 1000
                completion(response, elapsed, false)
                return
            }
            // First attempt could not reach the Agent. Wake the Main-App so
            // its `AppDelegate` re-registers the LaunchAgent via SMAppService,
            // then walk the backoff schedule.
            self.log.info("XPC unreachable — waking Main-App + backoff retry")
            self.wakeMainApp()
            self.retryWithBackoff(
                host: host,
                xpcStart: xpcStart,
                remainingDelaysMs: Self.retryDelaysMs,
                completion: completion
            )
        }
    }

    /// Iteratively retry `attemptLookup` on the given backoff schedule.
    /// Success (agent reached, regardless of whether it has a match) ends the
    /// chain. When the list is exhausted without reaching the agent, we
    /// complete with `nil` — the caller maps that to a graceful
    /// `cancelRequest(.credentialIdentityNotFound)` and Safari falls back to
    /// its system dialog.
    private func retryWithBackoff(
        host: String,
        xpcStart: CFAbsoluteTime,
        remainingDelaysMs: [Int],
        completion: @escaping (LookupResponse?, Double, Bool) -> Void
    ) {
        guard let delayMs = remainingDelaysMs.first else {
            let elapsed = (CFAbsoluteTimeGetCurrent() - xpcStart) * 1000
            self.log.error("XPC still unreachable after all retries (elapsed=\(elapsed, privacy: .public)ms)")
            completion(nil, elapsed, true)
            return
        }
        let next = Array(remainingDelaysMs.dropFirst())
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self else { return }
            self.log.info("retrying lookup after \(delayMs, privacy: .public)ms backoff")
            self.attemptLookup(host: host) { response, didSucceed in
                if didSucceed {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - xpcStart) * 1000
                    completion(response, elapsed, true)
                } else {
                    self.retryWithBackoff(
                        host: host,
                        xpcStart: xpcStart,
                        remainingDelaysMs: next,
                        completion: completion
                    )
                }
            }
        }
    }

    /// Single-shot lookup. Calls back with `didSucceed=false` when the proxy
    /// cast fails or the reply never arrives before invalidation — both
    /// signals the Agent is not reachable and the caller should retry.
    /// `didSucceed=true` with `response=nil` means we reached the Agent and it
    /// legitimately had no match for the host.
    private func attemptLookup(
        host: String,
        completion: @escaping (LookupResponse?, Bool) -> Void
    ) {
        let conn = NSXPCConnection(machServiceName: PFMachService.name, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: AgentServiceProtocol.self)

        // Guard: an XPC invalidation before the reply lands must still produce
        // exactly one callback. We use `completed` under a lock to enforce
        // once-semantics because `invalidationHandler` and the reply block can
        // race on separate dispatch queues.
        let lock = NSLock()
        var completed = false
        func finish(_ response: LookupResponse?, success: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !completed else { return }
            completed = true
            conn.invalidate()
            completion(response, success)
        }

        conn.invalidationHandler = { [log] in
            log.error("XPC invalidated before reply (agent unreachable?)")
            finish(nil, success: false)
        }
        conn.interruptionHandler = { [log] in
            log.error("XPC interrupted before reply")
            finish(nil, success: false)
        }
        conn.resume()

        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [log] err in
            log.error("remoteObjectProxy error: \(err.localizedDescription, privacy: .public)")
            finish(nil, success: false)
        }) as? AgentServiceProtocol else {
            finish(nil, success: false)
            return
        }

        proxy.lookupCredentials(host: host) { data in
            let decoded = XPCPayload.decode(LookupResponse.self, from: data)
            // A reply of any kind means we reached the Agent; `decoded == nil`
            // is a legitimate "no match" miss.
            finish(decoded, success: true)
        }
    }

    /// F5 fallback: `NSWorkspace.open` the Main-App bundle. The appex bundle
    /// lives at `PasswordFiller.app/Contents/PlugIns/CredProvider.appex`, so
    /// stripping three path components lands on the parent `.app` without
    /// hardcoding `/Applications/` (works equally for `~/Applications/` dev
    /// installs). Opening the Main-App triggers `AppDelegate
    /// .applicationDidFinishLaunching` which calls
    /// `SMAppService.agent.register()` — launchd then brings the Mach-Service
    /// back up so the retry succeeds.
    private func wakeMainApp() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns/
            .deletingLastPathComponent()   // Contents/
            .deletingLastPathComponent()   // PasswordFiller.app
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false            // don't steal focus from Safari
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [log] _, error in
            if let error {
                log.error("wakeMainApp failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("wakeMainApp launched \(appURL.lastPathComponent, privacy: .public)")
            }
        }
    }

    // MARK: - Shared Keychain read

    /// Reads the JSON payload SafariExt wrote on the last `webNavigation` event.
    /// Returns the host only if the entry exists, decodes cleanly, and is
    /// fresh enough — otherwise `nil`, which makes `prepareCredentialList`
    /// cancel with `credentialIdentityNotFound` and Safari falls back to its
    /// system dialog's manual fields.
    private func readObservedHost() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SharedHostKeychain.service,
            kSecAttrAccount: SharedHostKeychain.account,
            kSecAttrAccessGroup: SharedHostKeychain.accessGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            log.info("keychain miss: status=\(status, privacy: .public)")
            return nil
        }
        guard let payload = try? JSONDecoder().decode(SharedHostKeychain.Payload.self, from: data) else {
            log.error("keychain payload decode failed")
            return nil
        }
        guard payload.isFresh else {
            log.info("keychain payload stale: age=\(payload.age, privacy: .public)s")
            return nil
        }
        return payload.host
    }

    // MARK: - Helpers

    /// ServiceIdentifier values can be either bare hosts (`example.com`) or
    /// full URLs (`https://example.com/login`). Strip to a hostname either way
    /// so the Agent's `ItemStore.lookup(hostname:)` is fed a clean domain.
    private static func extractHost(from identifier: String) -> String? {
        if let url = URL(string: identifier), let host = url.host, !host.isEmpty {
            return host
        }
        return identifier.isEmpty ? nil : identifier
    }

    private func cancel(_ code: ASExtensionError.Code, reason: String) {
        log.info("cancel: \(reason, privacy: .public)")
        extensionContext.cancelRequest(
            withError: NSError(domain: ASExtensionErrorDomain, code: code.rawValue)
        )
    }
}
