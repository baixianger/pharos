import SwiftUI

/// Slack-style iPad workspace: a contextual sidebar with a bottom workspace
/// navigator, and the selected item's detail. This view is only created for
/// regular widths; the existing iPhone TabView remains the compact-width shell.
struct IPadWorkspaceShell: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @Binding var workspace: AppTab
    @State private var selectedProjectID: String?
    @State private var selectedIssueID: String?
    @State private var selectedAgentID: String?
    @State private var projects: [RemoteProject] = []
    @State private var issues: [RemoteIssue] = []
    @State private var projectFilter: ProjectFilter = .all
    @State private var issueFilter: IssueFilter = .all
    @State private var agentFilter: AgentFilter = .live
    @State private var projectsLoading = false
    @State private var issuesLoading = false
    @State private var projectsError: String?
    @State private var issuesError: String?
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView {
            IPadWorkspaceIndex(
                workspace: $workspace,
                projects: projects,
                issues: issues,
                members: Array(store.members.values),
                selectedProjectID: $selectedProjectID,
                selectedIssueID: $selectedIssueID,
                selectedAgentID: $selectedAgentID,
                selectedRoom: selectedRoomBinding,
                projectFilter: $projectFilter,
                issueFilter: $issueFilter,
                agentFilter: $agentFilter,
                projectsLoading: projectsLoading,
                issuesLoading: issuesLoading,
                projectsError: projectsError,
                issuesError: issuesError,
                onSettings: { showingSettings = true }
            )
            .id(workspace)
            .navigationTitle(workspace.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 360)
        } detail: {
            NavigationStack {
                IPadWorkspaceDetail(
                    workspace: workspace,
                    selectedProject: selectedProject,
                    selectedIssue: selectedIssue,
                    selectedAgent: selectedAgent,
                    projectAgents: selectedProject.map(agents(for:)) ?? [],
                    brokerConfigured: !settings.mesh.host.isEmpty,
                    hasSelectedRoom: store.selectedRoom != nil,
                    onOpenSettings: { showingSettings = true }
                )
                .id(detailIdentity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            SettingsView(showsDoneButton: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .presentationSizing(.form)
        }
        .task {
            if workspace == .settings { workspace = .projects }
            await loadProjects()
            await loadIssues()
            selectFirstAgentIfNeeded()
        }
        .onChange(of: store.members) {
            selectFirstAgentIfNeeded()
        }
    }

    private var selectedRoomBinding: Binding<String?> {
        @Bindable var store = store
        return $store.selectedRoom
    }

    private var selectedProject: RemoteProject? {
        projects.first { $0.id == selectedProjectID }
    }

    private var selectedIssue: RemoteIssue? {
        issues.first { $0.id == selectedIssueID }
    }

    private var selectedAgent: MeshMember? {
        store.members.values.first { $0.id == selectedAgentID }
    }

    private var detailIdentity: String {
        switch workspace {
        case .projects: "projects|\(selectedProjectID ?? "none")"
        case .issues: "issues|\(selectedIssueID ?? "none")"
        case .agents: "agents|\(selectedAgentID ?? "none")"
        case .chat: "chat|\(store.selectedRoom ?? "none")"
        case .settings: "settings"
        }
    }

    private func agents(for project: RemoteProject) -> [MeshMember] {
        store.members.values.filter { member in
            guard let memberPath = member.project, !memberPath.isEmpty else { return false }
            if let path = project.localPath, path == memberPath { return true }
            return (memberPath as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(project.name) == .orderedSame
        }
    }

    private func loadProjects() async {
        projectsLoading = true
        projectsError = nil
        defer { projectsLoading = false }
        guard let loaded = await store.fetchProjectsOverMesh() else {
            projectsError = "The Broker is unavailable and no project cache exists yet."
            return
        }
        projects = loaded
        if selectedProjectID == nil || !loaded.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = loaded.first?.id
        }
    }

    private func loadIssues() async {
        issuesLoading = true
        issuesError = nil
        defer { issuesLoading = false }
        guard let loaded = await store.fetchIssuesOverMesh() else {
            issuesError = "The Broker is unavailable and no issue cache exists yet."
            return
        }
        issues = loaded
        if selectedIssueID == nil || !loaded.contains(where: { $0.id == selectedIssueID }) {
            selectedIssueID = loaded.first?.id
        }
    }

    private func selectFirstAgentIfNeeded() {
        let live = store.members.values
            .filter { $0.nick != "human" && $0.state.flatMap(MeshSessionState.init(rawValue:)) != .gone }
            .sorted { ($0.host ?? "", $0.nick) < ($1.host ?? "", $1.nick) }
        if selectedAgentID == nil || !live.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = live.first?.id
        }
    }
}

private struct IPadWorkspaceIndex: View {
    @Binding var workspace: AppTab
    let projects: [RemoteProject]
    let issues: [RemoteIssue]
    let members: [MeshMember]
    @Binding var selectedProjectID: String?
    @Binding var selectedIssueID: String?
    @Binding var selectedAgentID: String?
    @Binding var selectedRoom: String?
    @Binding var projectFilter: ProjectFilter
    @Binding var issueFilter: IssueFilter
    @Binding var agentFilter: AgentFilter
    let projectsLoading: Bool
    let issuesLoading: Bool
    let projectsError: String?
    let issuesError: String?
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch workspace {
            case .projects:
                IPadProjectsIndex(projects: projects, members: members,
                                  selection: $selectedProjectID, filter: $projectFilter,
                                  loading: projectsLoading, error: projectsError)
            case .issues:
                IPadIssuesIndex(issues: issues, selection: $selectedIssueID,
                                filter: $issueFilter, loading: issuesLoading, error: issuesError)
            case .agents:
                IPadAgentsIndex(members: members, selection: $selectedAgentID, filter: $agentFilter)
            case .chat:
                RoomListView(selection: $selectedRoom, suppressesSystemSelection: true)
            case .settings:
                Color.clear
            }

            Divider()
            IPadBottomNavigator(selection: $workspace, onSettings: onSettings)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct IPadBottomNavigator: View {
    @Binding var selection: AppTab
    let onSettings: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 8) {
                IPadBottomNavigatorItems(selection: $selection, onSettings: onSettings)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        } else {
            IPadBottomNavigatorItems(selection: $selection, onSettings: onSettings)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
        }
    }
}

private struct IPadBottomNavigatorItems: View {
    @Binding var selection: AppTab
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.workspaces) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol)
                            .font(.body.weight(.medium))
                        Text(tab.title)
                            .font(.caption2.weight(selection == tab ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(selection == tab ? Color.accentColor : .clear)
                            .frame(width: 18, height: 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }

            Divider().frame(height: 30).padding(.horizontal, 3)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct IPadProjectsIndex: View {
    let projects: [RemoteProject]
    let members: [MeshMember]
    @Binding var selection: String?
    @Binding var filter: ProjectFilter
    let loading: Bool
    let error: String?

    var body: some View {
        List {
            Section {
                PharosFilterStrip(options: ProjectFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                    .padding(.vertical, 4)
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
            }
            if !activeProjects.isEmpty {
                Section {
                    ForEach(activeProjects) { project in projectRow(project) }
                } header: {
                    PharosSectionTitle(title: "In progress", count: activeProjects.count)
                }
            }
            if !otherProjects.isEmpty {
                Section {
                    ForEach(otherProjects) { project in projectRow(project) }
                } header: {
                    PharosSectionTitle(title: "Projects", count: otherProjects.count)
                }
            }
        }
        .pharosPlainList()
        .overlay {
            if loading && projects.isEmpty {
                PharosSkeletonRows(count: 7)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .background(PharosDesign.pageBackground)
            } else if filteredProjects.isEmpty {
                ContentUnavailableView("No projects", systemImage: error == nil ? "cube" : "exclamationmark.triangle",
                                       description: Text(error ?? "No projects match this filter."))
            }
        }
    }

    private func projectRow(_ project: RemoteProject) -> some View {
        Button { selection = project.id } label: {
            ProjectRow(project: project, agents: agents(for: project))
                .padding(.horizontal, 8)
                .background(selection == project.id ? Color.primary.opacity(0.055) : .clear,
                            in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                            bottom: 0, trailing: PharosDesign.pageInset))
        .listRowBackground(Color.clear)
    }

    private var filteredProjects: [RemoteProject] {
        projects.filter { project in
            switch filter {
            case .all: true
            case .active: !agents(for: project).isEmpty
            case .local: project.hasLocalPath
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var activeProjects: [RemoteProject] { filteredProjects.filter { !agents(for: $0).isEmpty } }
    private var otherProjects: [RemoteProject] { filteredProjects.filter { agents(for: $0).isEmpty } }

    private func agents(for project: RemoteProject) -> [MeshMember] {
        members.filter { member in
            guard let memberPath = member.project, !memberPath.isEmpty else { return false }
            if let path = project.localPath, path == memberPath { return true }
            return (memberPath as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(project.name) == .orderedSame
        }
    }
}

private struct IPadIssuesIndex: View {
    let issues: [RemoteIssue]
    @Binding var selection: String?
    @Binding var filter: IssueFilter
    let loading: Bool
    let error: String?

    var body: some View {
        List {
            Section {
                PharosFilterStrip(options: [(.all, "All"), (.active, "Active"), (.backlog, "Backlog")],
                                  selection: $filter)
                    .padding(.vertical, 4)
                    .listRowInsets(.init())
                    .listRowSeparator(.hidden)
            }
            ForEach(grouped, id: \.status) { group in
                Section {
                    ForEach(group.issues) { issue in
                        Button { selection = issue.id } label: {
                            IssueIndexRow(issue: issue)
                                .padding(.horizontal, 8)
                                .background(selection == issue.id ? Color.primary.opacity(0.055) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                            .buttonStyle(.plain)
                            .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                                                bottom: 0, trailing: PharosDesign.pageInset))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    PharosSectionTitle(title: group.status.displayName, count: group.issues.count)
                }
            }
        }
        .pharosPlainList()
        .overlay {
            if loading && issues.isEmpty {
                PharosSkeletonRows(count: 7)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                    .background(PharosDesign.pageBackground)
            } else if filteredIssues.isEmpty {
                ContentUnavailableView("No open issues", systemImage: error == nil ? "checkmark.circle" : "exclamationmark.triangle",
                                       description: Text(error ?? "No issues match this filter."))
            }
        }
    }

    private var filteredIssues: [RemoteIssue] {
        issues.filter { issue in
            let state = IssueWorkflowState(issue.status)
            return switch filter {
            case .all: true
            case .active: state == .inProgress || state == .blocked || state == .review
            case .backlog: state == .backlog || state == .todo
            }
        }
    }

    private var grouped: [(status: IssueWorkflowState, issues: [RemoteIssue])] {
        Dictionary(grouping: filteredIssues) { IssueWorkflowState($0.status) }
            .map { status, values in
                (status, values.sorted {
                    if priorityRank($0.priority) != priorityRank($1.priority) {
                        return priorityRank($0.priority) < priorityRank($1.priority)
                    }
                    return $0.number < $1.number
                })
            }
            .sorted { $0.status.sortOrder < $1.status.sortOrder }
    }

    private func priorityRank(_ priority: String) -> Int {
        switch priority.lowercased() {
        case "urgent": 0
        case "high": 1
        case "medium": 2
        case "low": 3
        default: 4
        }
    }
}

private struct IPadAgentsIndex: View {
    let members: [MeshMember]
    @Binding var selection: String?
    @Binding var filter: AgentFilter

    var body: some View {
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
                        Button { selection = member.id } label: {
                            AgentRow(member: member)
                                .padding(.horizontal, 8)
                                .background(selection == member.id ? Color.primary.opacity(0.055) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }
                            .buttonStyle(.plain)
                            .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                                                bottom: 0, trailing: PharosDesign.pageInset))
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    PharosSectionTitle(title: group.host, count: group.members.count)
                }
            }
        }
        .pharosPlainList()
        .overlay {
            if agents.isEmpty {
                ContentUnavailableView("No agents here", systemImage: "terminal",
                                       description: Text("Agents appear after they join a Mesh room."))
            }
        }
    }

    private var agents: [MeshMember] {
        members
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

private struct IPadWorkspaceDetail: View {
    let workspace: AppTab
    let selectedProject: RemoteProject?
    let selectedIssue: RemoteIssue?
    let selectedAgent: MeshMember?
    let projectAgents: [MeshMember]
    let brokerConfigured: Bool
    let hasSelectedRoom: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        switch workspace {
        case .projects:
            if let selectedProject {
                ProjectSummaryView(project: selectedProject, agents: projectAgents)
            } else {
                IPadDetailPlaceholder(title: "Choose a project", symbol: "cube",
                                      description: "Select a project from the middle column.")
            }
        case .issues:
            if let selectedIssue {
                IssueSummaryView(issue: selectedIssue)
            } else {
                IPadDetailPlaceholder(title: "Choose an issue", symbol: "checklist",
                                      description: "Select an issue from the middle column.")
            }
        case .agents:
            if let selectedAgent {
                AgentDetailView(member: selectedAgent)
            } else {
                IPadDetailPlaceholder(title: "Choose an agent", symbol: "terminal",
                                      description: "Select an agent from the middle column.")
            }
        case .chat:
            if !brokerConfigured {
                ContentUnavailableView {
                    Label("Connect to your Mesh", systemImage: "network")
                } description: {
                    Text("Add the Tailscale address of the Mac hosting Pharos Mesh.")
                } actions: {
                    Button("Open Settings", action: onOpenSettings)
                }
            } else if hasSelectedRoom {
                ConversationView()
            } else {
                IPadDetailPlaceholder(title: "Choose a room", symbol: "bubble.left.and.bubble.right",
                                      description: "Select a room from the middle column.")
            }
        case .settings:
            Color.clear
        }
    }
}

private struct IPadDetailPlaceholder: View {
    let title: LocalizedStringResource
    let symbol: String
    let description: LocalizedStringResource

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description)
        }
    }
}
