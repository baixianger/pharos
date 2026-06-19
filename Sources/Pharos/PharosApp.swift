import SwiftUI

/// Real entry point. Dispatches to the headless MCP server when launched with
/// `--mcp`; otherwise hands off to SwiftUI's synthesized `App` entry point so
/// the normal GUI launches unchanged.
///
/// The Mac App Store (sandboxed) build has no MCP server — a sandboxed app may
/// not spawn agents — so `main()` always runs the GUI there.
@main
enum PharosMain {
    static func main() {
        #if !APP_STORE
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
            return
        }
        #endif
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
            #if !APP_STORE
            // "Check for Updates…" appears in the app menu (after About Pharos).
            // Omitted in the Mac App Store build — the App Store delivers updates.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            #endif
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
