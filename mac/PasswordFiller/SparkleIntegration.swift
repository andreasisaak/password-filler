import SwiftUI
import Combine
import Sparkle

// Phase 5 Partial-3 — Sparkle SwiftUI wiring.
//
// `SPUStandardUpdaterController` is owned by `PasswordFillerApp` as a
// `private let` (not `@State`): it must be initialised in the App's `init()`
// so Sparkle's scheduled-check timer starts at process launch, not lazily on
// first view render. We pass `updater.updater` (the underlying `SPUUpdater`)
// down into the Settings About tab via `CheckForUpdatesView`.
//
// The view-model pattern (publishing `canCheckForUpdates`) follows Sparkle's
// official SwiftUI documentation — directly binding the button's `disabled`
// modifier to `updater.canCheckForUpdates` does not work because the property
// is KVO-backed, not a SwiftUI-observable state. Combine's `publisher(for:)`
// bridges it into an `@Published` that SwiftUI can track.

/// Tracks `SPUUpdater.canCheckForUpdates` so the SwiftUI button updates its
/// enabled state live — e.g. disabled while an update check is already in
/// flight. Must be retained for the lifetime of the `CheckForUpdatesView`.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// Settings-About-tab button that triggers a user-initiated update check.
/// The button disables itself while Sparkle is already mid-check; Sparkle's
/// own progress dialog handles the rest of the UI.
struct CheckForUpdatesView: View {
    @StateObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _viewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }

    var body: some View {
        Button(action: updater.checkForUpdates) {
            Label("Check for updates…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}
