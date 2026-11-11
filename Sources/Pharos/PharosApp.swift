import SwiftUI
import AppKit

/// Phase E: GUI-only Swift client. Mesh/Runtime CLI lives in the Rust `pharos` binary.
@main
struct PharosApp: App {
    @NSApplicationDelegateAdaptor(PharosApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var store = ProjectStore()
    private let updaterController = UpdaterController()

    init() {
        if ProcessInfo.processInfo.environment["PHAROS_SNAPSHOT"]?.isEmpty == false {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        WindowGroup("Pharos") {
            ContentView()
                .environment(store)
                .tint(PharosTheme.accent)
                .preferredColorScheme(store.appearance.colorScheme)
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Pharos") { openWindow(id: "about") }
            }
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
            Image(nsImage: LighthouseIcon.menuBar)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class PharosApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
