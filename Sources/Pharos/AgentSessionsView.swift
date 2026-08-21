import SwiftUI
import PharosMeshCore

/// A single control surface for conversations and their current runtime seats.
/// Until RFC-003 lands, live registrations and archives are intentionally kept
/// separate: a tmux process is not presented as a durable conversation.
struct AgentSessionsView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var openRoom: String?
    @Binding var selectedProject: Project.ID?

    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case live = "Live"
        case history = "History"
        case external = "External"
        var id: String { rawValue }
    }

    private struct ArchiveRow: Identifiable {
        let project: Project
        let session: AgentSession
        var id: String { "\(project.id)|\(session.kind.rawValue)|\(session.id)" }
    }

    @State private var archives: [ArchiveRow] = []
    @State private var scope: Scope = .all
    @State private var agentFilter: AgentKind?
    @State private var query = ""
    @State private var loading = false

    private var registered: [MeshMemberInfo] {
        store.meshRoster
            .filter { $0.session != nil || $0.kind != nil }
            .filter { matchesAgent($0) }
            .filter { query.isEmpty || searchable($0).localizedCaseInsensitiveContains(query) }
            .sorted(by: { (lhs: MeshMemberInfo, rhs: MeshMemberInfo) in
                let lhsLive = isLive(lhs)
                let rhsLive = isLive(rhs)
                if lhsLive != rhsLive { return lhsLive && !rhsLive }
                return lhs.lastSeen > rhs.lastSeen
            })
    }

    private var registeredTransportIDs: Set<String> {
        Set(store.meshRoster.compactMap(\.session))
    }

    private var externalSessions: [String] {
        store.allRunningSessions
            .filter { !registeredTransportIDs.contains($0) }
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted()
    }

    private var filteredArchives: [ArchiveRow] {
        archives.filter { row in
            let agentMatches = agentFilter == nil || row.session.kind == agentFilter
            let textMatches = query.isEmpty
                || "\(row.session.title) \(row.project.name) \(row.session.id)"
                    .localizedCaseInsensitiveContains(query)
            return agentMatches && textMatches
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                hero
                controls

                if scope == .all || scope == .live {
                    sectionHeader("Registered runtimes", count: registered.count,
                                  caption: "Broker identities with an active or recently attached surface")
                    if registered.isEmpty { emptyRow("No registered agent runtimes", symbol: "antenna.radiowaves.left.and.right.slash") }
                    else { ForEach(registered) { runtimeRow($0) } }
                }

                if scope == .all || scope == .external {
                    sectionHeader("External fallback", count: externalSessions.count,
                                  caption: "Legacy processes discovered through tmux; delivery is best effort")
                    if externalSessions.isEmpty { emptyRow("No unregistered fallback sessions", symbol: "checkmark.shield") }
                    else { ForEach(externalSessions, id: \.self) { externalRow($0) } }
                }

                if scope == .all || scope == .history {
                    sectionHeader("Conversation archive", count: filteredArchives.count,
                                  caption: "Persistent Claude and Codex conversations discovered on this Mac")
                    if loading { ProgressView("Indexing local conversations…").padding(.vertical, 24) }
                    else if filteredArchives.isEmpty { emptyRow("No conversations match this view", symbol: "tray") }
                    else { ForEach(filteredArchives) { archiveRow($0) } }
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background {
            LinearGradient(colors: [Color.accentColor.opacity(0.07), .clear, Color.orange.opacity(0.035)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onAppear {
            store.startMeshSnapshotPolling()
            store.refreshRunningAgents()
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("SESSION CONTROL")
                    .font(.caption.weight(.bold)).tracking(2.2).foregroundStyle(.secondary)
                Text("Every agent. One runtime view.")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Conversations persist. Runtimes and client surfaces may come and go.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            metric("LIVE", registered.filter { isLive($0) }.count, .green)
            metric("ARCHIVED", archives.count, .blue)
            metric("FALLBACK", externalSessions.count, .orange)
            newSessionMenu
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.accentColor.opacity(0.7)).frame(height: 2).padding(.horizontal, 22)
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 360)

            Menu {
                Button("All agents") { agentFilter = nil }
                Divider()
                ForEach(AgentKind.allCases) { kind in
                    Button(kind.label) { agentFilter = kind }
                }
            } label: {
                Label(agentFilter?.label ?? "All agents", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)

            Spacer()
            TextField("Search sessions", text: $query)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
        }
    }

    private var newSessionMenu: some View {
        Menu {
            ForEach(store.projects.filter(\.hasLocal)) { project in
                Menu(project.name) {
                    ForEach(AgentKind.allCases) { kind in
                        Button(kind.label) { launch(kind, in: project) }
                    }
                }
            }
        } label: {
            Label("New", systemImage: "plus")
                .font(.callout.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Uses the current launcher until the Host Runtime RPC is implemented")
    }

    private func runtimeRow(_ member: MeshMemberInfo) -> some View {
        HStack(spacing: 14) {
            agentMark(kind: AgentKind(rawValue: member.kind ?? ""), online: isLive(member))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(member.nick).font(.headline)
                    ownershipBadge(isLive(member) ? "ATTACHED" : "REGISTERED",
                                   color: isLive(member) ? .green : .secondary)
                    if let state = member.state { ownershipBadge(state.uppercased(), color: stateColor(state)) }
                }
                Text([member.kind, member.project, member.host].compactMap { $0 }.joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if member.unread ?? 0 > 0 {
                Text("\(member.unread ?? 0) unread").font(.caption.weight(.medium)).foregroundStyle(.orange)
            }
            if let room = member.rooms.first {
                Button("Open room") { openRoom = room }.buttonStyle(.bordered)
            }
            Text(Date(timeIntervalSince1970: member.lastSeen), style: .relative)
                .font(.caption).foregroundStyle(.tertiary).frame(width: 74, alignment: .trailing)
        }
        .sessionCard()
    }

    private func externalRow(_ session: String) -> some View {
        HStack(spacing: 14) {
            agentMark(kind: inferredKind(session), online: true, warning: true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(session).font(.headline.monospaced())
                    ownershipBadge("EXTERNAL", color: .orange)
                    ownershipBadge("TMUX", color: .secondary)
                }
                Text(store.remoteSessionHosts[session].map { "Fallback transport on \($0)" }
                     ?? "Fallback transport on this Mac")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop", role: .destructive) {
                store.stopAgent(session: session, host: store.remoteSessionHosts[session])
            }
            .buttonStyle(.bordered)
        }
        .sessionCard(tint: .orange)
    }

    private func archiveRow(_ row: ArchiveRow) -> some View {
        HStack(spacing: 14) {
            agentMark(kind: row.session.kind, online: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.session.title).font(.headline).lineLimit(1)
                    ownershipBadge("HISTORICAL", color: .blue)
                }
                Text("\(row.project.name)  ·  \(row.session.kind.label)  ·  \(row.session.id.prefix(8))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.session.modified, style: .relative)
                .font(.caption).foregroundStyle(.tertiary).frame(width: 74, alignment: .trailing)
            Button("Project") { selectedProject = row.project.id }.buttonStyle(.borderless)
            Button("Resume") { resume(row) }.buttonStyle(.borderedProminent)
        }
        .sessionCard(tint: kindColor(row.session.kind))
    }

    private func sectionHeader(_ title: String, count: Int, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Text(caption).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func emptyRow(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)").font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58, alignment: .leading)
    }

    private func agentMark(kind: AgentKind?, online: Bool, warning: Bool = false) -> some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill((warning ? Color.orange : kindColor(kind)).opacity(0.13))
                .frame(width: 44, height: 44)
            Image(systemName: kindSymbol(kind)).foregroundStyle(warning ? .orange : kindColor(kind))
                .frame(width: 44, height: 44)
            Circle().fill(online ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9).overlay(Circle().stroke(.background, lineWidth: 2))
        }
    }

    private func ownershipBadge(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func matchesAgent(_ member: MeshMemberInfo) -> Bool {
        guard let agentFilter else { return true }
        return member.kind == agentFilter.rawValue
    }

    private func isLive(_ member: MeshMemberInfo) -> Bool {
        guard member.state != "gone" else { return false }
        return Date().timeIntervalSince1970 - member.lastSeen < 45
    }

    private func searchable(_ member: MeshMemberInfo) -> String {
        [member.nick, member.kind, member.project, member.host, member.session]
            .compactMap { $0 }.joined(separator: " ")
    }

    private func inferredKind(_ session: String) -> AgentKind? {
        AgentKind.allCases.first { session.localizedCaseInsensitiveContains($0.rawValue) }
    }

    private func kindColor(_ kind: AgentKind?) -> Color {
        switch kind {
        case .claude: .orange
        case .codex: .teal
        case .dsh: .pink
        case nil: .secondary
        }
    }

    private func kindSymbol(_ kind: AgentKind?) -> String {
        switch kind {
        case .claude: "sparkles"
        case .codex: "terminal"
        case .dsh: "point.3.connected.trianglepath.dotted"
        case nil: "cpu"
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "working": .green
        case "waiting", "approval": .orange
        case "error", "stopped": .red
        default: .secondary
        }
    }

    private func launch(_ kind: AgentKind, in project: Project) {
        Task {
            await LaunchService.launchAgent(kind, project: project, terminal: store.terminal,
                                            extraArgs: store.agentArgs(for: kind))
            store.refreshRunningAgents()
        }
    }

    private func resume(_ row: ArchiveRow) {
        Task {
            await LaunchService.resumeSession(row.session, project: row.project, terminal: store.terminal,
                                              extraArgs: store.agentArgs(for: row.session.kind))
            store.refreshRunningAgents()
        }
    }

    private func reload() async {
        loading = true
        var result: [ArchiveRow] = []
        for project in store.projects {
            guard let path = project.localPath, !path.isEmpty else { continue }
            async let claude = SessionsService.claudeSessions(for: path)
            async let codex = SessionsService.codexSessions(for: path)
            let sessions = await claude + codex
            result.append(contentsOf: sessions.map { ArchiveRow(project: project, session: $0) })
        }
        archives = result.sorted { $0.session.modified > $1.session.modified }
        loading = false
    }
}

private extension View {
    func sessionCard(tint: Color = .secondary) -> some View {
        self
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.7)).frame(width: 3).padding(.vertical, 12)
            }
    }
}
