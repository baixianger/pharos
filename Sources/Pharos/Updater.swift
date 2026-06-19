import SwiftUI

#if APP_STORE

// MARK: - UpdaterController (App Store stub)

/// The Mac App Store delivers updates itself, and bundling Sparkle (which
/// downloads and launches its own updater) is forbidden in a sandboxed MAS app.
/// This stub keeps `PharosApp` compiling; the "Check for Updates…" menu command
/// and `CheckForUpdatesView` are omitted from the App Store build.
@MainActor
final class UpdaterController {
    init() {}
}

#else

import Sparkle

// MARK: - UpdaterController

/// Thin wrapper around SPUStandardUpdaterController that owns the Sparkle
/// update lifecycle for the lifetime of the app.
@MainActor
final class UpdaterController {
    /// The Sparkle controller. It only auto-starts once a real EdDSA public key
    /// (`SUPublicEDKey`) is configured in Info.plist. Until then there's no feed
    /// or key, so starting the updater would show a "failed to start" alert on
    /// launch — instead we stay dormant and start automatically once configured
    /// (see docs/SPARKLE.md).
    let controller: SPUStandardUpdaterController

    init() {
        let key = (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) ?? ""
        controller = SPUStandardUpdaterController(
            startingUpdater: !key.isEmpty,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// The underlying SPUUpdater, exposed so views can bind to it.
    var updater: SPUUpdater { controller.updater }
}

// MARK: - CheckForUpdatesView

/// A SwiftUI view that shows "Check for Updates…" in the menu bar, following
/// Sparkle's recommended SwiftUI integration pattern.
///
/// The button is disabled while an update check is already in progress (Sparkle
/// toggles `canCheckForUpdates` for this purpose).
struct CheckForUpdatesView: View {
    /// Wrap canCheckForUpdates in an ObservableObject so SwiftUI re-renders when
    /// Sparkle publishes changes on it.
    @ObservedObject private var observer: CanCheckForUpdatesObserver

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.observer = CanCheckForUpdatesObserver(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!observer.canCheckForUpdates)
    }
}

// MARK: - CanCheckForUpdatesObserver

/// Bridges Sparkle's KVO-published `canCheckForUpdates` property to SwiftUI's
/// ObservableObject system.
private final class CanCheckForUpdatesObserver: ObservableObject {
    @Published var canCheckForUpdates = false

    private var observation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        observation = updater.observe(
            \.canCheckForUpdates,
            options: [.new, .initial]
        ) { [weak self] updater, _ in
            // SPUUpdater publishes on an arbitrary queue; hop to main.
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }
}

#endif
