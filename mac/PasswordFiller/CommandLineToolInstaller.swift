import AppKit
import os.log

private let installerLog = Logger(subsystem: "app.passwordfiller.main", category: "cli-tool")

/// Puts `password-filler-mcp` on the user's `PATH` as a symlink in
/// `/usr/local/bin` (design.md D7). macOS lists `/usr/local/bin` in
/// `/etc/paths`, so every login shell finds it even on Macs where the
/// directory does not exist yet — it is created on install.
///
/// Rules: the link always targets the binary in the running bundle (the app
/// may live in `~/Applications/`); a regular file at the link path is never
/// replaced; without write access the macOS administrator prompt runs the
/// same commands; turning the switch off leaves the link in place.
enum CommandLineToolInstaller {

    static let linkPath = "/usr/local/bin/password-filler-mcp"

    static var targetPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/password-filler-mcp"
    }

    /// One line the user can paste into Terminal when the in-app install fails.
    static var manualCommand: String {
        "sudo mkdir -p /usr/local/bin && sudo ln -sfn \(shellQuoted(targetPath)) \(linkPath)"
    }

    enum InstallError: Error, CustomStringConvertible {
        case blockedByFile
        case administratorPromptCancelled
        case failed(String)

        var description: String {
            switch self {
            case .blockedByFile:
                return String(localized: "\(CommandLineToolInstaller.linkPath) belongs to another program and was not replaced.")
            case .administratorPromptCancelled:
                return String(localized: "The administrator prompt was cancelled.")
            case .failed(let detail):
                return String(localized: "Installing the command failed: \(detail)")
            }
        }
    }

    static func status() throws -> CommandLineToolStatus {
        try CommandLineToolStatus.evaluate(linkPath: linkPath, expectedTarget: targetPath)
    }

    /// Creates or repairs the link. Blocks the main thread while the
    /// administrator prompt is up, like any modal macOS authorization dialog.
    @MainActor
    static func install() throws {
        let current = try status()
        installerLog.info("install requested, status=\(String(describing: current), privacy: .public)")
        switch current {
        case .installed:
            return
        case .blockedByFile:
            throw InstallError.blockedByFile
        case .missing, .pointsElsewhere:
            if FileManager.default.isWritableFile(atPath: "/usr/local/bin") {
                try linkDirectly(replacingExisting: current != .missing)
            } else {
                try runAsAdministrator("mkdir -p /usr/local/bin && ln -sfn \(shellQuoted(targetPath)) \(shellQuoted(linkPath))")
            }
        }
        installerLog.info("installed \(linkPath, privacy: .public) -> \(targetPath, privacy: .public)")
    }

    /// App launch (EC-4): with the switch on, re-point a link left behind by
    /// a moved or replaced app. A missing link is left to the Settings tab, so
    /// a cancelled administrator prompt does not come back on every launch.
    @MainActor
    static func repairIfMoved() {
        do {
            guard try ConfigStore().load().mcpEnabled else { return }
            guard case .pointsElsewhere = try status() else { return }
            try install()
        } catch {
            installerLog.error("launch repair failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func linkDirectly(replacingExisting: Bool) throws {
        do {
            if replacingExisting {
                try FileManager.default.removeItem(atPath: linkPath)
            }
            try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        } catch {
            installerLog.error("direct link failed: \(String(describing: error), privacy: .public)")
            throw InstallError.failed(error.localizedDescription)
        }
    }

    @MainActor
    private static func runAsAdministrator(_ shellCommand: String) throws {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")
        var errorInfo: NSDictionary?
        guard script?.executeAndReturnError(&errorInfo) != nil else {
            let number = errorInfo?[NSAppleScript.errorNumber] as? Int
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "no AppleScript error message"
            installerLog.error("administrator install failed (\(number ?? 0, privacy: .public)): \(message, privacy: .public)")
            // -128: the user pressed Cancel.
            throw number == -128 ? InstallError.administratorPromptCancelled : InstallError.failed(message)
        }
    }

    /// Single-quotes for /bin/sh, so app paths with spaces or quotes survive.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
