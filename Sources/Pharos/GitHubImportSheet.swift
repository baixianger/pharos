import SwiftUI

/// Lists every GitHub repo (via `gh`), lets you check the ones to import and
/// assign them to a group, then adds them as GitHub-only projects.
struct GitHubImportSheet: View {
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var repos: [GitHubRepo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: Set<String> = []
    @State private var search = ""
    @State private var group = ""

    private var filtered: [GitHubRepo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = repos.sorted { $0.name.lowercased() < $1.name.lowercased() }
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Import from GitHub").font(.title2.bold())
                Spacer()
                if !repos.isEmpty {
                    Text("\(selected.count) selected · \(repos.count) repos")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter repositories", text: $search).textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Group {
                if loading {
                    ProgressView("Loading repositories…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn’t load repos",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else {
                    repoList
                }
            }
            .frame(height: 360)

            Divider()

            HStack(spacing: 8) {
                Text("Add to group:")
                TextField("optional", text: $group).frame(width: 150)
                if !store.groups.isEmpty {
                    Menu {
                        ForEach(store.groups, id: \.self) { g in Button(g) { group = g } }
                    } label: { Image(systemName: "chevron.down") }
                    .fixedSize()
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count)") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 660, height: 560)
        .task { await loadRepos() }
    }

    private var repoList: some View {
        List {
            ForEach(filtered) { repo in
                let isOn = selected.contains(repo.id)
                let already = store.contains(name: repo.name) || store.contains(remote: repo.url)
                HStack(spacing: 10) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(repo.name).font(.system(size: 13, weight: .semibold))
                            if repo.isPrivate {
                                Text("Private")
                                    .font(.caption2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                            }
                            if already {
                                Text("Added").font(.caption2.bold()).foregroundStyle(.green)
                            }
                        }
                        if let d = repo.description, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { if !already { toggle(repo) } }
                .opacity(already ? 0.45 : 1)
            }
        }
    }

    private func toggle(_ repo: GitHubRepo) {
        if selected.contains(repo.id) { selected.remove(repo.id) } else { selected.insert(repo.id) }
    }

    private func loadRepos() async {
        loading = true
        let result = await GitHubService.listRepos()
        repos = result
        if result.isEmpty {
            error = "No repositories returned. Check that `gh` is installed and authenticated (gh auth status)."
        }
        loading = false
    }

    private func importSelected() {
        let g = group.trimmingCharacters(in: .whitespaces)
        let chosen = repos.filter { selected.contains($0.id) }
        let fresh = chosen.filter { !(store.contains(name: $0.name) || store.contains(remote: $0.url)) }
        let projects = fresh.map {
            Project(name: $0.name, localPath: nil, githubRemote: $0.url,
                    tags: g.isEmpty ? [] : [g], yolo: true)
        }
        if !g.isEmpty { store.addGroup(g) }
        store.addProjects(projects)
        dismiss()
    }
}
