import SwiftUI

/// All open issues across every registered project, fetched from the hub via
/// `pharos issue list` over SSH and grouped by project.
struct IssuesView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(SSHIdentityStore.self) private var identities
    @State private var issues: [RemoteIssue] = []
    @State private var loading = false
    @State private var loadError: String?
    private let service = RemoteAgentService()

    var body: some View {
        NavigationStack {
            List {
                ForEach(grouped, id: \.project) { group in
                    Section {
                        ForEach(group.issues) { IssueRow(issue: $0) }
                    } header: {
                        Text(group.project).font(.headline).textCase(nil)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay { overlay }
            .navigationTitle("Issues")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if loading { ProgressView() }
                    else if !issues.isEmpty { Text("\(issues.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder private var overlay: some View {
        if issues.isEmpty && !loading {
            ContentUnavailableView {
                Label("No open issues", systemImage: "checkmark.circle")
            } description: {
                Text(loadError ?? (settings.mesh.host.isEmpty
                     ? "Connect to your Mesh in Settings — issues are served by the hub."
                     : "Nothing open across your projects. (An older hub needs the registry update, or add an SSH host mapping to read issues directly.)"))
            }
        }
    }

    private var grouped: [(project: String, issues: [RemoteIssue])] {
        Dictionary(grouping: issues) { $0.project }
            .map { (project: $0.key, issues: $0.value.sorted { $0.number < $1.number }) }
            .sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        // 1. Preferred: issues from the hub over the mesh.
        if let viaMesh = await store.fetchIssuesOverMesh() {
            issues = viaMesh
            return
        }
        // 2. Fallback: direct SSH to a configured host (pre-redeploy hubs).
        guard let host = settings.registryHost, let identityID = host.identityID else { return }
        do {
            let key = try identities.privateKey(for: identityID)
            issues = try await service.listIssues(profile: host, privateKey: key)
        } catch { loadError = error.localizedDescription }
    }
}

private struct IssueRow: View {
    let issue: RemoteIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("#\(issue.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text(issue.title).font(.subheadline).lineLimit(2)
            }
            HStack(spacing: 6) {
                badge(issue.status, color: statusColor)
                if !issue.priority.isEmpty, issue.priority != "none" { badge(issue.priority, color: priorityColor) }
                ForEach(issue.labels, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var statusColor: Color {
        switch issue.status.lowercased() {
        case "done", "closed", "shipped":         return .green
        case "doing", "in-progress", "inprogress": return .blue
        case "blocked":                            return .red
        case "review":                             return .purple
        default:                                   return .gray   // todo / backlog
        }
    }

    private var priorityColor: Color {
        switch issue.priority.lowercased() {
        case "urgent", "high": return .red
        case "medium":         return .orange
        default:               return .gray   // low
        }
    }
}
