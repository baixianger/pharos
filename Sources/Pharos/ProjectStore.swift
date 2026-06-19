import SwiftUI
import Observation
@preconcurrency import UserNotifications

/// On-disk shape of the registry.
struct StoreData: Codable {
    var projects: [Project] = []
    var groups: [String] = []   // user-defined groups (may be empty)
}

/// Owns projects + groups, persists to Application Support, and exposes the
/// currently-selected group (watchlist-style).
@MainActor
@Observable
final class ProjectStore {
    var projects: [Project] = []
    var groups: [String] = []
    var selection: GroupSelection = .all
    var addRequested = false
    var importRequested = false
    var paletteRequested = false
    var lastError: String?
    var terminal: TerminalApp = .ghostty {
        didSet { UserDefaults.standard.set(terminal.rawValue, forKey: "pharos.terminal") }
    }
    var editor: EditorApp = .vscode {
        didSet { UserDefaults.standard.set(editor.rawValue, forKey: "pharos.editor") }
    }
    var appearance: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "pharos.appearance") }
    }
    var defaultYolo = true {
        didSet { UserDefaults.standard.set(defaultYolo, forKey: "pharos.defaultYolo") }
    }
    var defaultTmux = false {
        didSet { UserDefaults.standard.set(defaultTmux, forKey: "pharos.defaultTmux") }
    }
    var notifyOnFinish = true {
        didSet { UserDefaults.standard.set(notifyOnFinish, forKey: "pharos.notifyOnFinish") }
    }
    var scanRoots: [String] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(scanRoots) {
                UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "pharos.scanRoots")
            }
        }
    }
    var claudeArgs = "" {
        didSet { UserDefaults.standard.set(claudeArgs, forKey: "pharos.claudeArgs") }
    }
    var codexArgs = "" {
        didSet { UserDefaults.standard.set(codexArgs, forKey: "pharos.codexArgs") }
    }
    /// SSH host alias or `user@host` for the peer machine. Empty = disabled.
    var peerHost = "" {
        didSet { UserDefaults.standard.set(peerHost, forKey: "pharos.peerHost") }
    }

    private let fileURL: URL
    private var pollTask: Task<Void, Never>?
    /// Last modification date of projects.json we've observed/written, used by the
    /// external-edit watcher to avoid reloading our own saves in a loop.
    private var lastFileMtime: Date?
    private var fileWatchTask: Task<Void, Never>?

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pharos", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("projects.json")
        let d = UserDefaults.standard
        terminal = TerminalApp(rawValue: d.string(forKey: "pharos.terminal") ?? "") ?? .ghostty
        editor = EditorApp(rawValue: d.string(forKey: "pharos.editor") ?? "") ?? .vscode
        appearance = AppearanceMode(rawValue: d.string(forKey: "pharos.appearance") ?? "") ?? .system
        if d.object(forKey: "pharos.defaultYolo") != nil { defaultYolo = d.bool(forKey: "pharos.defaultYolo") }
        if d.object(forKey: "pharos.defaultTmux") != nil { defaultTmux = d.bool(forKey: "pharos.defaultTmux") }
        if d.object(forKey: "pharos.notifyOnFinish") != nil { notifyOnFinish = d.bool(forKey: "pharos.notifyOnFinish") }
        if let raw = d.string(forKey: "pharos.scanRoots"),
           let data = raw.data(using: .utf8),
           let roots = try? JSONDecoder().decode([String].self, from: data) {
            scanRoots = roots
        }
        claudeArgs = d.string(forKey: "pharos.claudeArgs") ?? ""
        codexArgs  = d.string(forKey: "pharos.codexArgs")  ?? ""
        peerHost   = d.string(forKey: "pharos.peerHost")   ?? ""
        load()
        lastFileMtime = fileModificationDate()
        requestNotificationAuthorizationIfNeeded()
        startFileWatch()
        // Running-agent awareness polls tmux (a subprocess) and the external-edit
        // watcher reacts to the MCP server's writes. Neither tmux nor the MCP
        // server exists in the sandboxed Mac App Store build, so skip the poller.
        #if !APP_STORE
        refreshRunningAgents()
        startPolling()
        #endif
    }

    // MARK: External-edit watcher (live registry sync)

    /// The MCP server writes to the same `projects.json` from a separate process.
    /// Poll its modification date every ~2s and reload when it changes underneath
    /// us, so MCP-driven edits show up in the running GUI without a relaunch.
    private func startFileWatch() {
        fileWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.reloadIfChangedExternally()
            }
        }
    }

    /// Reloads the registry whenever the on-disk mtime DIFFERS from the one we
    /// last loaded/wrote — not only when it's strictly greater. An external (MCP)
    /// write that lands within the same mtime tick as, or even slightly "before",
    /// our last-seen value would be missed by a `>`-only check; `!=` catches any
    /// change. We never loop on our own saves because `save()` records the
    /// post-write mtime into `lastFileMtime`, so the next poll sees them equal.
    private func reloadIfChangedExternally() {
        guard let mtime = fileModificationDate() else { return }
        if let last = lastFileMtime, mtime == last { return }
        load()
        lastFileMtime = mtime
    }

    private func fileModificationDate() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
    }

    private func requestNotificationAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                await self.pollSessions()
            }
        }
    }

    @MainActor
    private func pollSessions() async {
        let newSessions = await Task.detached(priority: .utility) {
            LaunchService.runningSessions()
        }.value

        if notifyOnFinish {
            let finished = runningSessions.subtracting(newSessions)
            for sessionName in finished {
                postFinishedNotification(sessionName: sessionName)
            }
        }

        // TODO: needs-input detection

        runningSessions = newSessions
    }

    private func postFinishedNotification(sessionName: String) {
        // Parse "pharos-<proj>-<kind>" → kind is the last segment, proj is everything between
        let stripped = sessionName.hasPrefix("pharos-") ? String(sessionName.dropFirst(7)) : sessionName
        // kind is always the last "-claude" or "-codex" suffix
        let kindRawValues = AgentKind.allCases.map { $0.rawValue }
        var kindLabel = ""
        var projPart = stripped
        for kind in kindRawValues {
            let suffix = "-\(kind)"
            if stripped.hasSuffix(suffix) {
                kindLabel = kind.capitalized
                projPart = String(stripped.dropLast(suffix.count))
                break
            }
        }
        // Clean up project slug: replace hyphens with spaces, title-case each word
        let projLabel = projPart
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        let title = kindLabel.isEmpty ? "Agent finished" : "\(kindLabel) finished"
        let body = projLabel.isEmpty ? sessionName : projLabel

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "pharos-done-\(sessionName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let store = try? decoder.decode(StoreData.self, from: data) {
            projects = store.projects
            groups = store.groups
        } else if let legacy = try? decoder.decode([Project].self, from: data) {
            projects = legacy   // migrate older flat-array format
        }
        backfillGroups()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(StoreData(projects: projects, groups: groups)) {
            try? data.write(to: fileURL, options: .atomic)
            // Stamp the file with an mtime WE choose and record that exact value,
            // rather than re-stat'ing (which could capture a concurrent MCP
            // write's mtime and then be mistaken for our own save). Any later MCP
            // write gets a different mtime, which the `==` watcher reloads.
            let stamp = Date()
            try? FileManager.default.setAttributes([.modificationDate: stamp],
                                                   ofItemAtPath: fileURL.path)
            lastFileMtime = fileModificationDate() ?? stamp
        }
    }

    /// Every tag used by a project should exist as a group.
    private func backfillGroups() {
        for tag in projects.flatMap({ $0.tags }) where !groups.contains(tag) {
            groups.append(tag)
        }
        groups.sort { $0.lowercased() < $1.lowercased() }
    }

    // MARK: Projects

    func add(_ project: Project) { projects.append(project); backfillGroups(); save() }
    func addProjects(_ new: [Project]) { projects.append(contentsOf: new); backfillGroups(); save() }
    func update(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[idx] = project; backfillGroups(); save()
    }
    func remove(_ project: Project) { projects.removeAll { $0.id == project.id }; save() }
    func project(_ id: Project.ID) -> Project? { projects.first { $0.id == id } }
    func contains(name: String) -> Bool { projects.contains { $0.name == name } }
    func contains(remote: String) -> Bool { projects.contains { $0.githubRemote == remote } }

    // MARK: Groups

    func addGroup(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !groups.contains(n) else { return }
        groups.append(n)
        groups.sort { $0.lowercased() < $1.lowercased() }
        save()
    }

    func removeGroup(_ name: String) {
        groups.removeAll { $0 == name }
        for i in projects.indices { projects[i].tags.removeAll { $0 == name } }
        if selection == .group(name) { selection = .all }
        save()
    }

    func toggleMembership(_ id: Project.ID, group: String) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        if let t = projects[i].tags.firstIndex(of: group) {
            projects[i].tags.remove(at: t)
        } else {
            projects[i].tags.append(group)
        }
        save()
    }

    func count(in group: String) -> Int { projects.filter { $0.tags.contains(group) }.count }

    // MARK: Derived

    var visibleProjects: [Project] {
        let result: [Project]
        switch selection {
        case .all: result = projects
        case .group(let g): result = projects.filter { $0.tags.contains(g) }
        }
        return result.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var currentTitle: String {
        switch selection {
        case .all: return "All Projects"
        case .group(let g): return g
        }
    }

    func requestAdd() { addRequested = true }
    func requestImport() { importRequested = true }
    func requestPalette() { paletteRequested = true }
    func reportError(_ message: String) { lastError = message }

    // MARK: Scan roots

    func addScanRoot(_ path: String) {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !scanRoots.contains(p) else { return }
        scanRoots.append(p)
    }

    func removeScanRoot(_ path: String) {
        scanRoots.removeAll { $0 == path }
    }

    /// Scans each root for immediate git-repo children and adds any not already tracked.
    func scanForProjects() async {
        let roots = scanRoots
        let defaultYolo = self.defaultYolo
        let defaultTmux = self.defaultTmux
        let existingNames = Set(projects.map { $0.name })
        let existingPaths = Set(projects.compactMap { $0.localPath })

        let found: [Project] = await Task.detached(priority: .utility) {
            var result: [Project] = []
            let fm = FileManager.default
            for root in roots {
                guard let children = try? fm.contentsOfDirectory(atPath: root) else { continue }
                let parentName = URL(fileURLWithPath: root).lastPathComponent
                for child in children {
                    let dirPath = (root as NSString).appendingPathComponent(child)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    // Must be a git repo: has a .git entry
                    let gitEntry = (dirPath as NSString).appendingPathComponent(".git")
                    guard fm.fileExists(atPath: gitEntry) else { continue }
                    // Skip if already tracked
                    if existingNames.contains(child) || existingPaths.contains(dirPath) { continue }
                    let remote = GitService.detectRemote(at: dirPath)
                    result.append(Project(
                        name: child,
                        localPath: dirPath,
                        githubRemote: remote,
                        tags: [parentName],
                        yolo: defaultYolo,
                        tmux: defaultTmux
                    ))
                }
            }
            return result
        }.value

        if found.isEmpty {
            reportError("Scan complete — no new projects found.")
        } else {
            addProjects(found)
        }
    }

    // MARK: Per-row git status (lazy, cached)

    var gitInfo: [Project.ID: GitInfo] = [:]
    var gitRefreshToken = 0
    private var gitLoading: Set<Project.ID> = []

    /// Loads git status for a project once and caches it; rows call this on appear.
    func ensureGit(_ project: Project) async {
        if gitInfo[project.id] != nil || gitLoading.contains(project.id) { return }
        guard let path = project.localPath, !path.isEmpty else {
            gitInfo[project.id] = GitInfo.none
            return
        }
        gitLoading.insert(project.id)
        let info = await GitService.info(for: path)
        gitInfo[project.id] = info
        gitLoading.remove(project.id)
    }

    func refreshAllGit() {
        gitInfo.removeAll()
        gitLoading.removeAll()
        gitRefreshToken += 1
        refreshRunningAgents()
    }

    // MARK: Running-agent awareness

    /// The set of live tmux session names for Pharos-launched agents.
    var runningSessions: Set<String> = []

    /// Queries tmux for live sessions and updates `runningSessions`.
    func refreshRunningAgents() {
        Task {
            let sessions = await Task.detached(priority: .utility) {
                LaunchService.runningSessions()
            }.value
            runningSessions = sessions
        }
    }

    /// Returns true if a Pharos tmux session for this project + agent kind is live.
    func isRunning(_ project: Project, _ kind: AgentKind) -> Bool {
        runningSessions.contains(LaunchService.tmuxSessionName(project, kind))
    }

    /// Returns true if ANY Pharos agent session is live for this project.
    func hasRunningAgent(_ project: Project) -> Bool {
        AgentKind.allCases.contains { isRunning(project, $0) }
    }
}
