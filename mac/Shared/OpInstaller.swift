import Foundation
import OSLog

/// Installs the 1Password CLI on first launch via Apple's standard `installer(8)`.
///
/// **Why not bundle `op` in the .app:** Xcode auto-resigns nested binaries with
/// the host app's Developer ID. 1Password's CLI-integration trust check rejects
/// the resigned binary ("connecting to desktop app: 1Password CLI couldn't
/// connect"), so the binary must keep its original AgileBits signature.
///
/// **Why not extract the pkg manually:** macOS already has the right tool
/// (`installer -pkg`). Doing it ourselves would mean re-implementing
/// pkg-receipt tracking, conflict resolution with future Brew installs, and
/// uninstall handling. `installer` does all of that and lives in a path
/// (`/usr/local/bin/op`) every other 1P-CLI install — Brew, manual download,
/// Apple Configurator profiles — uses.
///
/// **Flow:**
/// 1. Fetch latest version from `app-updates.agilebits.com`
/// 2. Download `op_apple_universal_v<version>.pkg` from `cache.agilebits.com`
/// 3. Verify the .pkg is signed by AgileBits Inc. AND notarized
/// 4. `osascript` runs `installer -pkg ... -target /` with admin privileges →
///    macOS shows the standard auth panel (Touch ID / password)
/// 5. After successful install, `/usr/local/bin/op` exists with the original
///    AgileBits signature — `OpClient.resolveOpPath()` finds it via the
///    standard `/usr/local/bin/op` candidate.
public enum OpInstaller {

    public enum Error: Swift.Error, CustomStringConvertible {
        case versionFetchFailed(String)
        case downloadFailed(String)
        case signatureVerificationFailed(String)
        case authDeclined
        case installerFailed(String)
        case verifyFailed(String)

        public var description: String {
            switch self {
            case .versionFetchFailed(let s):       return "Latest-Version-Lookup fehlgeschlagen: \(s)"
            case .downloadFailed(let s):           return "Download fehlgeschlagen: \(s)"
            case .signatureVerificationFailed(let s): return "Signaturprüfung fehlgeschlagen: \(s)"
            case .authDeclined:                    return "Admin-Bestätigung abgebrochen"
            case .installerFailed(let s):          return "Installation fehlgeschlagen: \(s)"
            case .verifyFailed(let s):             return "Post-Install-Check fehlgeschlagen: \(s)"
            }
        }
    }

    /// Standard macOS install location used by Apple's `installer(8)` for the
    /// 1Password CLI pkg. Same path Brew Cask, manual `op.pkg` doppelclicks,
    /// and MDM-pushed installs all end up at.
    public static let standardInstallPath = "/usr/local/bin/op"

    /// `true` if a usable `op` binary is already on disk (anywhere `OpClient`
    /// resolves to). Skips the install flow entirely when the user already has
    /// `op` from Brew or a previous manual install.
    public static func isInstalled() -> Bool {
        (try? OpClient().resolveOpPath()) != nil
    }

    private static let log = Logger(subsystem: "app.passwordfiller", category: "op-installer")

    /// Download + verify + install. Calls `progress(fraction, status)` on the
    /// main actor at each step.
    ///
    /// Throws `Error.authDeclined` if the user cancels the auth panel —
    /// callers should surface that as a soft retry-state, not a hard error.
    public static func install(
        progress: @MainActor @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws {
        await MainActor.run { progress(0.0, "Latest version ermitteln …") }
        let version = try await fetchLatestVersion()
        log.info("Latest op CLI version: \(version, privacy: .public)")

        await MainActor.run { progress(0.1, "Lade 1Password CLI \(version) …") }
        let pkgURL = try await downloadPkg(version: version)
        defer { try? FileManager.default.removeItem(at: pkgURL) }

        await MainActor.run { progress(0.7, "Signatur prüfen …") }
        try verifySignature(pkgPath: pkgURL.path)

        await MainActor.run { progress(0.8, "Installation starten — bitte Touch ID / Passwort bestätigen …") }
        try runInstallerWithAdmin(pkgPath: pkgURL.path)

        await MainActor.run { progress(0.95, "Verifizieren …") }
        try verifyInstall(expectedVersion: version)

        await MainActor.run { progress(1.0, "Fertig.") }
        log.info("Installed op CLI \(version, privacy: .public) to \(standardInstallPath, privacy: .public)")
    }

    // MARK: - Step 1: latest version

    private struct VersionResponse: Decodable {
        let version: String
    }

    private static func fetchLatestVersion() async throws -> String {
        // 1Password's update-check endpoint. Returns
        //   {"available":"1","version":"2.34.0","relnotes":"..."}
        // for any client version below latest. We pass `2.0.0` so we always
        // get the current stable.
        let url = URL(string: "https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N")!
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error.versionFetchFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        do {
            let decoded = try JSONDecoder().decode(VersionResponse.self, from: data)
            guard decoded.version.split(separator: ".").count == 3,
                  decoded.version.allSatisfy({ $0.isNumber || $0 == "." })
            else {
                throw Error.versionFetchFailed("Unexpected version format: \(decoded.version)")
            }
            return decoded.version
        } catch let e as Error {
            throw e
        } catch {
            throw Error.versionFetchFailed(error.localizedDescription)
        }
    }

    // MARK: - Step 2: download

    private static func downloadPkg(version: String) async throws -> URL {
        let urlString = "https://cache.agilebits.com/dist/1P/op2/pkg/v\(version)/op_apple_universal_v\(version).pkg"
        guard let url = URL(string: urlString) else {
            throw Error.downloadFailed("invalid URL: \(urlString)")
        }
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw Error.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("pf-1password-cli-\(version)-\(UUID().uuidString).pkg")
        try FileManager.default.moveItem(at: downloadedURL, to: dest)
        return dest
    }

    // MARK: - Step 3: verify signature

    private static func verifySignature(pkgPath: String) throws {
        let result = run(executable: "/usr/sbin/pkgutil",
                         args: ["--check-signature", pkgPath],
                         timeout: 30)
        guard result.exitCode == 0 else {
            throw Error.signatureVerificationFailed("pkgutil exit \(result.exitCode): \(result.stderr)")
        }
        // Reject any pkg that isn't signed by AgileBits (Team 2BUA8C4S2C) AND
        // notarized. These checks together prevent us from running a malicious
        // pkg even if `cache.agilebits.com` were compromised somehow.
        guard result.stdout.contains("AgileBits Inc.") || result.stdout.contains("2BUA8C4S2C") else {
            throw Error.signatureVerificationFailed("Nicht von AgileBits signiert — Installation abgebrochen")
        }
        guard result.stdout.contains("Notarization: trusted") else {
            throw Error.signatureVerificationFailed("PKG nicht notarisiert — Installation abgebrochen")
        }
    }

    // MARK: - Step 4: run Apple's installer with admin

    /// Runs `installer -pkg <pkg> -target /` via osascript so macOS shows the
    /// standard "Du musst dich authentifizieren …" panel (Touch ID / Passwort).
    /// Same UX as a manually doubleclicked .pkg.
    private static func runInstallerWithAdmin(pkgPath: String) throws {
        // `do shell script ... with administrator privileges` returns a
        // distinct exit pattern when the user cancels: errAEEventNotPermitted
        // (-1743) or "User canceled" (-128). We surface that as `.authDeclined`
        // so the UI can offer Retry without scaring the user.
        //
        // Quoting: AppleScript string literals use double-quotes. We escape
        // any double-quotes in the path (unlikely but be defensive) and wrap
        // the path in AppleScript-quoted-form via the `quoted form of` sigil
        // so spaces in /tmp/ paths Just Work.
        let appleScript = """
        do shell script "/usr/sbin/installer -pkg " & quoted form of \"\(escapeForAppleScript(pkgPath))\" & " -target /" with administrator privileges
        """
        let result = run(executable: "/usr/bin/osascript",
                         args: ["-e", appleScript],
                         timeout: 300)
        if result.exitCode == 0 {
            return
        }
        // osascript returns 1 on most error patterns; the stderr distinguishes them.
        let stderrLower = result.stderr.lowercased()
        if stderrLower.contains("user canceled") || stderrLower.contains("user cancelled")
            || result.stderr.contains("(-128)")
        {
            throw Error.authDeclined
        }
        throw Error.installerFailed("osascript exit \(result.exitCode): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Step 5: verify install

    private static func verifyInstall(expectedVersion: String) throws {
        guard FileManager.default.isExecutableFile(atPath: standardInstallPath) else {
            throw Error.verifyFailed("\(standardInstallPath) existiert nicht oder ist nicht ausführbar")
        }
        let result = run(executable: standardInstallPath, args: ["--version"], timeout: 15)
        guard result.exitCode == 0 else {
            throw Error.verifyFailed("--version exit \(result.exitCode): \(result.stderr)")
        }
        let installed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // `op --version` prints just the bare version string (e.g. "2.34.0").
        guard installed == expectedVersion else {
            throw Error.verifyFailed("Installierte Version '\(installed)' ≠ erwartet '\(expectedVersion)'")
        }
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func run(
        executable: String,
        args: [String],
        timeout: TimeInterval = 60
    ) -> ProcessResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain pipes concurrently — `pipe_deadlock.md` memory: never wait for
        // exit before draining, the 64 KB buffer fills and the child blocks.
        var outData = Data(), errData = Data()
        let outQ = DispatchQueue(label: "OpInstaller.stdout")
        let errQ = DispatchQueue(label: "OpInstaller.stderr")
        let group = DispatchGroup()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                outQ.sync { outData.append(chunk) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errQ.sync { errData.append(chunk) }
            }
        }

        group.enter()
        proc.terminationHandler = { _ in group.leave() }

        do {
            try proc.run()
        } catch {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "spawn failed: \(error)")
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            proc.terminate()
            return ProcessResult(exitCode: -2, stdout: "", stderr: "process timed out after \(Int(timeout))s")
        }

        return ProcessResult(
            exitCode: proc.terminationStatus,
            stdout: outQ.sync { String(data: outData, encoding: .utf8) ?? "" },
            stderr: errQ.sync { String(data: errData, encoding: .utf8) ?? "" }
        )
    }
}
