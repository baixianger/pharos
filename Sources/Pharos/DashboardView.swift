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

/// The home screen: a cross-project rollup with a group switcher up top, stat
/// cards, and the recent-activity feed at the bottom. Click anything to jump in.
struct DashboardView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProject: Project.ID?
    @Binding var openRoom: String?

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All", issues = "Issues", updates = "Updates"
        var id: String { rawValue }
    }
    @State private var groupFilter: String?           // nil = all groups
    @State private var activityFilter: ActivityFilter = .all
    @State private var meshMessages: [MeshMsg] = []    // recent agent chatter (read from transcripts)
    @State private var agentToStop: StopTarget?
    @State private var meshAgents: [MeshMemberInfo] = []  // live roster across all machines (who)
    @State private var meshAgentToStop: MeshMemberInfo?
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
    private var agentCount: Int {
        store.runningSessions.filter { s in projects.contains { LaunchService.tmuxSessionPrefix($0).hasPrefix("pharos-") && s.hasPrefix(LaunchService.tmuxSessionPrefix($0)) } }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.groups.isEmpty { groupTabs }
                statTiles
                statusCard
                if !blocked.isEmpty || !urgent.isEmpty { attentionCard }
                if !activeAgents.isEmpty { agentsCard }
                if !liveMeshAgents.isEmpty { meshAgentsCard }
                if !meshMessages.isEmpty { meshCard }
                if projects.contains(where: { !$0.milestones.isEmpty }) { milestonesCard }
                activityCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Dashboard")
        .onAppear(perform: loadMesh)
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
            Text("Kills @\(m.nick)'s tmux session \(m.host.map { "on \($0)" } ?? "on this Mac"). Unsaved work is lost.")
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
        meshAgents.filter { $0.nick != "human" }
            .sorted { ($0.host ?? "", $0.nick) < ($1.host ?? "", $1.nick) }
    }

    private var meshAgentsCard: some View {
        card("Agents · \(liveMeshAgents.count) on the mesh") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(liveMeshAgents, id: \.id) { m in
                    HStack(spacing: 9) {
                        Circle().fill(meshStateColor(m.state)).frame(width: 8, height: 8)
                        Text(m.nick).font(.callout.weight(.medium))
                        Text(m.kind ?? "claude").font(.caption).foregroundStyle(.secondary)
                        if let h = m.host { Text(h).font(.caption).foregroundStyle(.secondary) }
                        if let p = m.project {
                            Text((p as NSString).abbreviatingWithTildeInPath)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if m.tmuxPane != nil {
                            Button("Attach") { attachMeshAgent(m) }.font(.caption).buttonStyle(.borderless)
                            Button("Stop") { meshAgentToStop = m }.font(.caption).buttonStyle(.borderless).foregroundStyle(.red)
                        } else {
                            Text("no tmux").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func meshStateColor(_ raw: String?) -> Color {
        switch raw.flatMap(MeshSessionState.init(rawValue:)) {
        case .busy: return .orange
        case .blocked: return .red
        case .stopped, .idle: return .green
        case .gone: return .gray.opacity(0.4)
        case nil: return .gray
        }
    }

    private func attachMeshAgent(_ m: MeshMemberInfo) {
        guard let cmd = meshTmuxCommand(m, attach: true) else { return }
        LaunchService.openTerminal(command: cmd, terminal: store.terminal)
    }

    private func stopMeshAgent(_ m: MeshMemberInfo) {
        guard let cmd = meshTmuxCommand(m, attach: false) else { return }
        Task.detached { _ = Shell.run("/bin/sh", ["-c", cmd]); await MainActor.run { loadMesh() } }
    }

    /// Shell command to attach or kill `m`'s tmux session, resolving its reported
    /// pane to the session name. Local when the agent is on this Mac; otherwise
    /// wrapped in `ssh <peer>` (escaped so the local shell hands the script to the
    /// remote shell verbatim).
    private func meshTmuxCommand(_ m: MeshMemberInfo, attach: Bool) -> String? {
        guard let pane = m.tmuxPane, pane.first == "%", pane.dropFirst().allSatisfy(\.isNumber) else { return nil }
        let action = attach ? "exec tmux attach -t \"=$s\"" : "tmux kill-session -t \"=$s\""
        let inner = "s=$(tmux display-message -p -t '\(pane)' '#{session_name}') && \(action)"
        if m.host == nil || m.host == HostIdentity.current { return inner }
        let peer = store.peerHost
        guard !peer.isEmpty else { return nil }
        let escaped = inner.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "$", with: "\\$")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        return "ssh \(attach ? "-t " : "")\(peer) \"\(escaped)\""
    }

    private func loadMesh() {
        let dir = MeshPaths.transcriptDir
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        var all: [MeshMsg] = []
        for f in files where f.pathExtension == "jsonl" {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for line in s.split(separator: "\n") {
                if let m = try? dec.decode(MeshMsg.self, from: Data(line.utf8)) { all.append(m) }
            }
        }
        meshMessages = all.sorted { $0.ts > $1.ts }
        // Live roster across every machine — fetched off-main so the socket
        // round-trip never stutters the dashboard.
        Task.detached {
            let roster = MeshClient.send(MeshRequest(cmd: "who")).members ?? []
            await MainActor.run { meshAgents = roster }
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
            tile("\(agentCount)", "Agents running", "sparkles")
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

    private var agentsCard: some View {
        card("Agents working") {
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
