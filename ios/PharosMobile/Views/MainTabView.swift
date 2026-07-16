import SwiftUI
import UIKit

/// The full-app shell: a bottom tab bar over Projects, Agents, Chat and Settings.
/// Owns the single `who`/`list` poll so every tab (not just Chat) shows live
/// agent status across all machines.
struct MainTabView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppTab = .projects

    init() {
        let requested = PharosLaunchOptions.value(after: "--ui-tab")
        _selection = State(initialValue: requested.flatMap(AppTab.init(rawValue:)) ?? .projects)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppTab.allCases) { tab in
                Tab(value: tab) {
                    tab.content
                } label: {
                    Label {
                        Text(tab.title)
                    } icon: {
                        FixedOutlineTabIcon(systemName: tab.symbol)
                    }
                }
            }
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
        let requestedRoom = PharosLaunchOptions.value(after: "--ui-room")
        while !Task.isCancelled {
            await store.refresh()
            if let requestedRoom, store.selectedRoom != requestedRoom,
               store.rooms.contains(where: { $0.name == requestedRoom }) {
                await store.select(room: requestedRoom)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// `TabView` automatically substitutes filled SF Symbol variants for selected
/// tabs, even when the label asks for `.none`. Resolve the base glyph to a
/// template image first so selection can tint it without changing its shape.
private struct FixedOutlineTabIcon: View {
    let systemName: String

    var body: some View {
        if let image = UIImage(systemName: systemName) {
            Image(uiImage: image)
                .renderingMode(.template)
        }
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case projects, issues, agents, chat, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Projects"
        case .issues: "Issues"
        case .agents: "Agents"
        case .chat: "Chat"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .projects: "folder"
        case .issues: "checklist"
        case .agents: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.bubble.right"
        case .settings: "gearshape"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .projects: ProjectsView()
        case .issues: IssuesView()
        case .agents: AgentsView()
        case .chat: RootView()
        case .settings: SettingsView()
        }
    }
}
