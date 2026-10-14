import Foundation
import os.log

// Entry point for the LaunchAgent-hosted `PasswordFillerAgent` CLI.
//
// Responsibilities (wired top-down):
//   1. Load Config (legacy migration handled by ConfigStore)
//   2. Build OpClient + ItemStore
//   3. Build AgentService (NSXPCListenerDelegate) and attach the Mach-Service listener
//   4. Build UnixSocketServer for pf-nmh-bridge clients
//   5. Seed ConnectionState from the persisted cache
//   6. RunLoop.main.run() — launchd owns the process lifecycle

let lifecycleLog = Logger(subsystem: "app.passwordfiller.agent", category: "lifecycle")

let configStore = ConfigStore()
let initialConfig: Config
do {
    initialConfig = try configStore.load()
} catch {
    lifecycleLog.error("config load failed: \(String(describing: error), privacy: .public)")
    initialConfig = Config()
}

// Shared config box — the refresh pipeline reads the latest values on every
// refresh, so hot-reloading settings (from the Main-App) does not require a
// restart. The Main-App writes config.json + triggers refreshCache.
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Config
    init(_ value: Config) { self.value = value }
    func get() -> Config { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Config) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
let configBox = ConfigBox(initialConfig)

let ttlSeconds = initialConfig.effectiveCacheTtlSeconds
// Persistent, encrypted on-disk cache. ItemStore eagerly loads the last
// snapshot from disk here so the Agent is warm on Mac-reboot — Basic-Auth
// lookups work immediately, without waiting for the user to reopen the
// 1Password desktop app for a fresh Touch-ID prompt.
let persistentCache = PersistentCache()
let store = ItemStore(ttl: ttlSeconds, persistence: persistentCache)
let opClient = OpClient()
let identityUpdater = IdentityStoreUpdater()

// One trust boundary shared by both IPC entrypoints (XPC + Unix socket).
let authorizer = PeerAuthorizer()

let agentService = AgentService(
    store: store,
    opClient: opClient,
    configProvider: { configBox.get() },
    // Reload path: Main-App persists config.json via ConfigStore.save(), then
    // calls reloadConfig via XPC. We re-read from disk (source of truth), push
    // into the shared box so the next refresh pipeline sees the new opTag, and
    // return the parsed Config so AgentService can apply TTL to ItemStore.
    configReloader: {
        let fresh = try configStore.load()
        configBox.set(fresh)
        return fresh
    },
    identityUpdater: identityUpdater,
    authorizer: authorizer
)

// MARK: - XPC listener

let xpcListener = NSXPCListener(machServiceName: PFMachService.name)
xpcListener.delegate = agentService
xpcListener.resume()
lifecycleLog.info("XPC listener resumed on \(PFMachService.name, privacy: .public)")

// MARK: - Unix socket server

let socketServer = UnixSocketServer(service: agentService, authorizer: authorizer)
do {
    try socketServer.start()
} catch {
    lifecycleLog.error("UnixSocketServer failed to start: \(String(describing: error), privacy: .public)")
}

// MARK: - Connection state seed

// Items on disk mean an earlier run connected successfully and the cache
// serves Basic-Auth lookups, so the popover says "Verbunden" (not "Nicht
// konfiguriert") until the next refresh proves otherwise. Only refreshes
// change the state after that; nothing polls 1Password (CLAUDE.md §
// Credential cache, Policy C).
if store.count > 0 {
    agentService.setConnectionState(.connected)
}

lifecycleLog.info("Agent ready (itemCount=\(store.count, privacy: .public))")
RunLoop.main.run()
