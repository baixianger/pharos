import Foundation

/// A recoverable error from a core operation. The CLI maps it to stderr + a
/// non-zero exit code.
struct CoreError: Error { let message: String }

/// The result of a *read* operation: a human-readable rendering plus an optional
/// JSON-able payload. The CLI prints `text` by default and `json` under `--json`.
struct CoreOutcome {
    var text: String
    var json: [String: Any]?
}

/// The single implementation behind the `pharos` CLI. Each command only parses
/// its own input and formats the result; every registry read/mutation and every
/// launch action lives here exactly once. The GUI keeps its own `@MainActor`
/// `ProjectStore` for live observation, but shares the same on-disk `StoreData`
/// shape and the same `StoreData` soft-delete logic.
enum PharosCore {

    // MARK: Registry location

    /// Location of the registry file. Honors `PHAROS_REGISTRY` (absolute path)
    /// so tests — and power users — can point at an alternate store without
    /// touching the real one.
    static var registryURL: URL {
        if let override = ProcessInfo.processInfo.environment["PHAROS_REGISTRY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return DataLocation.current.appendingPathComponent("projects.json")
    }

    // MARK: Registry IO

    /// Read the full `StoreData`. Tolerates a missing file (empty store) and
    /// migrates the older flat-array format — mirrors `ProjectStore.load()`.
    static func loadStore() -> StoreData {
        guard let data = try? Data(contentsOf: registryURL) else { return StoreData() }
        let decoder = JSONDecoder()
        var store = StoreData()
        if let decoded = try? decoder.decode(StoreData.self, from: data) {
            store = decoded
        } else if let legacy = try? decoder.decode([Project].self, from: data) {
            store = StoreData(projects: legacy, groups: [])
        } else {
            return StoreData()
        }
        // Resolve each project's localPath to THIS machine's checkout (per-host map).
        store.resolveHostPaths(host: HostIdentity.current)
        return store
    }

    static func loadProjects() -> [Project] { loadStore().projects }

    /// Write the registry back, pretty-printed with sorted keys and atomically —
    /// mirroring `ProjectStore.save()` so the GUI's file watcher picks it up.
    static func saveStore(_ store: StoreData) {
        let dir = registryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out = store
        out.captureHostPaths(host: HostIdentity.current)   // record this host's paths
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(out) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    /// Ensure every tag used by a project exists as a group, then sort groups.
    static func backfillGroups(_ store: inout StoreData) {
        for tag in store.projects.flatMap({ $0.tags }) where !store.groups.contains(tag) {
            store.groups.append(tag)
        }
        store.groups.sort { $0.lowercased() < $1.lowercased() }
    }

    static func findProject(_ name: String) -> Project? {
        let projects = loadProjects()
        if let exact = projects.first(where: { $0.name == name }) { return exact }
        return projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Index of a project in a list: exact name first, then case-insensitive.
    static func projectIndex(_ name: String, in projects: [Project]) -> Int? {
        if let exact = projects.firstIndex(where: { $0.name == name }) { return exact }
        return projects.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Persisted prefs (shared with the GUI via UserDefaults)

    static func persistedTerminal() -> TerminalApp {
        TerminalApp(rawValue: UserDefaults.standard.string(forKey: "pharos.terminal") ?? "") ?? .ghostty
    }

    static func persistedEditor() -> EditorApp {
        EditorApp(rawValue: UserDefaults.standard.string(forKey: "pharos.editor") ?? "") ?? .vscode
    }

    // MARK: Reads

    static func listProjects() -> CoreOutcome {
        let projects = loadProjects()
        let rows: [[String: Any]] = projects.map { p in
            [
                "name": p.name,
                "localPath": p.localPath ?? NSNull(),
                "githubRemote": p.githubRemote ?? NSNull(),
                "tags": p.tags,
                "notes": p.notes,
                "yolo": p.yolo,
                "tmux": p.tmux,
            ]
        }
        let text = projects.isEmpty
            ? "No projects."
            : projects.map { p in
                let path = p.localPath ?? p.githubRemote ?? "—"
                let tags = p.tags.isEmpty ? "" : "  [\(p.tags.joined(separator: ", "))]"
                let flags = [p.yolo ? "yolo" : nil, p.tmux ? "tmux" : nil].compactMap { $0 }.joined(separator: ",")
                let flagStr = flags.isEmpty ? "" : "  (\(flags))"
                return "\(p.name)\t\(path)\(tags)\(flagStr)"
            }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["projects": rows, "count": rows.count])
    }

    static func listGroups() -> CoreOutcome {
        let store = loadStore()
        let sorted = store.groups.sorted { $0.lowercased() < $1.lowercased() }
        let rows: [[String: Any]] = sorted.map { g in
            ["name": g, "count": store.projects.filter { $0.tags.contains(g) }.count]
        }
        let text = sorted.isEmpty
            ? "No groups."
            : sorted.map { g in "\(g) (\(store.projects.filter { $0.tags.contains(g) }.count))" }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["groups": rows, "count": rows.count])
    }

    static func gitStatus(project name: String) throws -> CoreOutcome {
        let (project, path) = try resolveLocalProject(name)
        let info = runBlocking { await GitService.info(for: path) }
        guard info.isRepo else {
            return CoreOutcome(text: "'\(project.name)' is not a git repository.", json: nil)
        }
        let payload: [String: Any] = [
            "project": project.name,
            "branch": info.branch,
            "dirty": info.isDirty,
            "ahead": info.ahead,
            "behind": info.behind,
            "lastCommit": [
                "hash": info.lastCommitHash,
                "subject": info.lastCommitSubject,
                "relative": info.lastCommitRelative,
            ],
        ]
        let dirty = info.isDirty ? " ✱" : ""
        let text = """
            \(project.name) — \(info.branch)\(dirty)
            ahead \(info.ahead), behind \(info.behind)
            \(info.lastCommitHash) \(info.lastCommitSubject) (\(info.lastCommitRelative))
            """
        return CoreOutcome(text: text, json: payload)
    }

    static func listWorktrees(project name: String) throws -> CoreOutcome {
        let (project, path) = try resolveLocalProject(name)
        let trees = runBlocking { await GitService.worktrees(for: path) }
        let rows: [[String: Any]] = trees.map { wt in
            ["name": wt.name, "branch": wt.branch, "path": wt.path, "isMain": wt.isMain]
        }
        let text = trees.isEmpty
            ? "No worktrees."
            : trees.map { "\($0.isMain ? "*" : " ") \($0.name)\t\($0.branch)\t\($0.path)" }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["project": project.name, "worktrees": rows, "count": rows.count])
    }

    static func listSessions(project name: String, agent agentRaw: String) throws -> CoreOutcome {
        guard let kind = AgentKind(rawValue: agentRaw) else {
            throw CoreError(message: "Argument 'agent' must be \"claude\" or \"codex\".")
        }
        let (project, path) = try resolveLocalProject(name)
        let sessions = runBlocking { () async -> [AgentSession] in
            switch kind {
            case .claude: return await SessionsService.claudeSessions(for: path)
            case .codex:  return await SessionsService.codexSessions(for: path)
            }
        }
        let rows: [[String: Any]] = sessions.map { ["id": $0.id, "title": $0.title] }
        let text = sessions.isEmpty
            ? "No \(kind.rawValue) sessions."
            : sessions.map { "\($0.id)\t\($0.title)" }.joined(separator: "\n")
        return CoreOutcome(text: text,
                           json: ["project": project.name, "agent": kind.rawValue,
                                  "sessions": rows, "count": rows.count])
    }

    static func listTrash() -> CoreOutcome {
        let store = loadStore()
        let fmt = ISO8601DateFormatter()
        let rows: [[String: Any]] = store.trash.map { item in
            ["id": item.id.uuidString, "title": item.title,
             "kind": item.kindLabel, "deletedAt": fmt.string(from: item.deletedAt)]
        }
        let text = store.trash.isEmpty
            ? "Trash is empty."
            : store.trash.map { "\($0.id.uuidString)\t\($0.kindLabel)\t\($0.title)" }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["trash": rows, "count": rows.count])
    }

    // MARK: Mutations (return a confirmation message)

    static func addProject(name rawName: String?, localPath: String?, githubRemote: String?,
                           tags: [String], notes: String?) throws -> String {
        guard let name = rawName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw CoreError(message: "Missing required argument: name")
        }
        var store = loadStore()
        if projectIndex(name, in: store.projects) != nil {
            throw CoreError(message: "A project named '\(name)' already exists.")
        }
        let lp = localPath.flatMap { $0.isEmpty ? nil : $0 }
        let remote = githubRemote.flatMap { $0.isEmpty ? nil : $0 }
        let project = Project(name: name, localPath: lp, githubRemote: remote,
                              tags: tags, notes: notes ?? "")
        store.projects.append(project)
        backfillGroups(&store)
        saveStore(store)
        return "Added project '\(name)'."
    }

    static func removeProject(name: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: project") }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        let removed = store.projects[idx].name
        store.softDeleteProject(id: store.projects[idx].id)
        store.purgeExpiredTrash()
        saveStore(store)
        return "Removed project '\(removed)' — moved to Pharos Trash, restorable for 30 days."
    }

    static func renameProject(name: String?, newName rawNew: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        guard let newName = rawNew?.trimmingCharacters(in: .whitespaces), !newName.isEmpty else {
            throw CoreError(message: "Missing required argument: new_name")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        if let clash = projectIndex(newName, in: store.projects), clash != idx {
            throw CoreError(message: "A project named '\(newName)' already exists.")
        }
        let old = store.projects[idx].name
        store.projects[idx].name = newName
        saveStore(store)
        return "Renamed project '\(old)' to '\(newName)'."
    }

    static func setDescription(name: String?, description: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        guard let description else { throw CoreError(message: "Missing required argument: description") }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        store.projects[idx].notes = description
        saveStore(store)
        return "Set description for '\(store.projects[idx].name)'."
    }

    static func addToGroup(name: String?, group rawGroup: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        guard let group = rawGroup?.trimmingCharacters(in: .whitespaces), !group.isEmpty else {
            throw CoreError(message: "Missing required argument: group")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        if !store.projects[idx].tags.contains(group) { store.projects[idx].tags.append(group) }
        if !store.groups.contains(group) { store.groups.append(group) }
        backfillGroups(&store)
        saveStore(store)
        return "Added '\(store.projects[idx].name)' to group '\(group)'."
    }

    static func removeFromGroup(name: String?, group: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        guard let group, !group.isEmpty else { throw CoreError(message: "Missing required argument: group") }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        store.projects[idx].tags.removeAll { $0 == group }
        saveStore(store)
        return "Removed '\(store.projects[idx].name)' from group '\(group)'."
    }

    static func createGroup(name rawName: String?) throws -> String {
        guard let name = rawName?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw CoreError(message: "Missing required argument: name")
        }
        var store = loadStore()
        if store.groups.contains(name) { return "Group '\(name)' already exists." }
        store.groups.append(name)
        store.groups.sort { $0.lowercased() < $1.lowercased() }
        saveStore(store)
        return "Created group '\(name)'."
    }

    static func deleteGroup(name: String?) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        var store = loadStore()
        let existed = store.groups.contains(name) || store.projects.contains { $0.tags.contains(name) }
        store.softDeleteGroup(name)
        store.purgeExpiredTrash()
        saveStore(store)
        guard existed else { return "Group '\(name)' did not exist." }
        return "Deleted group '\(name)' — moved to Pharos Trash, restorable for 30 days."
    }

    /// Set a boolean project flag. `flag` is "yolo" or "tmux".
    static func setFlag(name: String?, flag: String, value: Bool) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: name") }
        let keyPath: WritableKeyPath<Project, Bool>
        switch flag {
        case "yolo": keyPath = \.yolo
        case "tmux": keyPath = \.tmux
        default: throw CoreError(message: "Unknown flag: \(flag)")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        store.projects[idx][keyPath: keyPath] = value
        saveStore(store)
        return "Set \(flag) = \(value) for '\(store.projects[idx].name)'."
    }

    static func restoreTrash(id idString: String?) throws -> String {
        guard let idString, let id = UUID(uuidString: idString) else {
            throw CoreError(message: "Argument 'id' must be a trash item id (see `trash list`).")
        }
        var store = loadStore()
        guard let item = store.trash.first(where: { $0.id == id }) else {
            throw CoreError(message: "No trash item with id \(idString).")
        }
        let title = item.title
        store.restoreTrash(id)
        saveStore(store)
        return "Restored '\(title)'."
    }

    static func emptyTrash() -> String {
        var store = loadStore()
        let n = store.trash.count
        store.trash.removeAll()
        saveStore(store)
        sweepAttachments(store)   // delete attachment files for purged issues
        return n == 0 ? "Trash was already empty." : "Emptied Trash (\(n) item\(n == 1 ? "" : "s"))."
    }

    /// Delete attachment directories whose issue is neither live nor in the Trash.
    static func sweepAttachments(_ store: StoreData) {
        var keep = Set<UUID>()
        for p in store.projects { for issue in p.issues { keep.insert(issue.id) } }
        for item in store.trash { if case .issue(_, _, let issue) = item.payload { keep.insert(issue.id) } }
        AttachmentStore.sweepOrphans(keepingIssueIDs: keep)
    }

    // MARK: Issues & project-update feed

    static func issueAdd(project name: String?, title: String?,
                         priority: String?, body: String?, attach: [String] = [],
                         labels: [String] = []) throws -> String {
        guard let title = title?.trimmingCharacters(in: .whitespaces), !title.isEmpty else {
            throw CoreError(message: "Missing required argument: title")
        }
        let prio = try parsePriority(priority)
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let pid = store.projects[idx].id
        let pname = store.projects[idx].name
        // Stage attachments under the issue's id before creating it.
        let issueID = UUID()
        var attachments: [IssueAttachment] = []
        for path in attach {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do { attachments.append(try AttachmentStore.add(fileAt: url, toIssue: issueID)) }
            catch { throw CoreError(message: "Couldn't attach '\(path)': \(error.localizedDescription)") }
        }
        let cleanLabels = normalizedLabels(labels)
        guard let issue = store.addIssue(projectID: pid, title: title, priority: prio,
                                         body: body ?? "", id: issueID,
                                         attachments: attachments, labels: cleanLabels) else {
            throw CoreError(message: "Project not found: \(name ?? "")")
        }
        saveStore(store)
        let note = attachments.isEmpty ? "" : " (+\(attachments.count) attachment\(attachments.count == 1 ? "" : "s"))"
        return "Created \(pname)#\(issue.number): \(issue.title)\(note)"
    }

    static func issueLabel(project name: String?, number: Int?, add: Bool, label: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else {
            throw CoreError(message: "Missing required argument: label")
        }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let ok = store.updateIssue(projectID: store.projects[idx].id, number: number) { issue in
            if add {
                if !issue.labels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) {
                    issue.labels.append(label)
                }
            } else {
                issue.labels.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame }
            }
        }
        guard ok else { throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.") }
        saveStore(store)
        return "\(add ? "Added" : "Removed") label '\(label)' \(add ? "to" : "from") \(store.projects[idx].name)#\(number)."
    }

    static func issueList(project name: String?, all: Bool,
                          label: String? = nil, status: String? = nil, priority: String? = nil,
                          milestone: String? = nil) throws -> CoreOutcome {
        let store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let project = store.projects[idx]
        let statusFilter = try status.map { try parseStatus($0) }
        let priorityFilter = try priority.map { try parsePriority($0) }
        let milestoneNames = Dictionary(uniqueKeysWithValues: project.milestones.map { ($0.id, $0.name) })
        let milestoneID = milestone.flatMap { mname in
            project.milestones.first { $0.name.caseInsensitiveCompare(mname) == .orderedSame }?.id
        }
        let issues = project.issues
            .filter { all || statusFilter != nil || $0.status.isOpen }
            .filter { statusFilter == nil || $0.status == statusFilter }
            .filter { priorityFilter == nil || $0.priority == priorityFilter }
            .filter { label == nil || $0.labels.contains { $0.caseInsensitiveCompare(label!) == .orderedSame } }
            .filter { milestone == nil || $0.milestoneID == milestoneID }
            .sorted { lhs, rhs in
                if lhs.status.order != rhs.status.order { return lhs.status.order < rhs.status.order }
                if lhs.priority.rank != rhs.priority.rank { return lhs.priority.rank > rhs.priority.rank }
                return lhs.number < rhs.number
            }
        let subtasks = Dictionary(grouping: project.issues.compactMap { i in i.parent.map { ($0, i.number) } },
                                  by: { $0.0 }).mapValues { $0.map(\.1).sorted() }
        let rows: [[String: Any]] = issues.map { i in
            [
                "number": i.number, "title": i.title, "status": i.status.rawValue,
                "priority": i.priority.rawValue, "body": i.body, "labels": i.labels,
                "milestone": i.milestoneID.flatMap { milestoneNames[$0] } ?? NSNull(),
                "parent": i.parent ?? NSNull(),
                "subtasks": subtasks[i.number] ?? [],
                "relations": i.relations.map { ["kind": $0.kind.rawValue, "target": $0.target] },
                "activeSession": i.activeSession ?? NSNull(),
            ]
        }
        let text = issues.isEmpty ? "No issues." : issues.map { i in
            let prio = i.priority == .none ? "" : "\(i.priority.rawValue) "
            let lbls = i.labels.isEmpty ? "" : "  {\(i.labels.joined(separator: ", "))}"
            let ms = i.milestoneID.flatMap { milestoneNames[$0] }.map { "  @\($0)" } ?? ""
            let par = i.parent.map { "  ↳#\($0)" } ?? ""
            let subs = (subtasks[i.number]?.count).flatMap { $0 > 0 ? "  (\($0) sub)" : nil } ?? ""
            let agent = i.activeSession != nil ? "  ▶ agent" : ""
            return "#\(i.number)\t[\(i.status.rawValue)]\t\(prio)\(i.title)\(lbls)\(ms)\(par)\(subs)\(agent)"
        }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["project": project.name, "issues": rows, "count": rows.count])
    }

    // MARK: Milestones

    static func milestoneAdd(project name: String?, milestone mname: String?, due: String?) throws -> String {
        guard let mname = mname?.trimmingCharacters(in: .whitespaces), !mname.isEmpty else {
            throw CoreError(message: "Missing required argument: name")
        }
        let dueDate = try parseDue(due)
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard let m = store.addMilestone(projectID: store.projects[idx].id, name: mname, due: dueDate) else {
            throw CoreError(message: "Couldn't create milestone.")
        }
        saveStore(store)
        let dueStr = m.due.map { " (due \(Self.dueFormatter.string(from: $0)))" } ?? ""
        return "Milestone '\(m.name)'\(dueStr) in '\(store.projects[idx].name)'."
    }

    static func milestoneList(project name: String?) throws -> CoreOutcome {
        let store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let project = store.projects[idx]
        let rows: [[String: Any]] = project.milestones.map { m in
            let count = project.issues.filter { $0.milestoneID == m.id }.count
            return ["name": m.name, "due": m.due.map { Self.dueFormatter.string(from: $0) } ?? NSNull(), "count": count]
        }
        let text = project.milestones.isEmpty ? "No milestones." : project.milestones.map { m in
            let count = project.issues.filter { $0.milestoneID == m.id }.count
            let due = m.due.map { " · due \(Self.dueFormatter.string(from: $0))" } ?? ""
            return "\(m.name)\t(\(count) issues)\(due)"
        }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["project": project.name, "milestones": rows, "count": rows.count])
    }

    static func milestoneRemove(project name: String?, milestone mname: String?) throws -> String {
        guard let mname = mname?.trimmingCharacters(in: .whitespaces), !mname.isEmpty else {
            throw CoreError(message: "Missing required argument: name")
        }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard let m = store.milestone(projectID: store.projects[idx].id, named: mname) else {
            throw CoreError(message: "No milestone '\(mname)' in '\(store.projects[idx].name)'.")
        }
        store.removeMilestone(projectID: store.projects[idx].id, milestoneID: m.id)
        saveStore(store)
        return "Deleted milestone '\(m.name)' (issues unassigned)."
    }

    /// Assign (or clear, with name nil/"none") an issue's milestone. Auto-creates
    /// the milestone if it doesn't exist yet.
    static func issueSetMilestone(project name: String?, number: Int?, milestone mname: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let pid = store.projects[idx].id
        let trimmed = mname?.trimmingCharacters(in: .whitespaces)
        let targetID: UUID?
        if let trimmed, !trimmed.isEmpty, trimmed.lowercased() != "none" {
            targetID = store.addMilestone(projectID: pid, name: trimmed, due: nil)?.id
        } else {
            targetID = nil
        }
        let ok = store.updateIssue(projectID: pid, number: number) { $0.milestoneID = targetID }
        guard ok else { throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.") }
        saveStore(store)
        if let targetID, let m = store.projects[idx].milestones.first(where: { $0.id == targetID }) {
            return "\(store.projects[idx].name)#\(number) → milestone '\(m.name)'."
        }
        return "\(store.projects[idx].name)#\(number) milestone cleared."
    }

    // MARK: Overview / dashboard

    static func overview() -> CoreOutcome {
        let store = loadStore()
        let projects = store.projects
        let counts = store.issueStatusCounts()
        let open = store.openIssueCount
        let openIssues = projects.flatMap(\.issues).filter { $0.status.isOpen }
        let byPriority = Dictionary(grouping: openIssues, by: { $0.priority }).mapValues(\.count)
        let blocked = openIssues.filter { $0.relations.contains { $0.kind == .blockedBy } }.count
        let milestones = projects.reduce(0) { $0 + $1.milestones.count }
        let groups = store.groups.sorted { $0.lowercased() < $1.lowercased() }
        let groupRows: [[String: Any]] = groups.map { g in
            let ps = projects.filter { $0.tags.contains(g) }
            let openG = ps.reduce(0) { $0 + $1.issues.filter { $0.status.isOpen }.count }
            return ["name": g, "projects": ps.count, "open": openG]
        }

        let json: [String: Any] = [
            "projects": projects.count,
            "groups": store.groups.count,
            "openIssues": open,
            "byStatus": Dictionary(uniqueKeysWithValues: IssueStatus.allCases.map { ($0.rawValue, counts[$0] ?? 0) }),
            "byPriority": Dictionary(uniqueKeysWithValues: IssuePriority.allCases.map { ($0.rawValue, byPriority[$0] ?? 0) }),
            "blocked": blocked,
            "milestones": milestones,
            "groupRollup": groupRows,
        ]

        let statusLine = IssueStatus.allCases.map { "\($0.rawValue) \(counts[$0] ?? 0)" }.joined(separator: " · ")
        let prioLine = IssuePriority.allCases.reversed()
            .compactMap { p in (byPriority[p] ?? 0) > 0 ? "\(p.rawValue) \(byPriority[p]!)" : nil }
            .joined(separator: " · ")
        var lines = [
            "Projects: \(projects.count)   Groups: \(store.groups.count)   Open issues: \(open)   Milestones: \(milestones)   Blocked: \(blocked)",
            "By status: \(statusLine)",
        ]
        if !prioLine.isEmpty { lines.append("Open by priority: \(prioLine)") }
        for g in groupRows { lines.append("  • \(g["name"] ?? ""): \(g["projects"] ?? 0) projects, \(g["open"] ?? 0) open") }
        return CoreOutcome(text: lines.joined(separator: "\n"), json: json)
    }

    // MARK: Cross-project search

    /// Search every project's issues by title / body / labels / number. Returns
    /// matches with their project, number, title, and status.
    static func search(_ query: String?) throws -> CoreOutcome {
        guard let q = query?.trimmingCharacters(in: .whitespaces).lowercased(), !q.isEmpty else {
            throw CoreError(message: "Missing search query.")
        }
        let store = loadStore()
        var rows: [[String: Any]] = []
        var lines: [String] = []
        for p in store.projects {
            for i in p.issues where issueMatches(i, q) {
                rows.append(["project": p.name, "number": i.number, "title": i.title,
                             "status": i.status.rawValue, "labels": i.labels])
                let lbls = i.labels.isEmpty ? "" : "  {\(i.labels.joined(separator: ", "))}"
                lines.append("\(p.name)#\(i.number)\t[\(i.status.rawValue)]\t\(i.title)\(lbls)")
            }
        }
        let text = lines.isEmpty ? "No matches for \"\(q)\"." : lines.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["query": q, "matches": rows, "count": rows.count])
    }

    private static func issueMatches(_ issue: Issue, _ q: String) -> Bool {
        issue.title.lowercased().contains(q)
            || issue.body.lowercased().contains(q)
            || "#\(issue.number)".contains(q)
            || issue.labels.contains { $0.lowercased().contains(q) }
    }

    // MARK: Relations & subtasks

    static func issueSetParent(project name: String?, number: Int?, parent parentStr: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let parent: Int?
        if let p = parentStr?.trimmingCharacters(in: .whitespaces), !p.isEmpty, p.lowercased() != "none" {
            guard let pn = Int(p) else { throw CoreError(message: "Parent must be an issue number or 'none'.") }
            parent = pn
        } else {
            parent = nil
        }
        guard store.setIssueParent(projectID: store.projects[idx].id, number: number, parent: parent) else {
            throw CoreError(message: "Couldn't set parent — missing issue, self-parent, or would create a cycle.")
        }
        saveStore(store)
        let pn = store.projects[idx].name
        return parent.map { "\(pn)#\(number) is now a sub-task of #\($0)." } ?? "\(pn)#\(number) parent cleared."
    }

    static func issueLink(project name: String?, from: Int?, kind kindStr: String?, to: Int?, add: Bool) throws -> String {
        guard let from, let to else { throw CoreError(message: "Missing issue number(s).") }
        let kind = try parseRelationKind(kindStr)
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let ok = add
            ? store.addRelation(projectID: store.projects[idx].id, from: from, kind: kind, to: to)
            : store.removeRelation(projectID: store.projects[idx].id, from: from, kind: kind, to: to)
        guard ok else { throw CoreError(message: "Couldn't \(add ? "link" : "unlink") — check the issue numbers.") }
        saveStore(store)
        return "#\(from) \(kind.label.lowercased()) #\(to) — \(add ? "linked" : "unlinked")."
    }

    static func parseRelationKind(_ s: String?) throws -> RelationKind {
        switch (s ?? "").lowercased().replacingOccurrences(of: "-", with: "_") {
        case "relates", "related", "relates_to", "related_to": return .relates
        case "blocks", "block": return .blocks
        case "blocked_by", "blockedby", "blocked": return .blockedBy
        case "duplicate", "duplicate_of", "dup": return .duplicate
        default:
            throw CoreError(message: "Unknown relation '\(s ?? "")' (use relates|blocks|blocked-by|duplicate).")
        }
    }

    /// `yyyy-MM-dd` parser for `--due`. nil → nil; bad format → throws.
    private static func parseDue(_ s: String?) throws -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        guard let date = dueFormatter.date(from: s) else {
            throw CoreError(message: "Bad date '\(s)' (use yyyy-MM-dd).")
        }
        return date
    }

    static let dueFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Trim + de-dup labels (case-insensitive), preserving first-seen casing.
    private static func normalizedLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in labels {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            if seen.insert(l.lowercased()).inserted { out.append(l) }
        }
        return out
    }

    static func issueSetStatus(project name: String?, number: Int?, status: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        let st = try parseStatus(status)
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard store.setIssueStatus(projectID: store.projects[idx].id, number: number, status: st) else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        saveStore(store)
        return "\(store.projects[idx].name)#\(number) → \(st.label)."
    }

    static func issueSetPriority(project name: String?, number: Int?, priority: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        let prio = try parsePriority(priority)
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard store.setIssuePriority(projectID: store.projects[idx].id, number: number, priority: prio) else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        saveStore(store)
        return "\(store.projects[idx].name)#\(number) priority → \(prio.label)."
    }

    static func issueRemove(project name: String?, number: Int?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard store.softDeleteIssue(projectID: store.projects[idx].id, number: number) != nil else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        store.purgeExpiredTrash()
        saveStore(store)
        return "Removed \(store.projects[idx].name)#\(number) — moved to Pharos Trash, restorable for 30 days."
    }

    /// Launch an agent on an issue: move it to In Progress, link the session, then
    /// launch. When launched in tmux, the GUI auto-posts an update when the agent
    /// session ends (see `ProjectStore.postAgentFinished`).
    static func issueStart(project name: String?, number: Int?, agent agentRaw: String?,
                           yolo: Bool?, tmux: Bool?, host: String? = nil,
                           source: AuditLog.Source) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        guard let agentRaw, let kind = AgentKind(rawValue: agentRaw) else {
            throw CoreError(message: "Argument 'agent' must be \"claude\" or \"codex\".")
        }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let project = store.projects[idx]
        guard let issue = project.issues.first(where: { $0.number == number }) else {
            throw CoreError(message: "No issue #\(number) in '\(project.name)'.")
        }
        // Remote start: move to In Progress up front, launch, then link the
        // session tagged with the SSH alias — the reconcile sweep probes that
        // host's tmux (fail-open when unreachable), so a remote link is now
        // tracked exactly like a local one.
        if let host, !host.isEmpty {
            _ = store.setIssueStatus(projectID: project.id, number: number, status: .inProgress)
            saveStore(store)
            let brief = "You are working on \(project.name)#\(number): \(issue.title). "
                + "Read it with `pharos issue list \(project.name) --all`, log progress with "
                + "`pharos update add \(project.name) \"<note>\" --issue \(number)`, and set "
                + "`pharos issue status \(project.name) \(number) done` when finished."
            do {
                let summary = try RemoteLaunch.launch(project: project, kind: kind, host: host,
                                                      yolo: yolo ?? project.yolo, issue: number,
                                                      brief: brief, source: source)
                // Link AFTER the (minutes-long) launch, on a fresh load — the
                // GUI may have written the registry while we waited.
                var post = loadStore()
                _ = post.linkIssueSession(projectID: project.id, number: number,
                                          session: LaunchService.tmuxSessionName(project, kind, issue: number),
                                          host: host)
                saveStore(post)
                return "Started \(kind.label) on \(project.name)#\(number) remotely — issue moved to In Progress.\n" + summary
            } catch let e as RemoteLaunch.RemoteError {
                throw CoreError(message: e.message)
            }
        }
        guard let path = project.localPath, !path.isEmpty else {
            throw CoreError(message: "Project '\(project.name)' has no local path.")
        }
        let useYolo = yolo ?? project.yolo
        let useTmux = tmux ?? project.tmux
        let terminal = persistedTerminal()
        let tmuxName = LaunchService.tmuxSessionName(project, kind, issue: number)
        // Only link a trackable (tmux) session; otherwise just move to In Progress.
        if useTmux { store.linkIssueSession(projectID: project.id, number: number, session: tmuxName) }
        else { _ = store.setIssueStatus(projectID: project.id, number: number, status: .inProgress) }
        saveStore(store)
        runOnMain {
            LaunchService.launchAgent(kind, atPath: path, yolo: useYolo, tmux: useTmux,
                                      tmuxName: tmuxName, terminal: terminal, extraArgs: "", source: source)
        }
        return "Started \(kind.label) on \(project.name)#\(number) (\(issue.title)) — issue moved to In Progress."
    }

    static func updateAdd(project name: String?, body: String?, issueNumber: Int?) throws -> String {
        guard let body = body?.trimmingCharacters(in: .whitespaces), !body.isEmpty else {
            throw CoreError(message: "Missing required argument: text")
        }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        _ = store.addUpdate(projectID: store.projects[idx].id, body: body, kind: .note, issueNumber: issueNumber)
        saveStore(store)
        return "Logged update for '\(store.projects[idx].name)'."
    }

    // MARK: Attachments on existing issues

    static func attachAdd(project name: String?, number: Int?, paths: [String]) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        guard !paths.isEmpty else { throw CoreError(message: "No files to attach (use --file <path>).") }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard let issue = store.projects[idx].issues.first(where: { $0.number == number }) else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        let issueID = issue.id
        var added: [IssueAttachment] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            do { added.append(try AttachmentStore.add(fileAt: url, toIssue: issueID)) }
            catch { throw CoreError(message: "Couldn't attach '\(p)': \(error.localizedDescription)") }
        }
        _ = store.updateIssue(projectID: store.projects[idx].id, number: number) {
            $0.attachments.append(contentsOf: added)
        }
        saveStore(store)
        return "Attached \(added.count) file\(added.count == 1 ? "" : "s") to \(store.projects[idx].name)#\(number)."
    }

    static func attachList(project name: String?, number: Int?) throws -> CoreOutcome {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        let store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard let issue = store.projects[idx].issues.first(where: { $0.number == number }) else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        let rows: [[String: Any]] = issue.attachments.enumerated().map { n, a in
            ["index": n + 1, "name": a.originalName, "image": a.isImage, "bytes": a.byteSize, "stored": a.storedName]
        }
        let text = issue.attachments.isEmpty ? "No attachments." :
            issue.attachments.enumerated().map { n, a in "\(n + 1)\t\(a.originalName)\t\(a.byteSize)B" }
                .joined(separator: "\n")
        return CoreOutcome(text: text,
                           json: ["project": store.projects[idx].name, "number": number,
                                  "attachments": rows, "count": rows.count])
    }

    static func attachRemove(project name: String?, number: Int?, ref: String?) throws -> String {
        guard let number else { throw CoreError(message: "Missing required argument: number") }
        guard let ref = ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw CoreError(message: "Missing attachment ref (its index from `attach list`, or its name).")
        }
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        guard let issue = store.projects[idx].issues.first(where: { $0.number == number }) else {
            throw CoreError(message: "No issue #\(number) in '\(store.projects[idx].name)'.")
        }
        let target: IssueAttachment?
        if let n = Int(ref), n >= 1, n <= issue.attachments.count {
            target = issue.attachments[n - 1]
        } else {
            target = issue.attachments.first { $0.originalName == ref || $0.storedName == ref }
        }
        guard let target else { throw CoreError(message: "No attachment '\(ref)' on #\(number).") }
        try? FileManager.default.removeItem(at: AttachmentStore.fileURL(target, issueID: issue.id))
        _ = store.updateIssue(projectID: store.projects[idx].id, number: number) {
            $0.attachments.removeAll { $0.id == target.id }
        }
        saveStore(store)
        return "Removed attachment '\(target.originalName)' from \(store.projects[idx].name)#\(number)."
    }

    static func updateList(project name: String?) throws -> CoreOutcome {
        let store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let project = store.projects[idx]
        let fmt = ISO8601DateFormatter()
        let rows: [[String: Any]] = project.updates.map { u in
            [
                "createdAt": fmt.string(from: u.createdAt), "body": u.body,
                "kind": u.kind.rawValue, "issueNumber": u.issueNumber ?? NSNull(),
            ]
        }
        let text = project.updates.isEmpty ? "No updates." : project.updates.map { u in
            let tag = u.kind == .agent ? "[agent]" : "[note] "
            let iss = u.issueNumber.map { " (#\($0))" } ?? ""
            return "\(tag) \(u.body)\(iss)"
        }.joined(separator: "\n")
        return CoreOutcome(text: text, json: ["project": project.name, "updates": rows, "count": rows.count])
    }

    // MARK: Issue/update parsing helpers

    private static func projectIndexOrThrow(_ name: String?, in store: StoreData) throws -> Int {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: project") }
        guard let idx = projectIndex(name, in: store.projects) else {
            throw CoreError(message: "Project not found: \(name)")
        }
        return idx
    }

    static func parseStatus(_ s: String?) throws -> IssueStatus {
        switch (s ?? "").lowercased().replacingOccurrences(of: "-", with: "_") {
        case "backlog": return .backlog
        case "todo": return .todo
        case "in_progress", "inprogress", "progress", "started", "doing": return .inProgress
        case "done", "closed", "complete", "completed": return .done
        case "canceled", "cancelled": return .canceled
        default:
            throw CoreError(message: "Unknown status: \(s ?? "") (use backlog|todo|in_progress|done|canceled)")
        }
    }

    /// nil / empty → `.none`.
    static func parsePriority(_ s: String?) throws -> IssuePriority {
        switch (s ?? "").lowercased() {
        case "", "none", "no": return .none
        case "low": return .low
        case "medium", "med": return .medium
        case "high": return .high
        case "urgent": return .urgent
        default:
            throw CoreError(message: "Unknown priority: \(s ?? "") (use none|low|medium|high|urgent)")
        }
    }

    // MARK: Actions (side effects)

    static func launchAgent(project name: String?, agent agentRaw: String?,
                            yolo: Bool?, tmux: Bool?, host: String? = nil,
                            source: AuditLog.Source) throws -> String {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: project") }
        guard let agentRaw, let kind = AgentKind(rawValue: agentRaw) else {
            throw CoreError(message: "Argument 'agent' must be \"claude\" or \"codex\".")
        }
        guard let project = findProject(name) else { throw CoreError(message: "Project not found: \(name)") }
        // Remote launch: path resolves per-host from the synced registry; tmux is
        // implied (a detached remote session IS tmux). See RemoteLaunch.
        if let host, !host.isEmpty {
            do {
                return try RemoteLaunch.launch(project: project, kind: kind, host: host,
                                               yolo: yolo ?? true, source: source)
            } catch let e as RemoteLaunch.RemoteError {
                throw CoreError(message: e.message)
            }
        }
        guard let path = project.localPath, !path.isEmpty else {
            throw CoreError(message: "Project '\(name)' has no local path.")
        }
        let useYolo = yolo ?? true
        let useTmux = tmux ?? false
        let terminal = persistedTerminal()
        let tmuxName = LaunchService.tmuxSessionName(project, kind)
        runOnMain {
            LaunchService.launchAgent(kind, atPath: path, yolo: useYolo, tmux: useTmux,
                                      tmuxName: tmuxName, terminal: terminal, extraArgs: "", source: source)
        }
        let mode = [useYolo ? "yolo" : nil, useTmux ? "tmux" : nil].compactMap { $0 }.joined(separator: ", ")
        let suffix = mode.isEmpty ? "" : " (\(mode))"
        return "Launched \(kind.label) in '\(project.name)' at \(path) using \(terminal.label)\(suffix)."
    }

    static func resumeSession(project name: String?, agent agentRaw: String?,
                              sessionID: String?) throws -> String {
        guard let agentRaw, let kind = AgentKind(rawValue: agentRaw) else {
            throw CoreError(message: "Argument 'agent' must be \"claude\" or \"codex\".")
        }
        guard let sessionID, !sessionID.isEmpty else {
            throw CoreError(message: "Missing required argument: session_id")
        }
        let (project, path) = try resolveLocalProject(name)
        let terminal = persistedTerminal()
        let session = AgentSession(id: sessionID, kind: kind, title: "",
                                   modified: Date(), resumeCwd: path)
        runOnMain { LaunchService.resumeSession(session, project: project, terminal: terminal) }
        return "Resumed \(kind.label) session \(sessionID) in '\(project.name)' using \(terminal.label)."
    }

    static func runPlaybook(project name: String?, playbook playbookName: String?) throws -> String {
        guard let playbookName, !playbookName.isEmpty else {
            throw CoreError(message: "Missing required argument: playbook")
        }
        let (project, path) = try resolveLocalProject(name)
        let playbook = project.playbooks.first { $0.name == playbookName }
            ?? project.playbooks.first { $0.name.caseInsensitiveCompare(playbookName) == .orderedSame }
        guard let playbook else {
            throw CoreError(message: "Playbook '\(playbookName)' not found in '\(project.name)'.")
        }
        let terminal = persistedTerminal()
        runOnMain { LaunchService.runCommand(playbook.command, at: path, terminal: terminal) }
        return "Ran playbook '\(playbook.name)' (\(playbook.command)) in '\(project.name)' using \(terminal.label)."
    }

    static func openTerminal(project name: String?) throws -> String {
        let (project, path) = try resolveLocalProject(name)
        let terminal = persistedTerminal()
        runOnMain { LaunchService.openTerminal(at: path, terminal: terminal) }
        return "Opened \(terminal.label) at '\(project.name)' (\(path))."
    }

    static func openEditor(project name: String?) throws -> String {
        let (project, path) = try resolveLocalProject(name)
        let editor = persistedEditor()
        runOnMain { LaunchService.openEditor(editor, path: path) }
        return "Opened \(editor.label) at '\(project.name)' (\(path))."
    }

    static func revealInFinder(project name: String?) throws -> String {
        let (project, path) = try resolveLocalProject(name)
        runOnMain { LaunchService.revealInFinder(path) }
        return "Revealed '\(project.name)' (\(path)) in Finder."
    }

    // MARK: Per-host local path (multi-machine)

    /// Set (or clear) the current host's local checkout path for a project. The
    /// project's *data* is shared across machines; only this machine's path
    /// changes, stored under its host key.
    static func setLocalPath(project name: String?, path: String?, clear: Bool) throws -> String {
        var store = loadStore()
        let idx = try projectIndexOrThrow(name, in: store)
        let pname = store.projects[idx].name
        if clear {
            store.projects[idx].localPath = nil
            saveStore(store)
            return "Cleared '\(pname)' local path on \(HostIdentity.current)."
        }
        guard let raw = path?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            throw CoreError(message: "Missing required argument: path")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        store.projects[idx].localPath = expanded
        saveStore(store)
        return "Set '\(pname)' local path on \(HostIdentity.current) → \(expanded)."
    }

    /// Report the current host key (used to key per-host local paths).
    static func hostInfo() -> CoreOutcome {
        let host = HostIdentity.current
        return CoreOutcome(text: "host: \(host)", json: ["host": host])
    }

    // MARK: Resolution helpers

    /// Resolve a project name to a project with a non-empty local path, or throw
    /// a precise `CoreError` explaining why it failed.
    static func resolveLocalProject(_ name: String?) throws -> (Project, String) {
        guard let name, !name.isEmpty else { throw CoreError(message: "Missing required argument: project") }
        guard let project = findProject(name) else { throw CoreError(message: "Project not found: \(name)") }
        guard let path = project.localPath, !path.isEmpty else {
            throw CoreError(message: "Project '\(name)' has no local path.")
        }
        return (project, path)
    }

    // MARK: Threading bridges

    /// Run AppKit-adjacent work on the main thread. Blocks until done.
    static func runOnMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }

    /// Drive an async operation to completion from a synchronous front door.
    static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

/// A minimal box to ferry an async result back to a blocking caller. The value
/// is written once before the semaphore signal and read once after the wait, so
/// the unchecked conformance is sound (the semaphore provides ordering).
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}
