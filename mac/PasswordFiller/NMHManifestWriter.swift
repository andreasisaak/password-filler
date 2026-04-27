import Foundation
import os.log

// NMH-manifest path-repair (design.md D18).
//
// Chromium- and Firefox-based browsers discover Native Messaging Hosts via a
// per-browser JSON manifest in `~/Library/Application Support/<browser>/
// NativeMessagingHosts/app.passwordfiller.json`. The manifest carries the
// absolute path of the host binary — and if the .app bundle is moved or
// renamed, that path becomes stale and Basic-Auth-Fill silently breaks.
//
// Fix: rewrite the manifest from the current bundle's `pf-nmh-bridge` path
// on every Main-App launch. Browsers re-read the manifest the next time an
// extension calls `connectNative`, so the repair is effectively zero-latency.
//
// Skip silently if the parent browser directory does not exist — we do not
// want to leave orphan Application-Support folders for browsers the user
// has never installed.

enum NMHManifestWriter {

    private static let log = Logger(subsystem: "app.passwordfiller.main", category: "nmh-manifest")

    static let hostName = "app.passwordfiller"
    static let chromeExtensionID = "ebcpahcihmnibmplnblcikgjiicmpcff"
    static let firefoxExtensionID = "passwordfiller@app"

    struct BrowserTarget {
        enum Dialect { case chromium, firefox }
        let displayName: String
        /// Parent Application-Support directory that must already exist for
        /// the browser to be considered "installed".
        let browserDir: URL
        let dialect: Dialect
    }

    static func write(bridgePath: String) {
        let targets = enabledTargets()
        for target in targets {
            writeManifest(for: target, bridgePath: bridgePath)
        }
    }

    // MARK: - Target discovery

    private static func enabledTargets() -> [BrowserTarget] {
        let supportDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let candidates: [BrowserTarget] = [
            BrowserTarget(
                displayName: "Google Chrome",
                browserDir: supportDir.appendingPathComponent("Google/Chrome", isDirectory: true),
                dialect: .chromium
            ),
            BrowserTarget(
                displayName: "Google Chrome Beta",
                browserDir: supportDir.appendingPathComponent("Google/Chrome Beta", isDirectory: true),
                dialect: .chromium
            ),
            BrowserTarget(
                displayName: "Brave Browser",
                browserDir: supportDir.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true),
                dialect: .chromium
            ),
            BrowserTarget(
                displayName: "Vivaldi",
                browserDir: supportDir.appendingPathComponent("Vivaldi", isDirectory: true),
                dialect: .chromium
            ),
            BrowserTarget(
                displayName: "Firefox",
                browserDir: supportDir.appendingPathComponent("Mozilla", isDirectory: true),
                dialect: .firefox
            ),
        ]

        return candidates.filter { target in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: target.browserDir.path, isDirectory: &isDir)
            return exists && isDir.boolValue
        }
    }

    // MARK: - Manifest payload

    private static func manifest(bridgePath: String, dialect: BrowserTarget.Dialect) -> [String: Any] {
        var payload: [String: Any] = [
            "name": hostName,
            "description": "Password Filler Native Messaging Host",
            "path": bridgePath,
            "type": "stdio",
        ]
        switch dialect {
        case .chromium:
            payload["allowed_origins"] = ["chrome-extension://\(chromeExtensionID)/"]
        case .firefox:
            payload["allowed_extensions"] = [firefoxExtensionID]
        }
        return payload
    }

    private static func writeManifest(for target: BrowserTarget, bridgePath: String) {
        let nmhDir = target.browserDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        let manifestURL = nmhDir.appendingPathComponent("\(hostName).json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: nmhDir, withIntermediateDirectories: true)
        } catch {
            log.error("mkdir failed for \(target.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let payload = manifest(bridgePath: bridgePath, dialect: target.dialect)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        } catch {
            log.error("JSON encode failed for \(target.displayName, privacy: .public)")
            return
        }

        if let existing = try? Data(contentsOf: manifestURL), existing == data {
            log.debug("manifest already up-to-date for \(target.displayName, privacy: .public)")
            return
        }

        do {
            try data.write(to: manifestURL, options: [.atomic])
            log.info("wrote NMH manifest for \(target.displayName, privacy: .public) → \(manifestURL.path, privacy: .public)")
        } catch {
            log.error("write failed for \(target.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Convenience

    /// Absolute path of the `pf-nmh-bridge` tool inside the current bundle.
    static func currentBridgePath() -> String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/pf-nmh-bridge", isDirectory: false)
            .path
    }
}
