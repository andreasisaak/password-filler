import SwiftUI
import ServiceManagement
import Sparkle
import os.log

// Phase-4 Main-App shell: menu-bar-only SwiftUI app (`LSUIElement=true`) that
// exposes a popover UI driven by `AgentXPCClient` — the reactive bridge to
// the Agent's XPC Mach-Service.
//
// Settings window, onboarding wizard, icon state machine, and i18n via
// Xcode String Catalogs are deferred to the follow-up Phase-4 session (plan
// tasks 4.3, 4.4, 4.5, 4.7). The live path this session proves end-to-end:
//   menu-bar click → MenuBarExtra opens → PopoverContentView.task → polls
//   AgentXPCClient → XPC round-trip → AgentService.getStatus + listItems →
//   UI renders real item count + merged rows.

private let lifecycleLog = Logger(subsystem: "app.passwordfiller.main", category: "lifecycle")

@main
struct PasswordFillerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// Single source of truth for the popover UI. Owned by the App struct so
    /// its lifetime tracks the process; started once in `.task` on the scene.
    @State private var xpcClient = AgentXPCClient()

    /// Sparkle updater controller (Phase 5 Partial-3). Initialised in `init()`
    /// so the scheduled-check timer starts at process launch — not lazily on
    /// first Settings open. `startingUpdater: true` makes Sparkle read
    /// `SUEnableAutomaticChecks` + `SUScheduledCheckInterval` from Info.plist
    /// and kick off the background cadence.
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView(client: xpcClient)
        } label: {
            // The label is rendered immediately on app launch (unlike the
            // popover content, which is lazy until the user clicks the
            // menu-bar icon). Attach lifecycle `.task` here so polling and
            // autoRefresh kick off at actual launch time.
            MenuBarIconView(client: xpcClient)
                .task {
                    xpcClient.startPolling()
                    await xpcClient.autoRefreshIfConfigured()
                }
        }
        .menuBarExtraStyle(.window)

        // Settings scene — lets us use the standard ⌘, shortcut and the
        // `.openSettings` Environment action from the popover footer.
        // `LSUIElement=true` apps don't have a menu bar so there is no
        // "App > Preferences…" menu; the popover is the only entry point.
        Settings {
            SettingsView(client: xpcClient, updater: updaterController.updater)
        }
    }
}

/// Menu-bar icon that reflects the live agent state.
///
/// Rendering notes:
/// - macOS renders menu-bar icons as templates by default (monochrome). We keep
///   that convention — no `foregroundStyle` — and rely on distinct SF-Symbols
///   per state so the icon stays legible in both light and dark menu bars.
/// - `.symbolEffect(.pulse, isActive:)` animates during a refresh. The effect
///   is additive to whichever base symbol is currently shown.
/// - We intentionally use `Image(systemName:)` inside the label closure rather
///   than a wrapped `Text`/`Label` — some SwiftUI builds render non-Image label
///   content as plain text in the menu bar.
private struct MenuBarIconView: View {
    @Bindable var client: AgentXPCClient

    var body: some View {
        Image(systemName: iconName)
            .symbolEffect(.pulse, isActive: client.isRefreshing)
            .accessibilityLabel(accessibilityLabel)
    }

    /// Maps the live connection state (plus the transient XPC-connection error
    /// surfaced by `AgentXPCClient`) to a distinct SF-Symbol. Keep in sync with
    /// `StatusRow.iconName` in `PopoverContentView` — the popover header and
    /// the menu-bar icon should agree on the state at any moment.
    private var iconName: String {
        if client.connectionError != nil { return "lock.trianglebadge.exclamationmark" }
        guard let state = client.status?.connectionState else { return "lock.fill" }
        switch state {
        case .connected:     return "lock.fill"
        case .locked:        return "lock.slash.fill"
        case .revoked:       return "lock.trianglebadge.exclamationmark"
        case .notConfigured: return "lock.open"
        case .error:         return "lock.trianglebadge.exclamationmark"
        }
    }

    private var accessibilityLabel: String {
        // Short-label helper: assembles "Password Filler — <state>" from the
        // state-specific suffix. Uses `String(localized:)` (not SwiftUI's
        // auto-localizing `Text`) because accessibilityLabel takes a plain
        // String — we pre-resolve the key → locale via the catalog here.
        if client.connectionError != nil {
            return String(localized: "Password Filler — \(String(localized: "Agent unreachable"))")
        }
        guard let state = client.status?.connectionState else {
            return String(localized: "Password Filler — \(String(localized: "Connecting…"))")
        }
        switch state {
        case .connected:
            // Plural-variant key: "Password Filler — connected, %lld items".
            let count = client.status?.itemCount ?? 0
            return String(localized: "Password Filler — connected, \(count) items")
        case .locked:
            return String(localized: "Password Filler — \(String(localized: "1Password locked"))")
        case .revoked:
            return String(localized: "Password Filler — \(String(localized: "1Password access revoked"))")
        case .notConfigured:
            return String(localized: "Password Filler — \(String(localized: "Not configured"))")
        case .error:
            return String(localized: "Password Filler — \(String(localized: "Error during refresh"))")
        }
    }
}

/// Owns the non-UI app lifecycle: LaunchAgent registration, NMH-manifest
/// repair on every launch (D18 path-repair), and the one-shot XPC ping that
/// nudges launchd to start the Agent on-demand so its Unix-Socket server is
/// ready by the time the first browser request arrives.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        registerLaunchAgent()
        NMHManifestWriter.write(bridgePath: NMHManifestWriter.currentBridgePath())
        pingAgent()
        // Present the first-launch wizard iff `config.json` is missing. Kept
        // last so the other lifecycle work always runs — if the wizard never
        // opens (config exists) the menu-bar UI comes up normally. The
        // `Task { @MainActor }` hop defers the window-open by one runloop
        // tick so MenuBarExtra has finished mounting first — otherwise the
        // activation flag can steal focus from the menu-bar attachment.
        Task { @MainActor in
            OnboardingWindowController.showIfNeeded()
        }
    }

    private func pingAgent(remainingAttempts: Int = 3) {
        let connection = NSXPCConnection(machServiceName: PFMachService.name, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: AgentServiceProtocol.self)
        connection.invalidationHandler = { [remainingAttempts] in
            if remainingAttempts > 1 {
                lifecycleLog.info("XPC ping invalidated, \(remainingAttempts - 1, privacy: .public) retries left")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.pingAgent(remainingAttempts: remainingAttempts - 1)
                }
            } else {
                lifecycleLog.error("XPC ping exhausted retries")
            }
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ err in
            lifecycleLog.error("XPC ping error: \(String(describing: err), privacy: .public)")
        }) as? AgentServiceProtocol else {
            lifecycleLog.error("XPC proxy cast failed")
            return
        }

        proxy.ping { ok in
            lifecycleLog.info("XPC ping reply: \(ok, privacy: .public)")
        }
    }

    private func registerLaunchAgent() {
        // D5: Translocation-Guard. Bundle.main.bundlePath muss unter /Applications/
        // oder ~/Applications/ liegen, sonst ist's ein AppTranslocation-/DerivedData-
        // Pfad, der beim nächsten Login verschwindet.
        let bundlePath = Bundle.main.bundlePath
        let userAppsPath = ("~/Applications" as NSString).expandingTildeInPath
        let isValidLocation = bundlePath.hasPrefix("/Applications/")
            || bundlePath.hasPrefix(userAppsPath + "/")
        guard isValidLocation else {
            lifecycleLog.error("App must live in /Applications or ~/Applications (current: \(bundlePath, privacy: .public)) — skipping LaunchAgent registration")
            // D5 cont.: User-sichtbarer Alert, da LaunchAgent sonst stumm nicht funktioniert.
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = String(localized: "Move Password Filler to Applications")
                alert.informativeText = String(localized: "Please move Password Filler to your Applications folder and relaunch.")
                alert.alertStyle = .warning
                alert.runModal()
                NSApp.terminate(nil)
            }
            return
        }

        // D7: Einmalige SMAppService-Cleanup-Migration.
        migrateFromSMAppServiceIfNeeded()

        let uid = getuid()
        let label = "app.passwordfiller.agent"
        let plistURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let programPath = bundlePath
            + "/Contents/Resources/PasswordFillerAgent.app/Contents/MacOS/PasswordFillerAgent"

        // D9: LimitLoadToSessionType=Aqua → nur im GUI-Login-Kontext laden.
        // D10: ProcessType=Interactive → keine QoS-Throttling.
        let plist: [String: Any] = [
            "Label": label,
            "Program": programPath,
            "ProgramArguments": [programPath],
            "MachServices": ["group.A5278RL7RX.app.passwordfiller.agent": true],
            "AssociatedBundleIdentifiers": ["app.passwordfiller", "app.passwordfiller.agent"],
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "RunAtLoad": false,
            "KeepAlive": false,
        ]

        guard let newData = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else {
            lifecycleLog.error("LaunchAgent plist serialization failed")
            return
        }

        let existingData = try? Data(contentsOf: plistURL)
        let plistUnchanged = existingData == newData

        if !plistUnchanged {
            // D12: bootout rc-Klassifikation.
            let bootoutRc = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
            switch bootoutRc {
            case 0:
                lifecycleLog.info("Previous LaunchAgent booted out")
            case 3, 113:
                break  // expected on fresh install / first run
            case 36:
                // EAGAIN — einmal retry
                Thread.sleep(forTimeInterval: 0.1)
                _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
            case 125:
                lifecycleLog.error("launchctl bootout rc=125 (permission denied) — proceeding, but this may indicate a deeper issue")
            default:
                lifecycleLog.error("launchctl bootout unexpected rc=\(bootoutRc, privacy: .public)")
            }

            try? FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            do {
                try newData.write(to: plistURL, options: .atomic)
            } catch {
                lifecycleLog.error("LaunchAgent plist write failed: \(String(describing: error), privacy: .public)")
                return
            }

            let bootstrapRc = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            if bootstrapRc == 0 {
                lifecycleLog.info("LaunchAgent bootstrapped successfully")
            } else {
                lifecycleLog.error("launchctl bootstrap rc=\(bootstrapRc, privacy: .public)")
                return
            }
        } else {
            lifecycleLog.info("LaunchAgent plist unchanged; skipping bootstrap")
        }

        // D6: Sparkle-Kickstart nach Version-Bump.
        kickstartIfVersionChanged(uid: uid, label: label)
    }

    // MARK: - D6 Sparkle-Kickstart

    private static let bootstrappedVersionKey = "PFAgentBootstrappedVersion"

    private func kickstartIfVersionChanged(uid: uid_t, label: String) {
        let currentVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let previous = UserDefaults.standard.string(forKey: Self.bootstrappedVersionKey)
        guard previous != currentVersion else { return }

        lifecycleLog.info("Agent version changed \(previous ?? "nil", privacy: .public) → \(currentVersion, privacy: .public) — kickstart -k")
        let rc = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(label)"])
        if rc == 0 {
            UserDefaults.standard.set(currentVersion, forKey: Self.bootstrappedVersionKey)
        } else {
            lifecycleLog.error("launchctl kickstart -k rc=\(rc, privacy: .public)")
        }
    }

    // MARK: - D7 SMAppService Migration

    private static let migratedFromSMAppServiceKey = "PFMigratedFromSMAppService_v2"

    private func migrateFromSMAppServiceIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.migratedFromSMAppServiceKey) else { return }

        let service = SMAppService.agent(plistName: "app.passwordfiller.agent.plist")
        do {
            try service.unregister()
            lifecycleLog.info("SMAppService cleanup: legacy agent unregistered")
        } catch {
            // Erwartet auf Fresh-Installs (status=.notFound) oder in dev-builds.
            lifecycleLog.info("SMAppService cleanup: unregister skipped (\(String(describing: error), privacy: .public))")
        }
        UserDefaults.standard.set(true, forKey: Self.migratedFromSMAppServiceKey)
    }

    // MARK: - D8 launchctl Runner (no Pipe deadlocks)

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        // D8: /dev/null statt Pipe() → kein 64-KB-Buffer-Deadlock.
        if let devNull = FileHandle(forWritingAtPath: "/dev/null") {
            p.standardOutput = devNull
            p.standardError = devNull
        }
        do { try p.run() } catch {
            lifecycleLog.error("launchctl spawn failed: \(String(describing: error), privacy: .public)")
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
