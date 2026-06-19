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

    init(id: UUID = UUID(), name: String, localPath: String? = nil, githubRemote: String? = nil,
         tags: [String] = [], yolo: Bool = true, tmux: Bool = false,
         addedAt: Date = Date(), playbooks: [Playbook] = [], notes: String = "",
         peerPath: String? = nil) {
        self.id = id; self.name = name; self.localPath = localPath; self.githubRemote = githubRemote
        self.tags = tags; self.yolo = yolo; self.tmux = tmux; self.addedAt = addedAt
        self.playbooks = playbooks; self.notes = notes; self.peerPath = peerPath
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
