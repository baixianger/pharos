import SwiftUI
import UIKit

/// Registry projects presented as a quiet, status-first Linear-style index.
/// Distributed mode reads the device-local signed replica; legacy mode retains
/// the Broker cache until the migration flag becomes the only runtime.
struct ProjectsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(DistributedMeshSupport.self) private var distributedMesh
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
                        // Only label the split when both groups are present;
                        // otherwise the filter strip already says what this is.
                        if showsGroupHeaders {
                            PharosSectionTitle(title: "In progress", count: activeProjects.count)
                        }
                    }
                }

                if !otherProjects.isEmpty {
                    Section {
                        ForEach(otherProjects) { project in projectLink(project) }
                    } header: {
                        if showsGroupHeaders {
                            PharosSectionTitle(title: filter == .local ? "On this Mesh" : "Projects",
                                               count: otherProjects.count)
                        }
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
            .task(id: distributedMesh.registryRevision) { await load() }
            .refreshable { await load() }
        }
    }

    private func projectLink(_ project: RemoteProject) -> some View {
        NavigationLink { ProjectSummaryView(project: project, agents: agents(for: project)) } label: {
            ProjectRow(project: project, agents: agents(for: project))
        }
        .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                            bottom: 0, trailing: PharosDesign.pageInset))
        .listRowSeparator(.hidden)
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
    /// The "In progress" / "Projects" split is only worth labeling when both
    /// groups actually have rows; with one group the filter strip is enough.
    private var showsGroupHeaders: Bool { !activeProjects.isEmpty && !otherProjects.isEmpty }

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
        if isDistributed { return "Create a project here, or pair a trusted device to receive its replicated projects." }
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
        loadError = isDistributed
            ? "Pair this iPhone with a trusted Pharos device before loading replicated projects."
            : "The Broker is unavailable and no project cache exists yet."
    }

    private var isDistributed: Bool {
        PharosMeshRuntimeMode.usesDistributedMesh
    }
}

private struct NewProjectView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var githubRemote = ""
    @State private var notes = ""
    @State private var tags = ""
    @State private var yolo = true
    @State private var tmux = false
    @State private var playbooks: [RemotePlaybook] = []
    @State private var milestones: [ProjectMilestoneDraft] = []
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
                ProjectExecutionDefaultsSection(yolo: $yolo, tmux: $tmux)
                ProjectPlaybooksSection(playbooks: $playbooks)
                ProjectMilestonesSection(milestones: $milestones)
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
                                               notes: notes, tags: parsedTags,
                                               yolo: yolo, tmux: tmux,
                                               playbooks: cleanedPlaybooks,
                                               milestones: cleanedMilestones)
        saving = false
        if succeeded {
            onCreated()
            dismiss()
        }
    }

    private var cleanedPlaybooks: [RemotePlaybook] {
        playbooks.compactMap { value in
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = value.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }
            return RemotePlaybook(id: value.id, name: name, command: command)
        }
    }

    private var cleanedMilestones: [RemoteMilestone] {
        milestones.compactMap(\.remoteValue)
    }
}

private struct EditProjectView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let project: RemoteProject
    let onSaved: () -> Void

    @State private var name: String
    @State private var githubRemote: String
    @State private var notes: String
    @State private var tags: String
    @State private var yolo: Bool
    @State private var tmux: Bool
    @State private var playbooks: [RemotePlaybook]
    @State private var milestones: [ProjectMilestoneDraft]
    @State private var saving = false

    init(project: RemoteProject, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _name = State(initialValue: project.name)
        _githubRemote = State(initialValue: project.githubRemote ?? "")
        _notes = State(initialValue: project.notes)
        _tags = State(initialValue: project.tags.joined(separator: ", "))
        _yolo = State(initialValue: project.yolo)
        _tmux = State(initialValue: project.tmux)
        _playbooks = State(initialValue: project.playbooks)
        _milestones = State(initialValue: project.milestones.map(ProjectMilestoneDraft.init))
    }

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
                    Text("Separate tags with commas.")
                }
                ProjectExecutionDefaultsSection(yolo: $yolo, tmux: $tmux)
                ProjectPlaybooksSection(playbooks: $playbooks)
                ProjectMilestonesSection(milestones: $milestones)
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("Edit project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
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
        let succeeded = await store.updateProject(project, name: name, githubRemote: githubRemote,
                                                  notes: notes, tags: parsedTags,
                                                  yolo: yolo, tmux: tmux,
                                                  playbooks: cleanedPlaybooks,
                                                  milestones: cleanedMilestones)
        saving = false
        if succeeded {
            onSaved()
            dismiss()
        }
    }

    private var cleanedPlaybooks: [RemotePlaybook] {
        playbooks.compactMap { value in
            let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = value.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !command.isEmpty else { return nil }
            return RemotePlaybook(id: value.id, name: name, command: command)
        }
    }

    private var cleanedMilestones: [RemoteMilestone] {
        milestones.compactMap(\.remoteValue)
    }
}

private struct ProjectExecutionDefaultsSection: View {
    @Binding var yolo: Bool
    @Binding var tmux: Bool

    var body: some View {
        Section {
            Toggle("Allow autonomous agent actions", isOn: $yolo)
            Toggle("Keep agents in persistent tmux sessions", isOn: $tmux)
        } header: {
            Text("Agent defaults")
        } footer: {
            Text("These defaults follow the project. Each Host still chooses its own checkout path and execution environment.")
        }
    }
}

private struct ProjectPlaybooksSection: View {
    @Binding var playbooks: [RemotePlaybook]

    var body: some View {
        Section {
            ForEach($playbooks) { $playbook in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Playbook name", text: $playbook.name)
                    TextField("Command", text: $playbook.command, axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(2...5)
                }
            }
            .onDelete { playbooks.remove(atOffsets: $0) }
            Button("Add playbook", systemImage: "plus") {
                playbooks.append(RemotePlaybook(
                    id: UUID().uuidString, name: "", command: ""
                ))
            }
        } header: {
            Text("Playbooks")
        } footer: {
            Text("Swipe a playbook to remove it. Commands run only on the Host you choose.")
        }
    }
}

private struct ProjectMilestonesSection: View {
    @Binding var milestones: [ProjectMilestoneDraft]

    var body: some View {
        Section {
            ForEach($milestones) { $milestone in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Milestone name", text: $milestone.name)
                    Toggle("Due date", isOn: $milestone.hasDue)
                    if milestone.hasDue {
                        DatePicker(
                            "Due", selection: $milestone.due,
                            displayedComponents: .date
                        )
                    }
                }
            }
            .onDelete { milestones.remove(atOffsets: $0) }
            Button("Add milestone", systemImage: "plus") {
                milestones.append(ProjectMilestoneDraft())
            }
        } header: {
            Text("Milestones")
        } footer: {
            Text("Removing a milestone also clears it from issues that used it.")
        }
    }
}

private struct ProjectMilestoneDraft: Identifiable, Hashable {
    let id: String
    var name: String
    var hasDue: Bool
    var due: Date
    let createdAt: Date

    init(
        id: String = UUID().uuidString, name: String = "",
        hasDue: Bool = false, due: Date = .now, createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.hasDue = hasDue
        self.due = due
        self.createdAt = createdAt
    }

    init(_ milestone: RemoteMilestone) {
        id = milestone.id
        name = milestone.name
        hasDue = milestone.due != nil
        due = milestone.due ?? .now
        createdAt = milestone.createdAt
    }

    var remoteValue: RemoteMilestone? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return RemoteMilestone(
            id: id, name: value, due: hasDue ? due : nil,
            createdAt: createdAt
        )
    }
}

private struct ProjectUpdateComposer: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let projectName: String
    let onPosted: () -> Void

    @State private var body_ = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Update") {
                    TextField("What changed?", text: $body_, axis: .vertical)
                        .lineLimit(4...12)
                }
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("Post update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Posting…" : "Post") { Task { await post() } }
                        .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func post() async {
        saving = true
        let succeeded = await store.addProjectUpdate(to: projectName, body: body_)
        saving = false
        if succeeded {
            onPosted()
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
    @Environment(\.dismiss) private var dismiss
    @State private var project: RemoteProject
    let agents: [MeshMember]
    @State private var tab: ProjectDetailTab = .overview
    @State private var showingNewIssue = false
    @State private var showingEditor = false
    @State private var showingUpdateComposer = false
    @State private var showingDeleteConfirm = false
    @State private var isDeleting = false

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
                ProjectAutomationSummarySection(
                    yolo: project.yolo, tmux: project.tmux
                )
                ProjectPlaybookSummarySection(playbooks: project.playbooks)
                ProjectMilestoneSummarySection(milestones: project.milestones)
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
                    Button { showingUpdateComposer = true } label: {
                        Label("Post update", systemImage: "text.bubble")
                    }
                    Button { showingEditor = true } label: {
                        Label("Edit project", systemImage: "square.and.pencil")
                    }
                    Divider()
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
                    Divider()
                    Button(role: .destructive) {
                        showingDeleteConfirm = true
                    } label: {
                        Label("Delete project", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More project actions")
                .disabled(isDeleting)
            }
        }
        .sheet(isPresented: $showingNewIssue) {
            NewIssueView(initialProject: project.name) {
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showingEditor) {
            EditProjectView(project: project) {
                Task { await reload() }
            }
        }
        .sheet(isPresented: $showingUpdateComposer) {
            ProjectUpdateComposer(projectName: project.name) {
                Task { await reload() }
            }
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $showingDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                isDeleting = true
                Task {
                    let ok = await store.deleteProject(project)
                    isDeleting = false
                    if ok { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The project and its issues move to Trash and can be restored from Pharos on Mac.")
        }
    }

    private func reload() async {
        guard let projects = await store.fetchProjectsOverMesh(),
              let updated = projects.first(where: { $0.id == project.id }) else { return }
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
        if PharosMeshRuntimeMode.usesDistributedMesh {
            return "Project details, activity, and issues from your signed device replica."
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

private struct ProjectAutomationSummarySection: View {
    let yolo: Bool
    let tmux: Bool

    var body: some View {
        Section("Agent defaults") {
            LabeledContent(
                "Autonomous actions", value: yolo ? "Allowed" : "Ask first"
            )
            LabeledContent(
                "Session persistence", value: tmux ? "tmux" : "Standard"
            )
        }
    }
}

private struct ProjectPlaybookSummarySection: View {
    let playbooks: [RemotePlaybook]

    var body: some View {
        if !playbooks.isEmpty {
            Section("Playbooks") {
                ForEach(playbooks) { playbook in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playbook.name).font(.headline)
                        Text(playbook.command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct ProjectMilestoneSummarySection: View {
    let milestones: [RemoteMilestone]

    var body: some View {
        if !milestones.isEmpty {
            Section("Milestones") {
                ForEach(milestones) { milestone in
                    LabeledContent(milestone.name) {
                        if let due = milestone.due {
                            Text(due, format: .dateTime.year().month().day())
                        } else {
                            Text("No due date").foregroundStyle(.secondary)
                        }
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
