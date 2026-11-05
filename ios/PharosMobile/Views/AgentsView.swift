import PharosMeshControl
import SwiftUI

/// Shared presentation for an agent conversation's current runtime state.
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

    static func reason(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw == "permission" { return "Permission required" }
        if raw.hasPrefix("permission:") {
            return "Permission required · " + String(raw.dropFirst("permission:".count))
        }
        if raw == "elicitation" { return "Waiting for form response" }
        if raw.hasPrefix("api_error:") {
            return "API error · " + String(raw.dropFirst("api_error:".count))
        }
        return raw
    }
}

enum MobileSessionOwnership: String {
    case attached = "ATTACHED"
    case external = "EXTERNAL"

    static func classify(_ member: MeshMember) -> Self {
        guard member.session?.isEmpty == false, member.kind?.isEmpty == false else { return .external }
        return .attached
    }

    var color: Color { self == .attached ? .blue : .orange }
}

/// Compatibility Session surface backed by the Broker roster. RFC-003's remote
/// Runtime gateway will add Managed conversations and archives to this view;
/// current records are truthfully labelled Attached or External.
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
                        // A lone host header just repeats itself; only label the
                        // split when agents actually span more than one host.
                        if grouped.count > 1 {
                            PharosSectionTitle(title: group.host, count: group.members.count)
                        }
                    }
                }
            }
            .pharosPlainList()
            .overlay {
                if agents.isEmpty {
                    ContentUnavailableView {
                        Label(store.error == nil ? "No sessions here" : "Sessions unavailable",
                              systemImage: store.error == nil ? "terminal" : "exclamationmark.triangle")
                    } description: {
                        Text(store.error ?? "Attached sessions appear after they register with the Broker.")
                    } actions: {
                        if store.error != nil { Button("Try again") { Task { await store.refresh() } } }
                    }
                }
            }
            .navigationTitle("Sessions")
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
                    .accessibilityLabel("Session display options")
                }
            }
            .refreshable { await store.refresh() }
        }
    }

    private var agents: [MeshMember] {
        store.members.values
            .filter { $0.nick != "human" }
            .filter { member in
                // A roster record is actionable only when a real host Node is
                // online. Legacy/imported records can have a non-gone state
                // while having no live tmux owner at all.
                let isLive = member.nodeOnline == true
                    && member.state.flatMap(MeshSessionState.init(rawValue:)) != .gone
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
        case .all: "All sessions"
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
                    sessionBadge
                    Text(AgentStatus.label(member.state)).font(.caption).foregroundStyle(.secondary)
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let reason = AgentStatus.reason(member.stateReason) {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
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
        if member.tmuxPane?.isEmpty == false { bits.append("tmux fallback") }
        return bits.isEmpty ? "no location reported" : bits.joined(separator: " · ")
    }

    private var sessionBadge: some View {
        let ownership = MobileSessionOwnership.classify(member)
        return Text(ownership.rawValue)
            .font(.system(size: 8, weight: .bold)).tracking(0.5)
            .foregroundStyle(ownership.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(ownership.color.opacity(0.1), in: Capsule())
    }
}

struct AgentDetailView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    let member: MeshMember
    @State private var terminal: TerminalTarget?
    @State private var showingStopConfirm = false
    @State private var showingRemoveConfirm = false
    @State private var isStopping = false
    @State private var isRemoving = false
    @State private var distributedHost: DistributedAgentHostLocation?
    @State private var hostLookupError: String?
    @State private var isLocatingHost = false

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Ownership", value: MobileSessionOwnership.classify(member).rawValue.capitalized)
                LabeledContent("Delivery endpoint", value: String(member.id.prefix(8)))
                if let session = member.session, !session.isEmpty {
                    LabeledContent("Vendor session", value: String(session.prefix(12)))
                }
                LabeledContent("Runtime control", value: "Broker compatibility path")
            }

            Section {
                LabeledContent("State") {
                    HStack(spacing: 6) {
                        Circle().fill(AgentStatus.color(member.state)).frame(width: 9, height: 9)
                        Text(AgentStatus.label(member.state))
                    }
                }
                LabeledContent("Agent", value: (member.kind ?? "claude").capitalized)
                if let reason = AgentStatus.reason(member.stateReason) {
                    LabeledContent("Attention", value: reason)
                }
                if let host = member.host { LabeledContent("Host", value: host) }
                if let ip = member.tailscaleIP { LabeledContent("Tailscale IP", value: ip) }
                if let project = member.project { LabeledContent("Directory", value: (project as NSString).abbreviatingWithTildeInPath) }
                if let pane = member.tmuxPane { LabeledContent("Fallback transport", value: "tmux \(pane)") }
                if !member.rooms.isEmpty { LabeledContent("Rooms", value: member.rooms.joined(separator: ", ")) }
            }

            if PharosMeshRuntimeMode.usesDistributedMesh {
                distributedAttachSection
            } else if let profile = sshProfile {
                Section {
                    Button {
                        terminal = TerminalTarget(member: member, profile: profile)
                    } label: {
                        Label("Legacy terminal attach", systemImage: "terminal")
                    }
                    .disabled(member.tmuxPane == nil)
                } footer: {
                    Text(member.tmuxPane == nil
                         ? "This agent didn't report a tmux pane, so it can't be attached."
                         : "External fallback: opens SSH to \(profile.username)@\(profile.sshHost) and attaches its tmux pane. This is not a Runtime surface attachment.")
                }
            } else {
                Section {
                    Label("Add an SSH host mapping for \(member.host ?? "this host") in Settings to enable Remote Control.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }

            AgentLifecycleControls(
                isGone: (member.state ?? "").lowercased() == "gone",
                usesDistributedMesh: PharosMeshRuntimeMode.usesDistributedMesh,
                hostName: member.host ?? "the agent's host",
                controlReadiness: distributedHost?.controlReadiness,
                isLocatingHost: isLocatingHost,
                isStopping: isStopping,
                isRemoving: isRemoving,
                onStop: { showingStopConfirm = true },
                onRemove: { showingRemoveConfirm = true }
            )
        }
        .pharosPlainList()
        .navigationTitle("@\(member.nick)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .fullScreenCover(item: $terminal) { RemoteTerminalView(target: $0) }
        .task(id: member.id) {
            guard PharosMeshRuntimeMode.usesDistributedMesh else { return }
            isLocatingHost = true
            defer { isLocatingHost = false }
            do {
                distributedHost = try await store.locateAgentHost(memberID: member.id)
                hostLookupError = nil
            } catch {
                distributedHost = nil
                hostLookupError = error.localizedDescription
            }
        }
        .confirmationDialog("Stop @\(member.nick)?", isPresented: $showingStopConfirm, titleVisibility: .visible) {
            Button("Stop agent", role: .destructive) {
                isStopping = true
                Task {
                    _ = await store.stopAgent(member)
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the legacy tmux runtime on its host. It does not delete vendor conversation history.")
        }
        .confirmationDialog(
            "Remove @\(member.nick) from Mesh?",
            isPresented: $showingRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove from Mesh", role: .destructive) {
                isRemoving = true
                Task {
                    _ = await store.removeAgentFromMesh(member)
                    isRemoving = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the agent from every chat room but does not stop its process on the Host.")
        }
    }

    private var sshProfile: SSHHostProfile? {
        guard let profile = settings.sshHost(for: member),
              profile.identityID != nil, profile.acceptsUnverifiedHostKey else { return nil }
        return profile
    }

    @ViewBuilder
    private var distributedAttachSection: some View {
        if let host = distributedHost,
           host.controlReadiness == .managed,
           let profile = settings.sshHost(
               forDeviceID: host.deviceID.rawValue.uuidString,
               displayName: host.displayName
           ),
           profile.identityID != nil, profile.acceptsUnverifiedHostKey {
            Section {
                Button {
                    terminal = TerminalTarget(
                        member: member, profile: profile,
                        distributedResourceID: member.id
                    )
                } label: {
                    Label("Remote Control (SSH → tmux attach)", systemImage: "terminal")
                }
            } footer: {
                Text("Connects to \(profile.username)@\(profile.sshHost). The Host resolves resource \(member.id.prefix(8))… to its private tmux binding.")
            }
        } else if isLocatingHost {
            Section { HStack { ProgressView(); Text("Locating owning Host…") } }
        } else {
            Section {
                Label(
                    distributedHost.map {
                        "Add an SSH host mapping for \($0.displayName) in Settings."
                    } ?? "Owning Host is offline or no longer advertises this agent.",
                    systemImage: "info.circle"
                )
                .font(.caption).foregroundStyle(.secondary)
                if let hostLookupError {
                    Text(hostLookupError).font(.caption2).foregroundStyle(.orange)
                }
            } footer: {
                Text("P2P identifies the trusted Host; SSH provides the interactive byte stream. Private tmux socket and session names never leave that Host.")
            }
        }
    }
}

private struct AgentLifecycleControls: View {
    let isGone: Bool
    let usesDistributedMesh: Bool
    let hostName: String
    let controlReadiness: DistributedAgentHostControlReadiness?
    let isLocatingHost: Bool
    let isStopping: Bool
    let isRemoving: Bool
    let onStop: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if !isGone {
            Section {
                if canStop {
                    Button(role: .destructive, action: onStop) {
                        HStack {
                            Label("Stop managed agent", systemImage: "stop.circle")
                            if isStopping { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isStopping || isRemoving)
                }
                if usesDistributedMesh {
                    Button(role: .destructive, action: onRemove) {
                        HStack {
                            Label("Remove from Mesh", systemImage: "person.crop.circle.badge.minus")
                            if isRemoving { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isStopping || isRemoving)
                }
            } footer: {
                if usesDistributedMesh {
                    switch controlReadiness {
                    case .managed:
                        Text("Stop sends a signed, generation-bound command to the owning Host. Remove only changes the Mesh roster.")
                    case .unmanaged:
                        Text("This Agent is visible but its Host has not verified a safe tmux binding. Open Pharos on \(hostName) to repair it, or remove only its Mesh roster entry.")
                    case nil:
                        Text(isLocatingHost
                             ? "Checking the owning Host's control capability…"
                             : "The owning Host is unavailable. Removing from Mesh will not stop its process.")
                    }
                } else {
                    Text("Stops the tmux session on \(hostName). The legacy Host node must be online.")
                }
            }
        }
    }

    private var canStop: Bool {
        if !usesDistributedMesh { return true }
        return controlReadiness == .managed
    }
}
