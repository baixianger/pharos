import SwiftUI

/// The home screen (shown when no project is selected): a cross-project rollup of
/// projects, groups, issues, milestones, and recent activity — click anything to
/// jump to it.
struct DashboardView: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProject: Project.ID?

    private var projects: [Project] { store.projects }
    private var allIssues: [(p: Project, i: Issue)] { projects.flatMap { p in p.issues.map { (p, $0) } } }
    private var openIssues: [(p: Project, i: Issue)] { allIssues.filter { $0.i.status.isOpen } }
    private var blocked: [(p: Project, i: Issue)] {
        openIssues.filter { $0.i.relations.contains { $0.kind == .blockedBy } }
    }
    private var urgent: [(p: Project, i: Issue)] {
        openIssues.filter { $0.i.priority == .urgent }
    }
    private var activeAgents: [(p: Project, i: Issue)] {
        allIssues.filter { if let s = $0.i.activeSession { return store.runningSessions.contains(s) } else { return false } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statTiles
                statusCard
                if !blocked.isEmpty || !urgent.isEmpty { attentionCard }
                if !activeAgents.isEmpty { agentsCard }
                if projects.contains(where: { !$0.milestones.isEmpty }) { milestonesCard }
                if !store.groups.isEmpty { groupsCard }
                recentCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    // MARK: Tiles

    private var statTiles: some View {
        HStack(spacing: 12) {
            tile("\(projects.count)", "Projects", "square.grid.2x2")
            tile("\(store.groups.count)", "Groups", "tag")
            tile("\(openIssues.count)", "Open issues", "smallcircle.filled.circle")
            tile("\(store.runningSessions.count)", "Agents running", "sparkles")
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
                    issueRow(row.p, row.i, leading: "circle.fill", tint: .green, note: "running")
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
                                        .font(.caption2)
                                        .foregroundStyle(due < Date() ? .red : .secondary)
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

    private var groupsCard: some View {
        card("Groups") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(store.groups, id: \.self) { g in
                    let ps = projects.filter { $0.tags.contains(g) }
                    let openG = ps.reduce(0) { $0 + $1.issues.filter { $0.status.isOpen }.count }
                    Button { store.selection = .group(g) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tag").foregroundStyle(.secondary)
                            Text(g).font(.callout)
                            Spacer()
                            Text("\(ps.count) projects · \(openG) open").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recentCard: some View {
        let entries = recentActivity().prefix(6)
        return card("Recent activity") {
            if entries.isEmpty {
                Text("Nothing yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(entries)) { entry in activityRow(entry) }
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
            for i in p.issues { out.append(.issue(projectID: p.id, projectName: p.name, issue: i)) }
            for u in p.updates { out.append(.update(projectID: p.id, projectName: p.name, update: u)) }
        }
        return out.sorted { $0.date > $1.date }
    }

    private func open(_ p: Project, _ issue: Issue) {
        selectedProject = p.id
        store.requestIssue(p.id, number: issue.number)
    }

    private func openProject(_ p: Project) { selectedProject = p.id }
}
