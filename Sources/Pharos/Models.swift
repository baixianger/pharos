import Foundation

/// A custom command button the user attaches to a project.
struct Playbook: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var command: String
}

/// A project Pharos manages. It may live on disk, on GitHub, or both.
struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var localPath: String?      // absolute path; nil for a GitHub-only project
    var githubRemote: String?   // https://github.com/org/repo or git@github.com:org/repo.git
    var tags: [String] = []     // group memberships
    var yolo: Bool = true       // project-level default: agents launch in yolo mode
    var tmux: Bool = false      // launch the agent inside a persistent tmux session
    var addedAt: Date = Date()
    var playbooks: [Playbook] = []
    var notes: String = ""      // human-written description shown in Pharos
    var peerPath: String?       // override for this project's directory on the peer host; nil/empty = same as localPath
    var issues: [Issue] = []    // native, single-user issues (no human assignees)
    var updates: [ProjectUpdate] = []   // project-update feed / personal changelog
    var milestones: [Milestone] = []    // cycles / milestones issues can belong to
    /// Per-host local checkout paths (computer name → absolute path). The shared
    /// project data syncs across machines; this map keeps each machine's own
    /// path so iCloud sync never clobbers it. `localPath` above is the resolved
    /// path for the *current* host (set on load).
    var localPaths: [String: String] = [:]

    init(id: UUID = UUID(), name: String, localPath: String? = nil, githubRemote: String? = nil,
         tags: [String] = [], yolo: Bool = true, tmux: Bool = false,
         addedAt: Date = Date(), playbooks: [Playbook] = [], notes: String = "",
         peerPath: String? = nil, issues: [Issue] = [], updates: [ProjectUpdate] = [],
         localPaths: [String: String] = [:], milestones: [Milestone] = []) {
        self.id = id; self.name = name; self.localPath = localPath; self.githubRemote = githubRemote
        self.tags = tags; self.yolo = yolo; self.tmux = tmux; self.addedAt = addedAt
        self.playbooks = playbooks; self.notes = notes; self.peerPath = peerPath
        self.issues = issues; self.updates = updates; self.localPaths = localPaths
        self.milestones = milestones
    }

    /// Tolerant decoding — missing keys (older registries) fall back to defaults,
    /// so adding a new field never silently drops previously-saved projects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
        githubRemote = try c.decodeIfPresent(String.self, forKey: .githubRemote)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        yolo = try c.decodeIfPresent(Bool.self, forKey: .yolo) ?? true
        tmux = try c.decodeIfPresent(Bool.self, forKey: .tmux) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        playbooks = try c.decodeIfPresent([Playbook].self, forKey: .playbooks) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        peerPath = try c.decodeIfPresent(String.self, forKey: .peerPath)
        issues = try c.decodeIfPresent([Issue].self, forKey: .issues) ?? []
        updates = try c.decodeIfPresent([ProjectUpdate].self, forKey: .updates) ?? []
        localPaths = try c.decodeIfPresent([String: String].self, forKey: .localPaths) ?? [:]
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
    }

    /// Next per-project issue number (#1, #2, …). Based on current issues only;
    /// good enough for a single user.
    var nextIssueNumber: Int { (issues.map(\.number).max() ?? 0) + 1 }

    /// Resolve the local checkout path for a given host:
    ///  • the host's own entry, if present;
    ///  • else, for legacy single-machine data (empty map), the bare `localPath`;
    ///  • else nil — the project is known on other machines but not checked out here.
    func resolvedLocalPath(forHost host: String) -> String? {
        if let p = localPaths[host], !p.isEmpty { return p }
        if localPaths.isEmpty { return (localPath?.isEmpty == false) ? localPath : nil }
        return nil
    }

    var hasLocal: Bool { (localPath?.isEmpty == false) }
    var hasGitHub: Bool { (githubRemote?.isEmpty == false) }
    var displayPath: String { localPath ?? githubRemote ?? "—" }

    /// Parent folder name of the local path (e.g. ~/dev/acme-api -> "dev").
    var parentFolder: String? {
        guard let localPath, !localPath.isEmpty else { return nil }
        return URL(fileURLWithPath: localPath).deletingLastPathComponent().lastPathComponent
    }
}

/// A native issue. Single-user by design: there are no human assignees or teams —
/// the only "who" is which agent session (`activeSession`) is working it.
struct Issue: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var number: Int                       // per-project, human-facing (#1, #2, …)
    var title: String
    var status: IssueStatus = .todo
    var priority: IssuePriority = .none
    var body: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// tmux session name of an agent currently working this issue (nil = none).
    var activeSession: String?
    /// Worktree path an agent is running in for this issue, if any.
    var worktreePath: String?
    /// Images / files attached to the issue. The bytes live on disk under
    /// `<dataDir>/attachments/<issue.id>/`; this holds only metadata.
    var attachments: [IssueAttachment] = []
    /// Freeform labels (single-user — just tags, no team machinery).
    var labels: [String] = []
    /// Manual sort position within its board column (lower = higher up).
    var sortOrder: Double = 0
    /// The milestone/cycle this issue belongs to, if any.
    var milestoneID: UUID?
}

extension Issue {
    /// Tolerant decode (in an extension to keep the memberwise initializer) so
    /// adding fields like `attachments` never drops previously-saved issues.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try c.decodeIfPresent(IssueStatus.self, forKey: .status) ?? .todo
        priority = try c.decodeIfPresent(IssuePriority.self, forKey: .priority) ?? .none
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        activeSession = try c.decodeIfPresent(String.self, forKey: .activeSession)
        worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        attachments = try c.decodeIfPresent([IssueAttachment].self, forKey: .attachments) ?? []
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        sortOrder = try c.decodeIfPresent(Double.self, forKey: .sortOrder) ?? 0
        milestoneID = try c.decodeIfPresent(UUID.self, forKey: .milestoneID)
    }
}

/// A cycle / milestone: a named bucket (optionally with a due date) that issues
/// can belong to. Single-user — just an iteration label, no team sprints.
struct Milestone: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var due: Date?
    var createdAt: Date = Date()
}

/// Metadata for an image or file attached to an issue. The bytes live on disk
/// (synced with the rest of the data dir); this is what travels in the registry.
struct IssueAttachment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var storedName: String     // filename on disk within the issue's attachment dir
    var originalName: String   // display name shown in the UI
    var isImage: Bool
    var byteSize: Int
    var addedAt: Date = Date()
}

/// Linear-style workflow states. `in_progress` is wire-stable as a raw value.
enum IssueStatus: String, Codable, CaseIterable, Identifiable {
    case backlog, todo
    case inProgress = "in_progress"
    case done, canceled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }
    var symbol: String {
        switch self {
        case .backlog: return "circle.dashed"
        case .todo: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .canceled: return "xmark.circle"
        }
    }
    /// Board/sort order.
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    /// Open = still actionable (drives default list filtering).
    var isOpen: Bool { self != .done && self != .canceled }
}

/// Issue priority. `none` sorts last visually but ranks lowest.
enum IssuePriority: String, Codable, CaseIterable, Identifiable {
    case none, low, medium, high, urgent

    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No priority"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .urgent: return "Urgent"
        }
    }
    var symbol: String {
        switch self {
        case .none: return "minus"
        case .low: return "chevron.down"
        case .medium: return "equal"
        case .high: return "chevron.up"
        case .urgent: return "exclamationmark.triangle.fill"
        }
    }
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One entry in a project's update feed — a personal progress log / changelog.
/// Either a hand-written `note` or an `agent`-posted line (e.g. when an agent
/// launched on an issue finishes).
struct ProjectUpdate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var body: String
    var kind: UpdateKind = .note
    var issueNumber: Int?            // links the update to an issue, if any
}

enum UpdateKind: String, Codable { case note, agent }

/// An item the user removed that can still be restored from Trash.
///
/// Soft-delete is the heart of Pharos's "forget, don't destroy" safety model:
/// removing a project, group, or playbook moves its *full* payload here so a
/// restore is lossless, and records when it was deleted so a restore window can
/// auto-purge it. The recovery logic lives on `StoreData` (a value type) so the
/// GUI and the `pharos` CLI share one implementation.
struct TrashedItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var deletedAt: Date = Date()
    var payload: TrashPayload

    /// Display name for the Trash list.
    var title: String {
        switch payload {
        case .project(let p):         return p.name
        case .group(let name, _):     return name
        case .playbook(_, _, let pb): return pb.name
        case .issue(_, _, let issue): return "#\(issue.number) \(issue.title)"
        }
    }

    /// Short kind label for the Trash list, e.g. "Project" or "Playbook · Pharos".
    var kindLabel: String {
        switch payload {
        case .project:                         return "Project"
        case .group:                           return "Group"
        case .playbook(_, let projectName, _): return "Playbook · \(projectName)"
        case .issue(_, let projectName, _):    return "Issue · \(projectName)"
        }
    }
}

/// The recoverable contents of a `TrashedItem`.
enum TrashPayload: Codable, Hashable {
    /// A forgotten project — registry metadata only; the repo on disk is untouched.
    case project(Project)
    /// A deleted group plus the ids of the projects that were tagged with it, so
    /// membership is restored exactly.
    case group(name: String, memberProjectIDs: [UUID])
    /// A deleted issue plus the project (id + name) it belonged to.
    case issue(projectID: UUID, projectName: String, issue: Issue)
    /// A deleted playbook plus the project (id + name) it belonged to.
    case playbook(projectID: UUID, projectName: String, playbook: Playbook)
}

/// A transient "Undo" affordance shown after a reversible delete. Points at the
/// `TrashedItem` that an undo would restore.
struct UndoToken: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var itemID: TrashedItem.ID
}

/// Sidebar group selection — like a stock-app watchlist selector.
enum GroupSelection: Hashable, Codable {
    case all
    case group(String)
}

/// A GitHub repository returned by `gh repo list --json …`.
struct GitHubRepo: Identifiable, Codable, Hashable {
    let name: String
    let url: String
    let sshUrl: String
    let isPrivate: Bool
    let description: String?
    var id: String { url }
}

/// The two coding agents Pharos can launch.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var label: String { self == .claude ? "Claude Code" : "Codex" }
    var symbol: String { self == .claude ? "sparkles" : "chevron.left.forwardslash.chevron.right" }

    func command(yolo: Bool, extraArgs: String = "") -> String {
        let base: String
        switch self {
        case .claude:
            base = yolo ? "claude --dangerously-skip-permissions" : "claude"
        case .codex:
            base = yolo ? "codex --dangerously-bypass-approvals-and-sandbox" : "codex"
        }
        let trimmed = extraArgs.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? base : "\(base) \(trimmed)"
    }
}

/// A past agent session (Claude or Codex) for a project.
struct AgentSession: Identifiable, Hashable {
    let id: String          // session UUID
    let kind: AgentKind
    let title: String
    let modified: Date
    let resumeCwd: String   // directory to run the resume command in
}

/// A git worktree of a project.
struct Worktree: Identifiable, Hashable {
    let path: String
    let branch: String
    let isMain: Bool
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// Terminal app used to open shells and launch agents.
enum TerminalApp: String, CaseIterable, Identifiable, Codable {
    case ghostty, terminal, iterm, warp, wezterm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .terminal: return "macOS Terminal"
        case .iterm: return "iTerm"
        case .warp: return "Warp"
        case .wezterm: return "WezTerm"
        }
    }
}

/// Editor app used for "Open in Editor".
enum EditorApp: String, CaseIterable, Identifiable, Codable {
    case vscode, cursor, zed, xcode, sublime
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .sublime: return "Sublime Text"
        }
    }
    var appName: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .sublime: return "Sublime Text"
        }
    }
}

/// App appearance preference.
enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// GitHub status fetched via the `gh` CLI: open PRs + latest CI run.
struct GitHubStatus: Sendable, Equatable {
    var openPRs: Int
    var ciStatus: String      // e.g. "completed", "in_progress", "queued"
    var ciConclusion: String  // e.g. "success", "failure", "skipped", "" if none
    var available: Bool       // false = gh failed / not a GitHub repo
}

/// Git state fetched from a peer machine over SSH. Value type → Sendable.
struct PeerStatus: Sendable, Equatable {
    /// Short HEAD commit hash reported by the peer.
    var head: String
    /// Branch name reported by the peer.
    var branch: String
    /// Number of uncommitted changes (`git status --porcelain | wc -l`).
    var dirtyCount: Int
    /// True when the path does not exist on the peer (git exited non-zero).
    var missing: Bool
    /// False when SSH itself could not connect within the timeout.
    var reachable: Bool

    static let unreachable = PeerStatus(head: "", branch: "", dirtyCount: 0, missing: false, reachable: false)
    static let notOnPeer   = PeerStatus(head: "", branch: "", dirtyCount: 0, missing: true,  reachable: true)
}

/// Local git state shown in a project's detail view. Value type -> Sendable.
struct GitInfo: Equatable {
    var isRepo: Bool
    var branch: String
    var lastCommitHash: String
    var lastCommitSubject: String
    var lastCommitRelative: String
    var lastCommitAgeDays: Int
    var ahead: Int
    var behind: Int
    var isDirty: Bool
    var branchCount: Int
    var worktreeCount: Int
    var activity: [Int]   // daily commit counts, oldest -> newest

    static let none = GitInfo(
        isRepo: false, branch: "", lastCommitHash: "", lastCommitSubject: "",
        lastCommitRelative: "", lastCommitAgeDays: -1, ahead: 0, behind: 0,
        isDirty: false, branchCount: 0, worktreeCount: 0, activity: []
    )
}
