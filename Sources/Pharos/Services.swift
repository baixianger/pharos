import AppKit
import Foundation

/// Thin wrapper around `Process` for shelling out to git / open.
enum Shell {
    struct Result {
        let out: String
        let err: String
        let code: Int32
        var ok: Bool { code == 0 }
    }

    @discardableResult
    static func run(_ launchPath: String, _ args: [String], cwd: String? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            return Result(out: "", err: "\(error)", code: -1)
        }
        // Drain both pipes concurrently. If we read stdout fully before touching
        // stderr, a child that fills the stderr pipe (>~64KB) before closing
        // stdout would deadlock. Read stderr on a background queue while we read
        // stdout here, then join before waiting on exit.
        var errData = Data()
        let errQueue = DispatchQueue(label: "Shell.stderr")
        errQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errQueue.sync {}   // barrier: wait for the stderr read to finish
        process.waitUntilExit()
        return Result(
            out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            code: process.terminationStatus
        )
    }

    static func git(_ args: [String], at path: String) -> Result {
        run("/usr/bin/git", ["-C", path] + args)
    }
}

/// Caps concurrent `GitService.info` calls so ~22 rows appearing at once don't
/// fan out to ~150 git subprocesses. Six slots matches a typical I/O-bound sweet
/// spot without starving the main queue.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) { self.permits = permits }

    func wait() async {
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            permits += 1
        }
    }
}

/// Gathers local git state for a project directory.
enum GitService {
    /// Limits concurrent git-info fetches to avoid a ~150-process fan-out when
    /// all sidebar rows appear simultaneously.
    private static let semaphore = AsyncSemaphore(permits: 6)

    static func info(for path: String) async -> GitInfo {
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        return await Task.detached(priority: .utility) { compute(path) }.value
    }

    private static func compute(_ path: String) -> GitInfo {
        let inside = Shell.git(["rev-parse", "--is-inside-work-tree"], at: path)
        guard inside.ok, inside.out == "true" else { return .none }

        let branch = Shell.git(["rev-parse", "--abbrev-ref", "HEAD"], at: path).out

        // hash<US>subject<US>relative-date
        let log = Shell.git(["log", "-1", "--pretty=%h\u{1f}%s\u{1f}%cr"], at: path).out
        let parts = log.components(separatedBy: "\u{1f}")
        let hash = parts.count > 0 ? parts[0] : ""
        let subject = parts.count > 1 ? parts[1] : ""
        let relative = parts.count > 2 ? parts[2] : ""

        let dirty = !Shell.git(["status", "--porcelain"], at: path).out.isEmpty

        var ahead = 0, behind = 0
        let counts = Shell.git(["rev-list", "--left-right", "--count", "@{upstream}...HEAD"], at: path)
        if counts.ok {
            let nums = counts.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            if nums.count == 2 { behind = nums[0]; ahead = nums[1] }
        }

        let branchCount = Shell.git(["for-each-ref", "--format=%(refname)", "refs/heads"], at: path)
            .out.split(separator: "\n").count

        let worktreeCount = Shell.git(["worktree", "list", "--porcelain"], at: path)
            .out.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count

        let ts = Double(Shell.git(["log", "-1", "--format=%ct"], at: path).out) ?? 0
        let ageDays = ts > 0 ? Int((Date().timeIntervalSince1970 - ts) / 86400) : -1
        let activity = commitActivity(path, days: 21)

        return GitInfo(
            isRepo: true, branch: branch, lastCommitHash: hash,
            lastCommitSubject: subject, lastCommitRelative: relative,
            lastCommitAgeDays: ageDays, ahead: ahead, behind: behind, isDirty: dirty,
            branchCount: max(branchCount, 1), worktreeCount: max(worktreeCount, 1),
            activity: activity
        )
    }

    /// Daily commit counts over the last `days` days (oldest -> newest) for the sparkline.
    private static func commitActivity(_ path: String, days: Int) -> [Int] {
        let out = Shell.git(["log", "--since=\(days) days ago",
                             "--date=format:%Y-%m-%d", "--pretty=%cd"], at: path).out
        var counts: [String: Int] = [:]
        for line in out.split(separator: "\n") { counts[String(line), default: 0] += 1 }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        let today = Date()
        var buckets: [Int] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: today) ?? today
            buckets.append(counts[fmt.string(from: day)] ?? 0)
        }
        return buckets
    }
}

/// Launches Finder, a terminal (Ghostty), and coding agents.
enum LaunchService {
    /// Common install locations. Codex.app bundles a fully functional CLI but
    /// does not necessarily put it on PATH, especially for GUI-launched apps.
    static func agentExecutableCandidates(_ kind: AgentKind,
                                          home: String = NSHomeDirectory()) -> [String] {
        switch kind {
        case .claude:
            return [
                "\(home)/.local/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
                "\(home)/.asdf/shims/claude",
                "\(home)/.local/share/mise/shims/claude",
                "\(home)/.volta/bin/claude",
            ]
        case .codex:
            return [
                "/opt/homebrew/bin/codex",
                "/usr/local/bin/codex",
                "\(home)/.local/bin/codex",
                "/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/Applications/Codex.app/Contents/Resources/codex",
                "\(home)/.npm-global/bin/codex",
                "\(home)/.asdf/shims/codex",
                "\(home)/.local/share/mise/shims/codex",
                "\(home)/.volta/bin/codex",
            ]
        }
    }

    /// Last absolute executable emitted by a login-shell lookup. Shell startup
    /// files sometimes print banners, so do not blindly trust the first line.
    static func loginShellExecutable(_ output: String,
                                     isExecutable: (String) -> Bool) -> String? {
        output.split(separator: "\n").reversed().map(String.init)
            .first { $0.hasPrefix("/") && isExecutable($0) }
    }

    /// Resolve the exact binary that will be launched. Known locations keep
    /// this fast; the login-shell fallback supports nvm/fnm/custom PATH setups.
    static func agentExecutable(_ kind: AgentKind) -> String? {
        let fm = FileManager.default
        if let path = agentExecutableCandidates(kind).first(where: fm.isExecutableFile(atPath:)) {
            return path
        }
        let result = Shell.run("/bin/zsh", ["-lc", "command -v \(kind.rawValue)"])
        guard result.ok else { return nil }
        return loginShellExecutable(result.out, isExecutable: fm.isExecutableFile(atPath:))
    }

    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func openEditor(_ editor: EditorApp, path: String) {
        Shell.run("/usr/bin/open", ["-a", editor.appName, path])
    }

    static func openTerminal(at path: String, terminal: TerminalApp) {
        openInTerminal(terminal, path: path, command: nil)
    }

    /// Open a terminal window in the home dir and run `command` — used to attach
    /// a mesh agent's tmux session from the Dashboard.
    static func openTerminal(command: String, terminal: TerminalApp) {
        openInTerminal(terminal, path: NSHomeDirectory(), command: command)
    }

    /// Launch the agent in the chosen terminal. With `project.tmux`, it runs
    /// inside a persistent tmux session (attach-or-create); otherwise directly.
    /// If `desktop` is non-nil, switches to that Space (1-based) before launching
    /// so the new window appears there. Failure to switch is silently ignored.
    static func launchAgent(_ kind: AgentKind, project: Project, terminal: TerminalApp,
                            desktop: Int? = nil, extraArgs: String = "") {
        guard let path = project.localPath, !path.isEmpty else { return }
        let yolo = project.yolo, tmux = project.tmux
        let tmuxName = tmuxSessionName(project, kind)
        let launch = {
            launchAgent(kind, atPath: path, yolo: yolo, tmux: tmux,
                        tmuxName: tmuxName, terminal: terminal, extraArgs: extraArgs)
        }
        guard let d = desktop else { launch(); return }
        // Switch Spaces, let it settle, then open the terminal — all off the
        // main thread so `SpacesService.switchToDesktop`'s settle sleep never
        // freezes the UI. Order is preserved within the detached task.
        Task.detached(priority: .userInitiated) {
            SpacesService.switchToDesktop(d)   // performs the switch + settle delay
            await MainActor.run { launch() }
        }
    }

    /// Launch an agent at an arbitrary path (e.g. a worktree). `source` records
    /// who initiated a yolo launch in the audit log (defaults to the GUI).
    static func launchAgent(_ kind: AgentKind, atPath path: String, yolo: Bool, tmux: Bool,
                            tmuxName: String, terminal: TerminalApp, extraArgs: String = "",
                            source: AuditLog.Source = .ui) {
        let cmd = kind.command(yolo: yolo, extraArgs: extraArgs,
                               executable: agentExecutable(kind))
        let command: String
        if tmux {
            // `cmd` (carrying user `extraArgs`) sits inside the single-quoted
            // `zsh -lc '…'` body, so its single quotes must be escaped for that
            // context; the session name is quoted so odd characters can't break
            // the tmux command line.
            let inner = singleQuoteBody("\(cmd); exec zsh -l")
            command = "tmux new-session -A -s \(shellQuote(tmuxName)) -c \(shellQuote(path)) \"zsh -lc '\(inner)'\""
        } else {
            command = cmd
        }
        openInTerminal(terminal, path: path, command: command)
        // Yolo agents can delete files unattended — leave an audit trail (the
        // roadmap's "reversible/auditable, not just guarded by a UI prompt").
        if yolo {
            AuditLog.record(actor: source, action: "launch_agent_yolo",
                            detail: "\(kind.rawValue) @ \(path)")
        }
    }

    /// Resume a past agent session in the chosen terminal (honoring tmux + yolo).
    static func resumeSession(_ session: AgentSession, project: Project, terminal: TerminalApp,
                              extraArgs: String = "") {
        let path = session.resumeCwd
        let extra = extraArgs.trimmingCharacters(in: .whitespaces)
        let base: String
        switch session.kind {
        case .claude:
            let tool = session.kind.command(yolo: false, executable: agentExecutable(session.kind))
            base = "\(tool) --resume \(session.id)"
                + (project.yolo ? " --dangerously-skip-permissions" : "")
                + (extra.isEmpty ? "" : " \(extra)")
        case .codex:
            let tool = session.kind.command(yolo: false, executable: agentExecutable(session.kind))
            base = "\(tool) resume \(session.id)"
                + (project.yolo ? " --dangerously-bypass-approvals-and-sandbox" : "")
                + (extra.isEmpty ? "" : " \(extra)")
        }
        let command: String
        if project.tmux {
            let s = tmuxSessionName(project, session.kind) + "-resume"
            let inner = singleQuoteBody("\(base); exec zsh -l")
            command = "tmux new-session -A -s \(shellQuote(s)) -c \(shellQuote(path)) \"zsh -lc '\(inner)'\""
        } else {
            command = base
        }
        openInTerminal(terminal, path: path, command: command)
    }

    /// Open `terminal` at `path`. If `command` is given, run it (keeping a shell
    /// open afterwards); otherwise just open a login shell.
    private static func openInTerminal(_ terminal: TerminalApp, path: String, command: String?) {
        switch terminal {
        case .ghostty:
            var args = ["-na", "Ghostty.app", "--args", "--working-directory=\(path)"]
            if let command { args += ["-e", "zsh", "-lc", "\(command); exec zsh -l"] }
            Shell.run("/usr/bin/open", args)
        case .terminal:
            let body = command.map { "cd \(shellQuote(path)) && \($0)" } ?? "cd \(shellQuote(path))"
            let osa = "tell application \"Terminal\"\nactivate\ndo script \(appleString(body))\nend tell"
            Shell.run("/usr/bin/osascript", ["-e", osa])
        case .iterm:
            let body = command.map { "cd \(shellQuote(path)) && \($0)" } ?? "cd \(shellQuote(path))"
            let osa = "tell application \"iTerm\"\nactivate\ncreate window with default profile\ntell current session of current window to write text \(appleString(body))\nend tell"
            Shell.run("/usr/bin/osascript", ["-e", osa])
        case .warp:
            Shell.run("/usr/bin/open", ["-a", "Warp", path])
        case .wezterm:
            var args = ["-na", "WezTerm.app", "--args", "start", "--cwd", path]
            if let command { args += ["--", "zsh", "-lc", "\(command); exec zsh -l"] }
            Shell.run("/usr/bin/open", args)
        }
    }

    /// The tmux session name Pharos uses for a given project + agent kind.
    /// Public so ProjectStore can match against live session names.
    /// Common tmux prefix for a project: `pharos-<slug>-`. All of a project's
    /// agent sessions (per-kind and per-issue) start with this.
    static func tmuxSessionPrefix(_ project: Project) -> String {
        let base = project.name.lowercased().map { (c: Character) -> Character in
            (c.isLetter || c.isNumber) ? c : "-"
        }
        return "pharos-\(String(base))-"
    }

    static func tmuxSessionName(_ project: Project, _ kind: AgentKind) -> String {
        "\(tmuxSessionPrefix(project))\(kind.rawValue)"
    }

    /// Per-issue session name, so agents launched on different issues of the same
    /// project+kind don't collide (and finish-detection targets the right issue).
    static func tmuxSessionName(_ project: Project, _ kind: AgentKind, issue: Int) -> String {
        "\(tmuxSessionName(project, kind))-i\(issue)"
    }

    /// First installed tmux binary, or nil if tmux isn't installed.
    static let tmuxPath: String? = {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Returns the set of all live tmux session names that Pharos launched
    /// (prefix "pharos-"). Returns an empty set if tmux is not installed or
    /// not running.
    /// Live Pharos tmux sessions. Returns nil ("unknown") when tmux isn't
    /// installed, so callers never mistake "can't tell" for "nothing running"
    /// (which would falsely clear issue↔agent links). An installed tmux with no
    /// server simply yields an empty set.
    static func runningSessions() -> Set<String>? {
        guard let tmux = tmuxPath else { return nil }
        let r = Shell.run(tmux, ["list-sessions", "-F", "#{session_name}"])
        return Set(r.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("pharos-") })
    }

    /// Run an arbitrary shell command at `path` in the chosen terminal.
    static func runCommand(_ command: String, at path: String, terminal: TerminalApp) {
        openInTerminal(terminal, path: path, command: command)
    }

    /// Attach to an existing tmux session in the chosen terminal.
    static func attach(sessionName: String, terminal: TerminalApp) {
        let cmd = "/opt/homebrew/bin/tmux attach -t \(shellQuote(sessionName))"
        // We don't have a meaningful cwd; use home dir as fallback.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        openInTerminal(terminal, path: home, command: cmd)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use *inside* an already-open single-quoted shell
    /// context (i.e. the caller supplies the surrounding `'…'`). A literal `'`
    /// becomes `'\''` — close the quote, an escaped quote, reopen the quote.
    private static func singleQuoteBody(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func appleString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

extension GitService {
    /// Origin remote URL of a local repo, if any (used to auto-fill a project's
    /// GitHub remote when adding a folder).
    static func detectRemote(at path: String) -> String? {
        let r = Shell.git(["remote", "get-url", "origin"], at: path)
        return (r.ok && !r.out.isEmpty) ? r.out : nil
    }

    /// Commit-count grid for the last `weeks` weeks: columns of 7 days
    /// (Sun..Sat), `-1` marks cells after today. Drives the detail-view heatmap.
    static func heatmapGrid(for path: String, weeks: Int) async -> [[Int]] {
        await Task.detached(priority: .utility) {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            let todayWeekday = cal.component(.weekday, from: today) - 1   // 0 = Sunday
            let totalBack = (weeks - 1) * 7 + todayWeekday
            let out = Shell.git(["log", "--since=\(totalBack + 1) days ago",
                                 "--date=format:%Y-%m-%d", "--pretty=%cd"], at: path).out
            var counts: [String: Int] = [:]
            for line in out.split(separator: "\n") { counts[String(line), default: 0] += 1 }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            var grid: [[Int]] = []
            for c in 0..<weeks {
                var col: [Int] = []
                for r in 0..<7 {
                    let daysAgo = totalBack - (c * 7 + r)
                    if daysAgo < 0 {
                        col.append(-1)
                    } else {
                        let day = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
                        col.append(counts[fmt.string(from: day)] ?? 0)
                    }
                }
                grid.append(col)
            }
            return grid
        }.value
    }

    /// Pure parser for `git worktree list --porcelain` output.
    /// Extracted so it can be unit-tested without hitting the filesystem.
    static func parseWorktrees(_ porcelain: String) -> [Worktree] {
        var result: [Worktree] = []
        var curPath: String?
        var branch = "(detached)"
        var bare = false
        func flush() {
            if let p = curPath, !bare {
                result.append(Worktree(path: p, branch: branch, isMain: result.isEmpty))
            }
            curPath = nil; branch = "(detached)"; bare = false
        }
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("worktree ") { flush(); curPath = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            } else if line == "bare" { bare = true }
        }
        flush()
        return result
    }

    static func worktrees(for path: String) async -> [Worktree] {
        await Task.detached(priority: .utility) {
            let out = Shell.git(["worktree", "list", "--porcelain"], at: path).out
            return GitService.parseWorktrees(out)
        }.value
    }

    @discardableResult
    static func addWorktree(repo: String, name: String) -> Bool {
        let repoURL = URL(fileURLWithPath: repo)
        let dest = repoURL.deletingLastPathComponent()
            .appendingPathComponent("\(repoURL.lastPathComponent)-\(name)").path
        return Shell.git(["worktree", "add", "-b", name, dest], at: repo).ok
    }

    /// Count of pending changes (`git status --porcelain` lines, incl. untracked)
    /// in a worktree — used to show "what's lost" before removal. 0 = clean.
    static func worktreeDirtyCount(path: String) -> Int {
        let out = Shell.git(["status", "--porcelain"], at: path).out
        return out.isEmpty ? 0 : out.split(separator: "\n").count
    }

    /// Remove a worktree the recoverable way: move its working directory to the
    /// macOS Trash, then prune git's now-stale bookkeeping. The branch is left
    /// intact. Returns false if the directory could not be trashed — in which
    /// case git state is left untouched, so nothing is half-removed.
    @discardableResult
    static func trashWorktree(repo: String, path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } catch {
            return false
        }
        _ = Shell.git(["worktree", "prune"], at: repo)
        return true
    }
}

/// Lists the user's GitHub repos via the `gh` CLI.
enum GitHubService {
    /// Resolved path to the `gh` binary, shared across all methods.
    private static var ghPath: String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/opt/homebrew/bin/gh"
    }

    static func listRepos() async -> [GitHubRepo] {
        await Task.detached(priority: .userInitiated) {
            let r = Shell.run(ghPath, [
                "repo", "list", "--limit", "300",
                "--json", "name,url,sshUrl,isPrivate,description",
            ])
            guard r.ok, let data = r.out.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([GitHubRepo].self, from: data)) ?? []
        }.value
    }

    /// Parse `owner/repo` from an https or ssh GitHub remote URL.
    /// Returns nil if the URL is not a GitHub remote.
    static func ownerRepo(from remote: String) -> String? {
        let s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        // https://github.com/owner/repo[.git]
        if s.hasPrefix("https://github.com/") {
            var path = String(s.dropFirst("https://github.com/".count))
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return "\(parts[0])/\(parts[1])"
        }
        // git@github.com:owner/repo[.git]
        if s.hasPrefix("git@github.com:") {
            var path = String(s.dropFirst("git@github.com:".count))
            if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
            let parts = path.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return "\(parts[0])/\(parts[1])"
        }
        return nil
    }

    /// Fetch open PR count and latest CI run status for the given remote URL.
    /// Returns nil only when `ownerRepo` cannot be parsed (not a GitHub remote).
    /// Returns a `GitHubStatus` with `available: false` on any gh failure.
    static func status(remote: String) async -> GitHubStatus? {
        guard let ownerRepo = ownerRepo(from: remote) else { return nil }
        return await Task.detached(priority: .utility) {
            let unavailable = GitHubStatus(openPRs: 0, ciStatus: "", ciConclusion: "", available: false)
            let gh = ghPath

            // -- Open PRs --
            let prResult = Shell.run(gh, [
                "pr", "list",
                "--repo", ownerRepo,
                "--state", "open",
                "--json", "number",
            ])
            var openPRs = 0
            if prResult.ok, let data = prResult.out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                openPRs = json.count
            } else if !prResult.ok {
                return unavailable
            }

            // -- Latest CI run --
            let runResult = Shell.run(gh, [
                "run", "list",
                "--repo", ownerRepo,
                "--limit", "1",
                "--json", "status,conclusion",
            ])
            var ciStatus = ""
            var ciConclusion = ""
            if runResult.ok, let data = runResult.out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = json.first {
                ciStatus = first["status"] as? String ?? ""
                ciConclusion = first["conclusion"] as? String ?? ""
            } else if !runResult.ok {
                return unavailable
            }

            return GitHubStatus(openPRs: openPRs, ciStatus: ciStatus,
                                ciConclusion: ciConclusion, available: true)
        }.value
    }
}
