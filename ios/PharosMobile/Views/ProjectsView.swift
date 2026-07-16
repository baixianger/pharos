import SwiftUI
import UIKit

/// Registry projects presented as a quiet, status-first Linear-style index.
/// Project data comes only from the Broker, with a device-local offline cache.
struct ProjectsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var projects: [RemoteProject] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var filter: ProjectFilter = .all
    @State private var showingNewProject = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PharosFilterStrip(options: ProjectFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                        .padding(.vertical, 4)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                }
                if !activeProjects.isEmpty {
                    Section {
                        ForEach(activeProjects) { project in projectLink(project) }
                    } header: {
                        PharosSectionTitle(title: "In progress", count: activeProjects.count)
                    }
                }

                if !otherProjects.isEmpty {
                    Section {
                        ForEach(otherProjects) { project in projectLink(project) }
                    } header: {
                        PharosSectionTitle(title: filter == .local ? "On this Mesh" : "Projects",
                                           count: otherProjects.count)
                    }
                }
            }
            .pharosPlainList()
            .overlay { stateOverlay }
            .navigationTitle("Projects")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingNewProject = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add project")
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(ProjectFilter.allCases) { Text($0.title).tag($0) }
                        }
                        Divider()
                        Button { Task { await load() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Project display options")
                }
            }
            .sheet(isPresented: $showingNewProject) {
                NewProjectView {
                    Task { await load() }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func projectLink(_ project: RemoteProject) -> some View {
        NavigationLink { ProjectSummaryView(project: project, agents: agents(for: project)) } label: {
            ProjectRow(project: project, agents: agents(for: project))
        }
        .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                            bottom: 0, trailing: PharosDesign.pageInset))
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if loading && projects.isEmpty {
            PharosSkeletonRows(count: 7)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
                .background(PharosDesign.pageBackground)
        } else if filtered.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: loadError == nil ? "cube" : "exclamationmark.triangle")
            } description: {
                Text(emptyDescription)
            } actions: {
                if loadError != nil { Button("Try again") { Task { await load() } } }
                else if filter != .active { Button("Add project") { showingNewProject = true } }
            }
        }
    }

    private var filtered: [RemoteProject] {
        projects
            .filter { project in
                switch filter {
                case .all: true
                case .active: !agents(for: project).isEmpty
                case .local: project.hasLocalPath
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var activeProjects: [RemoteProject] { filtered.filter { !agents(for: $0).isEmpty } }
    private var otherProjects: [RemoteProject] { filtered.filter { agents(for: $0).isEmpty } }

    private func agents(for project: RemoteProject) -> [MeshMember] {
        store.members.values.filter { member in
            guard let memberPath = member.project, !memberPath.isEmpty else { return false }
            if let path = project.localPath, path == memberPath { return true }
            return (memberPath as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(project.name) == .orderedSame
        }
    }

    private var emptyTitle: String {
        if loadError != nil { return "Projects unavailable" }
        return filter == .active ? "No active projects" : "No projects"
    }

    private var emptyDescription: String {
        if let loadError { return loadError }
        if settings.mesh.host.isEmpty { return "Connect to your Broker in Settings to load the registry." }
        if filter == .active { return "Projects appear here while an agent reports that working directory." }
        return "The Broker registry did not return any projects."
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        if let viaMesh = await store.fetchProjectsOverMesh() {
            projects = viaMesh
            return
        }
        loadError = "The Broker is unavailable and no project cache exists yet."
    }
}

private struct NewProjectView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var githubRemote = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var saving = false
    let onCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Name", text: $name)
                    TextField("Git remote (optional)", text: $githubRemote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Description") {
                    TextField("What is this project for?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
                Section {
                    TextField("personal, ios, tools", text: $tags)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Tags")
                } footer: {
                    Text("Separate tags with commas. Checkout paths are configured separately on each Host.")
                }
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { Task { await save() } }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        let parsedTags = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let succeeded = await store.addProject(name: name, githubRemote: githubRemote,
                                               notes: notes, tags: parsedTags)
        saving = false
        if succeeded {
            onCreated()
            dismiss()
        }
    }
}

enum ProjectFilter: String, CaseIterable, Identifiable {
    case all, active, local
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All projects"
        case .active: "Active"
        case .local: "Available"
        }
    }
}

struct ProjectRow: View {
    let project: RemoteProject
    let agents: [MeshMember]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: project.githubRemote == nil ? "cube" : "chevron.left.forwardslash.chevron.right")
                .font(.body.weight(.medium))
                .foregroundStyle(agents.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(metadata)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PharosStatusGlyph(kind: agents.isEmpty ? (project.hasLocalPath ? .offline : .warning) : .active)
        }
        .padding(.vertical, PharosDesign.rowVerticalPadding)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var metadata: String {
        if !agents.isEmpty {
            return agents.count == 1 ? "@\(agents[0].nick) working" : "\(agents.count) agents working"
        }
        if !project.tags.isEmpty { return project.tags.joined(separator: " · ") }
        if let path = project.localPath { return (path as NSString).abbreviatingWithTildeInPath }
        return "Remote project"
    }
}

struct ProjectSummaryView: View {
    @Environment(RoomStore.self) private var store
    @State private var project: RemoteProject
    let agents: [MeshMember]
    @State private var tab: ProjectDetailTab = .overview
    @State private var showingNewIssue = false

    init(project: RemoteProject, agents: [MeshMember]) {
        _project = State(initialValue: project)
        self.agents = agents
    }

    var body: some View {
        List {
            Section {
                ProjectDetailHeader(project: project, activeAgentCount: agents.count)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 8, leading: PharosDesign.pageInset,
                                        bottom: 8, trailing: PharosDesign.pageInset))
                PharosFilterStrip(options: ProjectDetailTab.allCases.map { ($0, $0.title) }, selection: $tab)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init())
            }

            switch tab {
            case .overview:
                ProjectOverviewSections(project: project, agents: agents)
            case .activity:
                ProjectActivitySections(project: project, agents: agents)
            case .issues:
                ProjectIssuesSection(issues: project.issues)
            }
        }
        .pharosPlainList()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingNewIssue = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add issue")
                Menu {
                    Button { Task { await reload() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = project.name
                    } label: {
                        Label("Copy project name", systemImage: "doc.on.doc")
                    }
                    if let remote = project.githubRemote {
                        Button {
                            UIPasteboard.general.string = remote
                        } label: {
                            Label("Copy Git remote", systemImage: "link")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More project actions")
            }
        }
        .sheet(isPresented: $showingNewIssue) {
            NewProjectIssueView(projectName: project.name) {
                Task { await reload() }
            }
        }
    }

    private func reload() async {
        guard let projects = await store.fetchProjectsOverMesh(),
              let updated = projects.first(where: { $0.name == project.name }) else { return }
        project = updated
    }
}

private enum ProjectDetailTab: String, CaseIterable, Identifiable {
    case overview, activity, issues
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct ProjectDetailHeader: View {
    let project: RemoteProject
    let activeAgentCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(project.name)
                    .font(.title.bold())
                    .lineLimit(2)
            }
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if !project.notes.isEmpty { return project.notes }
        if activeAgentCount > 0 {
            return activeAgentCount == 1 ? "One agent is working on this project." : "\(activeAgentCount) agents are working on this project."
        }
        return "Project details, activity, and issues from your Broker registry."
    }
}

private struct ProjectOverviewSections: View {
    let project: RemoteProject
    let agents: [MeshMember]

    var body: some View {
        Section("Properties") {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ProjectPropertyChip(title: agents.isEmpty ? "Available" : "In progress",
                                        symbol: agents.isEmpty ? "circle" : "circle.lefthalf.filled",
                                        tint: agents.isEmpty ? .secondary : .accentColor)
                    ProjectPropertyChip(title: "\(project.issues.filter { IssueWorkflowState($0.status).isOpen }.count) open",
                                        symbol: "checklist")
                    ForEach(project.tags, id: \.self) { tag in
                        ProjectPropertyChip(title: tag, symbol: "tag")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .listRowInsets(.init(top: 8, leading: PharosDesign.pageInset,
                                bottom: 8, trailing: 0))
        }

        Section("Description") {
            Text(project.notes.isEmpty ? "Add a description from Pharos on Mac or when creating the project." : project.notes)
                .foregroundStyle(project.notes.isEmpty ? .secondary : .primary)
        }

        Section("Project information") {
            if let path = project.localPath {
                LabeledContent("Path", value: (path as NSString).abbreviatingWithTildeInPath)
            } else {
                LabeledContent("Checkout", value: "Not on this Host")
            }
            if let remote = project.githubRemote {
                LabeledContent("Git remote", value: remote)
            }
            LabeledContent("Issues", value: "\(project.issues.count)")
            LabeledContent("Updates", value: "\(project.updates.count)")
        }

        Section("Live agents") {
            if agents.isEmpty {
                Text("No agent currently reports this project.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agents) { member in
                    LabeledContent {
                        Text((member.state ?? "online").capitalized)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("@\(member.nick)", systemImage: AgentStatus.icon(member.kind))
                    }
                }
            }
        }
    }
}

private struct ProjectPropertyChip: View {
    let title: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PharosDesign.secondaryBackground, in: .capsule)
    }
}

private struct ProjectActivitySections: View {
    let project: RemoteProject
    let agents: [MeshMember]

    var body: some View {
        Section("Recent activity") {
            ForEach(agents) { member in
                Label("@\(member.nick) is \((member.state ?? "online").lowercased())", systemImage: "bolt.horizontal.circle")
            }
            ForEach(project.updates) { update in
                VStack(alignment: .leading, spacing: 4) {
                    Text(update.body)
                    Text(update.issueNumber.map { "Issue #\($0) · \(update.kind.capitalized)" } ?? update.kind.capitalized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if agents.isEmpty && project.updates.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Agent presence and project updates will appear here."))
            }
        }
    }
}

private struct ProjectIssuesSection: View {
    let issues: [RemoteIssue]

    var body: some View {
        Section("Issues") {
            if issues.isEmpty {
                ContentUnavailableView("No issues", systemImage: "checklist",
                                       description: Text("Use + to create the first issue."))
            } else {
                ForEach(issues.sorted { $0.number > $1.number }) { issue in
                    HStack(spacing: 10) {
                        PharosStatusGlyph(kind: IssueWorkflowState(issue.status).glyph, size: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title)
                                .font(.body.weight(.medium))
                            Text("#\(issue.number) · \(IssueWorkflowState(issue.status).displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

private struct NewProjectIssueView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectName: String
    let onCreated: () -> Void
    @State private var title = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Issue") {
                    TextField("Issue title", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    LabeledContent("Project", value: projectName)
                    LabeledContent("Status", value: "Todo")
                }
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("New issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        let succeeded = await store.addIssue(to: projectName, title: title)
        saving = false
        if succeeded {
            onCreated()
            dismiss()
        }
    }
}

private extension IssueWorkflowState {
    var isOpen: Bool {
        switch self {
        case .other(let raw): !["done", "canceled", "cancelled"].contains(raw.lowercased())
        default: true
        }
    }
}
