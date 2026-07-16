import SwiftUI

/// Open work across the registry, grouped by workflow state instead of by card.
struct IssuesView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var issues: [RemoteIssue] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var filter: IssueFilter = .all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PharosFilterStrip(options: IssueFilter.allCases.map { ($0, $0.title) }, selection: $filter)
                        .padding(.vertical, 4)
                        .listRowInsets(.init())
                        .listRowSeparator(.hidden)
                }
                ForEach(grouped, id: \.status) { group in
                    Section {
                        ForEach(group.issues) { issue in
                            NavigationLink { IssueSummaryView(issue: issue) } label: { IssueIndexRow(issue: issue) }
                                .listRowInsets(.init(top: 0, leading: PharosDesign.pageInset,
                                                    bottom: 0, trailing: PharosDesign.pageInset))
                        }
                    } header: {
                        PharosSectionTitle(title: group.status.displayName, count: group.issues.count)
                    }
                }
            }
            .pharosPlainList()
            .overlay { stateOverlay }
            .navigationTitle("Issues")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(IssueFilter.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Issue display options")
                }
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        if loading && issues.isEmpty {
            PharosSkeletonRows(count: 7)
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 10)
                .background(PharosDesign.pageBackground)
        } else if filtered.isEmpty {
            ContentUnavailableView {
                Label(loadError == nil ? "No open issues" : "Issues unavailable",
                      systemImage: loadError == nil ? "checkmark.circle" : "exclamationmark.triangle")
            } description: {
                Text(emptyDescription)
            } actions: {
                if loadError != nil { Button("Try again") { Task { await load() } } }
            }
        }
    }

    private var filtered: [RemoteIssue] {
        issues.filter { issue in
            let state = IssueWorkflowState(issue.status)
            let included = switch filter {
            case .all: true
            case .active: state == .inProgress || state == .blocked || state == .review
            case .backlog: state == .backlog || state == .todo
            }
            return included
        }
    }

    private var grouped: [(status: IssueWorkflowState, issues: [RemoteIssue])] {
        Dictionary(grouping: filtered) { IssueWorkflowState($0.status) }
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

    private var emptyDescription: String {
        if let loadError { return loadError }
        if settings.mesh.host.isEmpty { return "Connect to your Broker in Settings to load issues." }
        return filter == .all ? "Nothing is open across your projects." : "No issues match this workflow filter."
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

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        if let viaMesh = await store.fetchIssuesOverMesh() {
            issues = viaMesh
            return
        }
        loadError = "The Broker is unavailable and no issue cache exists yet."
    }
}

private enum IssueFilter: String, CaseIterable, Identifiable {
    case all, active, backlog
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All open"
        case .active: "In progress"
        case .backlog: "Todo & backlog"
        }
    }
}

private enum IssueWorkflowState: Hashable {
    case blocked, inProgress, review, todo, backlog, other(String)

    init(_ raw: String) {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "blocked": self = .blocked
        case "doing", "in-progress", "inprogress": self = .inProgress
        case "review", "in-review": self = .review
        case "todo", "open": self = .todo
        case "backlog": self = .backlog
        default: self = .other(raw)
        }
    }

    var displayName: String {
        switch self {
        case .blocked: "Blocked"
        case .inProgress: "In progress"
        case .review: "Review"
        case .todo: "Todo"
        case .backlog: "Backlog"
        case .other(let raw): raw.capitalized
        }
    }

    var sortOrder: Int {
        switch self {
        case .blocked: 0
        case .inProgress: 1
        case .review: 2
        case .todo: 3
        case .backlog: 4
        case .other: 5
        }
    }

    var glyph: PharosStatusGlyph.Kind {
        switch self {
        case .blocked: .blocked
        case .inProgress: .active
        case .review: .warning
        case .todo: .idle
        case .backlog, .other: .offline
        }
    }
}

private struct IssueIndexRow: View {
    let issue: RemoteIssue

    var body: some View {
        HStack(spacing: 11) {
            priorityIcon
                .frame(width: 24)
            PharosStatusGlyph(kind: IssueWorkflowState(issue.status).glyph, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(issue.project) · #\(issue.number)\(labelSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, PharosDesign.rowVerticalPadding)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var priorityIcon: some View {
        let priority = issue.priority.lowercased()
        return Image(systemName: priority == "urgent" ? "exclamationmark.square.fill" : "chart.bar.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(priority == "urgent" || priority == "high" ? Color.orange : Color.secondary)
            .opacity(priority == "none" || priority.isEmpty ? 0.28 : 1)
    }

    private var labelSummary: String {
        guard let first = issue.labels.first else { return "" }
        return " · \(first)"
    }
}

private struct IssueSummaryView: View {
    let issue: RemoteIssue

    var body: some View {
        List {
            Section {
                Text(issue.title).font(.title3.weight(.semibold))
                LabeledContent("Project", value: issue.project)
                LabeledContent("Issue", value: "#\(issue.number)")
                LabeledContent("Status", value: IssueWorkflowState(issue.status).displayName)
                if !issue.priority.isEmpty, issue.priority != "none" {
                    LabeledContent("Priority", value: issue.priority.capitalized)
                }
                if !issue.labels.isEmpty { LabeledContent("Labels", value: issue.labels.joined(separator: ", ")) }
            }
        }
        .navigationTitle("\(issue.project)-\(issue.number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
