import SwiftUI

/// Real entry point. Dispatches to the headless MCP server when launched with
/// `--mcp`; otherwise hands off to SwiftUI's synthesized `App` entry point so
/// the normal GUI launches unchanged.
@main
enum PharosMain {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        } else {
            PharosApp.main()
        }
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
