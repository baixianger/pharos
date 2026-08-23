import SwiftUI

struct NewSessionLauncherSheet: View {
    enum Mode: String, CaseIterable, Identifiable { case new = "New", history = "History"; var id: String { rawValue } }

    @Environment(ProjectStore.self) private var store
    @Binding var isPresented: Bool
    @Binding var selectedProject: Project.ID?
    @Binding var surface: WorkspaceSurface
    @State private var mode: Mode = .new
    @State private var agent: AgentKind = .codex
    @State private var projectID: Project.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("New Session").font(.title2.weight(.semibold))
                    Text("One Pharos session, backed by the agent you choose.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }.buttonStyle(.plain)
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if mode == .new {
                Text("Agent").font(.headline)
                HStack(spacing: 10) {
                    ForEach(AgentKind.allCases) { kind in
                        Button { agent = kind } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: symbol(kind)).font(.title3)
                                Text(kind.label).font(.system(size: 12, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                            .padding(12)
                            .background(agent == kind ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.045),
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text("Project").font(.headline)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.projects) { project in
                        Button { projectID = project.id } label: {
                            HStack(spacing: 10) {
                                Circle().fill(projectColor(project)).frame(width: 9, height: 9)
                                Text(project.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                if projectID == project.id { Image(systemName: "checkmark") }
                            }
                            .padding(.horizontal, 11).frame(height: 38)
                            .background(projectID == project.id ? Color.primary.opacity(0.075) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 184)

            HStack {
                if mode == .history {
                    Text("History opens in the unified Sessions browser.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(mode == .new ? "Start Session" : "Browse History") { commit() }
                    .buttonStyle(.glassProminent)
                    .disabled(mode == .new && projectID == nil)
            }
        }
        .padding(24)
        .frame(width: 540, height: 520)
        .onAppear { projectID = selectedProject ?? store.projects.first?.id }
    }

    private func commit() {
        if mode == .history {
            selectedProject = nil
            surface = .sessions
            isPresented = false
            return
        }
        guard let projectID, let project = store.project(projectID) else { return }
        selectedProject = project.id
        surface = .sessions
        isPresented = false
        Task {
            await LaunchService.launchAgent(agent, project: project, terminal: store.terminal,
                                            extraArgs: store.agentArgs(for: agent))
            store.refreshRunningAgents()
        }
    }

    private func symbol(_ kind: AgentKind) -> String {
        switch kind { case .claude: "sparkles"; case .codex: "terminal"; case .dsh: "point.3.connected.trianglepath.dotted" }
    }

    private func projectColor(_ project: Project) -> Color {
        let bytes = project.id.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return Color(hue: Double(bytes % 360) / 360, saturation: 0.58, brightness: 0.82)
    }
}
