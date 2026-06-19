import SwiftUI

/// Content of the Pharos menu-bar extra (`.menu` style).
struct MenuBarView: View {
    let store: ProjectStore

    var body: some View {
        // Header
        let count = store.projects.count
        let running = store.projects.filter { store.hasRunningAgent($0) }.count

        Text("Pharos — \(count) project\(count == 1 ? "" : "s")" +
             (running > 0 ? " · \(running) running" : ""))
            .foregroundStyle(.secondary)

        Divider()

        // Project list — sorted alphabetically (mirrors visibleProjects when selection == .all)
        let sorted = store.projects.sorted { $0.name.lowercased() < $1.name.lowercased() }
        ForEach(sorted) { project in
            Menu {
                let disabled = !project.hasLocal

                Button {
                    LaunchService.launchAgent(.claude, project: project, terminal: store.terminal)
                } label: {
                    Label(AgentKind.claude.label, systemImage: AgentKind.claude.symbol)
                }
                .disabled(disabled)

                Button {
                    LaunchService.launchAgent(.codex, project: project, terminal: store.terminal)
                } label: {
                    Label(AgentKind.codex.label, systemImage: AgentKind.codex.symbol)
                }
                .disabled(disabled)

                Divider()

                Button {
                    if let path = project.localPath { LaunchService.openTerminal(at: path, terminal: store.terminal) }
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .disabled(disabled)

                Button {
                    if let path = project.localPath { LaunchService.revealInFinder(path) }
                } label: {
                    Label("Finder", systemImage: "folder")
                }
                .disabled(disabled)

            } label: {
                let marker = store.hasRunningAgent(project) ? "●  " : ""
                Text(marker + project.name)
            }
        }

        Divider()

        Button("Command Palette…") { store.requestPalette() }
            .keyboardShortcut("k", modifiers: [.command])

        Button("Add Project…") { store.requestAdd() }

        Divider()

        Button("Quit Pharos") { NSApplication.shared.terminate(nil) }
    }
}
