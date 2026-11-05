import SwiftUI
import AppKit
import PharosRuntime

/// Real entry point. Two front doors share one binary:
///   • a CLI subcommand   → the `pharos` CLI (e.g. `Pharos list`, `Pharos launch …`)
///   • anything else      → the SwiftUI GUI, unchanged
/// The CLI is only entered for a bare-word subcommand (or `--help`/`--version`),
/// so GUI launch arguments from LaunchServices (`-psn_…`, `-NSDocument…`) still
/// open the app normally.
@main
enum PharosMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        // Invoked as `chat` (a symlink to this binary) → it's the mesh chat room.
        let invokedAs = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? ""
        if invokedAs == "chat" {
            exit(await CLI.run(["mesh"] + args))
        }
        if let first = args.first, CLI.isCommand(first) {
            exit(await CLI.run(args))
        }
        // Snapshot mode: become an ACCESSORY app BEFORE any window exists, so it
        // never activates, never steals focus, and never switches Spaces — the
        // capture window lives off-screen and the user's foreground app is
        // untouched. Referencing NSApplication.shared here (pre-`main()`)
        // creates the app instance so the very first window inherits the policy.
        if ProcessInfo.processInfo.environment["PHAROS_SNAPSHOT"]?.isEmpty == false {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        PharosApp.main()
    }
}

struct PharosApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var store = ProjectStore()
    @State private var showsBrokerSetup: Bool
    // Owns the Sparkle update lifecycle for the app's lifetime.
    private let updaterController = UpdaterController()

    init() {
        let alreadyConfigured = PharosRuntimeConfigurationStore(defaults: PharosPrefs.shared)
            .isConfigured
        _showsBrokerSetup = State(initialValue: !alreadyConfigured)
    }

    var body: some Scene {
        WindowGroup("Pharos") {
            Group {
                if showsBrokerSetup {
                    BrokerSetupOnboardingView {
                        showsBrokerSetup = false
                    }
                } else {
                    ContentView()
                }
            }
                .environment(store)
                .tint(PharosTheme.accent)
                .preferredColorScheme(store.appearance.colorScheme)
                .task {
                    guard !store.didBootstrapMesh else { return }
                    store.didBootstrapMesh = true
                    store.startMeshSnapshotPolling()
                    await store.recoverLegacyPeerIfNeeded()
                    // Runtime ownership lives in PharosRuntime. Startup only
                    // asks the application service to converge saved intent.
                    do {
                        try await store.applyRuntimeConfiguration(store.runtimeConfiguration)
                    } catch {
                        fputs("Pharos runtime reconcile failed: \(error.localizedDescription)\n", stderr)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            // Replace the default "About Pharos" with our custom window.
            CommandGroup(replacing: .appInfo) {
                Button("About Pharos") { openWindow(id: "about") }
            }
            // "Check for Updates…" appears in the app menu (after About Pharos).
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .newItem) {
                Button("Add Project…") { store.requestAdd() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Command Palette…") { store.requestPalette() }
                    .keyboardShortcut("k", modifiers: [.command])
            }
        }

        // Custom About window
        Window("About Pharos", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("Set Up Mesh Broker", id: "broker-setup") {
            BrokerSetupWindow()
                .environment(store)
        }
        .defaultSize(width: 900, height: 720)

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(nsImage: LighthouseIcon.menuBar)
        }
        .menuBarExtraStyle(.menu)
    }
}
