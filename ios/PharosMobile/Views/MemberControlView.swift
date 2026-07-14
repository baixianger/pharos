import SwiftUI

struct MemberControlView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RoomStore.self) private var store
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss
    let room: String
    @State private var candidate: TerminalTarget?
    @State private var terminal: TerminalTarget?

    var body: some View {
        NavigationStack {
            List(members) { member in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("@\(member.nick)", systemImage: "person.crop.circle")
                            .font(.headline)
                        Spacer()
                        Text(member.state ?? "unknown").foregroundStyle(.secondary)
                    }
                    LabeledContent("Host", value: member.host ?? "Not reported")
                    LabeledContent("tmux pane", value: member.tmuxPane ?? "Not reported")
                    if let profile = settings.sshHost(for: member.host), canConnect(profile: profile, member: member) {
                        Button("Open remote terminal", systemImage: "terminal") {
                            candidate = TerminalTarget(member: member, profile: profile)
                        }
                    } else {
                        Label(connectionHint(for: member), systemImage: "lock.trianglebadge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Remote control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay {
                if members.isEmpty {
                    ContentUnavailableView("No active members", systemImage: "person.2.slash",
                                           description: Text("No agents currently report membership in \(room)."))
                }
            }
        }
        .confirmationDialog("Attach to @\(candidate?.member.nick ?? "member")?",
                            isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } }),
                            titleVisibility: .visible) {
            Button("Connect & attach") { terminal = candidate; candidate = nil }
            Button("Cancel", role: .cancel) { candidate = nil }
        } message: {
            if let candidate {
                Text("SSH to \(candidate.profile.username)@\(candidate.profile.sshHost), resolve pane \(candidate.member.tmuxPane ?? "unknown"), and attach its exact tmux session. Close the terminal to disconnect.")
            }
        }
        .fullScreenCover(item: $terminal) { RemoteTerminalView(target: $0) }
    }

    private var members: [MeshMember] {
        store.members.values.filter { $0.rooms.contains(room) && $0.nick != "human" }.sorted { $0.nick < $1.nick }
    }

    private func canConnect(profile: SSHHostProfile, member: MeshMember) -> Bool {
        profile.acceptsUnverifiedHostKey && profile.identityID.flatMap { id in identities.identities.first { $0.id == id } } != nil
            && member.tmuxPane != nil
    }

    private func connectionHint(for member: MeshMember) -> String {
        guard member.tmuxPane != nil else { return "Member did not report a tmux pane" }
        guard let profile = settings.sshHost(for: member.host) else { return "Add an SSH mapping for this host in Settings" }
        guard profile.acceptsUnverifiedHostKey else { return "Confirm this host's key policy in Settings" }
        return "Choose a device-local SSH identity in Settings"
    }
}
