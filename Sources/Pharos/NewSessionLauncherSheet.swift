import SwiftUI

struct NewSessionLauncherSheet: View {
    enum Mode: String, CaseIterable, Identifiable { case new = "New", history = "History"; var id: String { rawValue } }

    @Environment(ProjectStore.self) private var store
    @Binding var isPresented: Bool
    @Binding var selectedProject: Project.ID?
    @Binding var surface: WorkspaceSurface
    @State private var mode: Mode = .new
    @AppStorage("pharos.newSession.lastAgent") private var agent: AgentKind = .codex
    @State private var projectID: Project.ID?
    @State private var launchOptionID: String?

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
                Text("Agent platform").font(.headline)
                HStack(spacing: 10) {
                    ForEach(AgentKind.allCases) { kind in
                        let selected = agent == kind
                        Button { agent = kind } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: symbol(kind))
                                        .font(.system(size: 20, weight: .medium))
                                        .foregroundStyle(selected ? PharosTheme.accent : .secondary)
                                    Spacer()
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(PharosTheme.accent)
                                    }
                                }
                                Text(kind.label).font(.system(size: 14, weight: .semibold))
                                Text(subtitle(kind)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
                            .padding(12)
                            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(PharosTheme.accent.opacity(0.6), lineWidth: 1.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if mode == .new && !agent.launchOptions.isEmpty {
                Text("Mode").font(.headline)
                HStack(spacing: 8) {
                    ForEach(agent.launchOptions) { option in
                        let selected = launchOptionID == option.id
                        Button { launchOptionID = option.id } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.label).font(.system(size: 12, weight: .semibold))
                                Text(option.detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(selected ? PharosTheme.selection : Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(PharosTheme.accent.opacity(0.5), lineWidth: 1)
                                }
                            }
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
        .onAppear {
            projectID = selectedProject ?? store.projects.first?.id
            launchOptionID = agent.launchOptions.first?.id
        }
        .onChange(of: agent) { _, newAgent in
            launchOptionID = newAgent.launchOptions.first?.id
        }
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
        let modeExtra = agent.launchOptions.first { $0.id == launchOptionID }?.extraArgs ?? ""
        let combinedExtra = [store.agentArgs(for: agent), modeExtra]
            .filter { !$0.isEmpty }.joined(separator: " ")
        Task {
            // Driver-consumed launch modes (e.g. DSH presets) are queued through
            // the runtime RPC so the selected mode actually takes effect; the
            // terminal launch below still opens the surface that hosts the driver.
            if agent.launchesViaRuntime {
                LaunchService.submitRuntimeLaunch(kind: agent, modeID: launchOptionID, project: project)
            }
            await LaunchService.launchAgent(agent, project: project, terminal: store.terminal,
                                            extraArgs: combinedExtra)
            store.refreshRunningAgents()
        }
    }

    private func symbol(_ kind: AgentKind) -> String {
        switch kind { case .claude: "sparkles"; case .codex: "terminal"; case .dsh: "point.3.connected.trianglepath.dotted" }
    }

    private func subtitle(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: "Anthropic"
        case .codex:  "OpenAI"
        case .dsh:    "DeepSeek"
        }
    }

    private func projectColor(_ project: Project) -> Color {
        let bytes = project.id.uuidString.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fffffff }
        return Color(hue: Double(bytes % 360) / 360, saturation: 0.58, brightness: 0.82)
    }
}
