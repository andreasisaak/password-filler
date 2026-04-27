import SwiftUI
import os.log

/// Main popover content shown when the menu-bar icon is clicked.
///
/// Structure (top → bottom):
///   1. Status row: connection state + item count
///   2. Last-refresh row + Refresh button
///   3. Divider
///   4. Scrollable item list (alphabetical, merged rows show vault-count badge)
///   5. Footer: Quit button
///
/// Settings + Onboarding + Sparkle checks are deferred to the follow-up
/// Phase-4 session (plan tasks 4.3, 4.4, 4.5, 4.7). The footer button for
/// "Einstellungen…" is intentionally omitted until those land.
struct PopoverContentView: View {
    @Bindable var client: AgentXPCClient
    @Environment(\.openURL) private var openURL

    private static let log = Logger(subsystem: "app.passwordfiller.main", category: "ui")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusRow(status: client.status, error: client.connectionError)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            RefreshRow(
                lastRefresh: client.status?.lastRefresh,
                isRefreshing: client.isRefreshing,
                onRefresh: { Task { await client.triggerCacheRefresh() } }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ItemsList(items: client.items)
                .frame(height: 320)

            Divider()

            FooterRow()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
        .task {
            await client.pollOnce()
        }
        .onAppear {
            // Tell the XPC client the popover is visible so it switches to the
            // 3 s poll cadence (task 4.5). `.onDisappear` reverts to 30 s.
            // `MenuBarExtra(style: .window)` mounts the content when the user
            // clicks the menu-bar icon and unmounts when the panel closes, so
            // these fire exactly on open / close transitions.
            client.setPopoverVisible(true)
        }
        .onDisappear {
            client.setPopoverVisible(false)
        }
    }
}

// MARK: - Status row

private struct StatusRow: View {
    let status: AgentStatus?
    let error: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLine)
                    .font(.headline)
                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var iconName: String {
        if error != nil { return "exclamationmark.triangle.fill" }
        guard let state = status?.connectionState else { return "questionmark.circle" }
        switch state {
        case .connected:      return "lock.fill"
        case .locked:         return "lock.slash.fill"
        case .revoked:        return "xmark.octagon.fill"
        case .notConfigured:  return "gear.badge.questionmark"
        case .error:          return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        if error != nil { return .orange }
        switch status?.connectionState {
        case .connected:      return .green
        case .locked:         return .yellow
        case .revoked, .error: return .red
        case .notConfigured, .none: return .secondary
        }
    }

    private var primaryLine: String {
        // `String(localized:)` resolves the current locale's catalog entry.
        // Plural-variant keys use %lld interpolation — the catalog picks the
        // right form for 1 vs N automatically.
        if error != nil { return String(localized: "Agent unreachable") }
        guard let status else { return String(localized: "Connecting…") }
        switch status.connectionState {
        case .connected:     return String(localized: "Connected · \(status.itemCount) items")
        case .locked:        return String(localized: "1Password locked")
        case .revoked:       return String(localized: "1Password access revoked")
        case .notConfigured: return String(localized: "Not configured")
        case .error:         return String(localized: "Error during refresh")
        }
    }

    private var secondaryLine: String? {
        // Priority: transient XPC error > persisted agent error > TTL info.
        if let error { return error }
        guard let status else { return nil }
        // Surface the persisted reason for any non-connected state so the
        // user sees *why* the agent is unhappy, not just that it is.
        if status.connectionState != .connected, let msg = status.errorMessage {
            return msg
        }
        if status.connectionState == .connected {
            // Plural-variant catalog key "Cache TTL: %lld days" → DE picks
            // "Cache-TTL: N Tag" vs "Cache-TTL: N Tage" automatically.
            return String(localized: "Cache TTL: \(status.ttlDays) days")
        }
        return nil
    }
}

// MARK: - Refresh row

private struct RefreshRow: View {
    let lastRefresh: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void

    @State private var now = Date()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        // Follow the user's system language — "vor 3 Std." vs "3 hrs ago"
        // switches automatically when they change Language & Region.
        f.locale = .autoupdatingCurrent
        return f
    }()
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            Text("Last refresh: \(lastRefreshText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRefreshing)
        }
        .onReceive(tick) { now = $0 }
    }

    private var lastRefreshText: String {
        guard let lastRefresh else { return String(localized: "never") }
        // Two edge-cases stacked:
        //   1. `now` ticks every 30 s, so mid-interval `lastRefresh` can be
        //      microseconds ahead of our cached `now`. The `max` clamp makes
        //      the delta non-negative so we never hit future-tense.
        //   2. With `delta == 0`, `RelativeDateTimeFormatter` emits e.g.
        //      "in 0 Sekunden" (German) / "in 0 seconds" (English) for the
        //      literal-zero case. We short-circuit to the "just now" key so
        //      the text reads naturally right after a refresh completes.
        let reference = max(now, lastRefresh)
        let delta = reference.timeIntervalSince(lastRefresh)
        if delta < 2 { return String(localized: "just now") }
        return Self.relativeFormatter.localizedString(for: lastRefresh, relativeTo: reference)
    }
}

// MARK: - Items list

private struct ItemsList: View {
    let items: [DisplayRow]

    var body: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("No items in cache")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items, id: \.primaryItemId) { row in
                        ItemRow(row: row)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}

private struct ItemRow: View {
    let row: DisplayRow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                Text(domainLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 6)

            if row.sourceVaults.count > 1 {
                // Plural-variant key "%lld vaults" — guard above ensures >1
                // so the "other" case always wins, but we still route through
                // the catalog so the word itself localizes ("Tresore" in DE).
                Text("\(row.sourceVaults.count) vaults")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .help(row.hostnames.joined(separator: "\n"))
    }

    /// Prefer the compact domain list; fall back to hostnames when empty.
    private var domainLine: String {
        let list = row.domains.isEmpty ? row.hostnames : row.domains
        return list.joined(separator: ", ")
    }
}

// MARK: - Footer

private struct FooterRow: View {
    /// `.openSettings` is the macOS 14+ way to surface the `Settings {}` scene
    /// from code. `LSUIElement=true` hides the app from the Dock and removes
    /// the standard "App → Preferences…" menu, so the popover is the only
    /// entry point to Settings — this button has to work.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack {
            Button {
                // Two fixes needed for `accessory`/`LSUIElement` apps:
                //   1. `NSApp.activate` — without it the Settings window is
                //      created but stays behind the frontmost app because the
                //      policy is `.accessory`.
                //   2. Defer `openSettings()` so the MenuBarExtra popover has
                //      finished dismissing before SwiftUI tries to surface
                //      another window — otherwise the window-manager drops
                //      the show request silently on some macOS 14 builds.
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    openSettings()
                }
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit Password Filler", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}
