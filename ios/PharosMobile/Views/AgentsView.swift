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
    @State private var filter: AgentFilter = .live

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PharosFilterStrip(options: AgentFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                        .padding(.vertical, 4)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                }
                ForEach(grouped, id: \.host) { group in
                    Section {
                        ForEach(group.members) { member in
                            NavigationLink { AgentDetailView(member: member) } label: { AgentRow(member: member) }
                                .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                                                    bottom: 0, trailing: PharosDesign.pageInset))
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        PharosSectionTitle(title: group.host, count: group.members.count)
                    }
                }
            }
            .pharosPlainList()
            .overlay {
                if agents.isEmpty {
                    ContentUnavailableView {
                        Label(store.error == nil ? "No agents here" : "Agents unavailable",
                              systemImage: store.error == nil ? "terminal" : "exclamationmark.triangle")
                    } description: {
                        Text(store.error ?? "Agents appear when they join a Mesh room.")
                    } actions: {
                        if store.error != nil { Button("Try again") { Task { await store.refresh() } } }
                    }
                }
            }
            .navigationTitle("Agents")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(AgentFilter.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Agent display options")
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private var agents: [MeshMember] {
        store.members.values
            .filter { $0.nick != "human" }
            .filter { member in
                let isLive = member.state.flatMap(MeshSessionState.init(rawValue:)) != .gone
                return switch filter {
                case .live: isLive
                case .all: true
                case .ended: !isLive
                }
            }
            .sorted { ($0.host ?? "", $0.nick) < ($1.host ?? "", $1.nick) }
    }

    private var grouped: [(host: String, members: [MeshMember])] {
        Dictionary(grouping: agents) { member in
            guard let host = member.host, !host.isEmpty else { return "Unknown host" }
            return host
        }
        .map { ($0.key, $0.value) }
        .sorted { $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending }
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case live, all, ended
    var id: String { rawValue }
    var title: String {
        switch self {
        case .live: "Live"
        case .all: "All agents"
        case .ended: "Ended"
        }
    }
}

struct AgentRow: View {
    let member: MeshMember

    var body: some View {
        HStack(spacing: 12) {
            ChatAvatar(name: member.nick, member: member, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(member.nick).font(.body.weight(.semibold))
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
        .padding(.vertical, PharosDesign.rowVerticalPadding)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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

struct AgentDetailView: View {
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
        .pharosPlainList()
        .navigationTitle("@\(member.nick)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(item: $terminal) { RemoteTerminalView(target: $0) }
    }

    private var sshProfile: SSHHostProfile? {
        guard let profile = settings.sshHost(for: member.host),
              profile.identityID != nil, profile.acceptsUnverifiedHostKey else { return nil }
        return profile
    }
}
