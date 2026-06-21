import SwiftUI

/// One entry in the cross-project activity feed: either an issue (by its last
/// update time) or a project-log update.
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

/// A view of all recent issues and project-log updates across every project,
/// newest first. Clicking an entry jumps to it in the main window.
struct ActivityView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedProject: Project.ID?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", issues = "Issues", updates = "Updates"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all

    private var entries: [ActivityEntry] {
        var out: [ActivityEntry] = []
        if filter != .updates {
            for p in store.projects {
                for issue in p.issues { out.append(.issue(projectID: p.id, projectName: p.name, issue: issue)) }
            }
        }
        if filter != .issues {
            for p in store.projects {
                for update in p.updates { out.append(.update(projectID: p.id, projectName: p.name, update: update)) }
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Activity").font(.title2).bold()
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).fixedSize().labelsHidden()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if entries.isEmpty {
                ContentUnavailableView(
                    "Nothing yet",
                    systemImage: "tray",
                    description: Text("Issues and project-log updates across all your projects appear here, newest first.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(entries.prefix(150)) { entry in
                        row(entry)
                            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 580, height: 620)
    }

    @ViewBuilder
    private func row(_ entry: ActivityEntry) -> some View {
        switch entry {
        case .issue(let pid, let pname, let issue):
            Button { open(projectID: pid, issueNumber: issue.number) } label: { issueRow(pname, issue) }
                .buttonStyle(.plain)
        case .update(let pid, let pname, let update):
            Button { open(projectID: pid, issueNumber: update.issueNumber) } label: { updateRow(pname, update) }
                .buttonStyle(.plain)
        }
    }

    private func issueRow(_ projectName: String, _ issue: Issue) -> some View {
        HStack(spacing: 10) {
            Image(systemName: issue.status.symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(issue.number)  \(issue.title)").font(.callout).lineLimit(1)
                Text("\(projectName) · \(issue.status.label) · updated \(issue.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if issue.priority != .none {
                Image(systemName: issue.priority.symbol)
                    .font(.caption).foregroundStyle(issue.priority == .urgent ? .orange : .secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func updateRow(_ projectName: String, _ update: ProjectUpdate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: update.kind == .agent ? "sparkles" : "text.bubble")
                .foregroundStyle(update.kind == .agent ? Color.blue : Color.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(update.body).font(.callout).lineLimit(2)
                Text("\(projectName) · \(update.createdAt.formatted(.relative(presentation: .named)))"
                     + (update.issueNumber.map { " · #\($0)" } ?? ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    private func open(projectID: Project.ID, issueNumber: Int?) {
        selectedProject = projectID
        if let n = issueNumber { store.requestIssue(projectID, number: n) }
        dismiss()
    }
}
