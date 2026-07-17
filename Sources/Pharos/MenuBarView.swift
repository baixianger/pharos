import SwiftUI

/// Content of the Pharos menu-bar extra (`.menu` style). Mirrors the iOS tab
/// layout: the first group navigates the main window to the four workspace
/// surfaces (projects · issues · agents · chat rooms); the second group is
/// Command Palette and Settings; the last item quits.
struct MenuBarView: View {
    let store: ProjectStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Header — live project + agent counts.
        let count = store.projects.count
        let running = store.projects.filter { store.hasRunningAgent($0) }.count
        Text("Pharos — \(count) project\(count == 1 ? "" : "s")" +
             (running > 0 ? " · \(running) running" : ""))
            .foregroundStyle(.secondary)

        Divider()

        // Group 1 — workspace surfaces (mirrors the iOS tabs).
        Button { navigate(.projects) } label: { Label("Projects", systemImage: "folder") }
        Button { navigate(.issues) } label: { Label("Issues", systemImage: "checklist") }
        Button { navigate(.agents) } label: { Label("Agents", systemImage: "chevron.left.forwardslash.chevron.right") }
        Button { navigate(.chatRooms) } label: { Label("Chat Rooms", systemImage: "bubble.left.and.bubble.right") }

        Divider()

        // Group 2 — command palette + settings.
        Button { activateApp(); store.requestPalette() } label: {
            Label("Command Palette…", systemImage: "command")
        }
        .keyboardShortcut("k", modifiers: [.command])

        Button { activateApp(); openSettings() } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        // Group 3 — quit.
        Button("Quit Pharos") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }

    /// Bring the main window forward, then hand the surface request to
    /// ContentView, which owns the split-view selection.
    private func navigate(_ target: MenuNavTarget) {
        activateApp()
        store.requestMenuNav(target)
    }

    private func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        // Bring an existing main window forward. If the user closed every
        // window, the queued nav request still applies when one reopens.
        NSApplication.shared.windows
            .first { $0.canBecomeMain && $0.level == .normal }?
            .makeKeyAndOrderFront(nil)
    }
}
