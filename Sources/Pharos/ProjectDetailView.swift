import AppKit
import SwiftUI

struct ProjectDetailView: View {
    @Environment(ProjectStore.self) private var store
    let projectID: Project.ID

    @State private var git: GitInfo = .none
    @State private var loadingGit = false
    @State private var cloning = false
    @State private var heatmap: [[Int]] = []
    @State private var claudeSessions: [AgentSession] = []
    @State private var codexSessions: [AgentSession] = []
    @State private var sessionsLoading = false
    @State private var sessionTab: AgentKind = .claude
    @State private var worktrees: [Worktree] = []
    @State private var newWorktreeShown = false
    @State private var newWorktreeName = ""
    @State private var agentDesktop: Int? = nil
    @State private var tab: DetailTab = .overview
    @State private var addPlaybookShown = false
    @State private var newPlaybookName = ""
    @State private var newPlaybookCommand = ""
    @State private var peer: PeerStatus? = nil
    @State private var peerLoading = false
    @State private var ghStatus: GitHubStatus? = nil
    @State private var ghLoading = false
    @State private var worktreeToRemove: Worktree?
    @State private var worktreeDirtyCount = 0
    @State private var worktreeConfirmText = ""
    @State private var worktreeRemoving = false

    private enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case issues   = "Issues"
        case git      = "Git"
        case sessions = "Sessions"
        var id: String { rawValue }
    }

    // Issue/update composer state.
    @State private var newIssueTitle = ""
    @State private var newIssuePriority: IssuePriority = .none
    @State private var newUpdateText = ""
    @State private var showIssueComposer = false
    @State private var detailIssueNumber: Int?

    private var project: Project? { store.project(projectID) }

    var body: some View {
        Group {
            if let project {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(project)
                        Picker("Tab", selection: $tab) {
                            ForEach(DetailTab.allCases) { t in
                                Text(t.rawValue).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        GlassEffectContainer(spacing: 18) {
                            VStack(spacing: 18) {
                                tabContent(project)
                            }
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(project.name)
                .task(id: "\(projectID)|\(store.gitRefreshToken)|\(store.peerHost)") {
                    await loadGit(project)
                    await loadHeatmap(project)
                    await loadSessions(project)
                    await loadWorktrees(project)
                    await loadPeer(project)
                    await loadGitHubStatus(project)
                }
                .alert("New worktree", isPresented: $newWorktreeShown) {
                    TextField("branch name", text: $newWorktreeName)
                    Button("Cancel", role: .cancel) { }
                    Button("Create") {
                        let name = newWorktreeName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, let p = store.project(projectID), let repo = p.localPath else { return }
                        Task {
                            _ = await Task.detached { GitService.addWorktree(repo: repo, name: name) }.value
                            await loadWorktrees(p)
                        }
                    }
                }
                .alert("Add Playbook", isPresented: $addPlaybookShown) {
                    TextField("Name (e.g. dev server)", text: $newPlaybookName)
                    TextField("Command (e.g. npm run dev)", text: $newPlaybookCommand)
                    Button("Cancel", role: .cancel) { newPlaybookName = ""; newPlaybookCommand = "" }
                    Button("Add") {
                        let n = newPlaybookName.trimmingCharacters(in: .whitespaces)
                        let c = newPlaybookCommand.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty, !c.isEmpty, var p = store.project(projectID) else { return }
                        p.playbooks.append(Playbook(name: n, command: c))
                        store.update(p)
                        newPlaybookName = ""; newPlaybookCommand = ""
                    }
                }
                .sheet(item: $worktreeToRemove) { wt in
                    worktreeRemoveSheet(wt)
                }
            } else {
                ContentUnavailableView("Project not found", systemImage: "questionmark.folder")
            }
        }
    }

    // MARK: Tab content

    @ViewBuilder
    private func tabContent(_ project: Project) -> some View {
        switch tab {
        case .overview:
            actionsCard(project)
            if project.localPath == nil { localFolderCard(project) }
            notesCard(project)
            if !project.hasLocal, project.hasGitHub {
                cloneCard(project)
            }
            if project.hasGitHub {
                githubStatusCard(project)
            }
            playbooksCard(project)
        case .issues:
            issuesCard(project)
            logCard(project)
        case .git:
            if project.hasLocal {
                gitCard
                if git.isRepo { heatmapCard }
                if git.isRepo { worktreesCard }
                if !store.peerHost.isEmpty {
                    peerCard(project)
                }
            } else {
                Text("Not a local repository.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        case .sessions:
            sessionsCard
        }
    }

    // MARK: Header

    private func header(_ project: Project) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(project.name).font(.largeTitle.bold())
                    if !project.tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(project.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                Text(project.displayPath)
                    .font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                let claudeRunning = store.isRunning(project, .claude)
                let codexRunning  = store.isRunning(project, .codex)
                if claudeRunning || codexRunning {
                    HStack(spacing: 8) {
                        if claudeRunning { runningBadge(project: project, kind: .claude) }
                        if codexRunning { runningBadge(project: project, kind: .codex) }
                    }
                }
                if git.isRepo, git.activity.contains(where: { $0 > 0 }) {
                    Sparkline(values: git.activity)
                        .frame(width: 130, height: 36)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: Actions card

    private func actionsCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Actions").font(.headline)
            HStack(spacing: 10) {
                Button { LaunchService.revealInFinder(project.localPath ?? "") } label: {
                    Label("Finder", systemImage: "folder")
                }
                Button { LaunchService.openEditor(store.editor, path: project.localPath ?? "") } label: {
                    Label("Editor", systemImage: "curlybraces")
                }
                Button { LaunchService.openTerminal(at: project.localPath ?? "", terminal: store.terminal) } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                Button { launchAgentWithPreflight(.claude, project: project) } label: {
                    Label("Claude Code", systemImage: AgentKind.claude.symbol)
                }
                Button { launchAgentWithPreflight(.codex, project: project) } label: {
                    Label("Codex", systemImage: AgentKind.codex.symbol)
                }
            }
            .buttonStyle(.glass)
            .disabled(!project.hasLocal)

            HStack(spacing: 18) {
                Toggle("yolo", isOn: yoloBinding(project))
                Toggle("tmux", isOn: tmuxBinding(project))
                Divider().frame(height: 16)
                desktopPicker
            }
            .toggleStyle(.switch)
            .font(.system(size: 12, weight: .medium))
            .fixedSize()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Notes card

    private func notesCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.headline)
            TextField("Notes / description…", text: notesBinding(project), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...8)
                .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func notesBinding(_ project: Project) -> Binding<String> {
        Binding(
            get: { store.project(project.id)?.notes ?? "" },
            set: { newValue in
                if var p = store.project(project.id), p.notes != newValue {
                    p.notes = newValue; store.update(p)
                }
            }
        )
    }

    // MARK: Desktop picker

    private var desktopPicker: some View {
        let count = SpacesService.spaceCount()
        return HStack(spacing: 6) {
            Text("desktop").font(.system(size: 12, weight: .medium))
            Picker("desktop", selection: $agentDesktop) {
                Text("current").tag(Int?.none)
                ForEach(1...max(count, 1), id: \.self) { n in
                    Text("\(n)").tag(Optional(n))
                }
            }
            .labelsHidden()
            .frame(width: 70)
        }
    }

    // MARK: Git card

    private var gitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Git").font(.headline)
                Spacer()
                if loadingGit { ProgressView().controlSize(.small) }
            }
            if git.isRepo {
                infoRow("arrow.triangle.branch", "Branch", git.branch)
                infoRow("checkmark.seal", "Last commit", "\(git.lastCommitHash) · \(git.lastCommitSubject)")
                infoRow("clock", "Committed", git.lastCommitRelative)
                HStack(spacing: 18) {
                    stat("\(git.branchCount)", "branches")
                    stat("\(git.worktreeCount)", "worktrees")
                    stat(git.ahead > 0 ? "↑\(git.ahead)" : "0", "ahead")
                    stat(git.behind > 0 ? "↓\(git.behind)" : "0", "behind")
                    stat(git.isDirty ? "dirty" : "clean", "status")
                }
                .padding(.top, 4)
            } else if loadingGit {
                Text("Reading repository…").foregroundStyle(.secondary)
            } else {
                Text("Not a git repository.").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func infoRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(label).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(value).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold))
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: Commit-activity heatmap card

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit activity").font(.headline)
            if heatmap.isEmpty {
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    ContributionHeatmap(grid: heatmap)
                }
                Text("Last \(heatmap.count) weeks").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Peer machine card

    @ViewBuilder
    private func peerCard(_ project: Project) -> some View {
        let host = store.peerHost
        let localPath = project.localPath ?? ""
        VStack(alignment: .leading, spacing: 12) {
            // Header row
            HStack {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text("Peer: \(host)").font(.headline)
                Spacer()
                if peerLoading { ProgressView().controlSize(.small) }
            }

            // Directory override row
            HStack(spacing: 8) {
                Text("Directory on \(host)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize()
                TextField(localPath, text: peerPathBinding(project))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { Task { await loadPeer(project) } }
                Button("Check") { Task { await loadPeer(project) } }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(peerLoading)
            }

            Divider()

            // Status section
            if peerLoading && peer == nil {
                Text("Connecting…").foregroundStyle(.secondary).font(.callout)
            } else if let p = peer {
                if !p.reachable {
                    Label("Unreachable — host did not respond", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else if p.missing {
                    // Prominent not-on-peer message to prompt the user to fix the directory
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Not found on \(host)", systemImage: "questionmark.folder")
                            .font(.callout.weight(.medium))
                        let effectivePath = project.peerPath ?? localPath
                        Text("No git repo at \(effectivePath) — update the directory above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    infoRow("arrow.triangle.branch", "Peer branch", p.branch)
                    infoRow("checkmark.seal", "Peer HEAD", p.head)
                    if p.dirtyCount > 0 {
                        infoRow("pencil", "Peer changes", "\(p.dirtyCount) uncommitted")
                    } else {
                        infoRow("checkmark.circle", "Peer working tree", "clean")
                    }
                    Divider()
                    // Drift indicator: compare peer HEAD vs local last commit hash
                    let localHash = git.lastCommitHash
                    let inSync = !localHash.isEmpty && localHash == p.head
                    if inSync {
                        Label("In sync", systemImage: "arrow.left.arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else if localHash.isEmpty {
                        Label("Local HEAD unavailable", systemImage: "minus.circle")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Differs", systemImage: "arrow.left.arrow.right.square")
                                .font(.callout)
                                .foregroundStyle(.primary)
                            HStack(spacing: 4) {
                                Text("local").foregroundStyle(.secondary)
                                Text(localHash).fontWeight(.medium)
                                Text("↔")
                                Text("peer").foregroundStyle(.secondary)
                                Text(p.head).fontWeight(.medium)
                            }
                            .font(.caption)
                        }
                    }
                }
            } else if !peerLoading {
                Text("No data — click Check to poll.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func peerPathBinding(_ project: Project) -> Binding<String> {
        Binding(
            get: { store.project(project.id)?.peerPath ?? "" },
            set: { newValue in
                if var p = store.project(project.id) {
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    p.peerPath = trimmed.isEmpty ? nil : trimmed
                    store.update(p)
                }
            }
        )
    }

    // MARK: Worktrees card

    private var worktreesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Worktrees (\(worktrees.count))").font(.headline)
                Spacer()
                Button { newWorktreeName = ""; newWorktreeShown = true } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            ForEach(worktrees) { wt in
                HStack(spacing: 10) {
                    Image(systemName: wt.isMain ? "house" : "arrow.triangle.branch")
                        .foregroundStyle(.secondary).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(wt.name).font(.callout).lineLimit(1)
                        Text(wt.branch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button { launchInWorktree(.claude, wt) } label: { Label("Claude Code", systemImage: AgentKind.claude.symbol) }
                        Button { launchInWorktree(.codex, wt) } label: { Label("Codex", systemImage: AgentKind.codex.symbol) }
                        Button { LaunchService.openTerminal(at: wt.path, terminal: store.terminal) } label: { Label("Terminal", systemImage: "terminal") }
                        Button { LaunchService.revealInFinder(wt.path) } label: { Label("Finder", systemImage: "folder") }
                        if !wt.isMain {
                            Divider()
                            Button(role: .destructive) { beginRemoveWorktree(wt) } label: { Label("Remove worktree…", systemImage: "trash") }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Worktree actions for \(wt.name)")
                }
                .padding(.vertical, 3)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Issues + project log (single-user; no human assignees)

    @ViewBuilder
    private func issuesCard(_ project: Project) -> some View {
        let sorted = project.issues.sorted { a, b in
            if a.status.order != b.status.order { return a.status.order < b.status.order }
            if a.priority.rank != b.priority.rank { return a.priority.rank > b.priority.rank }
            return a.number < b.number
        }
        let openCount = project.issues.filter { $0.status.isOpen }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Issues (\(openCount) open)").font(.headline)
                Spacer()
                Button { showIssueComposer = true } label: {
                    Label("New issue…", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            HStack(spacing: 8) {
                TextField("Quick add a title…", text: $newIssueTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addIssueFromComposer(project) }
                Menu {
                    ForEach(IssuePriority.allCases) { p in
                        Button { newIssuePriority = p } label: { Label(p.label, systemImage: p.symbol) }
                    }
                } label: { Label(newIssuePriority.label, systemImage: newIssuePriority.symbol) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Priority for the new issue")
                Button { addIssueFromComposer(project) } label: { Label("Add", systemImage: "plus") }
                    .disabled(newIssueTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if sorted.isEmpty {
                Text("No issues yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sorted) { issue in
                    issueRow(project, issue)
                    if issue.id != sorted.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .sheet(isPresented: $showIssueComposer) {
            IssueComposer(projectID: projectID).environment(store)
        }
        .sheet(isPresented: Binding(
            get: { detailIssueNumber != nil },
            set: { if !$0 { detailIssueNumber = nil } }
        )) {
            if let n = detailIssueNumber {
                IssueDetailSheet(projectID: projectID, number: n).environment(store)
            }
        }
    }

    @ViewBuilder
    private func issueRow(_ project: Project, _ issue: Issue) -> some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(IssueStatus.allCases) { s in
                    Button { store.setIssueStatus(project.id, number: issue.number, status: s) } label: {
                        Label(s.label, systemImage: s.symbol)
                    }
                }
            } label: {
                Image(systemName: issue.status.symbol).foregroundStyle(.secondary).frame(width: 18)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Status: \(issue.status.label)")

            Button { detailIssueNumber = issue.number } label: {
                HStack(spacing: 8) {
                    Text("#\(issue.number)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.title)
                            .font(.callout)
                            .strikethrough(issue.status == .canceled)
                            .foregroundStyle(issue.status.isOpen ? .primary : .secondary)
                            .lineLimit(1)
                        if let session = issue.activeSession, store.runningSessions.contains(session) {
                            Label("agent running", systemImage: "circle.fill")
                                .font(.caption2).foregroundStyle(.green).labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .help("Open issue")
            Spacer()
            if !issue.attachments.isEmpty {
                Label("\(issue.attachments.count)", systemImage: "paperclip")
                    .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    .help("\(issue.attachments.count) attachment(s)")
            }
            Menu {
                ForEach(IssuePriority.allCases) { p in
                    Button { store.setIssuePriority(project.id, number: issue.number, priority: p) } label: {
                        Label(p.label, systemImage: p.symbol)
                    }
                }
            } label: {
                Image(systemName: issue.priority.symbol)
                    .foregroundStyle(issue.priority == .urgent ? .orange : .secondary)
                    .frame(width: 16)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Priority: \(issue.priority.label)")

            Menu {
                if project.hasLocal {
                    Button { store.startAgentOnIssue(project, number: issue.number, kind: .claude) } label: {
                        Label("Start Claude Code", systemImage: AgentKind.claude.symbol)
                    }
                    Button { store.startAgentOnIssue(project, number: issue.number, kind: .codex) } label: {
                        Label("Start Codex", systemImage: AgentKind.codex.symbol)
                    }
                    Divider()
                }
                if !issue.attachments.isEmpty {
                    Button {
                        LaunchService.revealInFinder(AttachmentStore.directory(forIssue: issue.id).path)
                    } label: { Label("Reveal attachments in Finder", systemImage: "folder") }
                    Divider()
                }
                Button(role: .destructive) {
                    store.removeIssue(project.id, number: issue.number, title: issue.title)
                } label: { Label("Delete issue", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Actions for issue \(issue.number)")
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func logCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project Log").font(.headline)
            HStack(spacing: 8) {
                TextField("Log a progress note…", text: $newUpdateText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addUpdateFromComposer(project) }
                Button { addUpdateFromComposer(project) } label: { Label("Post", systemImage: "paperplane") }
                    .disabled(newUpdateText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if project.updates.isEmpty {
                Text("No updates yet. Agents finishing on an issue post here automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(project.updates) { u in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: u.kind == .agent ? "sparkles" : "text.bubble")
                            .foregroundStyle(u.kind == .agent ? Color.blue : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(u.body).font(.callout)
                            Text(u.createdAt.formatted(.relative(presentation: .named))
                                 + (u.issueNumber.map { " · #\($0)" } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    if u.id != project.updates.last?.id { Divider() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func addIssueFromComposer(_ project: Project) {
        store.addIssue(project.id, title: newIssueTitle, priority: newIssuePriority)
        newIssueTitle = ""
        newIssuePriority = .none
    }

    private func addUpdateFromComposer(_ project: Project) {
        store.addUpdate(project.id, body: newUpdateText)
        newUpdateText = ""
    }

    // MARK: Local-folder card (project synced but not checked out on this host)

    private func localFolderCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not checked out on \(HostIdentity.current)", systemImage: "externaldrive.badge.questionmark")
                .font(.headline)
            Text("This project's data syncs across your Macs, but it has no local folder on this machine. Set one — it's saved per-host, so it won't affect your other Macs.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { chooseLocalFolder(project) } label: {
                Label("Set local folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.glassProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func chooseLocalFolder(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Folder"
        panel.message = "Choose this project's local folder on \(HostIdentity.current)"
        if panel.runModal() == .OK, let url = panel.url {
            store.setLocalPath(project.id, path: url.path)
        }
    }

    // MARK: Clone card (GitHub-only project)

    private func cloneCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remote only").font(.headline)
            Text(project.githubRemote ?? "").font(.callout).foregroundStyle(.secondary)
            Button { clone(project) } label: {
                Label(cloning ? "Cloning…" : "Pull to local…", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.glassProminent)
            .disabled(cloning)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: GitHub status card

    @ViewBuilder
    private func githubStatusCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "cloud").foregroundStyle(.secondary)
                Text("GitHub").font(.headline)
                Spacer()
                if ghLoading { ProgressView().controlSize(.small) }
            }

            if ghLoading && ghStatus == nil {
                Text("Loading…").foregroundStyle(.secondary).font(.callout)
            } else if let gh = ghStatus {
                if !gh.available {
                    Label("Unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    // Open PRs row
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.pull")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text("Open PRs")
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text("\(gh.openPRs)").fontWeight(.medium)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)

                    // CI row
                    HStack(spacing: 8) {
                        Image(systemName: ciSymbol(gh))
                            .foregroundStyle(ciColor(gh))
                            .frame(width: 18)
                        Text("CI")
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(ciLabel(gh))
                            .fontWeight(.medium)
                            .foregroundStyle(ciColor(gh))
                        Spacer(minLength: 0)
                    }
                    .font(.callout)
                }
            } else if !ghLoading {
                Text("No data.").foregroundStyle(.secondary).font(.callout)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func ciSymbol(_ gh: GitHubStatus) -> String {
        let c = gh.ciConclusion.lowercased()
        let s = gh.ciStatus.lowercased()
        if c == "success" { return "checkmark.seal" }
        if c == "failure" || c == "timed_out" || c == "cancelled" { return "xmark.seal" }
        if s == "in_progress" || s == "queued" || s == "waiting" { return "clock" }
        if gh.ciStatus.isEmpty && gh.ciConclusion.isEmpty { return "minus.circle" }
        return "clock"
    }

    private func ciColor(_ gh: GitHubStatus) -> Color {
        let c = gh.ciConclusion.lowercased()
        if c == "success" { return .accentColor }
        return .secondary
    }

    private func ciLabel(_ gh: GitHubStatus) -> String {
        if !gh.ciConclusion.isEmpty { return gh.ciConclusion }
        if !gh.ciStatus.isEmpty { return gh.ciStatus }
        return "—"
    }

    // MARK: Playbooks card

    private func playbooksCard(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Playbooks").font(.headline)
                Spacer()
                Button {
                    newPlaybookName = ""; newPlaybookCommand = ""
                    addPlaybookShown = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless).controlSize(.small)
            }
            if project.playbooks.isEmpty {
                Text("No playbooks yet.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(project.playbooks.enumerated()), id: \.element.id) { idx, pb in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pb.name).font(.callout).lineLimit(1)
                                Text(pb.command).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                LaunchService.runCommand(pb.command, at: project.localPath ?? "", terminal: store.terminal)
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(!project.hasLocal)
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button(role: .destructive) {
                                store.removePlaybook(projectID: projectID, playbook: pb)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        if idx < project.playbooks.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Sessions card (Phase 2 placeholder)

    private var sessionsCard: some View {
        let list = sessionTab == .claude ? claudeSessions : codexSessions
        let items = Array(list.prefix(25))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Agent Sessions").font(.headline)
                Spacer()
                if sessionsLoading { ProgressView().controlSize(.small) }
            }
            Picker("", selection: $sessionTab) {
                Text("Claude (\(claudeSessions.count))").tag(AgentKind.claude)
                Text("Codex (\(codexSessions.count))").tag(AgentKind.codex)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if items.isEmpty {
                Text(sessionsLoading ? "Loading…" : "No \(sessionTab.label) sessions for this project.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, session in
                        sessionRow(session)
                        if idx < items.count - 1 { Divider() }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.callout).lineLimit(1)
                Text(relativeAge(session.modified)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if let p = store.project(projectID) {
                    let extra = session.kind == .claude ? store.claudeArgs : store.codexArgs
                    LaunchService.resumeSession(session, project: p, terminal: store.terminal,
                                               extraArgs: extra)
                }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func relativeAge(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Helpers

    @ViewBuilder
    private func runningBadge(project: Project, kind: AgentKind) -> some View {
        let sessionName = LaunchService.tmuxSessionName(project, kind)
        HStack(spacing: 6) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(kind.label)
                .font(.system(size: 12, weight: .medium))
            Button {
                LaunchService.attach(sessionName: sessionName, terminal: store.terminal)
            } label: {
                Label("Attach", systemImage: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .tint(.accentColor)
        }
    }

    private func yoloBinding(_ project: Project) -> Binding<Bool> {
        Binding(
            get: { store.project(project.id)?.yolo ?? true },
            set: { newValue in
                if var p = store.project(project.id) { p.yolo = newValue; store.update(p) }
            }
        )
    }

    private func tmuxBinding(_ project: Project) -> Binding<Bool> {
        Binding(
            get: { store.project(project.id)?.tmux ?? false },
            set: { newValue in
                if var p = store.project(project.id) { p.tmux = newValue; store.update(p) }
            }
        )
    }

    private func loadGit(_ project: Project) async {
        guard let path = project.localPath, !path.isEmpty else { git = .none; return }
        loadingGit = true
        git = await GitService.info(for: path)
        loadingGit = false
    }

    private func loadHeatmap(_ project: Project) async {
        guard let path = project.localPath, !path.isEmpty else { heatmap = []; return }
        heatmap = await GitService.heatmapGrid(for: path, weeks: 26)
    }

    private func loadSessions(_ project: Project) async {
        guard let path = project.localPath, !path.isEmpty else {
            claudeSessions = []; codexSessions = []; return
        }
        sessionsLoading = true
        async let c = SessionsService.claudeSessions(for: path)
        async let x = SessionsService.codexSessions(for: path)
        claudeSessions = await c
        codexSessions = await x
        sessionsLoading = false
    }

    private func loadWorktrees(_ project: Project) async {
        guard let path = project.localPath, !path.isEmpty else { worktrees = []; return }
        worktrees = await GitService.worktrees(for: path)
    }

    private func loadPeer(_ project: Project) async {
        let host = store.peerHost
        guard !host.isEmpty, let localPath = project.localPath, !localPath.isEmpty else {
            peer = nil; return
        }
        // Prefer an explicit per-project override; else the peer's own path from
        // the per-host map (when a peer host key is configured); else the local path.
        let key = store.peerHostKey
        let mapped = key.isEmpty ? nil : project.localPaths[key]
        let effectivePath = project.peerPath ?? mapped ?? localPath
        peerLoading = true
        peer = await PeerService.status(host: host, path: effectivePath)
        peerLoading = false
    }

    private func loadGitHubStatus(_ project: Project) async {
        guard let remote = project.githubRemote, !remote.isEmpty else {
            ghStatus = nil; return
        }
        ghLoading = true
        ghStatus = await GitHubService.status(remote: remote)
        ghLoading = false
    }

    private func launchInWorktree(_ kind: AgentKind, _ wt: Worktree) {
        guard let p = store.project(projectID) else { return }
        let safe = String(wt.name.lowercased().map { (c: Character) -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        })
        let extra = kind == .claude ? store.claudeArgs : store.codexArgs
        LaunchService.launchAgent(kind, atPath: wt.path, yolo: p.yolo, tmux: p.tmux,
                                  tmuxName: "pharos-\(safe)-\(kind.rawValue)", terminal: store.terminal,
                                  extraArgs: extra)
    }

    /// Open the worktree-removal confirm sheet and asynchronously load how many
    /// uncommitted changes would be lost (shown so the confirm is informed).
    private func beginRemoveWorktree(_ wt: Worktree) {
        worktreeConfirmText = ""
        worktreeDirtyCount = 0
        worktreeRemoving = false
        worktreeToRemove = wt
        Task {
            let count = await Task.detached { GitService.worktreeDirtyCount(path: wt.path) }.value
            if worktreeToRemove?.id == wt.id { worktreeDirtyCount = count }
        }
    }

    /// Actually remove the pending worktree: move its directory to the macOS
    /// Trash and prune git's record. The branch is left intact, and the files
    /// remain recoverable from the Finder Trash.
    private func confirmRemoveWorktree(_ wt: Worktree) {
        guard let p = store.project(projectID), let repo = p.localPath else { return }
        worktreeRemoving = true
        Task {
            let ok = await Task.detached { GitService.trashWorktree(repo: repo, path: wt.path) }.value
            AuditLog.record(actor: .ui, action: "remove_worktree", detail: wt.path)
            if !ok { store.reportError("Couldn't move “\(wt.name)” to the Trash. The worktree was left in place.") }
            await loadWorktrees(p)
            worktreeRemoving = false
            worktreeToRemove = nil
        }
    }

    /// Confirm sheet for removing a worktree, with friction scaled to blast
    /// radius: a clean worktree needs only a tap; a dirty one shows the count of
    /// changes that would be trashed and requires typing the worktree name.
    @ViewBuilder
    private func worktreeRemoveSheet(_ wt: Worktree) -> some View {
        let isDirty = worktreeDirtyCount > 0
        let canRemove = !isDirty || worktreeConfirmText.trimmingCharacters(in: .whitespaces) == wt.name
        VStack(alignment: .leading, spacing: 16) {
            Label("Remove worktree “\(wt.name)”?", systemImage: "trash")
                .font(.title3).bold()

            VStack(alignment: .leading, spacing: 6) {
                Text("The branch **\(wt.branch)** is kept. Its working directory is moved to the Trash (recoverable in Finder):")
                    .font(.callout).foregroundStyle(.secondary)
                Text(wt.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if isDirty {
                Label("\(worktreeDirtyCount) uncommitted change\(worktreeDirtyCount == 1 ? "" : "s") will be trashed with it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type the worktree name to confirm:").font(.caption).foregroundStyle(.secondary)
                    TextField(wt.name, text: $worktreeConfirmText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { worktreeToRemove = nil }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { confirmRemoveWorktree(wt) } label: {
                    if worktreeRemoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Move to Trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canRemove || worktreeRemoving)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    /// Known binary locations for agent tools (best-effort; user may have custom installs).
    private static let agentBinaryPaths: [AgentKind: [String]] = [
        .claude: [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ],
        .codex: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ],
    ]

    /// Launch an agent after verifying its binary exists; surfaces an error if not found.
    private func launchAgentWithPreflight(_ kind: AgentKind, project: Project) {
        let paths = Self.agentBinaryPaths[kind] ?? []
        let found = paths.contains { LaunchService.toolExists($0) }
        guard found else {
            let name = kind == .claude ? "Claude CLI" : "Codex"
            store.reportError("\(name) not found — install it and ensure it is available at one of: \(paths.joined(separator: ", "))")
            return
        }
        let extra = kind == .claude ? store.claudeArgs : store.codexArgs
        LaunchService.launchAgent(kind, project: project, terminal: store.terminal,
                                  desktop: agentDesktop, extraArgs: extra)
    }

    private func clone(_ project: Project) {
        guard let remote = project.githubRemote else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Clone Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let dest = dir.appendingPathComponent(project.name).path
        cloning = true
        Task {
            let result = await Task.detached { Shell.run("/usr/bin/git", ["clone", remote, dest]) }.value
            cloning = false
            if result.ok, var p = store.project(project.id) {
                p.localPath = dest
                store.update(p)
                await loadGit(p)
                await loadHeatmap(p)
            } else if !result.ok {
                let msg = result.err.isEmpty ? "Unknown error (exit \(result.code))" : result.err
                store.reportError("Clone failed: \(msg)")
            }
        }
    }
}

/// GitHub-style commit heatmap using a single system colour (accent), not green.
struct ContributionHeatmap: View {
    let grid: [[Int]]   // columns of 7 days; -1 = no cell (after today)

    private var maxV: Int {
        max(grid.flatMap { $0 }.filter { $0 > 0 }.max() ?? 1, 1)
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(grid.enumerated()), id: \.offset) { _, col in
                VStack(spacing: 3) {
                    ForEach(Array(col.enumerated()), id: \.offset) { _, value in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: value))
                            .frame(width: 11, height: 11)
                    }
                }
            }
        }
    }

    private func color(for value: Int) -> Color {
        if value < 0 { return .clear }
        if value == 0 { return Color.secondary.opacity(0.12) }
        let level = min(Double(value) / Double(maxV), 1.0)
        return Color.accentColor.opacity(0.3 + 0.6 * level)
    }
}
