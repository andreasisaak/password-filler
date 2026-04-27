import Foundation
import os.log

// Entry point for the LaunchAgent-hosted `PasswordFillerAgent` CLI.
//
// Responsibilities (wired top-down):
//   1. Load Config (legacy migration handled by ConfigStore)
//   2. Build OpClient + ItemStore
//   3. Build AgentService (NSXPCListenerDelegate) and attach the Mach-Service listener
//   4. Build UnixSocketServer for pf-nmh-bridge clients
//   5. Build RevokePoller (30 min + wake) and map events to ConnectionState
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

let ttlSeconds = TimeInterval(max(1, initialConfig.cacheTtlDays) * 86_400)
// Persistent, encrypted on-disk cache. ItemStore eagerly loads the last
// snapshot from disk here so the Agent is warm on Mac-reboot — Basic-Auth
// lookups work immediately, without waiting for the user to reopen the
// 1Password desktop app for a fresh Touch-ID prompt.
let persistentCache = PersistentCache()
let store = ItemStore(ttl: ttlSeconds, persistence: persistentCache)
let opClient = OpClient(account: initialConfig.opAccount.isEmpty ? nil : initialConfig.opAccount)
let identityUpdater = IdentityStoreUpdater()

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
    identityUpdater: identityUpdater
)

// MARK: - XPC listener

let xpcListener = NSXPCListener(machServiceName: PFMachService.name)
xpcListener.delegate = agentService
xpcListener.resume()
lifecycleLog.info("XPC listener resumed on \(PFMachService.name, privacy: .public)")

// MARK: - Unix socket server

let socketServer = UnixSocketServer(service: agentService)
do {
    try socketServer.start()
} catch {
    lifecycleLog.error("UnixSocketServer failed to start: \(String(describing: error), privacy: .public)")
}

// MARK: - Connection state seed

// The RevokePoller used to drive `connectionState` from periodic `op whoami`
// polls, but `whoami` is a *passive* check (it doesn't trigger the 1Password
// Touch-ID prompt that would renew a lost CLI authorization), so it can't
// distinguish "1P Desktop locked" from "Agent's CLI trust was invalidated by
// a new build". We were misclassifying the latter as the former, showing
// "1Password gesperrt" while 1P Desktop was wide open next to the popover.
//
// Policy C (2026-04-23) dropped the automatic revocation-on-revoke path
// anyway, so the poller had no remaining responsibility. We now seed the
// connection state from what the persistent cache tells us at launch:
// if items are on disk, the Agent has already been connected successfully
// in a prior run and the cache is valid for Basic-Auth lookups — the popover
// should say "Verbunden", not "Nicht konfiguriert", until the next manual
// refresh proves otherwise.
if store.count > 0 {
    agentService.setConnectionState(.connected)
    agentService.setLastErrorMessage(nil)
}

lifecycleLog.info("Agent ready (itemCount=\(store.count, privacy: .public))")
RunLoop.main.run()
