import Foundation
import SwiftUI
import os.log

/// Observable wrapper around the Main-App's XPC connection to the Agent.
///
/// Responsibilities:
/// - Own the `NSXPCConnection` lifecycle (create lazily, recreate after
///   invalidation/interruption — the Agent can be killed and restarted by
///   launchd at any time).
/// - Bridge the callback-style `AgentServiceProtocol` calls to Swift async so
///   SwiftUI views can `await` them in a Task.
/// - Poll `getStatus` + `listItems` on a timer so the popover stays live even
///   without user interaction (cache-TTL eviction, RevokePoller clearing the
///   cache, refresh completing in the background — all visible here).
///
/// Thread-safety: all `@Observable` property mutations are funnelled through
/// `@MainActor`. XPC reply callbacks land on arbitrary threads and hop back.
@Observable
@MainActor
final class AgentXPCClient {

    // MARK: - Observable state (read by SwiftUI)

    /// Latest agent status; `nil` before the first successful poll or if the
    /// agent is unreachable.
    private(set) var status: AgentStatus?

    /// Merged-for-display rows, alphabetically sorted by title (case-insensitive).
    /// Empty until the first successful `listItems` call.
    private(set) var items: [DisplayRow] = []

    /// Audit findings for items the Agent can't autofill correctly. Refreshed
    /// alongside `items` and `status` on every `pollOnce`.
    private(set) var findings: [Finding] = []

    /// `true` while a user-triggered `triggerCacheRefresh` is in flight. The
    /// popover uses this to spin the refresh icon and disable the button.
    private(set) var isRefreshing = false

    /// Human-readable error message when the XPC round-trip fails. The popover
    /// surfaces this in the status row. Cleared on next successful poll.
    private(set) var connectionError: String?

    // MARK: - Private

    private let log = Logger(subsystem: "app.passwordfiller.main", category: "xpc")
    private var connection: NSXPCConnection?
    private var pollTask: Task<Void, Never>?

    /// Visibility-aware poll cadence (plan task 4.5). The popover calls
    /// `setPopoverVisible` on appear/disappear, which restarts the poll loop
    /// with the matching interval and fires an immediate one-shot poll so the
    /// user sees fresh data the moment the popover opens.
    private static let pollIntervalVisible: Duration = .seconds(3)
    private static let pollIntervalHidden: Duration = .seconds(30)

    /// Tracks popover visibility. Defaults to `false` — the popover is closed
    /// until the user clicks the menu-bar icon for the first time.
    private var popoverVisible = false

    // MARK: - Lifecycle

    init() {
        log.info("AgentXPCClient init")
    }

    /// Start the background polling loop. Idempotent while a task is running —
    /// a second call with a live `pollTask` is a no-op. `setPopoverVisible`
    /// cancels + nils the task before calling us again on every visibility
    /// flip, so the loop always runs with the right cadence for the current
    /// state.
    func startPolling() {
        guard pollTask == nil else { return }
        log.info("Starting poll loop (visible=\(Self.pollIntervalVisible.components.seconds, privacy: .public)s / hidden=\(Self.pollIntervalHidden.components.seconds, privacy: .public)s)")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = self?.currentPollInterval() ?? Self.pollIntervalHidden
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Called by `PopoverContentView.onAppear` / `.onDisappear` so the client
    /// can switch to the 3 s cadence while visible and 30 s when hidden. On
    /// state change we cancel the running poll task and spawn a fresh one —
    /// otherwise a mid-sleep visibility flip would be delayed by up to the
    /// previous interval (30 s worst case).
    func setPopoverVisible(_ visible: Bool) {
        guard popoverVisible != visible else { return }
        popoverVisible = visible
        log.debug("Popover visibility → \(visible, privacy: .public)")
        // Relaunch the poll loop so the new interval takes effect immediately.
        // `startPolling` is the only place we create the task — keep the
        // creation-point unique so cancellation semantics stay simple.
        pollTask?.cancel()
        pollTask = nil
        startPolling()
    }

    private func currentPollInterval() -> Duration {
        popoverVisible ? Self.pollIntervalVisible : Self.pollIntervalHidden
    }

    // No deinit: this client lives for the lifetime of the app. Its polling
    // Task captures `[weak self]` so it exits naturally; NSXPCConnection is
    // released with the property. Swift 6 strict-concurrency makes it
    // error-prone to touch `@MainActor`-isolated state from a nonisolated
    // deinit — the lifetime contract avoids the whole class of issue.

    // MARK: - Public actions (called by SwiftUI)

    /// One-shot refresh of observable state from the agent. Called by the poll
    /// loop and on popover open.
    func pollOnce() async {
        async let statusPart: () = fetchStatus()
        async let itemsPart: () = fetchItems()
        async let findingsPart: () = fetchFindings()
        _ = await (statusPart, itemsPart, findingsPart)
    }

    /// Ask the Agent to re-read `config.json` from disk and apply the new
    /// values (TTL takes effect immediately, opTag on next refresh). Called by
    /// `SettingsWindow` after persisting a change. Returns the parsed result
    /// so the UI can surface success/failure inline. Triggers a follow-up
    /// status poll so the popover reflects the new `ttlDays` right away.
    @discardableResult
    func reloadAgentConfig() async -> ReloadConfigResult? {
        let result: ReloadConfigResult?
        do {
            result = try await call { proxy, reply in
                proxy.reloadConfig(reply: reply)
            } decode: { data in
                XPCPayload.decode(ReloadConfigResult.self, from: data)
            }
        } catch {
            log.error("reloadConfig XPC error: \(String(describing: error), privacy: .public)")
            connectionError = Self.userFacingMessage(for: error)
            return nil
        }

        if let result {
            if result.success {
                log.info("Agent config reloaded: ttlDays=\(result.ttlDays, privacy: .public)")
                connectionError = nil
            } else {
                log.error("Agent reloadConfig failed: \(result.errorMessage ?? "unknown", privacy: .public)")
                connectionError = result.errorMessage
            }
        }

        await pollOnce()
        return result
    }

    /// User pressed the "Refresh"-button in the popover — kick off a cache
    /// refresh on the agent, then re-poll status+items when it returns.
    func triggerCacheRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result: RefreshResult?
        do {
            result = try await call { proxy, reply in
                proxy.refreshCache(reply: reply)
            } decode: { data in
                XPCPayload.decode(RefreshResult.self, from: data)
            }
        } catch {
            log.error("refreshCache XPC error: \(String(describing: error), privacy: .public)")
            connectionError = Self.userFacingMessage(for: error)
            return
        }

        if let result {
            if result.success {
                log.info("Cache refresh complete: \(result.itemCount, privacy: .public) items in \(result.durationSeconds, privacy: .public)s")
                connectionError = nil
            } else {
                log.error("Cache refresh reported failure: \(result.errorMessage ?? "unknown", privacy: .public)")
                connectionError = result.errorMessage
            }
        }

        await pollOnce()
    }

    /// Called once on scene mount. If the user enabled `autoRefreshOnStart`
    /// in Settings *and* the Agent's cache is empty (fresh boot / Agent
    /// respawn), trigger a refresh automatically so the popover shows live
    /// data without the user having to click "Aktualisieren" manually. If
    /// the Agent already has items cached, we leave it alone — the Touch-ID
    /// prompt is unwelcome when the cache is still warm.
    func autoRefreshIfConfigured() async {
        // Wait for the first status poll so `status.itemCount` is populated
        // — otherwise we could race against an in-flight cache that would
        // come through a millisecond later.
        await pollOnce()

        let config: Config
        do {
            config = try ConfigStore().load()
        } catch {
            log.debug("autoRefresh: skipped (config load failed: \(String(describing: error), privacy: .public))")
            return
        }

        guard config.autoRefreshOnStart else {
            log.debug("autoRefresh: disabled in config")
            return
        }

        let cachedCount = status?.itemCount ?? 0
        guard cachedCount == 0 else {
            log.info("autoRefresh: skipped, cache has \(cachedCount, privacy: .public) items")
            return
        }

        log.info("autoRefresh: triggering (cache empty + autoRefreshOnStart=true)")
        await triggerCacheRefresh()
    }

    // MARK: - Internal fetchers

    private func fetchStatus() async {
        do {
            let fresh = try await call { proxy, reply in
                proxy.getStatus(reply: reply)
            } decode: { data in
                XPCPayload.decode(AgentStatus.self, from: data)
            }
            status = fresh
            connectionError = nil
        } catch {
            log.debug("getStatus XPC error: \(String(describing: error), privacy: .public)")
            connectionError = Self.userFacingMessage(for: error)
        }
    }

    private func fetchItems() async {
        do {
            let fresh: [DisplayRow]? = try await call { proxy, reply in
                proxy.listItems(reply: reply)
            } decode: { data in
                XPCPayload.decode([DisplayRow].self, from: data)
            }
            let rows = fresh ?? []
            items = rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            log.error("listItems XPC error: \(String(describing: error), privacy: .public)")
            // Leave existing `items` intact — a transient XPC failure during
            // poll shouldn't blank the UI.
        }
    }

    private func fetchFindings() async {
        do {
            let fresh: [Finding]? = try await call { proxy, reply in
                proxy.getAuditFindings(reply: reply)
            } decode: { data in
                XPCPayload.decode([Finding].self, from: data)
            }
            findings = (fresh ?? []).sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } catch {
            log.error("getAuditFindings XPC error: \(String(describing: error), privacy: .public)")
            // Same policy as `fetchItems`: leave the last good list in place.
        }
    }

    // MARK: - XPC plumbing

    /// Generic callback-to-async bridge for `AgentServiceProtocol` methods that
    /// reply with `Data?`. Throws `XPCClientError` on connection failure or
    /// proxy-cast failure.
    private func call<T>(
        _ invoke: (AgentServiceProtocol, @escaping (Data?) -> Void) -> Void,
        decode: @escaping (Data?) -> T?
    ) async throws -> T? {
        let proxy = try activeProxy()
        return await withCheckedContinuation { continuation in
            invoke(proxy) { data in
                continuation.resume(returning: decode(data))
            }
        }
    }

    private func activeProxy() throws -> AgentServiceProtocol {
        let conn = existingOrNewConnection()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] err in
            self?.log.error("XPC proxy error: \(String(describing: err), privacy: .public)")
        }) as? AgentServiceProtocol else {
            throw XPCClientError.proxyCastFailed
        }
        return proxy
    }

    private func existingOrNewConnection() -> NSXPCConnection {
        if let conn = connection { return conn }
        let conn = NSXPCConnection(machServiceName: PFMachService.name, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: AgentServiceProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.log.info("XPC connection invalidated — will reconnect on next call")
                self?.connection = nil
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.log.info("XPC connection interrupted")
                // Don't drop the connection — macOS will reestablish it for us.
            }
        }
        conn.resume()
        connection = conn
        log.info("XPC connection opened to \(PFMachService.name, privacy: .public)")
        return conn
    }

    // MARK: - Error translation

    private static func userFacingMessage(for error: Error) -> String {
        if let xpcError = error as? XPCClientError {
            return xpcError.message
        }
        return (error as NSError).localizedDescription
    }
}

/// Errors surfaced by `AgentXPCClient` to the UI layer.
enum XPCClientError: Error {
    case proxyCastFailed

    var message: String {
        switch self {
        case .proxyCastFailed:
            return "Agent-XPC-Proxy nicht erreichbar"
        }
    }
}
