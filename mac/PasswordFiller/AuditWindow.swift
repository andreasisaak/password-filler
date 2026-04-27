import SwiftUI

/// Diagnostic window listing every `.htaccess`-tagged item the Agent can't
/// (correctly) autofill, grouped per logical item with bullet-listed defects.
///
/// Surfaced from `PopoverContentView` via `openWindow(id: "audit")`. Visibility
/// is gated upstream — the popover only shows the "open" indicator when
/// `findings.count > 0`, but the window itself works fine with an empty list
/// (shows only the disclaimer + a "no issues" message).
///
/// Phase-3 strings are hardcoded English; Phase-4 swaps them for
/// `String(localized:)` calls against `Localizable.xcstrings`.
struct AuditWindowView: View {
    @Bindable var client: AgentXPCClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Showing only items in vaults you have access to.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()

            Divider()

            if client.findings.isEmpty {
                ContentUnavailableView(
                    "No issues found",
                    systemImage: "checkmark.seal.fill",
                    description: Text("All `.htaccess`-tagged items look healthy.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sortedFindings) { finding in
                            FindingRow(finding: finding)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var sortedFindings: [Finding] {
        client.findings.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.red)
                Text(finding.title)
                    .font(.headline)
                Text("· " + finding.vaults.joined(separator: " / "))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            ForEach(finding.defects, id: \.self) { defect in
                Text("• " + defect.displayDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Defect → display string (Phase 3: English-only, Phase 4 will localize)

extension Defect {
    /// User-visible explanation of a single defect. Each branch routes through
    /// `String(localized:)` so translators can edit the text in
    /// `Localizable.xcstrings`. String-interpolation arguments become %@/%lld
    /// placeholders in the catalog at extraction time.
    var displayDescription: String {
        switch self {
        case .noWebsite:
            return String(localized: "No website field")
        case .noUsername:
            return String(localized: "No username")
        case .noPassword:
            return String(localized: "No password")
        case .sectionBrokenUsername:
            return String(localized: "Section present but username field is missing or empty — Agent falls back to top-level (likely wrong credentials)")
        case .sectionBrokenPassword:
            return String(localized: "Section present but password field is not of type Password (e.g. stored as a Text field) — Agent falls back to top-level (likely wrong credentials)")
        case let .vaultDuplicate(otherTitle, otherVaults, hostnameCount):
            let vaultsLabel = otherVaults.joined(separator: " / ")
            return String(localized: "Likely vault duplicate of '\(otherTitle)' (\(vaultsLabel)) — same \(hostnameCount) hostnames, diverging credentials")
        case let .hostnameCollision(otherTitle, otherVaults, hostnames):
            let vaultsLabel = otherVaults.joined(separator: " / ")
            if hostnames.count == 1 {
                return String(localized: "Hostname conflict with '\(otherTitle)' (\(vaultsLabel)) on '\(hostnames[0])'")
            } else {
                return String(localized: "Conflict with '\(otherTitle)' (\(vaultsLabel)) on \(hostnames.count) hostnames")
            }
        }
    }
}
