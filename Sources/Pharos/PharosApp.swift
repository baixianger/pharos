import SwiftUI

/// Real entry point. Two front doors share one binary:
///   • a CLI subcommand   → the `pharos` CLI (e.g. `Pharos list`, `Pharos launch …`)
///   • anything else      → the SwiftUI GUI, unchanged
/// The CLI is only entered for a bare-word subcommand (or `--help`/`--version`),
/// so GUI launch arguments from LaunchServices (`-psn_…`, `-NSDocument…`) still
/// open the app normally.
@main
enum PharosMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.isCommand(first) {
            exit(CLI.run(args))
        }
        PharosApp.main()
    }
}

struct PharosApp: App {
    @Environment(\.openWindow) private var openWindow
    @State private var store = ProjectStore()
    // Owns the Sparkle update lifecycle for the app's lifetime.
    private let updaterController = UpdaterController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(store.appearance.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
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

        Settings {
            SettingsView()
                .environment(store)
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .menuBarExtraStyle(.menu)
    }
}
