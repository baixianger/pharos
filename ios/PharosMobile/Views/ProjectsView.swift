import SwiftUI

/// Registry projects presented as a quiet, status-first Linear-style index.
/// Project data still comes from the Mesh broker with the existing SSH fallback.
struct ProjectsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @State private var projects: [RemoteProject] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var filter: ProjectFilter = .all
    private let service = RemoteAgentService()

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
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(ProjectFilter.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Project display options")
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
        guard let host = settings.registryHost, let identityID = host.identityID else { return }
        do {
            let key = try identities.privateKey(for: identityID)
            projects = try await service.listProjects(profile: host, privateKey: key)
        } catch { loadError = error.localizedDescription }
    }
}

private enum ProjectFilter: String, CaseIterable, Identifiable {
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

private struct ProjectRow: View {
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

private struct ProjectSummaryView: View {
    let project: RemoteProject
    let agents: [MeshMember]

    var body: some View {
        List {
            Section("Project") {
                LabeledContent("Name", value: project.name)
                if let path = project.localPath {
                    LabeledContent("Path", value: (path as NSString).abbreviatingWithTildeInPath)
                }
                if let remote = project.githubRemote { LabeledContent("Git remote", value: remote) }
                if !project.tags.isEmpty { LabeledContent("Tags", value: project.tags.joined(separator: ", ")) }
            }
            Section("Live agents") {
                if agents.isEmpty {
                    Text("No agent currently reports this project.").foregroundStyle(.secondary)
                } else {
                    ForEach(agents) { member in
                        Label("@\(member.nick)", systemImage: AgentStatus.icon(member.kind))
                    }
                }
            }
        }
        .navigationTitle(project.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
