import SwiftUI
import AppKit
import os.log

// Phase-4 onboarding wizard (plan task 4.4).
//
// Five steps: Welcome → Preflight → Config-Entry → First-Refresh → Finish.
// Shown on launch when either `~/Library/Application Support/passwordfiller/
// config.json` is missing OR the wizard has never run to a successful first
// refresh (UserDefaults flag `PFOnboardingCompleted`). The split is
// deliberate: `config.json` has to be written before the First-Refresh step
// because the Agent reads it at XPC reload; if the refresh then fails (op
// not installed, 1P locked, SMAppService hiccup, …) the config stays on
// disk so the Agent boots normally on the next launch — but the user has
// not actually completed setup, so we must re-present the wizard. The flag
// tracks that completion separately from the on-disk config.
//
// Ownership: AppDelegate calls `OnboardingWindowController.showIfNeeded()`
// at end of `applicationDidFinishLaunching`. The controller retains itself
// via `strongRef` for the window's lifetime and releases on close.
//
// Intentionally hardcoded German for this slice — i18n via Xcode String
// Catalogs is plan task 4.7 and will sweep popover + settings + onboarding
// in one pass once the onboarding copy is final.

private let onboardingLog = Logger(subsystem: "app.passwordfiller.main", category: "onboarding")

// MARK: - Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// Keeps the controller alive while the window is visible. Without this the
    /// `AppDelegate` callsite would drop the only reference immediately after
    /// `showIfNeeded()` returns, and the window would deallocate mid-render.
    private var strongRef: OnboardingWindowController?

    /// UserDefaults key recording that the wizard has run all the way through
    /// a successful first refresh. Missing or `false` → wizard should re-open.
    static let completedDefaultsKey = "PFOnboardingCompleted"

    /// Presents the wizard iff setup has not completed yet. Returns the
    /// controller so the caller can optionally hold a reference; the
    /// controller retains itself internally, so discarding is safe.
    ///
    /// Two independent conditions trigger the wizard:
    ///   1. `config.json` missing  (fresh install, nothing to read)
    ///   2. `PFOnboardingCompleted` false/missing  (wizard interrupted mid-run)
    /// Either condition alone is sufficient to re-present. Both are cleared
    /// only by completing the First-Refresh step end-to-end.
    @MainActor
    @discardableResult
    static func showIfNeeded() -> OnboardingWindowController? {
        let configPath = ConfigStore.defaultURL.path
        let configExists = FileManager.default.fileExists(atPath: configPath)
        let completed = UserDefaults.standard.bool(forKey: completedDefaultsKey)

        if configExists && completed {
            onboardingLog.info("Setup complete — skipping onboarding")
            return nil
        }
        if !configExists {
            onboardingLog.info("Config missing at \(configPath, privacy: .public) — presenting onboarding wizard")
        } else {
            onboardingLog.info("Config present but PFOnboardingCompleted flag unset — presenting onboarding wizard")
        }
        let controller = OnboardingWindowController()
        controller.present()
        return controller
    }

    func present() {
        strongRef = self

        let rootView = OnboardingRootView(onFinish: { [weak self] in
            self?.finish()
        })
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "Welcome to Password Filler")
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Accessory apps (`LSUIElement=true`) have no activation policy window,
        // so `makeKeyAndOrderFront` alone puts the window behind the frontmost
        // regular app. Activating explicitly matches the `openSettings` dance
        // in `PopoverContentView.FooterRow`.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Called by the Finish step's "Fertig"-button. Releases the window; the
    /// delegate callback handles the strongRef cleanup so both the close-box
    /// path and the finish-button path converge on the same teardown.
    private func finish() {
        onboardingLog.info("Onboarding finished — closing window")
        window?.close()
    }

    // MARK: NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        // Schedule cleanup on the main actor without capturing `self`
        // across the nonisolated boundary — we only need to clear the
        // strong reference + nil the window property so ARC can reclaim
        // the controller once the current runloop tick completes.
        Task { @MainActor [weak self] in
            self?.strongRef = nil
            self?.window = nil
        }
    }
}

// MARK: - Step enum

private enum OnboardingStep: Int, CaseIterable {
    case welcome, preflight, config, firstRefresh, finish
}

// MARK: - Shared state

/// Communicates the state of the Step-4 refresh between the step view and the
/// nav bar (which gates "Weiter" on success). Lifted into the root view so
/// navigating away and back doesn't reset the result.
private enum FirstRefreshState: Equatable {
    case pending
    case running
    case success(count: Int)
    case failure(String)
}

// MARK: - Root view

private struct OnboardingRootView: View {
    let onFinish: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var draft = Config()
    @State private var firstRefreshState: FirstRefreshState = .pending

    /// Shared XPC client across the wizard. Step 4 is the only caller, but
    /// keeping the client in the root view means repeatedly visiting Step 4
    /// doesn't open a new NSXPCConnection each time.
    @State private var client = AgentXPCClient()

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch step {
                case .welcome:       WelcomeStep()
                case .preflight:     PreflightStep()
                case .config:        ConfigStep(draft: $draft)
                case .firstRefresh:  FirstRefreshStep(draft: draft, state: $firstRefreshState, client: client)
                case .finish:        FinishStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)

            Divider()

            NavBar(
                step: $step,
                draft: draft,
                firstRefreshState: firstRefreshState,
                onFinish: onFinish
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { stepCase in
                Circle()
                    .fill(stepCase.rawValue <= current.rawValue
                          ? Color.accentColor
                          : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Password Filler").font(.title.bold())
                    Text("Basic Auth login from 1Password")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Password Filler auto-fills HTTP Basic Auth dialogs in Chrome, Firefox, Brave and Safari with entries from your 1Password vault. The setup assistant walks you through the initial configuration in a few steps.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Prerequisites:").font(.body.bold())
                BulletLine(text: String(localized: "The 1Password Desktop app must be installed and running."))
                BulletLine(text: String(localized: "The 1Password CLI (op) is installed (e.g. via Homebrew)."))
                BulletLine(text: String(localized: "At least one 1Password entry has a shared tag — default: .htaccess."))
            }
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
    }
}

private struct BulletLine: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2: Preflight

private enum PreflightStatus: Equatable {
    case checking
    case ok
    case warn(String)
}

private struct PreflightRowModel {
    var onePassword: PreflightStatus = .checking
    var opBinary: PreflightStatus = .checking
    var opPath: String?
}

private struct PreflightStep: View {
    @State private var model = PreflightRowModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("System check").font(.title2.bold())
            Text("We'll quickly check all components. You can install anything missing and re-run the check.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                PreflightRow(
                    title: String(localized: "1Password Desktop app is running"),
                    detail: String(localized: "The 1Password Desktop app must be running so op can authenticate via Touch ID."),
                    status: model.onePassword
                )
                PreflightRow(
                    title: String(localized: "1Password CLI (op) available"),
                    detail: model.opPath.map { String(localized: "Found at \($0)") }
                        ?? String(localized: "Install op via brew install 1password-cli or from 1password.com."),
                    status: model.opBinary
                )
            }
            .padding(.leading, 4)

            Spacer(minLength: 0)

            HStack {
                Button {
                    Task { await runChecks() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .task {
            await runChecks()
        }
    }

    private func runChecks() async {
        model.onePassword = .checking
        model.opBinary = .checking
        model.opPath = nil

        if PreflightProbe.isOnePasswordRunning() {
            model.onePassword = .ok
        } else {
            model.onePassword = .warn(String(localized: "The 1Password Desktop app is not running. Start it and click \u{201E}Check again\u{201C}."))
        }

        if let path = PreflightProbe.resolveOpBinary() {
            model.opPath = path
            model.opBinary = .ok
        } else {
            model.opBinary = .warn(String(localized: "op could not be found in any of the known paths. Install it and try again."))
        }
    }
}

private struct PreflightRow: View {
    let title: String
    let detail: String
    let status: PreflightStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private var iconName: String {
        switch status {
        case .checking: return "clock"
        case .ok:       return "checkmark.circle.fill"
        case .warn:     return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .checking: return .secondary
        case .ok:       return .green
        case .warn:     return .orange
        }
    }

    private var detailText: String {
        if case .warn(let message) = status { return message }
        return detail
    }
}

// MARK: - Preflight probe helpers

/// Read-only system probes used during onboarding. Reuses `OpClient`'s path
/// resolver so the "found"-result matches what the Agent will pick on first
/// refresh — otherwise we'd risk showing green here while the Agent fails.
private enum PreflightProbe {
    static func isOnePasswordRunning() -> Bool {
        let bundleIDs = [
            "com.1password.1password",
            "com.1password.1password-launcher",
            "com.agilebits.onepassword7",
        ]
        return bundleIDs.contains { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    static func resolveOpBinary() -> String? {
        (try? OpClient().resolveOpPath())
    }

    /// Invokes `op account list --format json` to pre-fill the Step-3 account
    /// picker. Fails silently on any error — this is a convenience, not a gate.
    ///
    /// Runs on a detached task because `Process.waitUntilExit` blocks. The
    /// stdout payload is tiny (a handful of JSON objects), so a post-exit
    /// `readDataToEndOfFile` is safe — the 64 KB pipe-buffer deadlock noted
    /// in `OpClient` only matters for large outputs.
    static func listOpAccounts() async -> [String] {
        guard let opPath = resolveOpBinary() else { return [] }
        return await Task.detached(priority: .utility) { () -> [String] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: opPath)
            proc.arguments = ["account", "list", "--format", "json"]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    onboardingLog.debug("op account list exited \(proc.terminationStatus, privacy: .public)")
                    return []
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                struct Account: Decodable { let shorthand: String }
                let accounts = try JSONDecoder().decode([Account].self, from: data)
                let shorthands = accounts.map(\.shorthand).filter { !$0.isEmpty }
                onboardingLog.info("op account list returned \(shorthands.count, privacy: .public) accounts")
                return shorthands
            } catch {
                onboardingLog.debug("op account list failed: \(String(describing: error), privacy: .public)")
                return []
            }
        }.value
    }
}

// MARK: - Step 3: Config-Entry

private struct ConfigStep: View {
    @Binding var draft: Config

    @State private var accountSuggestions: [String] = []
    @State private var loadingAccounts = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1Password connection").font(.title2.bold())
            Text("Select your 1Password account and the tag used to mark relevant entries.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            accountSection

            tagSection

            Spacer(minLength: 0)
        }
        .task {
            loadingAccounts = true
            let found = await PreflightProbe.listOpAccounts()
            accountSuggestions = found
            if draft.opAccount.isEmpty, let first = found.first {
                draft.opAccount = first
            }
            loadingAccounts = false
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1Password account").font(.caption).foregroundStyle(.secondary)

            if loadingAccounts {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for accounts…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if accountSuggestions.count > 1 {
                // Multiple accounts: offer a picker as the primary affordance
                // and keep the text field as an override for manual entry.
                Picker("", selection: $draft.opAccount) {
                    ForEach(accountSuggestions, id: \.self) { shorthand in
                        // Pre-set identifier strings from `op account list` —
                        // not translatable content, wrap so the compiler takes
                        // them as plain Strings (not LocalizedStringKey).
                        Text(verbatim: shorthand).tag(shorthand)
                    }
                    if !accountSuggestions.contains(draft.opAccount) && !draft.opAccount.isEmpty {
                        Text("Custom: \(draft.opAccount)").tag(draft.opAccount)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // TextField placeholder — hostname-like literal, not translated.
            TextField(text: $draft.opAccount, prompt: Text(verbatim: "team.1password.com")) {
                Text("1Password account")
            }
            .textFieldStyle(.roundedBorder)

            Text("Shorthand from op account list — e.g. team or firma.1password.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Item tag").font(.caption).foregroundStyle(.secondary)
            TextField(text: $draft.opTag, prompt: Text(verbatim: ".htaccess")) {
                Text("Item tag")
            }
            .textFieldStyle(.roundedBorder)
            Text("All 1Password items with this tag are loaded on refresh. Default is .htaccess.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 4: First refresh

private struct FirstRefreshStep: View {
    let draft: Config
    @Binding var state: FirstRefreshState
    let client: AgentXPCClient

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("First refresh").font(.title2.bold())
            Text("Password Filler is now loading all marked entries from 1Password. On first access a Touch-ID prompt appears — please confirm.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            resultView

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch state {
        case .pending:
            Button {
                Task { await runRefresh() }
            } label: {
                Label("Start lookup", systemImage: "key.fill")
                    .font(.body.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

        case .running:
            HStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Waiting for 1Password — please confirm the Touch ID prompt…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

        case .success(let count):
            StatusBox(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: String(localized: "Lookup successful"),
                // Plural-variant key "%lld entries loaded from 1Password."
                detail: String(localized: "\(count) entries loaded from 1Password.")
            )

        case .failure(let message):
            VStack(alignment: .leading, spacing: 10) {
                StatusBox(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: String(localized: "Lookup failed"),
                    detail: message
                )
                Button {
                    Task { await runRefresh() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Persists the draft to disk, asks the Agent to reload (so the new
    /// `opAccount` + `opTag` take effect immediately), then kicks off a cache
    /// refresh. The Agent's internal `OpClient.account` is `let` — account
    /// changes actually need an Agent restart — but for first-time setup the
    /// Agent will boot fresh after launchd spawns it on demand, so a reload
    /// is fine here.
    private func runRefresh() async {
        state = .running
        onboardingLog.info("Onboarding: saving config + triggering first refresh")

        do {
            try ConfigStore().save(draft)
        } catch {
            onboardingLog.error("Onboarding: config save failed: \(String(describing: error), privacy: .public)")
            state = .failure(String(localized: "Configuration could not be saved: \(error.localizedDescription)"))
            return
        }

        if let reload = await client.reloadAgentConfig(), !reload.success {
            state = .failure(reload.errorMessage ?? String(localized: "Agent could not apply the new configuration."))
            return
        }

        await client.triggerCacheRefresh()

        if let xpcError = client.connectionError {
            state = .failure(xpcError)
            return
        }
        guard let status = client.status else {
            state = .failure(String(localized: "No answer from the agent. Open System Settings → Login Items and verify Password Filler is enabled."))
            return
        }
        if status.connectionState != .connected, let errorMessage = status.errorMessage {
            state = .failure(errorMessage)
            return
        }
        // Only now mark onboarding as completed. An earlier persist (right
        // after writeConfig) would mis-classify the wizard as "done" if the
        // user quits while refresh is still in flight; `PFOnboardingCompleted`
        // must flip strictly after a verified connected status.
        UserDefaults.standard.set(true, forKey: OnboardingWindowController.completedDefaultsKey)
        onboardingLog.info("Onboarding: first refresh succeeded, completion flag set")
        state = .success(count: status.itemCount)
    }
}

private struct StatusBox: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Step 5: Finish

private struct FinishStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All set").font(.title2.bold())
                    Text("Password Filler is now running in the background.")
                        .foregroundStyle(.secondary)
                }
            }

            Text("Next steps:").font(.body.bold()).padding(.top, 4)

            VStack(alignment: .leading, spacing: 12) {
                NextStepRow(
                    icon: "globe",
                    title: String(localized: "Install browser extensions"),
                    detail: String(localized: "Chrome, Firefox and Brave need the Password Filler extension from their respective store.")
                )
                NextStepRow(
                    icon: "safari",
                    title: String(localized: "Safari integration (coming soon)"),
                    detail: String(localized: "The native Safari support will be enabled in a later version via System Settings → Passwords.")
                )
                NextStepRow(
                    icon: "menubar.rectangle",
                    title: String(localized: "Menu-bar icon"),
                    detail: String(localized: "Click the lock icon in the menu bar for status and actions. Settings open via ⌘,.")
                )
            }

            Spacer(minLength: 0)
        }
    }
}

private struct NextStepRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Nav bar

private struct NavBar: View {
    @Binding var step: OnboardingStep
    let draft: Config
    let firstRefreshState: FirstRefreshState
    let onFinish: () -> Void

    var body: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    if let prev = OnboardingStep(rawValue: step.rawValue - 1) {
                        step = prev
                    }
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!primaryEnabled)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var primaryLabel: LocalizedStringKey {
        // Return LocalizedStringKey so SwiftUI auto-localizes at render time.
        // (Button(_:action:) with LocalizedStringKey routes through the catalog.)
        switch step {
        case .welcome:      return "Let's get started"
        case .preflight:    return "Continue"
        case .config:       return "Continue"
        case .firstRefresh: return "Continue"
        case .finish:       return "Done"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .welcome, .preflight, .finish:
            return true
        case .config:
            // Require non-empty values so the Agent has a usable config. No
            // format validation — `op` will reject nonsense shorthands at
            // Step 4 with a real error.
            return !draft.opAccount.trimmingCharacters(in: .whitespaces).isEmpty
                && !draft.opTag.trimmingCharacters(in: .whitespaces).isEmpty
        case .firstRefresh:
            if case .success = firstRefreshState { return true }
            return false
        }
    }

    private func primaryAction() {
        switch step {
        case .welcome, .preflight, .config, .firstRefresh:
            if let next = OnboardingStep(rawValue: step.rawValue + 1) {
                step = next
            }
        case .finish:
            onFinish()
        }
    }
}
