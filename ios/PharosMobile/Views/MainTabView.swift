import SwiftUI

/// The full-app shell: a bottom tab bar over Projects, Agents, Chat and Settings.
/// Owns the single `who`/`list` poll so every tab (not just Chat) shows live
/// agent status across all machines.
struct MainTabView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        TabView {
            Tab("Projects", systemImage: "folder") { ProjectsView() }
            Tab("Issues", systemImage: "ladybug") { IssuesView() }
            Tab("Agents", systemImage: "cpu") { AgentsView() }
            Tab("Chat", systemImage: "bubble.left.and.bubble.right") { RootView() }
            Tab("Settings", systemImage: "gearshape") { NavigationStack { SettingsView() } }
        }
        // Owned here (not RootView) so it's set before the app-wide poll runs,
        // even if the Chat tab is never opened. Compact iPhone: land on the room
        // list. Regular iPad: keep a default room selected in the detail column.
        .onChange(of: horizontalSizeClass, initial: true) {
            store.autoSelectsFirstRoom = horizontalSizeClass != .compact
        }
        .task { await pollWhileVisible() }
    }

    private func pollWhileVisible() async {
        while !Task.isCancelled {
            await store.refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
