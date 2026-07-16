import SwiftUI

struct SpawnAgentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let room: String
    private enum SpawnDirChoice: Hashable { case scratch, project(String), custom }
    @State private var nick = ""
    @State private var kind = MobileAgentKind.claude
    @State private var hostID: UUID?
    @State private var isSpawning = false
    @State private var result: String?
    @State private var error: String?
    @State private var dirChoice: SpawnDirChoice = .scratch
    @State private var customPath = ""
    @State private var projects: [RemoteProject] = []
    @State private var loadingProjects = false
    @State private var projectsError: String?
    private let service = RemoteAgentService()

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
                    Picker("Run on", selection: $hostID) {
                        Text("Choose a host").tag(UUID?.none)
                        ForEach(eligibleHosts) { profile in
                            Text("\(profile.displayName) · \(profile.username)@\(profile.sshHost)")
                                .tag(Optional(profile.id))
                        }
                    }
                }

                Section {
                    Picker("Directory", selection: $dirChoice) {
                        Text("Scratch (default)").tag(SpawnDirChoice.scratch)
                        ForEach(projects) { Text($0.name).tag(SpawnDirChoice.project($0.name)) }
                        Text("Custom path…").tag(SpawnDirChoice.custom)
                    }
                    if dirChoice == .custom {
                        TextField("/absolute/path/on/host", text: $customPath)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                    .disabled(hostID == nil || loadingProjects)
                    if let projectsError {
                        Label(projectsError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Working directory")
                } footer: {
                    Text("Scratch is a neutral per-agent folder. Pick a registered project (loaded from the host) or type any absolute path to start the agent there.")
                }

                Section {
                    Label("The selected host runs its installed `pharos mesh spawn` workflow.", systemImage: "arrow.triangle.branch")
                    Label("The new agent gets a dedicated tmux session and the desktop workflow's approval-bypass flags.", systemImage: "exclamationmark.shield")
                } header: { Text("Before spawning") }
                footer: { Text("This is a live remote action. Pharos waits for the agent to announce that it joined before reporting success.") }

                if let result {
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
                        .disabled(!canSpawn || isSpawning)
                }
            }
            .interactiveDismissDisabled(isSpawning)
            .onAppear { if hostID == nil { hostID = eligibleHosts.first?.id } }
            .onChange(of: hostID) {
                dirChoice = .scratch; customPath = ""; projects = []; projectsError = nil
            }
        }
    }

    private var eligibleHosts: [SSHHostProfile] {
        settings.sshHosts.filter { $0.acceptsUnverifiedHostKey && $0.identityID != nil }
    }

    private var canSpawn: Bool {
        hostID != nil && !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var workDir: SpawnWorkDir {
        switch dirChoice {
        case .scratch: return .scratch
        case .project(let name): return .project(name)
        case .custom:
            let p = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return p.isEmpty ? .scratch : .path(p)
        }
    }

    private func loadProjects() async {
        guard let profile = eligibleHosts.first(where: { $0.id == hostID }),
              let identityID = profile.identityID else { return }
        loadingProjects = true
        projectsError = nil
        defer { loadingProjects = false }
        do {
            let key = try identities.privateKey(for: identityID)
            let fetched = try await service.listProjects(profile: profile, privateKey: key)
            projects = fetched
            if fetched.isEmpty { projectsError = "No projects registered on this host." }
        } catch { projectsError = error.localizedDescription }
    }

    private func spawn() async {
        guard let profile = eligibleHosts.first(where: { $0.id == hostID }),
              let identityID = profile.identityID else { return }
        isSpawning = true
        error = nil
        result = nil
        defer { isSpawning = false }
        do {
            let key = try identities.privateKey(for: identityID)
            result = try await service.spawn(room: room, nick: nick.trimmingCharacters(in: .whitespacesAndNewlines),
                                             kind: kind, profile: profile, privateKey: key, workDir: workDir)
            await store.refreshAfterRemoteAction()
        } catch { self.error = error.localizedDescription }
    }
}
