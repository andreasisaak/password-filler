import SafariServices
import Security
import os.log

/// Safari Web Extension host — the native counterpart that
/// `browser.runtime.sendNativeMessage` in `Resources/background.js` talks to.
///
/// The extension's only job is to shuttle the currently-observed main-frame
/// URL into the Shared Keychain so `CredentialProviderViewController` can
/// read it when Safari's Basic-Auth dialog invokes `prepareCredentialList(
/// for: [])` with empty identifiers (see `CredentialProviderViewController
/// .readObservedHost()`).
///
/// Wire format: `SharedHostKeychain.Payload` (`{host, ts}`) — the same struct
/// both extensions decode, so a schema change breaks the build, not the
/// runtime. Entries older than `SharedHostKeychain.maxFreshnessSeconds` are
/// ignored by the reader.
///
/// Keychain access-group: `A5278RL7RX.app.passwordfiller` — declared in
/// `SafariExt.entitlements` as `$(AppIdentifierPrefix)app.passwordfiller`,
/// matches the CredProvider entitlement of the same shape.
final class SafariExtHandler: NSObject, NSExtensionRequestHandling {

    private let log = Logger(subsystem: "app.passwordfiller.safariext", category: "handler")

    func beginRequest(with context: NSExtensionContext) {
        // `context.completeRequest` must always run, including when we return
        // early — Safari keeps the extension host process alive waiting for
        // the callback and the next native message will stall otherwise.
        defer { context.completeRequest(returningItems: [], completionHandler: nil) }

        guard
            let inputItem = context.inputItems.first as? NSExtensionItem,
            let message = inputItem.userInfo?[SFExtensionMessageKey],
            let dict = message as? [String: Any]
        else {
            log.error("message missing or not a dictionary")
            return
        }

        let type = (dict["type"] as? String) ?? "?"
        let urlStr = (dict["url"] as? String) ?? ""
        guard !urlStr.isEmpty else {
            log.info("empty url, ignoring message type=\(type, privacy: .public)")
            return
        }

        // Trust the host the background script already computed when present
        // — on `onAuthRequired` events it is the authoritative `challenger
        // .host` (the host the 401 came from, which can differ from the
        // document host when a sub-request to another origin triggers the
        // challenge).
        let host = (dict["host"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: urlStr)?.host
            ?? ""

        guard !host.isEmpty else {
            log.info("could not derive host for url type=\(type, privacy: .public)")
            return
        }

        let payload = SharedHostKeychain.Payload(host: host)
        guard let data = try? JSONEncoder().encode(payload) else {
            log.error("payload encode failed")
            return
        }

        writeKeychain(data: data)
        log.log("wrote observed host type=\(type, privacy: .public) host=\(host, privacy: .private)")
    }

    /// Updates the existing keychain entry or adds one if missing. Using
    /// `SecItemUpdate` first means a stuck legacy entry on the same
    /// service+account slot (e.g. from a previous build) is overwritten in
    /// place instead of colliding with `errSecDuplicateItem` on `SecItemAdd`.
    private func writeKeychain(data: Data) {
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: SharedHostKeychain.service,
            kSecAttrAccount: SharedHostKeychain.account,
            kSecAttrAccessGroup: SharedHostKeychain.accessGroup,
        ]
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = data
            // `AfterFirstUnlock` so the entry survives fast-user-switching /
            // screen-lock and is available as soon as the user's keychain is
            // unlocked — matches the spike's proven attribute.
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(addQuery as CFDictionary, nil)
            if add != errSecSuccess {
                log.error("SecItemAdd failed status=\(add, privacy: .public)")
            }
        } else if status != errSecSuccess {
            log.error("SecItemUpdate failed status=\(status, privacy: .public)")
        }
    }
}
