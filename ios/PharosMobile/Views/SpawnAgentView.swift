import SwiftUI

struct SpawnAgentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let room: String
    private enum SpawnDirChoice: Hashable { case scratch, project(String) }
    @State private var nick = ""
    @State private var kind = MobileAgentKind.claude
    @State private var nodeID: String?
    @State private var isSpawning = false
    @State private var succeeded = false
    @State private var result: String?
    @State private var error: String?
    @State private var dirChoice: SpawnDirChoice = .scratch
    @State private var projects: [RemoteProject] = []
    @State private var loadingProjects = false
    @State private var projectsError: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    LabeledContent("Room", value: room)
                    TextField("Member nick", text: $nick)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Agent", selection: $kind) {
                        ForEach(MobileAgentKind.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Run on", selection: $nodeID) {
                        Text("Choose a host").tag(String?.none)
                        ForEach(store.nodes) { node in
                            Text("\(node.host) · \(node.tailscaleIP ?? "no Tailscale IP")")
                                .tag(Optional(node.id))
                        }
                    }
                }

                Section {
                    Picker("Directory", selection: $dirChoice) {
                        Text("Scratch (default)").tag(SpawnDirChoice.scratch)
                        ForEach(projects) { Text($0.name).tag(SpawnDirChoice.project($0.name)) }
                    }
                    Button {
                        Task { await loadProjects() }
                    } label: {
                        HStack {
                            Label(loadingProjects ? "Loading projects…" : "Load projects from host",
                                  systemImage: "arrow.down.circle")
                            if loadingProjects { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(nodeID == nil || loadingProjects)
                    if let projectsError {
                        Label(projectsError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Working directory")
                } footer: {
                    Text("Scratch or a project registered on the selected Host node. Filesystem paths stay Host-local and are not sent through the Broker.")
                }

                Section {
                    Label("The selected Host node runs the spawn command from the central Broker queue.", systemImage: "arrow.triangle.branch")
                    Label("The new agent gets a dedicated tmux session and the desktop workflow's approval-bypass flags.", systemImage: "exclamationmark.shield")
                } header: { Text("Before spawning") }
                footer: { Text("This is a live remote action. Pharos waits for the agent to announce that it joined before reporting success.") }

                if succeeded {
                    Section {
                        Label("@\(nick.trimmingCharacters(in: .whitespacesAndNewlines)) joined #\(room)",
                              systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } footer: {
                        Text("Closing…")
                    }
                } else if let result {
                    Section("Result") { Text(result).font(.caption.monospaced()).textSelection(.enabled) }
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
            }
            .pharosPlainList()
            .navigationTitle("Spawn member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSpawning) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSpawning ? "Spawning…" : "Spawn") { Task { await spawn() } }
                        .disabled(!canSpawn || isSpawning || succeeded)
                }
            }
            .interactiveDismissDisabled(isSpawning)
            .task {
                if store.nodes.isEmpty { await store.refresh() }
                if nodeID == nil { nodeID = store.nodes.first?.id }
            }
            .onChange(of: nodeID) {
                dirChoice = .scratch; projects = []; projectsError = nil
            }
        }
    }

    private var canSpawn: Bool {
        nodeID != nil && !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workDir: SpawnWorkDir {
        switch dirChoice {
        case .scratch: return .scratch
        case .project(let name): return .project(name)
        }
    }

    private func loadProjects() async {
        guard nodeID != nil else { return }
        loadingProjects = true
        projectsError = nil
        defer { loadingProjects = false }
        let fetched = await store.fetchProjectsOverMesh() ?? []
        projects = fetched
        if fetched.isEmpty { projectsError = "No projects registered on this Broker." }
    }

    private func spawn() async {
        guard let nodeID, !nodeID.isEmpty else { return }
        isSpawning = true
        error = nil
        result = nil
        do {
            let projectID: String
            switch dirChoice {
            case .scratch: projectID = "__scratch__"
            case .project(let name):
                guard let project = projects.first(where: { $0.name == name }),
                      let id = project.projectID, !id.isEmpty else {
                    throw RemoteActionError.spawnNotConfirmed("The selected project has no Broker project ID.")
                }
                projectID = id
            }
            result = try await store.spawnAgent(room: room,
                                                nick: nick.trimmingCharacters(in: .whitespacesAndNewlines),
                                                kind: kind, nodeID: nodeID, projectID: projectID)
            isSpawning = false
            succeeded = true
            // Give the confirmation a beat to register, then close automatically.
            try? await Task.sleep(for: .seconds(1.3))
            dismiss()
        } catch {
            self.error = error.localizedDescription
            isSpawning = false
        }
    }
}
