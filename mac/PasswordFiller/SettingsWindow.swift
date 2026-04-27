import SwiftUI
import AppKit
import AuthenticationServices
import Sparkle
import os.log

// Phase-4 Settings window (plan task 4.3).
//
// Four tabs bound to the same shared Config. Changes auto-persist —
// toggles / dropdowns commit immediately, text fields commit on `.onSubmit`
// (Enter) or focus loss. Every successful persist also asks the Agent to
// reload config so the TTL window takes effect in-session without a restart.
//
// Phase 5 wired `ASCredentialIdentityStore.shared.getState()` into the
// Security tab so the Safari row reflects whether the user has actually
// toggled Password Filler on in System Settings → Passwords → AutoFill —
// not just "will ship later".

private let settingsLog = Logger(subsystem: "app.passwordfiller.main", category: "settings")

// MARK: - Root view

struct SettingsView: View {
    @Bindable var client: AgentXPCClient

    @State private var draft = Config()
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveIndicator: SaveIndicator = .idle

    private let store: ConfigStore
    private let updater: SPUUpdater

    init(client: AgentXPCClient, updater: SPUUpdater, store: ConfigStore = ConfigStore()) {
        self.client = client
        self.updater = updater
        self.store = store
    }

    var body: some View {
        TabView {
            GeneralTab(draft: $draft, onChange: scheduleSave)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            OnePasswordTab(draft: $draft, onSubmit: scheduleSave)
                .tabItem { Label("1Password", systemImage: "key.fill") }
                .tag(SettingsTab.onePassword)

            SecurityTab()
                .tabItem { Label("Security", systemImage: "lock.shield") }
                .tag(SettingsTab.security)

            AboutTab(updater: updater)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: 420)
        .overlay(alignment: .bottom) {
            StatusFooter(indicator: saveIndicator, loadError: loadError, saveError: saveError)
        }
        .task {
            loadInitialConfig()
        }
    }

    // MARK: - Persistence

    private func loadInitialConfig() {
        do {
            draft = try store.load()
            loadError = nil
        } catch {
            settingsLog.error("Settings load failed: \(String(describing: error), privacy: .public)")
            loadError = String(localized: "Configuration could not be loaded: \(String(describing: error))")
        }
    }

    /// Persist the draft to disk and ask the Agent to reload. Called on every
    /// commit — toggles/pickers from `.onChange`, text fields from `.onSubmit`.
    /// Swallow-idempotent: saving identical content is a no-op for the user.
    private func scheduleSave() {
        Task { @MainActor in
            saveIndicator = .saving
            do {
                try store.save(draft)
                saveError = nil
            } catch {
                settingsLog.error("Settings save failed: \(String(describing: error), privacy: .public)")
                saveError = String(localized: "Save failed: \(String(describing: error))")
                saveIndicator = .failed
                return
            }
            let result = await client.reloadAgentConfig()
            if let result, !result.success {
                saveError = result.errorMessage ?? String(localized: "Agent reload failed")
                saveIndicator = .failed
            } else {
                saveIndicator = .saved
                // Fade the "Gespeichert"-badge back to idle after a moment so
                // the footer doesn't feel sticky.
                try? await Task.sleep(for: .seconds(2))
                if saveIndicator == .saved { saveIndicator = .idle }
            }
        }
    }
}

// MARK: - Tab enum (tag type)

private enum SettingsTab: Hashable {
    case general, onePassword, security, about
}

// MARK: - Save indicator

private enum SaveIndicator: Equatable {
    case idle, saving, saved, failed
}

private struct StatusFooter: View {
    let indicator: SaveIndicator
    let loadError: String?
    let saveError: String?

    var body: some View {
        HStack(spacing: 6) {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
            } else {
                switch indicator {
                case .idle: EmptyView()
                case .saving:
                    ProgressView().controlSize(.small)
                    Text("Saving…").font(.caption).foregroundStyle(.secondary)
                case .saved:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                case .failed: EmptyView() // saveError renders above
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

// MARK: - Tab 1: Allgemein

private struct GeneralTab: View {
    @Binding var draft: Config
    let onChange: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $draft.autoStart)
                    .onChange(of: draft.autoStart) { _, _ in onChange() }

                Toggle("Refresh on launch", isOn: $draft.autoRefreshOnStart)
                    .onChange(of: draft.autoRefreshOnStart) { _, _ in onChange() }
            } header: {
                Text("Startup")
            }

            Section {
                // Plural-variant key "%lld days" — Picker rows localize each
                // fixed count through the catalog instead of being five
                // distinct hardcoded strings.
                Picker("Keep cache for", selection: $draft.cacheTtlDays) {
                    Text("\(1) days").tag(1)
                    Text("\(3) days").tag(3)
                    Text("\(7) days").tag(7)
                    Text("\(14) days").tag(14)
                    Text("\(30) days").tag(30)
                }
                .onChange(of: draft.cacheTtlDays) { _, _ in onChange() }

                Text("Entries are removed from the cache after this period. On next access 1Password is queried again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Cache")
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40) // leave room for StatusFooter
    }
}

// MARK: - Tab 2: 1Password

private struct OnePasswordTab: View {
    @Binding var draft: Config
    let onSubmit: () -> Void

    var body: some View {
        Form {
            Section {
                TextField("1Password account", text: $draft.opAccount, prompt: Text("team.1password.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)

                Text("Shorthand from `op account list`. Changes take effect only after restarting the Agent (menu → \"Quit Password Filler\" and reopen).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Account")
            }

            Section {
                TextField("Item tag", text: $draft.opTag, prompt: Text(".htaccess"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onSubmit)

                Text("1Password items with this tag are loaded on refresh. Changes take effect on the next refresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Filter")
            }

            Section {
                Button {
                    if let url = URL(string: "onepassword://") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open 1Password", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
    }
}

// MARK: - Tab 3: Sicherheit

private struct SecurityTab: View {
    @State private var browserRows: [BrowserRow] = []
    @State private var safariState: SafariProviderState = .unknown

    var body: some View {
        Form {
            Section {
                ForEach(browserRows) { row in
                    BrowserRowView(row: row)
                }
                SafariRowView(state: safariState)
            } header: {
                Text("Browser integration")
            } footer: {
                Text("Manifests are refreshed automatically on every app start. If a browser is missing here, it has not been launched yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    let path = "x-apple.systempreferences:com.apple.Passwords-Settings.extension"
                    if let url = URL(string: path) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Safari AutoFill", systemImage: "safari")
                }

                Button {
                    let path = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
                    if let url = URL(string: path) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Login Items", systemImage: "power")
                }
            } header: {
                Text("System Settings")
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .task {
            browserRows = BrowserRow.probe()
            await refreshSafariState()
        }
        // Re-probe when the window regains focus: toggling the provider in
        // System Settings happens out-of-process, so we can't observe it
        // directly — the next time the user lands back on this tab is the
        // earliest we can refresh without polling.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refreshSafariState() }
        }
    }

    private func refreshSafariState() async {
        safariState = await SafariProviderState.probe()
    }

    private struct BrowserRowView: View {
        let row: BrowserRow
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: row.status.iconName)
                    .foregroundStyle(row.status.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.displayName)
                    Text(row.status.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private struct SafariRowView: View {
        let state: SafariProviderState
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: state.iconName)
                    .foregroundStyle(state.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Safari")
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    /// Live probe of the CredProvider state. Reflects the System Settings →
    /// Passwords → AutoFill toggle for "Password Filler" — `.isEnabled=true`
    /// means Safari will offer us as a Basic-Auth provider, `false` means the
    /// Credential Provider Extension is registered but switched off.
    private enum SafariProviderState {
        case unknown, enabled, disabled

        var iconName: String {
            switch self {
            case .unknown: return "questionmark.circle"
            case .enabled: return "checkmark.circle.fill"
            case .disabled: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .unknown: return .secondary
            case .enabled: return .green
            case .disabled: return .orange
            }
        }

        var label: String {
            switch self {
            case .unknown: return String(localized: "Checking AutoFill status…")
            case .enabled: return String(localized: "AutoFill provider enabled")
            case .disabled: return String(localized: "Enable in System Settings → Passwords → AutoFill")
            }
        }

        static func probe() async -> SafariProviderState {
            await withCheckedContinuation { cont in
                ASCredentialIdentityStore.shared.getState { state in
                    cont.resume(returning: state.isEnabled ? .enabled : .disabled)
                }
            }
        }
    }

    private struct BrowserRow: Identifiable {
        enum Status {
            case ready, manifestMissing, browserAbsent

            var iconName: String {
                switch self {
                case .ready: return "checkmark.circle.fill"
                case .manifestMissing: return "exclamationmark.triangle.fill"
                case .browserAbsent: return "minus.circle"
                }
            }

            var tint: Color {
                switch self {
                case .ready: return .green
                case .manifestMissing: return .orange
                case .browserAbsent: return .secondary
                }
            }

            var label: String {
                switch self {
                case .ready: return String(localized: "Available")
                case .manifestMissing: return String(localized: "Manifest missing — restart the app once")
                case .browserAbsent: return String(localized: "Not installed")
                }
            }
        }

        let id = UUID()
        let displayName: String
        let status: Status

        /// Probe Chrome/Chrome Beta/Brave/Vivaldi/Firefox by checking for
        /// their NMH manifest. Safari lives in its own row (`SafariRowView`)
        /// because it uses Credential Provider Extension + Safari Web
        /// Extension, not NMH.
        static func probe() -> [BrowserRow] {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

            let specs: [(String, String)] = [
                ("Google Chrome",      "Google/Chrome"),
                ("Google Chrome Beta", "Google/Chrome Beta"),
                ("Brave Browser",      "BraveSoftware/Brave-Browser"),
                ("Vivaldi",            "Vivaldi"),
                ("Firefox",            "Mozilla"),
            ]

            return specs.map { display, relative -> BrowserRow in
                let browserDir = support.appendingPathComponent(relative, isDirectory: true)
                let manifest = browserDir
                    .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
                    .appendingPathComponent("\(NMHManifestWriter.hostName).json", isDirectory: false)

                var isDir: ObjCBool = false
                let browserExists = FileManager.default.fileExists(atPath: browserDir.path, isDirectory: &isDir) && isDir.boolValue
                if !browserExists {
                    return BrowserRow(displayName: display, status: .browserAbsent)
                }
                let manifestExists = FileManager.default.fileExists(atPath: manifest.path)
                return BrowserRow(displayName: display, status: manifestExists ? .ready : .manifestMissing)
            }
        }
    }
}

// MARK: - Tab 4: Über

private struct AboutTab: View {
    let updater: SPUUpdater

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (Build \(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    // Use the actual app icon from NSWorkspace — honours the
                    // Asset Catalog AppIcon and matches what the user sees in
                    // Finder / Dock / System Settings. Fallback to the SF
                    // symbol if the lookup fails (e.g. app moved out of a
                    // valid LaunchServices location).
                    if let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) as NSImage? {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 48, height: 48)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Password Filler").font(.title2.bold())
                        Text(versionString).font(.caption).foregroundStyle(.secondary)
                        Text("© 2026 Andreas Isaak")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                Button {
                    if let url = URL(string: "https://github.com/andreasisaak/password-filler") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                Button {
                    openConsoleFiltered()
                } label: {
                    Label("Show logs", systemImage: "doc.text.magnifyingglass")
                }

                // Sparkle-backed "Check for updates" button (Phase 5 Partial-3).
                // The view's `disabled` binding follows `updater.canCheckForUpdates`
                // via the Combine publisher in `CheckForUpdatesViewModel`, so a
                // second click while a check is already running is suppressed
                // without extra state here.
                CheckForUpdatesView(updater: updater)
            } header: {
                Text("Links & diagnostics")
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
    }

    /// Open Terminal.app with a pre-filled `log show` command, so the user
    /// sees our subsystem's last 30 minutes of events in a single scroll
    /// instead of landing on Console.app's unfiltered live-stream.
    ///
    /// Implementation: write an executable `.command` script to temp and
    /// `NSWorkspace.open` it. Terminal's LaunchServices handler runs `.command`
    /// files directly. Two reasons this beats `NSAppleScript`:
    ///   1. No AppleEvent — no macOS 14 Automation-Privacy prompt.
    ///   2. Shell quoting is straightforward (the file contents are literal
    ///      bash); no double-escaping the inner `"..."` around the predicate.
    private func openConsoleFiltered() {
        settingsLog.info("User opened logs from Settings → Über")
        let command = #"log show --predicate 'subsystem BEGINSWITH "app.passwordfiller"' --info --last 30m"#
        let scriptContents = """
        #!/bin/bash
        echo "Zeige Password-Filler-Logs der letzten 30 Minuten…"
        echo "Befehl: \(command)"
        echo
        \(command)
        """
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("password-filler-logs.command")
        do {
            try scriptContents.write(to: tempURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: tempURL.path
            )
            NSWorkspace.shared.open(tempURL)
        } catch {
            settingsLog.error("Logs-Script schreiben fehlgeschlagen: \(String(describing: error), privacy: .public)")
            // Last-resort fallback: copy command, open Terminal, user pastes.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open(terminalURL)
        }
    }
}
