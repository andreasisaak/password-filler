#if canImport(AppKit)
import AppKit
#endif
import Foundation
import os.log

/// Active offboarding enforcement (design.md D23 / requirements.md FR-12a).
///
/// Polls `op whoami` on a 30-minute cadence plus on every wake-from-sleep
/// notification, and evicts the in-memory cache the moment the CLI reports
/// that the 1Password account is no longer authorised.
public final class RevokePoller {

    /// Observable result surface so AgentService can re-map to ConnectionState.
    public enum Event: Equatable {
        case authenticated
        case locked
        case revoked
        case unknown
    }

    private let provider: WhoamiProvider
    private let onEvent: (Event) -> Void
    private let interval: TimeInterval
    private let log = Logger(subsystem: "app.passwordfiller.agent", category: "revoke-poller")
    private let queue = DispatchQueue(label: "app.passwordfiller.agent.revoke-poller")

    private var timer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?
    private var pendingWakeWork: DispatchWorkItem?

    public init(
        provider: WhoamiProvider,
        interval: TimeInterval = 30 * 60,
        onEvent: @escaping (Event) -> Void
    ) {
        self.provider = provider
        self.interval = interval
        self.onEvent = onEvent
    }

    public func start() {
        stop() // idempotent

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(60))
        t.setEventHandler { [weak self] in self?.pollNow() }
        t.resume()
        timer = t

        #if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleDebouncedWakePoll()
        }
        #endif

        log.info("RevokePoller started (interval=\(self.interval, privacy: .public)s)")

        // Kick a poll immediately so the UI sees the current 1P state within
        // a few hundred ms of Agent startup instead of the first full
        // `interval` later. Cheap — `op whoami` is a single in-process call.
        queue.async { [weak self] in self?.pollNow() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        pendingWakeWork?.cancel()
        pendingWakeWork = nil
        #if canImport(AppKit)
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        wakeObserver = nil
        #endif
    }

    /// Public so AgentService can piggy-back its "Refresh" button on the same
    /// code path and reuse the policy for `.noAccounts` → evict.
    public func pollNow() {
        let result: WhoamiResult
        do {
            result = try provider.whoami()
        } catch {
            log.error("whoami threw: \(String(describing: error), privacy: .public)")
            onEvent(.unknown)
            return
        }

        switch result {
        case .authenticated:
            log.debug("whoami: authenticated")
            onEvent(.authenticated)
        case .locked:
            log.info("whoami: locked (transient, no cache change)")
            onEvent(.locked)
        case .noAccounts:
            log.error("whoami: noAccounts — treating as revoked, evicting cache")
            onEvent(.revoked)
        case .unknown(let stderr, let code):
            log.error("whoami: unknown (exit=\(code, privacy: .public), stderr=\(stderr, privacy: .public))")
            onEvent(.unknown)
        case .timeout:
            log.error("whoami: timeout")
            onEvent(.unknown)
        }
    }

    private func scheduleDebouncedWakePoll() {
        pendingWakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollNow() }
        pendingWakeWork = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
