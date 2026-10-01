import SwiftUI
import AppKit
import os.log

private let aiAgentsLog = Logger(subsystem: "app.passwordfiller.main", category: "settings")

/// Settings tab "For AI Agents" (specs/ai-agent-access, FR-7/FR-8): the
/// `mcp_enabled` switch, the state of the `password-filler-mcp` command and
/// the Claude Code plugin install commands.
struct AIAgentsTab: View {
    @Binding var draft: Config
    let onChange: () -> Void

    @State private var toolStatus: CommandLineToolStatus?
    @State private var toolError: String?

    private static let marketplaceCommand = "/plugin marketplace add andreasisaak/password-filler"
    private static let pluginCommand = "/plugin install password-filler@password-filler"

    var body: some View {
        Form {
            Section {
                Toggle("Enable local MCP server", isOn: $draft.mcpEnabled)
                    .onChange(of: draft.mcpEnabled) { _, enabled in
                        onChange()
                        if enabled { install() }
                    }
            } footer: {
                Text("Lets Claude Code and other AI agents reach htaccess-protected sites. They never see the passwords; a command started with password-filler-mcp run receives them as environment variables and could print them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                statusRow
                if let toolError {
                    Text(toolError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyableCommand(command: CommandLineToolInstaller.manualCommand)
                }
                if draft.mcpEnabled, toolStatus != .installed, toolStatus != .blockedByFile {
                    Button("Install command") { install() }
                }
            } header: {
                Text("Command")
            }

            Section {
                CopyableCommand(command: Self.marketplaceCommand)
                CopyableCommand(command: Self.pluginCommand)
            } header: {
                Text("Claude Code plugin")
            } footer: {
                Text("Run both commands in Claude Code. The plugin tells Claude how to use Password Filler.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 40)
        .task {
            refreshStatus()
            // EC-4: an app moved or replaced since the last install leaves a
            // dangling link; repair it while the switch is on.
            if draft.mcpEnabled, case .pointsElsewhere = toolStatus { install() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch toolStatus {
        case .installed:
            Label("Installed at \(CommandLineToolInstaller.linkPath)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .missing:
            Label("Not installed", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        case .pointsElsewhere(let destination):
            Label("Points to another app: \(destination)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .blockedByFile:
            Label("\(CommandLineToolInstaller.linkPath) belongs to another program and was not replaced.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case nil:
            Label("Status unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func refreshStatus() {
        do {
            toolStatus = try CommandLineToolInstaller.status()
        } catch {
            aiAgentsLog.error("command status failed: \(String(describing: error), privacy: .public)")
            toolStatus = nil
            toolError = String(localized: "Could not read \(CommandLineToolInstaller.linkPath): \(error.localizedDescription)")
        }
    }

    private func install() {
        do {
            try CommandLineToolInstaller.install()
            toolError = nil
        } catch {
            toolError = String(describing: error)
        }
        refreshStatus()
    }
}

/// A command in monospace with a copy button — for pasting into Terminal or
/// Claude Code.
private struct CopyableCommand: View {
    let command: String

    var body: some View {
        HStack {
            Text(verbatim: command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
    }
}
