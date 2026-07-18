import SwiftUI
import UIKit

/// Open work across the registry, grouped by workflow state instead of by card.
struct IssuesView: View {
    @Environment(RoomStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var issues: [RemoteIssue] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var filter: IssueFilter = .open
    @State private var selectedLabel: String?
    @State private var showingNewIssue = false

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
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        // Only label status sections when more than one is
                        // visible; a single group would just echo the filter.
                        if grouped.count > 1 {
                            PharosSectionTitle(title: group.status.displayName, count: group.issues.count)
                        }
                    }
                }
            }
            .pharosPlainList()
            .overlay { stateOverlay }
            .navigationTitle("Issues")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingNewIssue = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add issue")
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(IssueFilter.allCases) { Text($0.title).tag($0) }
                        }
                        if !allLabels.isEmpty {
                            Picker("Label", selection: $selectedLabel) {
                                Text("All labels").tag(String?.none)
                                ForEach(allLabels, id: \.self) { Text($0).tag(String?.some($0)) }
                            }
                        }
                        Divider()
                        Button { Task { await load() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Issue display options")
                }
            }
            .sheet(isPresented: $showingNewIssue) {
                NewIssueView {
                    Task { await load() }
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
                Label(loadError == nil ? "No issues" : "Issues unavailable",
                      systemImage: loadError == nil ? "checkmark.circle" : "exclamationmark.triangle")
            } description: {
                Text(emptyDescription)
            } actions: {
                if loadError != nil { Button("Try again") { Task { await load() } } }
            }
        }
    }

    private var allLabels: [String] {
        Array(Set(issues.flatMap(\.labels))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filtered: [RemoteIssue] {
        issues.filter { issue in
            guard filter.includes(IssueWorkflowState(issue.status)) else { return false }
            if let selectedLabel, !issue.labels.contains(selectedLabel) { return false }
            return true
        }
    }

    private var grouped: [(status: IssueWorkflowState, issues: [RemoteIssue])] {
        Dictionary(grouping: filtered) { IssueWorkflowState($0.status) }
            .map { status, values in (status, values.sorted(by: issueOrder)) }
            .sorted { $0.status.sortOrder < $1.status.sortOrder }
    }

    /// Honor the desktop's manual board order when both issues carry it, then
    /// fall back to priority, then issue number.
    private func issueOrder(_ a: RemoteIssue, _ b: RemoteIssue) -> Bool {
        if let sa = a.sortOrder, let sb = b.sortOrder, sa != sb { return sa < sb }
        if priorityRank(a.priority) != priorityRank(b.priority) {
            return priorityRank(a.priority) < priorityRank(b.priority)
        }
        return a.number < b.number
    }

    private var emptyDescription: String {
        if let loadError { return loadError }
        if settings.mesh.host.isEmpty { return "Connect to your Broker in Settings to load issues." }
        if selectedLabel != nil { return "No issues match this label and filter." }
        return filter == .open ? "Nothing is open across your projects." : "No issues match this filter."
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

private struct NewIssueView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [RemoteProject] = []
    @State private var selectedProject = ""
    @State private var title = ""
    @State private var loadingProjects = true
    @State private var saving = false
    let onCreated: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Issue") {
                    Picker("Project", selection: $selectedProject) {
                        if projects.isEmpty {
                            Text(loadingProjects ? "Loading projects…" : "No projects available")
                                .tag("")
                        } else {
                            ForEach(projects) { project in
                                Text(project.name).tag(project.name)
                            }
                        }
                    }
                    TextField("Issue title", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section {
                    LabeledContent("Status", value: "Todo")
                    LabeledContent("Priority", value: "No priority")
                } footer: {
                    Text("Open the issue after creating it to add context, labels, and priority.")
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
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Adding…" : "Add") { Task { await save() } }
                        .disabled(selectedProject.isEmpty
                                  || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .task { await loadProjects() }
        }
    }

    private func loadProjects() async {
        loadingProjects = true
        defer { loadingProjects = false }
        projects = (await store.fetchProjectsOverMesh() ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selectedProject.isEmpty { selectedProject = projects.first?.name ?? "" }
    }

    private func save() async {
        saving = true
        let succeeded = await store.addIssue(to: selectedProject, title: title)
        saving = false
        if succeeded {
            onCreated()
            dismiss()
        }
    }
}

enum IssueFilter: String, CaseIterable, Identifiable {
    case open, inProgress, done, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "Open"
        case .inProgress: "In progress"
        case .done: "Done"
        case .all: "All"
        }
    }

    func includes(_ state: IssueWorkflowState) -> Bool {
        switch self {
        case .open: state.isOpen
        case .inProgress: state == .inProgress
        case .done: !state.isOpen          // done + canceled
        case .all: true
        }
    }
}

/// Mirrors the desktop `IssueStatus` exactly — the only five statuses the model
/// and CLI ever produce. Unknown raw values fall back to `.other` rather than
/// inventing states the rest of the app can't set.
enum IssueWorkflowState: Hashable {
    case inProgress, todo, backlog, done, canceled, other(String)

    init(_ raw: String) {
        switch raw.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "in-progress", "inprogress": self = .inProgress
        case "todo": self = .todo
        case "backlog": self = .backlog
        case "done": self = .done
        case "canceled", "cancelled": self = .canceled
        default: self = .other(raw)
        }
    }

    /// Open work vs resolved (done/canceled). Unknown states are treated as open.
    var isOpen: Bool {
        switch self {
        case .done, .canceled: false
        default: true
        }
    }

    var displayName: String {
        switch self {
        case .inProgress: "In progress"
        case .todo: "Todo"
        case .backlog: "Backlog"
        case .done: "Done"
        case .canceled: "Canceled"
        case .other(let raw): raw.capitalized
        }
    }

    /// Section order: active work first, resolved last.
    var sortOrder: Int {
        switch self {
        case .inProgress: 0
        case .todo: 1
        case .backlog: 2
        case .other: 3
        case .done: 4
        case .canceled: 5
        }
    }

    var glyph: PharosStatusGlyph.Kind {
        switch self {
        case .inProgress: .active
        case .todo: .idle
        case .backlog: .offline
        case .done: .done
        case .canceled: .warning
        case .other: .offline
        }
    }
}

struct IssueIndexRow: View {
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

struct IssueSummaryView: View {
    @Environment(RoomStore.self) private var store
    @State private var issue: RemoteIssue
    @State private var showingEditor = false

    init(issue: RemoteIssue) {
        _issue = State(initialValue: issue)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(issue.project.uppercased())-\(issue.number)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(issue.title)
                        .font(.title.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowSeparator(.hidden)
            }

            Section("Properties") {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        IssuePropertyChip(title: IssueWorkflowState(issue.status).displayName,
                                          symbol: IssueWorkflowState(issue.status).symbol,
                                          tint: .accentColor)
                        if !issue.priority.isEmpty, issue.priority != "none" {
                            IssuePropertyChip(title: issue.priority.capitalized,
                                              symbol: issue.priority.lowercased() == "urgent" ? "exclamationmark" : "chart.bar")
                        }
                        IssuePropertyChip(title: issue.project, symbol: "cube")
                        ForEach(issue.labels, id: \.self) { label in
                            IssuePropertyChip(title: label, symbol: "tag")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .listRowInsets(.init(top: 8, leading: PharosDesign.pageInset, bottom: 8, trailing: 0))
            }

            Section("Context") {
                if issue.body.isEmpty {
                    Text("No description yet. Tap Edit to add context.")
                        .foregroundStyle(.secondary)
                } else {
                    StableMarkdownView(content: issue.body)
                }
            }

            if let session = issue.activeSession {
                Section("Active agent") {
                    Label(session, systemImage: "bolt.horizontal.circle")
                }
            }
        }
        .pharosPlainList()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingEditor = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Edit issue")
                Menu {
                    Button { Task { await reload() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button {
                        UIPasteboard.general.string = "\(issue.project)-\(issue.number)"
                    } label: {
                        Label("Copy issue ID", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = issue.title
                    } label: {
                        Label("Copy title", systemImage: "text.quote")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More issue actions")
            }
        }
        .sheet(isPresented: $showingEditor) {
            IssueEditorView(issue: issue) { updated in
                issue = updated
            }
        }
    }

    private func reload() async {
        guard let issues = await store.fetchIssuesOverMesh(),
              let updated = issues.first(where: { $0.id == issue.id }) else { return }
        issue = updated
    }
}

private extension IssueWorkflowState {
    var symbol: String {
        switch self {
        case .inProgress: "circle.lefthalf.filled"
        case .todo: "circle"
        case .backlog: "circle.dashed"
        case .done: "checkmark.circle.fill"
        case .canceled: "xmark.circle"
        case .other: "circle"
        }
    }
}

private struct IssuePropertyChip: View {
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

private struct IssueEditorView: View {
    @Environment(RoomStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let issue: RemoteIssue
    let onSaved: (RemoteIssue) -> Void
    @State private var title: String
    @State private var bodyText: String
    @State private var status: String
    @State private var priority: String
    @State private var labels: String
    @State private var saving = false

    init(issue: RemoteIssue, onSaved: @escaping (RemoteIssue) -> Void) {
        self.issue = issue
        self.onSaved = onSaved
        _title = State(initialValue: issue.title)
        _bodyText = State(initialValue: issue.body)
        _status = State(initialValue: issue.status.isEmpty ? "todo" : issue.status)
        _priority = State(initialValue: issue.priority.isEmpty ? "none" : issue.priority)
        _labels = State(initialValue: issue.labels.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Issue") {
                    TextField("Title", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                    TextField("Context", text: $bodyText, axis: .vertical)
                        .lineLimit(5...14)
                }
                Section("Properties") {
                    Picker("Status", selection: $status) {
                        Text("Backlog").tag("backlog")
                        Text("Todo").tag("todo")
                        Text("In progress").tag("in_progress")
                        Text("Done").tag("done")
                        Text("Canceled").tag("canceled")
                    }
                    Picker("Priority", selection: $priority) {
                        Text("No priority").tag("none")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                        Text("Urgent").tag("urgent")
                    }
                    TextField("Labels, separated by commas", text: $labels)
                }
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .pharosPlainList()
            .navigationTitle("Edit issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() async {
        saving = true
        let parsedLabels = labels.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let succeeded = await store.updateIssue(issue, title: title, body: bodyText,
                                                status: status, priority: priority,
                                                labels: parsedLabels)
        saving = false
        if succeeded {
            onSaved(RemoteIssue(project: issue.project, number: issue.number,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                status: status, priority: priority, labels: parsedLabels,
                                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                                activeSession: issue.activeSession))
            dismiss()
        }
    }
}
