import SwiftUI

/// Content of the Pharos menu-bar extra (`.menu` style).
struct MenuBarView: View {
    let store: ProjectStore
    @Environment(\.openSettings) private var openSettings

    private var openIssues: [(project: Project, issue: Issue)] {
        var rows: [(project: Project, issue: Issue)] = []
        for project in store.projects {
            for issue in project.issues where issue.status.isOpen {
                rows.append((project, issue))
            }
        }
        return rows.sorted { lhs, rhs in
            let ln = lhs.project.name.lowercased(), rn = rhs.project.name.lowercased()
            if ln != rn { return ln < rn }
            return lhs.issue.number > rhs.issue.number
        }
    }

    var body: some View {
        let count = store.projects.count
        let running = store.projects.filter { store.hasRunningAgent($0) }.count
        Text("Pharos — \(count) project\(count == 1 ? "" : "s")" +
             (running > 0 ? " · \(running) running" : ""))
            .foregroundStyle(.secondary)

        Divider()

        projectsMenu
        issuesMenu
        agentsMenu
        roomsMenu

        Divider()

        Button { activateApp(); store.requestPalette() } label: {
            Label("Command Palette…", systemImage: "command")
        }
        .keyboardShortcut("k", modifiers: [.command])

        Button { activateApp(); openSettings() } label: {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button("Quit Pharos") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: [.command])
    }

    private var projectsMenu: some View {
        Menu {
            Button("Open Projects") { navigate(.projects) }
            if !store.projects.isEmpty {
                Divider()
                ForEach(store.projects.sorted { $0.name.lowercased() < $1.name.lowercased() }) { project in
                    Button {
                        activateApp(); store.requestOpenProject(project.id)
                    } label: {
                        let marker = store.hasRunningAgent(project) ? "●  " : ""
                        Text(marker + project.name)
                    }
                }
            }
        } label: {
            Label("Projects", systemImage: "folder")
        }
    }

    private var issuesMenu: some View {
        Menu {
            Button("Open Issues") { navigate(.issues) }
            let issues = openIssues
            if !issues.isEmpty {
                Divider()
                ForEach(issues.prefix(30), id: \.issue.id) { row in
                    Button {
                        activateApp()
                        store.requestOpenIssue(projectID: row.project.id, number: row.issue.number)
                    } label: {
                        Text("\(row.project.name) #\(row.issue.number)  \(row.issue.title)")
                    }
                }
            }
        } label: {
            Label("Issues", systemImage: "checklist")
        }
    }

    private var agentsMenu: some View {
        Menu {
            Button("Open Agents") { navigate(.agents) }
            let roster = store.meshRoster
            if !roster.isEmpty {
                Divider()
                ForEach(roster) { agent in
                    Button {
                        activateApp()
                        if let room = agent.rooms.first { store.requestOpenRoom(room) }
                        else { store.requestMenuNav(.agents) }
                    } label: {
                        Text("@\(agent.nick)" + (agent.rooms.first.map { " · \($0)" } ?? ""))
                    }
                }
            }
        } label: {
            Label("Agents", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    private var roomsMenu: some View {
        Menu {
            Button("Open Chat Rooms") { navigate(.chatRooms) }
            let rooms = store.meshRoomNames
            if !rooms.isEmpty {
                Divider()
                ForEach(rooms, id: \.self) { room in
                    Button { activateApp(); store.requestOpenRoom(room) } label: {
                        Label(room, systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        } label: {
            Label("Chat Rooms", systemImage: "bubble.left.and.bubble.right")
        }
    }

    private func navigate(_ target: MenuNavTarget) {
        activateApp()
        store.requestMenuNav(target)
    }

    private func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows
            .first { $0.canBecomeMain && $0.level == .normal }?
            .makeKeyAndOrderFront(nil)
    }
}
