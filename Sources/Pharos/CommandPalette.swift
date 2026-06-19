import SwiftUI

// MARK: - CommandPalette

struct CommandPalette: View {
    @Environment(ProjectStore.self) private var store
    @Binding var selectedProject: Project.ID?
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted: Project.ID? = nil
    @FocusState private var fieldFocused: Bool

    @ViewBuilder
    private var resultsView: some View {
        ScrollViewReader { proxy in
            rowList
                .frame(maxHeight: 360)
                .onChange(of: results) { _, new in
                    highlighted = new.first?.id
                    if let h = new.first?.id { proxy.scrollTo(h, anchor: .center) }
                }
                .onChange(of: highlightedString) { _, newH in
                    proxy.scrollTo(newH, anchor: .center)
                }
        }
    }

    /// String-wrapped highlighted ID so onChange uses the two-arg overload cleanly.
    private var highlightedString: String { highlighted?.uuidString ?? "" }

    @ViewBuilder
    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { project in
                    let isHL = highlighted == project.id
                    PaletteRow(
                        project: project,
                        isHighlighted: isHL,
                        onSelect: { jump(to: project) },
                        onAction: { dismiss() }
                    )
                    .id(project.id)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var results: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.projects.sorted { $0.name.lowercased() < $1.name.lowercased() } }
        return store.projects.filter {
            $0.name.lowercased().contains(q) ||
            ($0.localPath?.lowercased().contains(q) == true) ||
            ($0.githubRemote?.lowercased().contains(q) == true)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search field ──────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 15, weight: .medium))
                TextField("Jump to a project or action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { activateHighlighted() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        highlighted = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.4)

            // ── Results list ──────────────────────────────────────────────
            if results.isEmpty {
                Text("No projects match \"\(query)\"")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .padding(.vertical, 32)
            } else {
                resultsView
            }
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .glassEffect()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 32, x: 0, y: 12)
        // Keyboard navigation
        .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
        // Esc to dismiss (also handled by .sheet dismiss, but belt-and-suspenders)
        .onKeyPress(.escape) { dismiss(); return .handled }
        .onAppear {
            fieldFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { _, _ in
            highlighted = results.first?.id
        }
    }

    // MARK: – Helpers

    private func jump(to project: Project) {
        selectedProject = project.id
        dismiss()
    }

    private func activateHighlighted() {
        guard let h = highlighted, let project = store.project(h) else { return }
        jump(to: project)
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        if let current = highlighted, let idx = results.firstIndex(where: { $0.id == current }) {
            let next = (idx + delta + results.count) % results.count
            highlighted = results[next].id
        } else {
            highlighted = delta > 0 ? results.first?.id : results.last?.id
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

// MARK: - PaletteRow

private struct PaletteRow: View {
    @Environment(ProjectStore.self) private var store
    let project: Project
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Project icon
            Image(systemName: project.hasLocal ? "folder.fill" : "cloud.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            // Name + path
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let path = project.localPath, !path.isEmpty {
                    Text(path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let remote = project.githubRemote {
                    Text(remote)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Quick-action buttons — only visible when this row is highlighted
            if isHighlighted {
                HStack(spacing: 4) {
                    // Launching agents and opening a terminal spawn processes, which
                    // a sandboxed Mac App Store app may not do — those quick actions
                    // are hidden there; Editor and Finder (NSWorkspace) remain.
                    #if !APP_STORE
                    QuickActionButton(
                        symbol: "sparkles",
                        label: "Claude",
                        disabled: !project.hasLocal
                    ) {
                        LaunchService.launchAgent(.claude, project: project, terminal: store.terminal)
                        onSelect()
                        onAction()
                    }

                    QuickActionButton(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        label: "Codex",
                        disabled: !project.hasLocal
                    ) {
                        LaunchService.launchAgent(.codex, project: project, terminal: store.terminal)
                        onSelect()
                        onAction()
                    }

                    QuickActionButton(
                        symbol: "terminal",
                        label: "Terminal",
                        disabled: !project.hasLocal
                    ) {
                        if let path = project.localPath {
                            LaunchService.openTerminal(at: path, terminal: store.terminal)
                        }
                        onSelect()
                        onAction()
                    }
                    #endif

                    QuickActionButton(
                        symbol: "pencil",
                        label: "Editor",
                        disabled: !project.hasLocal
                    ) {
                        if let path = project.localPath {
                            LaunchService.openEditor(store.editor, path: path)
                        }
                        onSelect()
                        onAction()
                    }

                    QuickActionButton(
                        symbol: "folder",
                        label: "Finder",
                        disabled: !project.hasLocal
                    ) {
                        if let path = project.localPath {
                            LaunchService.revealInFinder(path)
                        }
                        onSelect()
                        onAction()
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            isHighlighted
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .animation(.easeInOut(duration: 0.12), value: isHighlighted)
    }
}

// MARK: - QuickActionButton

private struct QuickActionButton: View {
    let symbol: String
    let label: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24)
                .background(.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(label)
    }
}
