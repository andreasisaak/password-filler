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
// Manifests are written only for browsers whose app bundle LaunchServices
// actually knows (`BrowserCatalog.Browser.isInstalled`) — the mere existence
// of the browser's Application-Support directory proves nothing, because
// 1Password creates those directories for every browser it supports. For
// browsers that are not installed, a previously written manifest is removed
// so uninstalling a browser leaves nothing of ours behind.

enum NMHManifestWriter {

    private static let log = Logger(subsystem: "app.passwordfiller.main", category: "nmh-manifest")

    static let hostName = "app.passwordfiller"
    static let chromeExtensionID = "ebcpahcihmnibmplnblcikgjiicmpcff"
    static let firefoxExtensionID = "passwordfiller@app"

    static func write(bridgePath: String) {
        for browser in BrowserCatalog.all {
            if browser.isInstalled {
                writeManifest(for: browser, bridgePath: bridgePath)
            } else {
                removeStaleManifest(for: browser)
            }
        }
    }

    /// Manifest location for one browser — shared with the Settings security
    /// tab so its status probe checks the exact file this writer maintains.
    static func manifestURL(for browser: BrowserCatalog.Browser) -> URL {
        browser.supportDirectory
            .appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent("\(hostName).json", isDirectory: false)
    }

    // MARK: - Manifest payload

    private static func manifest(bridgePath: String, dialect: BrowserCatalog.Dialect) -> [String: Any] {
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

    private static func writeManifest(for browser: BrowserCatalog.Browser, bridgePath: String) {
        let manifestURL = manifestURL(for: browser)

        do {
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            log.error("mkdir failed for \(browser.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let payload = manifest(bridgePath: bridgePath, dialect: browser.dialect)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        } catch {
            log.error("JSON encode failed for \(browser.displayName, privacy: .public)")
            return
        }

        if let existing = try? Data(contentsOf: manifestURL), existing == data {
            log.debug("manifest already up-to-date for \(browser.displayName, privacy: .public)")
            return
        }

        do {
            try data.write(to: manifestURL, options: [.atomic])
            log.info("wrote NMH manifest for \(browser.displayName, privacy: .public) → \(manifestURL.path, privacy: .public)")
        } catch {
            log.error("write failed for \(browser.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Removes a manifest this app wrote for a browser that is no longer
    /// installed. Only our own `app.passwordfiller.json` is touched — the
    /// directory and other publishers' manifests stay untouched.
    private static func removeStaleManifest(for browser: BrowserCatalog.Browser) {
        let manifestURL = manifestURL(for: browser)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: manifestURL)
            log.info("removed stale NMH manifest for \(browser.displayName, privacy: .public) — browser not installed")
        } catch {
            log.error("stale-manifest removal failed for \(browser.displayName, privacy: .public): \(String(describing: error), privacy: .public)")
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
