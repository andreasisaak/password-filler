import Foundation
import os.log

/// Agent-side XPC service. Hosts the Mach-Service, handles `AgentServiceProtocol`
/// calls from the Main-App, CredProvider.appex and the Unix-Socket bridge (via
/// an in-process helper, not XPC), and coordinates cache refreshes.
public final class AgentService: NSObject, AgentServiceProtocol, NSXPCListenerDelegate {

    private let store: ItemStore
    private let opClient: OpClient
    private let configProvider: () -> Config
    private let configReloader: () throws -> Config
    private let identityUpdater: IdentityStoreUpdater?
    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "xpc")

    /// Serializes state mutation. Refresh work runs off the main queue but hits
    /// this queue for the shared-state updates.
    private let stateQueue = DispatchQueue(label: "app.passwordfiller.agent.state")

    private var _connectionState: ConnectionState = .notConfigured
    private var _lastErrorMessage: String?
    private var refreshInFlight: Task<RefreshResult, Never>?

    public init(
        store: ItemStore,
        opClient: OpClient,
        configProvider: @escaping () -> Config,
        configReloader: @escaping () throws -> Config,
        identityUpdater: IdentityStoreUpdater? = nil
    ) {
        self.store = store
        self.opClient = opClient
        self.configProvider = configProvider
        self.configReloader = configReloader
        self.identityUpdater = identityUpdater
        super.init()
    }

    // MARK: - Mutable state (stateQueue-protected)

    public func setConnectionState(_ state: ConnectionState) {
        stateQueue.sync { _connectionState = state }
    }

    public var connectionState: ConnectionState {
        stateQueue.sync { _connectionState }
    }

    /// Remembers the user-facing message from the last failed refresh so the
    /// popover can surface it even after the XPC-transient error has cleared.
    /// Pass `nil` to reset on success.
    public func setLastErrorMessage(_ message: String?) {
        stateQueue.sync { _lastErrorMessage = message }
    }

    public var lastErrorMessage: String? {
        stateQueue.sync { _lastErrorMessage }
    }

    // MARK: - AgentServiceProtocol

    public func lookupCredentials(host: String, reply: @escaping (Data?) -> Void) {
        log.debug("lookupCredentials for \(host, privacy: .private)")
        guard let match = store.lookup(hostname: host) else {
            reply(nil)
            return
        }
        let response = LookupResponse(username: match.username, password: match.password)
        reply(XPCPayload.encode(response))
    }

    public func refreshCache(reply: @escaping (Data?) -> Void) {
        Task { [weak self] in
            guard let self else { return reply(nil) }
            let result = await self.performRefresh()
            reply(XPCPayload.encode(result))
        }
    }

    public func getStatus(reply: @escaping (Data?) -> Void) {
        let status = AgentStatus(
            itemCount: store.count,
            lastRefresh: store.lastRefresh,
            ttlDays: Int(store.ttl / 86_400),
            connectionState: connectionState,
            errorMessage: lastErrorMessage
        )
        reply(XPCPayload.encode(status))
    }

    public func listItems(reply: @escaping (Data?) -> Void) {
        reply(XPCPayload.encode(store.mergedForDisplay()))
    }

    public func reloadConfig(reply: @escaping (Data?) -> Void) {
        do {
            let fresh = try configReloader()
            // Apply TTL immediately so the next `allItems` / `lookup` call
            // prunes entries under the new window. `opTag` and `opAccount`
            // propagate via `configProvider` — `opTag` reaches the next refresh
            // naturally, `opAccount` needs an Agent restart (OpClient captures
            // it at init time). Settings UI documents that caveat.
            store.ttl = TimeInterval(max(1, fresh.cacheTtlDays) * 86_400)
            log.info("Config reloaded: ttlDays=\(fresh.cacheTtlDays, privacy: .public)")
            let result = ReloadConfigResult(
                success: true,
                ttlDays: fresh.cacheTtlDays,
                errorMessage: nil
            )
            reply(XPCPayload.encode(result))
        } catch {
            let message = String(describing: error)
            log.error("reloadConfig failed: \(message, privacy: .public)")
            let result = ReloadConfigResult(
                success: false,
                ttlDays: Int(store.ttl / 86_400),
                errorMessage: message
            )
            reply(XPCPayload.encode(result))
        }
    }

    public func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    // MARK: - In-process helpers for UnixSocketServer

    /// Synchronous lookup used by the non-XPC Unix-Socket path.
    public func lookup(host: String) -> Credentials? {
        guard let item = store.lookup(hostname: host) else { return nil }
        return Credentials(username: item.username, password: item.password)
    }

    public var itemCount: Int { store.count }

    public func currentConfig() -> Config { configProvider() }

    public func displayRows() -> [DisplayRow] { store.mergedForDisplay() }

    // MARK: - NSXPCListenerDelegate

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let interface = NSXPCInterface(with: AgentServiceProtocol.self)
        newConnection.exportedInterface = interface
        newConnection.exportedObject = self
        newConnection.resume()
        log.info("XPC client connected")
        return true
    }

    // MARK: - Refresh coordinator

    /// Runs the list→get-per-item→replace pipeline. Concurrent calls share the
    /// same in-flight `Task` so a UI double-click never triggers duplicate
    /// 1Password work (and duplicate Touch-ID prompts).
    public func performRefresh() async -> RefreshResult {
        let task: Task<RefreshResult, Never> = stateQueue.sync {
            if let existing = refreshInFlight { return existing }
            let fresh = Task { [weak self] () -> RefreshResult in
                guard let self else {
                    return RefreshResult(
                        success: false, itemCount: 0, durationSeconds: 0,
                        errorMessage: "agent deallocated"
                    )
                }
                let result = await self.runRefreshPipeline()
                self.stateQueue.sync { self.refreshInFlight = nil }
                return result
            }
            refreshInFlight = fresh
            return fresh
        }
        return await task.value
    }

    private func runRefreshPipeline() async -> RefreshResult {
        let start = Date()
        let config = configProvider()

        // Update TTL from config so the next eviction uses the current setting.
        store.ttl = TimeInterval(max(1, config.cacheTtlDays) * 86_400)

        do {
            let summaries = try opClient.itemList(tag: config.opTag)
            log.info("Fetched \(summaries.count, privacy: .public) item summaries")

            // Prefilter to items that carry at least one URL — avoids kicking
            // off an `op item get` subprocess for entries we'd discard anyway.
            let withHosts: [(summary: ItemSummary, hostnames: [String])] = summaries.compactMap { summary in
                let hosts = ItemStore.extractHostnames(from: summary.urls)
                return hosts.isEmpty ? nil : (summary, hosts)
            }

            let stored = await fanOutItemGet(for: withHosts)

            store.replace(with: stored)
            setConnectionState(.connected)
            setLastErrorMessage(nil)

            let allHosts = Set(stored.flatMap(\.hostnames))
            try? identityUpdater?.update(hosts: allHosts, items: stored)

            let duration = Date().timeIntervalSince(start)
            log.info("Refresh complete: \(stored.count, privacy: .public) items in \(duration, privacy: .public)s")
            return RefreshResult(
                success: true,
                itemCount: stored.count,
                durationSeconds: duration,
                errorMessage: nil
            )
        } catch {
            let message = Self.describeError(error)
            log.error("Refresh failed: \(message, privacy: .public)")
            // Don't wipe the cache — stale data is better than nothing for
            // transient failures. `RevokePoller` handles authoritative eviction.
            if case OpClientError.processFailed = error {
                setConnectionState(.locked)
            } else {
                setConnectionState(.error)
            }
            // Persist the reason across `getStatus` polls so the popover shows
            // "Fehler beim Refresh — <why>" instead of just the bare state.
            setLastErrorMessage(message)
            return RefreshResult(
                success: false,
                itemCount: store.count,
                durationSeconds: Date().timeIntervalSince(start),
                errorMessage: message
            )
        }
    }

    /// Fans `op item get` subprocesses out with **bounded parallelism** (5 in
    /// flight). 1Password's Desktop-App-Auth layer serialises per-parent-process
    /// auth checks in `op daemon`, so 30+ simultaneous `op item get` subprocesses
    /// pile up in its queue and the later ones time out. 5 keeps the queue
    /// healthy and still gives ~6× the serial-port throughput.
    private func fanOutItemGet(
        for withHosts: [(summary: ItemSummary, hostnames: [String])]
    ) async -> [StoredItem] {
        let opClient = self.opClient
        let maxInFlight = 5
        return await withTaskGroup(of: StoredItem?.self) { group in
            var out: [StoredItem] = []
            out.reserveCapacity(withHosts.count)
            var inFlight = 0
            for (summary, hostnames) in withHosts {
                if inFlight >= maxInFlight, let maybe = await group.next() {
                    // Reap oldest result, preserve it, then queue the next.
                    if let item = maybe { out.append(item) }
                    inFlight -= 1
                }
                inFlight += 1
                group.addTask { [log] in
                    do {
                        let full = try opClient.itemGet(id: summary.id)
                        guard let creds = ItemStore.extractCredentials(from: full.fields ?? []) else {
                            return nil
                        }
                        let domains = Array(Set(hostnames.compactMap { PublicSuffixList.eTLDPlusOne(host: $0) }))
                        return StoredItem(
                            itemId: summary.id,
                            title: summary.title,
                            hostnames: hostnames,
                            domains: domains,
                            username: creds.username,
                            password: creds.password,
                            sourceVault: summary.vault?.name,
                            cachedAt: Date()
                        )
                    } catch {
                        let describe = String(describing: error)
                        let itemID = summary.id
                        log.error("itemGet failed for \(itemID, privacy: .public): \(describe, privacy: .public)")
                        return nil
                    }
                }
            }
            // Drain remaining (~maxInFlight) results.
            for await maybe in group {
                if let item = maybe { out.append(item) }
            }
            return out
        }
    }

    private static func describeError(_ error: Error) -> String {
        switch error {
        case OpClientError.binaryNotFound: return "op binary not found"
        case OpClientError.timeout(let command): return "op timeout: \(command)"
        case OpClientError.decodingFailed(let reason): return "op decode error: \(reason)"
        case OpClientError.processFailed(let stderr, let code):
            return "op exit \(code): \(stderr.prefix(120))"
        default:
            return String(describing: error)
        }
    }
}
