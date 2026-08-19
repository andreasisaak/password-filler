import Foundation
import UserNotifications
import os.log

/// Fires a user notification when the Agent's cache transitions into the
/// expired state (see `AgentStatus.isCacheExpired`).
///
/// Edge-triggered: one notification per transition. `wasExpired` starts
/// `false`, so an app launch into an already-expired cache also notifies
/// exactly once — every login re-nudges, but polling never spams. The
/// menu-bar warning icon is the persistent signal; this is only the
/// transient nudge for users who are not looking at the menu bar.
@MainActor
final class StaleCacheNotifier {

    private let log = Logger(subsystem: "app.passwordfiller.main", category: "notifications")
    private var wasExpired = false

    func statusDidUpdate(_ status: AgentStatus?) {
        let expired = status?.isCacheExpired() ?? false
        defer { wasExpired = expired }
        guard expired, !wasExpired else { return }
        log.info("Cache transitioned to expired — posting user notification")
        post()
    }

    private func post() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Password cache expired")
        content.body = String(
            localized: "Open Password Filler and click Refresh to sign in to 1Password again."
        )
        content.sound = .default
        // Stable identifier: a re-post replaces the previous notification
        // instead of stacking a new banner per expiry episode.
        let request = UNNotificationRequest(
            identifier: "app.passwordfiller.cache-expired",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { [log] error in
            if let error {
                log.error("Notification delivery failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
