import SwiftUI

/// One entry in the activity feed: an issue (by last update) or a project-log update.
enum ActivityEntry: Identifiable {
    case issue(projectID: Project.ID, projectName: String, issue: Issue)
    case update(projectID: Project.ID, projectName: String, update: ProjectUpdate)

    var id: String {
        switch self {
        case .issue(_, _, let i):  return "i:\(i.id.uuidString)"
        case .update(_, _, let u): return "u:\(u.id.uuidString)"
        }
    }
    var date: Date {
        switch self {
        case .issue(_, _, let i):  return i.updatedAt
        case .update(_, _, let u): return u.createdAt
        }
    }
}

struct DashboardAgentSession: Hashable, Sendable, Identifiable {
    let session: String
    let sshHost: String?
    var id: String { "\(sshHost ?? "local")|\(session)" }

    static func unregistered(running: Set<String>, remoteHosts: [String: String],
                             registered: Set<Self>) -> [Self] {
        running.compactMap { session in
            let value = Self(session: session, sshHost: remoteHosts[session])
            return registered.contains(value) ? nil : value
        }.sorted { $0.id < $1.id }
    }
}

/// The home screen: a cross-project rollup with a group switcher up top, stat
/// cards, and the recent-activity feed at the bottom. Click anything to jump in.
struct DashboardView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(DistributedMeshSupport.self) private var distributedMesh
    @Binding var selectedProject: Project.ID?
    @Binding var openRoom: String?
    /// Menu-bar deep-link: scroll to a section (issues/agents), then self-clear.
    @Binding var focus: DashboardFocus?

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All", issues = "Issues", updates = "Updates"
        var id: String { rawValue }
    }
    @State private var groupFilter: String?           // nil = all groups
    @State private var activityFilter: ActivityFilter = .all
    @State private var meshMessages: [MeshMsg] = []    // recent agent chatter (read from transcripts)
    @State private var agentToStop: StopTarget?
    @State private var meshAgents: [MeshMemberInfo] = []  // live roster across all machines (who)
    @State private var meshAgentSessions: [String: DashboardAgentSession] = [:]
    @State private var meshAgentToStop: MeshMemberInfo?
    @State private var meshAgentToRename: MeshMemberInfo?
    @State private var meshAgentRenameText = ""
    @State private var agentActionError: String?
    private struct StopTarget: Identifiable {
        let session: String; let host: String?; let label: String
        var id: String { session }
    }
    private let meshTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Projects in scope, narrowed by the selected group tab.
    private var projects: [Project] {
        guard let g = groupFilter, store.groups.contains(g) else { return store.projects }
        return store.projects.filter { $0.tags.contains(g) }
    }
    private var allIssues: [(p: Project, i: Issue)] { projects.flatMap { p in p.issues.map { (p, $0) } } }
    private var openIssues: [(p: Project, i: Issue)] { allIssues.filter { $0.i.status.isOpen } }
    private var blocked: [(p: Project, i: Issue)] {
        openIssues.filter { $0.i.relations.contains { $0.kind == .blockedBy } }
    }
    private var urgent: [(p: Project, i: Issue)] { openIssues.filter { $0.i.priority == .urgent } }
    private var activeAgents: [(p: Project, i: Issue)] {
        allIssues.filter { if let s = $0.i.activeSession { return store.allRunningSessions.contains(s) } else { return false } }
    }
    private var agentCount: Int { liveMeshAgents.count + unregisteredSessions.count }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.groups.isEmpty { groupTabs }
                    statTiles
                    statusCard
                        .id(DashboardFocus.issues.rawValue)
                    if !blocked.isEmpty || !urgent.isEmpty { attentionCard }
                    if !activeAgents.isEmpty { issueWorkCard }
                    if agentCount > 0 {
                        DashboardAgentsCard(
                            meshAgents: liveMeshAgents,
                            unregisteredSessions: unregisteredSessions,
                            supportsSignedHostControl: distributedMesh.isProductModeEnabled,
                            onRename: beginRename,
                            onAttachMesh: attachMeshAgent,
                            onStopMesh: { meshAgentToStop = $0 },
                            onAttachSession: attachSession,
                            onStopSession: beginStopSession
                        )
                        .id(DashboardFocus.agents.rawValue)
                    }
                    if !meshMessages.isEmpty { meshCard }
                    if projects.contains(where: { !$0.milestones.isEmpty }) { milestonesCard }
                    activityCard
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focus) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(target.rawValue, anchor: .top)
                }
                focus = nil            // one-shot: don't fight a later manual scroll
            }
        }
        // No `navigationTitle` here: on a freshly created window tab SwiftUI
        // painted it ~7s late. WindowTabBar sets `window.title` via AppKit
        // instead, which draws with the window's first frame.
        .onAppear { loadMesh() }
        .onReceive(meshTick) { _ in loadMesh() }
        .confirmationDialog("Stop agent on \(agentToStop?.label ?? "")?",
                            isPresented: Binding(get: { agentToStop != nil },
                                                 set: { if !$0 { agentToStop = nil } }),
                            titleVisibility: .visible,
                            presenting: agentToStop) { t in
            Button("Stop agent", role: .destructive) { store.stopAgent(session: t.session, host: t.host) }
            Button("Cancel", role: .cancel) {}
        } message: { t in
            Text("Kills its tmux session \(t.host.map { "on \($0)" } ?? "on this Mac"). Unsaved work is lost.")
        }
        .confirmationDialog("Stop @\(meshAgentToStop?.nick ?? "")?",
                            isPresented: Binding(get: { meshAgentToStop != nil },
                                                 set: { if !$0 { meshAgentToStop = nil } }),
                            titleVisibility: .visible,
                            presenting: meshAgentToStop) { m in
            Button("Stop agent", role: .destructive) { stopMeshAgent(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in
            Text("Kills @\(m.nick)'s tmux session \(m.host.map { "on \($0)" } ?? "on this Mac") and removes this session from its chat rooms. Unsaved work is lost.")
        }
        .alert("Rename agent", isPresented: Binding(get: { meshAgentToRename != nil },
                                                     set: { if !$0 { meshAgentToRename = nil } }),
               presenting: meshAgentToRename) { m in
            TextField("Name", text: $meshAgentRenameText)
            Button("Cancel", role: .cancel) { meshAgentToRename = nil }
            Button("Rename") { renameMeshAgent(m) }
        } message: { m in
            Text("The session ID stays \(m.id.prefix(8))…; only its name in \(m.rooms.first ?? "this room") changes.")
        }
        .alert("Agent action failed", isPresented: Binding(get: { agentActionError != nil },
                                                           set: { if !$0 { agentActionError = nil } })) {
            Button("OK", role: .cancel) { agentActionError = nil }
        } message: {
            Text(agentActionError ?? "Unknown error")
        }
    }

    // MARK: Chat rooms (agents talking)

    private var meshCard: some View {
        let rooms = Set(meshMessages.map(\.room)).count
        return card("Chat rooms · \(rooms) active") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(meshMessages.prefix(6).enumerated()), id: \.offset) { _, m in
                    Button { openRoom = m.room } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.tint).font(.caption)
                            Text(m.from).font(.callout.weight(.medium))
                            Text(m.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Text("· \(m.room)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { openRoom = "" } label: {
                    Label("Open chat rooms", systemImage: "arrow.up.forward.app").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.tint).padding(.top, 2)
            }
        }
    }

    // MARK: Mesh agents (all machines · attach / stop)

    private var liveMeshAgents: [MeshMemberInfo] {
        var byID: [String: MeshMemberInfo] = [:]
        for member in meshAgents where member.nick != "human"
            && MeshSessionState(rawValue: member.state ?? "") != .gone {
            if var existing = byID[member.id] {
                existing.rooms = Array(Set(existing.rooms + member.rooms)).sorted()
                if member.lastSeen >= existing.lastSeen {
                    var newest = member
                    newest.rooms = existing.rooms
                    byID[member.id] = newest
                } else {
                    byID[member.id] = existing
                }
            } else {
                byID[member.id] = member
            }
        }
        return byID.values.sorted { ($0.host ?? "", $0.nick) < ($1.host ?? "", $1.nick) }
    }

    private var unregisteredSessions: [DashboardAgentSession] {
        DashboardAgentSession.unregistered(running: store.allRunningSessions,
                                           remoteHosts: store.remoteSessionHosts,
                                           registered: Set(meshAgentSessions.values))
    }

    private func beginRename(_ member: MeshMemberInfo) {
        meshAgentRenameText = member.nick
        meshAgentToRename = member
    }

    private func attachSession(_ session: DashboardAgentSession) {
        let command = RemoteLaunch.interactiveAttachCommand(session: session.session,
                                                             host: session.sshHost)
        LaunchService.openTerminal(command: command, terminal: store.terminal)
    }

    private func beginStopSession(_ session: DashboardAgentSession) {
        agentToStop = StopTarget(session: session.session, host: session.sshHost,
                                 label: session.session)
    }

    private func attachMeshAgent(_ m: MeshMemberInfo) {
        guard let cmd = meshAttachCommand(m) else { return }
        LaunchService.openTerminal(command: cmd, terminal: store.terminal)
    }

    private func stopMeshAgent(_ m: MeshMemberInfo) {
        let registrations = meshAgents.filter { $0.id == m.id }.flatMap { member in
            member.rooms.map { (room: $0, nick: member.nick) }
        }
        if distributedMesh.isProductModeEnabled {
            Task {
                do {
                    try await distributedMesh.stopAgent(memberID: m.id)
                    try await distributedMesh.removeChatMemberFromAllRooms(m.id)
                } catch {
                    agentActionError = error.localizedDescription
                }
                loadMesh()
            }
            return
        }
        if let node = MeshNodeControl.activeNode(for: m.tailscaleIP ?? m.host) {
            Task {
                let command = await MeshNodeControl.stop(node: node, memberID: m.id)
                if command.state == .succeeded {
                    if let error = await removeMeshRegistrations(registrations, memberID: m.id) {
                        agentActionError = error
                    }
                } else {
                    agentActionError = command.result ?? "Node could not stop the agent."
                }
            }
            return
        }
        guard let pane = m.tmuxPane else { return }
        let local = m.host == nil || HostIdentity.isCurrent(host: m.host, tailscaleIP: m.tailscaleIP)
        let host = local ? nil : store.executionHost(forMeshHost: m.host,
                                                     tailscaleIP: m.tailscaleIP)?.sshHost
        guard local || !(host?.isEmpty ?? true) else {
            agentActionError = "No paired Mac SSH host is configured."
            return
        }
        // `who` returns one row per room alias. Closing a session must remove
        // every alias for its immutable id, not only the row the user clicked.
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try RemoteLaunch.kill(pane: pane, host: host, socket: m.tmuxSocket)) }
                catch { return .failure(error) }
            }.value
            switch result {
            case .success:
                if let error = await removeMeshRegistrations(registrations, memberID: m.id) {
                    agentActionError = error
                }
            case .failure(let error):
                // A missing pane on this Mac means the process is already gone;
                // finish the requested close by deleting its stale mesh rows.
                if let remoteError = error as? RemoteLaunch.RemoteError,
                   remoteError.reason == .paneUnavailable {
                    if let cleanupError = await removeMeshRegistrations(registrations, memberID: m.id) {
                        agentActionError = cleanupError
                    }
                } else {
                    agentActionError = error.localizedDescription
                }
            }
            loadMesh()
        }
    }

    private func removeMeshRegistrations(_ registrations: [(room: String, nick: String)],
                                         memberID: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            for registration in registrations {
                let response = MeshClient.send(MeshRequest(cmd: "leave", room: registration.room,
                                                           nick: registration.nick, memberID: memberID))
                if !response.ok { return response.error ?? "Couldn't remove the agent registration." }
            }
            return nil
        }.value
    }

    private func renameMeshAgent(_ m: MeshMemberInfo) {
        let name = meshAgentRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let room = m.rooms.first else { return }
        meshAgentToRename = nil
        Task {
            let response = await Task.detached {
                MeshClient.send(MeshRequest(cmd: "rename-member", room: room, nick: m.nick,
                                            memberID: m.id, text: name))
            }.value
            if !response.ok { agentActionError = response.error ?? "Rename failed" }
            loadMesh()
        }
    }

    /// Shell command to attach `m`'s tmux session, resolving its reported pane
    /// to the session name. Local when the agent is on this Mac; otherwise SSH.
    private func meshAttachCommand(_ m: MeshMemberInfo) -> String? {
        guard let pane = m.tmuxPane, pane.first == "%", pane.dropFirst().allSatisfy(\.isNumber) else { return nil }
        guard m.tmuxSocket == nil || RemoteLaunch.validTmuxSocket(m.tmuxSocket!) else { return nil }
        let local = m.host == nil || HostIdentity.isCurrent(host: m.host, tailscaleIP: m.tailscaleIP)
        if !local, m.tmuxSocket == nil { return nil }
        let socket = m.tmuxSocket.map { " -S '\($0.replacingOccurrences(of: "'", with: "'\\''"))'" } ?? ""
        let action = "exec tmux\(socket) attach -t \"=$s\""
        let inner = RemoteLaunch.terminalSafeRemoteShell(
            "export PATH=\"$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin\"; "
                + "s=$(tmux\(socket) display-message -p -t '\(pane)' '#{session_name}') && \(action)"
        )
        if local { return inner }
        guard let peer = store.executionHost(forMeshHost: m.host,
                                             tailscaleIP: m.tailscaleIP)?.sshHost,
              !peer.isEmpty else { return nil }
        let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "$", with: "\\$")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "ssh -t \(peer) \"\(escaped)\""
    }

    private func loadMesh() {
        if distributedMesh.isProductModeEnabled {
            Task {
                do {
                    let rooms = try await distributedMesh.chatRooms()
                    var messages: [MeshMsg] = []
                    var members: [String: MeshMemberInfo] = [:]
                    for room in rooms {
                        messages.append(contentsOf: try await distributedMesh
                            .chatMessages(in: room, limit: 20))
                        for member in try await distributedMesh.chatMembers(in: room) {
                            if var existing = members[member.id] {
                                existing.rooms = Array(
                                    Set(existing.rooms + [room.name])
                                ).sorted()
                                members[member.id] = existing
                            } else {
                                members[member.id] = MeshMemberInfo(
                                    id: member.id, nick: member.nick,
                                    rooms: [room.name], lastSeen: 0,
                                    nodeOnline: nil
                                )
                            }
                        }
                    }
                    meshMessages = messages.sorted { $0.ts > $1.ts }
                    meshAgents = Array(members.values)
                    // Distributed Host controls bind opaque resource IDs on
                    // the owning device; legacy SSH/tmux discovery is never
                    // used to infer a command route.
                    meshAgentSessions = [:]
                } catch {
                    meshMessages = []
                    meshAgents = []
                    meshAgentSessions = [:]
                }
            }
            return
        }

        // Explicit legacy diagnostic mode reads recent chatter from the Broker.
        // Everything here is off-main; results publish on the main actor.
        let hostProfiles = store.executionHosts
        Task.detached {
            let rooms = (MeshClient.send(MeshRequest(cmd: "list")).rooms ?? []).map(\.name)
            var all: [MeshMsg] = []
            for room in rooms {
                var msgs = MeshClient.send(MeshRequest(cmd: "history", room: room, limit: 20)).messages ?? []
                for i in msgs.indices where msgs[i].room.isEmpty { msgs[i].room = room }
                all.append(contentsOf: msgs)
            }
            let sortedMessages = all.sorted { $0.ts > $1.ts }

            let roster = MeshClient.send(MeshRequest(cmd: "who")).members ?? []
            var resolved: [String: DashboardAgentSession] = [:]
            for member in roster {
                guard let pane = member.tmuxPane else { continue }
                let local = member.host == nil
                    || HostIdentity.isCurrent(host: member.host, tailscaleIP: member.tailscaleIP)
                let sshHost = local ? nil : ExecutionHostProfile.resolve(
                    meshHostID: member.host, tailscaleIP: member.tailscaleIP,
                    in: hostProfiles
                )?.sshHost
                guard local || sshHost != nil else { continue }
                if let session = RemoteLaunch.sessionName(pane: pane, host: sshHost,
                                                          socket: member.tmuxSocket) {
                    resolved[member.id] = DashboardAgentSession(session: session,
                                                                sshHost: sshHost)
                }
            }
            let resolvedSessions = resolved
            await MainActor.run {
                meshMessages = sortedMessages
                meshAgents = roster
                meshAgentSessions = resolvedSessions
            }
        }
    }

    // MARK: Group tabs

    private var groupTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupPill("All Projects", group: nil)
                ForEach(store.groups, id: \.self) { g in groupPill(g, group: g) }
            }
        }
    }

    private func groupPill(_ label: String, group: String?) -> some View {
        let selected = groupFilter == group
        return Button { groupFilter = group } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Tiles

    private var statTiles: some View {
        HStack(spacing: 12) {
            tile("\(projects.count)", "Projects", "square.grid.2x2")
            tile("\(openIssues.count)", "Open issues", "smallcircle.filled.circle")
            tile("\(blocked.count)", "Blocked", "exclamationmark.octagon")
            tile("\(agentCount)", "Agents", "terminal")
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Cards

    @ViewBuilder
    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusCard: some View {
        let counts = Dictionary(grouping: allIssues, by: { $0.i.status }).mapValues(\.count)
        return card("Issues by status") {
            if allIssues.isEmpty {
                Text("No issues yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    ForEach(IssueStatus.allCases) { s in
                        HStack(spacing: 5) {
                            Image(systemName: s.symbol).foregroundStyle(.secondary)
                            Text("\(counts[s] ?? 0)").font(.body.monospacedDigit().weight(.semibold))
                            Text(s.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var attentionCard: some View {
        card("Needs attention") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocked.prefix(6), id: \.i.id) { row in
                    issueRow(row.p, row.i, leading: "exclamationmark.octagon", tint: .orange, note: "blocked")
                }
                ForEach(urgent.filter { u in !blocked.contains { $0.i.id == u.i.id } }.prefix(6), id: \.i.id) { row in
                    issueRow(row.p, row.i, leading: "exclamationmark.triangle.fill", tint: .red, note: "urgent")
                }
            }
        }
    }

    private var issueWorkCard: some View {
        card("Issue work · \(activeAgents.count) active") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(activeAgents.prefix(8), id: \.i.id) { row in
                    HStack(spacing: 8) {
                        Button { open(row.p, row.i) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption)
                                Text("#\(row.i.number) \(row.i.title)").font(.callout).lineLimit(1)
                                Text("· \(row.p.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let session = row.i.activeSession {
                            Button {
                                agentToStop = StopTarget(session: session, host: row.i.activeSessionHost,
                                                         label: "#\(row.i.number)")
                            } label: {
                                Label("Stop", systemImage: "stop.circle").font(.caption2)
                            }
                            .buttonStyle(.borderless).controlSize(.small).tint(.red)
                            .help("Stop this agent")
                        }
                    }
                }
            }
        }
    }

    private var milestonesCard: some View {
        card("Milestones") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(projects) { p in
                    ForEach(p.milestones) { m in
                        let issues = p.issues.filter { $0.milestoneID == m.id }
                        let done = issues.filter { $0.status == .done }.count
                        Button { openProject(p) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "flag").foregroundStyle(.secondary)
                                Text(m.name).font(.callout)
                                Text("· \(p.name)").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if let due = m.due {
                                    Text(due.formatted(.dateTime.month().day()))
                                        .font(.caption2).foregroundStyle(due < Date() ? .red : .secondary)
                                }
                                Text("\(done)/\(issues.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var activityCard: some View {
        let entries = recentActivity().prefix(50)
        return card("Activity") {
            Picker("", selection: $activityFilter) {
                ForEach(ActivityFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize().labelsHidden()

            if entries.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries)) { activityRow($0) }
                }
            }
        }
    }

    // MARK: Rows

    private func issueRow(_ p: Project, _ issue: Issue, leading: String, tint: Color, note: String) -> some View {
        Button { open(p, issue) } label: {
            HStack(spacing: 8) {
                Image(systemName: leading).foregroundStyle(tint).font(.caption)
                Text("#\(issue.number) \(issue.title)").font(.callout).lineLimit(1)
                Text("· \(p.name)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func activityRow(_ entry: ActivityEntry) -> some View {
        switch entry {
        case .issue(let pid, let pname, let issue):
            Button { selectedProject = pid; store.requestIssue(pid, number: issue.number) } label: {
                HStack(spacing: 8) {
                    Image(systemName: issue.status.symbol).foregroundStyle(.secondary).font(.caption)
                    Text("#\(issue.number) \(issue.title)").font(.callout).lineLimit(1)
                    Text("· \(pname)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(issue.updatedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        case .update(let pid, let pname, let update):
            Button { selectedProject = pid } label: {
                HStack(spacing: 8) {
                    Image(systemName: update.kind == .agent ? "sparkles" : "text.bubble")
                        .foregroundStyle(update.kind == .agent ? Color.blue : Color.secondary).font(.caption)
                    Text(update.body).font(.callout).lineLimit(1)
                    Text("· \(pname)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(update.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
    }

    // MARK: Data / nav

    private func recentActivity() -> [ActivityEntry] {
        var out: [ActivityEntry] = []
        for p in projects {
            if activityFilter != .updates {
                for i in p.issues { out.append(.issue(projectID: p.id, projectName: p.name, issue: i)) }
            }
            if activityFilter != .issues {
                for u in p.updates { out.append(.update(projectID: p.id, projectName: p.name, update: u)) }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    private func open(_ p: Project, _ issue: Issue) {
        selectedProject = p.id
        store.requestIssue(p.id, number: issue.number)
    }

    private func openProject(_ p: Project) { selectedProject = p.id }
}

private struct DashboardAgentsCard: View {
    let meshAgents: [MeshMemberInfo]
    let unregisteredSessions: [DashboardAgentSession]
    let supportsSignedHostControl: Bool
    let onRename: (MeshMemberInfo) -> Void
    let onAttachMesh: (MeshMemberInfo) -> Void
    let onStopMesh: (MeshMemberInfo) -> Void
    let onAttachSession: (DashboardAgentSession) -> Void
    let onStopSession: (DashboardAgentSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agents · \(meshAgents.count + unregisteredSessions.count) running")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(meshAgents) { member in
                    DashboardMeshAgentRow(
                        member: member,
                        supportsSignedHostControl: supportsSignedHostControl,
                        onRename: { onRename(member) },
                        onAttach: { onAttachMesh(member) },
                        onStop: { onStopMesh(member) }
                    )
                }
                ForEach(unregisteredSessions) { session in
                    DashboardSessionAgentRow(
                        session: session,
                        onAttach: { onAttachSession(session) },
                        onStop: { onStopSession(session) }
                    )
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct DashboardMeshAgentRow: View {
    let member: MeshMemberInfo
    let supportsSignedHostControl: Bool
    let onRename: () -> Void
    let onAttach: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.nick).font(.callout.weight(.medium)).lineLimit(1)
                    Text(member.kind ?? "agent").font(.caption).foregroundStyle(.secondary)
                    Text(stateLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Text(machineLine)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let reason = stateReasonLabel {
                    Text(reason).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if !member.rooms.isEmpty {
                    Text(member.rooms.sorted().map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button("Rename", systemImage: "pencil", action: onRename)
                .labelStyle(.iconOnly).help("Rename agent")
            if member.tmuxPane != nil || supportsSignedHostControl {
                if member.tmuxPane != nil { Button("Attach", action: onAttach) }
                Button("Stop", role: .destructive, action: onStop).foregroundStyle(.red)
            } else {
                Text("Not in tmux").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }

    private var machineLine: String {
        var values: [String] = []
        if let host = member.host, !host.isEmpty { values.append(host) }
        if let ip = member.tailscaleIP, !ip.isEmpty, ip != member.host { values.append(ip) }
        if let project = member.project, !project.isEmpty {
            values.append((project as NSString).abbreviatingWithTildeInPath)
        }
        return values.isEmpty ? "Unknown machine" : values.joined(separator: " · ")
    }

    private var stateLabel: String {
        switch member.state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: "working"
        case .blocked: "waiting"
        case .stopped, .idle: "idle"
        case .gone: "ended"
        case nil: "unknown"
        }
    }

    private var stateColor: Color {
        switch member.state.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: .orange
        case .blocked: .red
        case .stopped, .idle: .green
        case .gone: .gray.opacity(0.4)
        case nil: .gray
        }
    }

    private var stateReasonLabel: String? {
        guard let reason = member.stateReason, !reason.isEmpty else { return nil }
        if reason == "permission" { return "Permission required" }
        if reason.hasPrefix("permission:") {
            return "Permission required · " + String(reason.dropFirst("permission:".count))
        }
        if reason == "elicitation" { return "Waiting for form response" }
        if reason.hasPrefix("api_error:") {
            return "API error · " + String(reason.dropFirst("api_error:".count))
        }
        return reason
    }
}

private struct DashboardSessionAgentRow: View {
    let session: DashboardAgentSession
    let onAttach: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.green).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.session).font(.callout.weight(.medium)).lineLimit(1)
                    Text("Not in Mesh")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(session.sshHost ?? HostIdentity.current)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Attach", action: onAttach)
            Button("Stop", role: .destructive, action: onStop).foregroundStyle(.red)
        }
        .font(.caption)
        .buttonStyle(.borderless)
    }
}
