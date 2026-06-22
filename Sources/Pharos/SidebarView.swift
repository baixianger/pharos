import SwiftUI

/// Single sidebar with a watchlist-style group switcher in the section header.
/// Search + tools live in the window toolbar (see ContentView).
struct ProjectsSidebar: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProject: Project.ID?
    let searchText: String
    @State private var newGroupShown = false
    @State private var newGroupName = ""
    @State private var renameTarget: Project?
    @State private var renameText = ""

    var body: some View {
        List(selection: $selectedProject) {
            Section {
                navRow("Dashboard", "Stats · activity · all projects", "square.grid.2x2",
                       selected: selectedProject == nil) { selectedProject = nil }
            }
            Section {
                ForEach(shown) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu { rowMenu(project) }
                }
            } header: {
                groupHeader
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Pharos")
        .overlay { if store.visibleProjects.isEmpty { emptyState } }
        .alert("New group", isPresented: $newGroupShown) {
            TextField("Name", text: $newGroupName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                let n = newGroupName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { store.addGroup(n); store.selection = .group(n) }
            }
        }
        .alert("Rename project", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                if let p = renameTarget { store.rename(p.id, to: renameText) }
                renameTarget = nil
            }
        }
    }

    /// A Wick-style top-of-sidebar nav row: gradient icon badge + title +
    /// subtitle, highlighted when selected.
    @ViewBuilder
    private func navRow(_ title: String, _ subtitle: String, _ symbol: String,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private var groupHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(store.currentTitle.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            groupMenu
        }
    }

    /// Group-filtered projects, narrowed by the toolbar search field.
    private var shown: [Project] {
        let base = store.visibleProjects
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q)
                || ($0.localPath ?? $0.githubRemote ?? "").lowercased().contains(q)
        }
    }

    /// Flat menu — groups listed directly (a checkmark marks the current one).
    private var groupMenu: some View {
        Menu {
            Button { store.selection = .all } label: {
                Label("All Projects (\(store.projects.count))",
                      systemImage: store.selection == .all ? "checkmark" : "square.grid.2x2")
            }
            ForEach(store.groups, id: \.self) { g in
                Button { store.selection = .group(g) } label: {
                    Label("\(g) (\(store.count(in: g)))",
                          systemImage: store.selection == .group(g) ? "checkmark" : "tag")
                }
            }
            Divider()
            Button { newGroupName = ""; newGroupShown = true } label: {
                Label("New group…", systemImage: "plus")
            }
            if case .group(let g) = store.selection {
                Button(role: .destructive) { store.removeGroup(g) } label: {
                    Label("Delete “\(g)”", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch / add group")
        .accessibilityLabel("Switch or add group")
    }

    @ViewBuilder
    private func rowMenu(_ project: Project) -> some View {
        if store.groups.isEmpty {
            Text("No groups yet")
        } else {
            ForEach(store.groups, id: \.self) { g in
                let isMember = project.tags.contains(g)
                Button { store.toggleMembership(project.id, group: g) } label: {
                    Label(isMember ? "Remove from \(g)" : "Add to \(g)",
                          systemImage: isMember ? "minus.circle" : "plus.circle")
                }
            }
        }
        Divider()
        Button { renameText = project.name; renameTarget = project } label: {
            Label("Rename…", systemImage: "pencil")
        }
        Button(role: .destructive) { store.remove(project) } label: {
            Label("Remove from Pharos", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "tray")
        } actions: {
            VStack(spacing: 8) {
                Button("Add Local Folder") { store.requestAdd() }.buttonStyle(.borderedProminent)
                Button("Import from GitHub") { store.requestImport() }
            }
        }
    }
}

/// Watchlist-style row: project name over its directory, plus a neutral
/// commit-activity sparkline (system colour — no red/green).
struct ProjectRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project

    var body: some View {
        let git = store.gitInfo[project.id]
        let running = store.hasRunningAgent(project)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if running {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                            .help("Agent running")
                            .accessibilityHidden(true)
                    }
                }
                Text(directory)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let git, git.isRepo, git.activity.contains(where: { $0 > 0 }) {
                Sparkline(values: git.activity)
                    .frame(width: 46, height: 20)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .task(id: "\(project.id)|\(store.gitRefreshToken)") { await store.ensureGit(project) }
    }

    private var directory: String {
        if let p = project.localPath, !p.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        }
        return project.githubRemote ?? "—"
    }
}

/// Tiny area sparkline (neutral system colour by default), modeled on Wick's SparklineView.
struct Sparkline: View {
    let values: [Int]
    var tint: Color = .secondary

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxV = CGFloat(max(values.max() ?? 1, 1))
            let n = max(values.count, 1)
            let stepX = n > 1 ? w / CGFloat(n - 1) : w
            let pts: [CGPoint] = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX, y: h - (CGFloat(v) / maxV) * h)
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: h))
                    for pt in pts { p.addLine(to: pt) }
                    p.addLine(to: CGPoint(x: pts.last?.x ?? 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
