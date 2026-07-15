import SwiftUI

/// Shared presentation for a mesh agent's live session state.
enum AgentStatus {
    static func color(_ raw: String?) -> Color {
        switch raw.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy:            return .orange
        case .blocked:         return .red
        case .stopped, .idle:  return .green
        case .gone:            return .gray.opacity(0.4)
        case nil:              return .gray
        }
    }

    static func label(_ raw: String?) -> String {
        switch raw.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy:     return "working"
        case .blocked:  return "waiting on human"
        case .stopped:  return "idle"
        case .idle:     return "idle"
        case .gone:     return "ended"
        case nil:       return raw ?? "unknown"
        }
    }

    static func icon(_ kind: String?) -> String {
        kind == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkles"
    }
}

/// Live roster of every agent across every machine on the mesh — the "see other
/// ends' agents" panel. Backed by the same `who` poll that drives the chat.
struct AgentsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationStack {
            List {
                ForEach(agents) { member in
                    NavigationLink { AgentDetailView(member: member) } label: { AgentRow(member: member) }
                }
            }
            .overlay {
                if agents.isEmpty {
                    ContentUnavailableView("No agents online", systemImage: "cpu",
                        description: Text(store.error ?? "Connect to your Mesh in Settings to see agents across all your machines."))
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(agents.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private var agents: [MeshMember] {
        store.members.values
            .filter { $0.nick != "human" }
            .sorted { ($0.host ?? "", $0.nick) < ($1.host ?? "", $1.nick) }
    }
}

private struct AgentRow: View {
    let member: MeshMember

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: AgentStatus.icon(member.kind))
                .foregroundStyle(.tint).font(.title3).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(AgentStatus.color(member.state)).frame(width: 9, height: 9)
                    Text(member.nick).font(.headline)
                    Text(AgentStatus.label(member.state)).font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if !member.rooms.isEmpty {
                    Text(member.rooms.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if let unread = member.unread, unread > 0 {
                Text("\(unread)").font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.red, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var bits: [String] = []
        if let host = member.host, !host.isEmpty { bits.append(host) }
        if let project = member.project, !project.isEmpty {
            bits.append((project as NSString).abbreviatingWithTildeInPath)
        }
        if let pane = member.tmuxPane, !pane.isEmpty { bits.append(pane) }
        return bits.isEmpty ? "no location reported" : bits.joined(separator: " · ")
    }
}

private struct AgentDetailView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let member: MeshMember
    @State private var terminal: TerminalTarget?

    var body: some View {
        List {
            Section {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(AgentStatus.color(member.state)).frame(width: 9, height: 9)
                        Text(AgentStatus.label(member.state))
                    }
                }
                LabeledContent("Agent", value: (member.kind ?? "claude").capitalized)
                if let host = member.host { LabeledContent("Host", value: host) }
                if let ip = member.tailscaleIP { LabeledContent("Tailscale IP", value: ip) }
                if let project = member.project { LabeledContent("Directory", value: (project as NSString).abbreviatingWithTildeInPath) }
                if let pane = member.tmuxPane { LabeledContent("tmux pane", value: pane) }
                if !member.rooms.isEmpty { LabeledContent("Rooms", value: member.rooms.joined(separator: ", ")) }
                LabeledContent("Session", value: String(member.id.prefix(8)))
            }

            if let profile = sshProfile {
                Section {
                    Button {
                        terminal = TerminalTarget(member: member, profile: profile)
                    } label: {
                        Label("Remote Control (SSH → tmux attach)", systemImage: "terminal")
                    }
                    .disabled(member.tmuxPane == nil)
                } footer: {
                    Text(member.tmuxPane == nil
                         ? "This agent didn't report a tmux pane, so it can't be attached."
                         : "Opens an SSH terminal on \(profile.username)@\(profile.sshHost) and attaches its tmux pane.")
                }
            } else {
                Section {
                    Label("Add an SSH host mapping for \(member.host ?? "this host") in Settings to enable Remote Control.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("@\(member.nick)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $terminal) { RemoteTerminalView(target: $0) }
    }

    private var sshProfile: SSHHostProfile? {
        guard let profile = settings.sshHost(for: member.host),
              profile.identityID != nil, profile.acceptsUnverifiedHostKey else { return nil }
        return profile
    }
}
