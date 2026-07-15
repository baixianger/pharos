import SwiftUI

/// All registered projects, read from the hub broker over the mesh (the hub is
/// the single source of truth). Falls back to a direct SSH `pharos list` when the
/// broker is older than the registry endpoint but an SSH host is configured.
struct ProjectsView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @State private var projects: [RemoteProject] = []
    @State private var loading = false
    @State private var loadError: String?
    private let service = RemoteAgentService()

    var body: some View {
        NavigationStack {
            List {
                ForEach(sorted) { project in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.headline)
                        if let path = project.localPath {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        if project.githubRemote != nil || !project.tags.isEmpty {
                            HStack(spacing: 6) {
                                if project.githubRemote != nil {
                                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                                        .labelStyle(.iconOnly).foregroundStyle(.secondary)
                                }
                                ForEach(project.tags, id: \.self) { tag in
                                    Text(tag).font(.caption2)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.secondary.opacity(0.15), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .overlay { overlay }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if loading { ProgressView() }
                    else if !projects.isEmpty { Text("\(projects.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private var sorted: [RemoteProject] {
        projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @ViewBuilder private var overlay: some View {
        if projects.isEmpty && !loading {
            ContentUnavailableView {
                Label("No projects", systemImage: "folder")
            } description: {
                Text(loadError ?? (store.selectedRoom == nil && settings.mesh.host.isEmpty
                     ? "Connect to your Mesh in Settings — projects are served by the hub."
                     : "The hub returned no projects. (An older hub needs the registry update, or add an SSH host mapping to read it directly.)"))
            }
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        // 1. Preferred: read the registry from the hub over the mesh.
        if let viaMesh = await store.fetchProjectsOverMesh() {
            projects = viaMesh
            return
        }
        // 2. Fallback: direct SSH to a configured host (pre-redeploy hubs).
        guard let host = settings.registryHost, let identityID = host.identityID else { return }
        do {
            let key = try identities.privateKey(for: identityID)
            projects = try await service.listProjects(profile: host, privateKey: key)
        } catch { loadError = error.localizedDescription }
    }
}
