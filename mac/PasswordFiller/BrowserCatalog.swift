import AppKit

// Single source of truth for the NMH-capable browsers Password Filler
// supports. Consumed by `NMHManifestWriter` (manifest targets) and the
// Settings security tab (integration status rows). Safari is not listed —
// it integrates via Credential Provider + Safari Web Extension, not NMH.
//
// Installation is decided by asking LaunchServices whether an app bundle
// with one of the browser's bundle identifiers is registered. The browser's
// Application-Support directory is deliberately NOT used as the install
// heuristic: 1Password (and other NMH publishers) create those directories
// for every browser they support, so directory existence proves nothing —
// users without Vivaldi were shown a green "Vivaldi — Available" row purely
// because 1Password had created `~/Library/Application Support/Vivaldi/`.
enum BrowserCatalog {

    enum Dialect {
        case chromium
        case firefox
    }

    struct Browser {
        let displayName: String
        /// Application-Support subdirectory whose `NativeMessagingHosts/`
        /// folder the browser reads NMH manifests from.
        let supportSubdirectory: String
        /// Every bundle identifier whose app reads manifests from
        /// `supportSubdirectory`. Firefox release, Developer Edition and
        /// Nightly all share the `Mozilla` directory.
        let bundleIdentifiers: [String]
        let dialect: Dialect

        var supportDirectory: URL {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(supportSubdirectory, isDirectory: true)
        }

        var isInstalled: Bool {
            bundleIdentifiers.contains { identifier in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) != nil
            }
        }
    }

    static let all: [Browser] = [
        Browser(
            displayName: "Google Chrome",
            supportSubdirectory: "Google/Chrome",
            bundleIdentifiers: ["com.google.Chrome"],
            dialect: .chromium
        ),
        Browser(
            displayName: "Google Chrome Beta",
            supportSubdirectory: "Google/Chrome Beta",
            bundleIdentifiers: ["com.google.Chrome.beta"],
            dialect: .chromium
        ),
        Browser(
            displayName: "Brave Browser",
            supportSubdirectory: "BraveSoftware/Brave-Browser",
            bundleIdentifiers: ["com.brave.Browser"],
            dialect: .chromium
        ),
        Browser(
            displayName: "Vivaldi",
            supportSubdirectory: "Vivaldi",
            bundleIdentifiers: ["com.vivaldi.Vivaldi"],
            dialect: .chromium
        ),
        Browser(
            displayName: "Firefox",
            supportSubdirectory: "Mozilla",
            bundleIdentifiers: [
                "org.mozilla.firefox",
                "org.mozilla.firefoxdeveloperedition",
                "org.mozilla.nightly",
            ],
            dialect: .firefox
        ),
    ]
}
