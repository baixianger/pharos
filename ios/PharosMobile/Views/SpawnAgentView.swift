import SwiftUI

struct SpawnAgentView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let room: String
    @State private var nick = ""
    @State private var kind = MobileAgentKind.claude
    @State private var hostID: UUID?
    @State private var isSpawning = false
    @State private var result: String?
    @State private var error: String?
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
                            Text("\(profile.username)@\(profile.sshHost)").tag(Optional(profile.id))
                        }
                    }
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
        }
    }

    private var eligibleHosts: [SSHHostProfile] {
        settings.sshHosts.filter { $0.acceptsUnverifiedHostKey && $0.identityID != nil }
    }

    private var canSpawn: Bool {
        hostID != nil && !nick.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                             kind: kind, profile: profile, privateKey: key)
            await store.refreshAfterRemoteAction()
        } catch { self.error = error.localizedDescription }
    }
}
