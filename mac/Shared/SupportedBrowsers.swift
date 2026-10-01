import Foundation

/// Code-signing identity of one browser app: its bundle identifier (equal to
/// its signing identifier) and the Apple Team ID that signs it.
public struct BrowserIdentity: Equatable {
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(bundleIdentifier: String, teamIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }
}

/// Single source for the browsers allowed to spawn `pf-nmh-bridge`.
///
/// `BrowserCatalog` (Main-App) detects installation from the bundle
/// identifiers; the Agent's `BridgeParentPolicy` (D25) accepts a bridge only
/// when its parent process carries one of these exact identities. A browser
/// missing here loses autofill — add it together with a live check that its
/// main process (not a helper) is the bridge's parent.
///
/// Team IDs read with `codesign -dv` on 2026-10-01; parents seen live for
/// Chrome.
public enum SupportedBrowsers {
    public static let chrome = BrowserIdentity(bundleIdentifier: "com.google.Chrome", teamIdentifier: "EQHXZ8M8AV")
    public static let chromeBeta = BrowserIdentity(bundleIdentifier: "com.google.Chrome.beta", teamIdentifier: "EQHXZ8M8AV")
    public static let brave = BrowserIdentity(bundleIdentifier: "com.brave.Browser", teamIdentifier: "KL8N8XSYF4")
    public static let vivaldi = BrowserIdentity(bundleIdentifier: "com.vivaldi.Vivaldi", teamIdentifier: "4XF3XNRN6Y")
    public static let firefox = BrowserIdentity(bundleIdentifier: "org.mozilla.firefox", teamIdentifier: "43AQ936H96")
    public static let firefoxDeveloperEdition = BrowserIdentity(bundleIdentifier: "org.mozilla.firefoxdeveloperedition", teamIdentifier: "43AQ936H96")
    public static let firefoxNightly = BrowserIdentity(bundleIdentifier: "org.mozilla.nightly", teamIdentifier: "43AQ936H96")

    public static let all: [BrowserIdentity] = [
        chrome,
        chromeBeta,
        brave,
        vivaldi,
        firefox,
        firefoxDeveloperEdition,
        firefoxNightly,
    ]
}
