import SwiftUI
import Observation
import AppKit
@preconcurrency import UserNotifications

/// On-disk shape of the registry.
struct StoreData: Codable {
    var projects: [Project] = []
    var groups: [String] = []   // user-defined groups (may be empty)
    var trash: [TrashedItem] = []   // soft-deleted items awaiting restore/purge
    /// Which machine hosts the mesh (its `HostIdentity`). Lives in the synced
    /// store — every Mac reads the SAME answer, so a second hub is impossible
    /// by construction (Pharos#5 P2). nil = nobody hosts.
    var meshHubHostID: String?

    init(projects: [Project] = [], groups: [String] = [], trash: [TrashedItem] = [],
         meshHubHostID: String? = nil) {
        self.projects = projects
        self.groups = groups
        self.trash = trash
        self.meshHubHostID = meshHubHostID
    }

    /// Tolerant decode — missing keys fall back to empty rather than failing the
    /// whole decode. Without this, adding the `trash` key would make every
    /// pre-existing `{projects, groups}` registry fail `decode(StoreData.self)`
    /// and silently reset to an empty store on upgrade. A top-level JSON *array*
    /// (the legacy flat format) still throws here, so the caller's `[Project]`
    /// fallback continues to handle migration.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        trash = try c.decodeIfPresent([TrashedItem].self, forKey: .trash) ?? []
        meshHubHostID = try c.decodeIfPresent(String.self, forKey: .meshHubHostID)
    }
}

extension StoreData {
    /// Restore window: trashed items older than this are auto-purged (30 days).
    static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Soft-delete a project: move it (with its full metadata) to Trash.
    /// Returns the new trash item's id (for an Undo token), or nil if absent.
    @discardableResult
    mutating func softDeleteProject(id: Project.ID, now: Date = Date()) -> TrashedItem.ID? {
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return nil }
        let project = projects.remove(at: idx)
        let item = TrashedItem(deletedAt: now, payload: .project(project))
        trash.insert(item, at: 0)
        return item.id
    }

    /// Soft-delete a group: capture which projects held the tag, strip it, trash it.
    @discardableResult
    mutating func softDeleteGroup(_ name: String, now: Date = Date()) -> TrashedItem.ID? {
        let members = projects.filter { $0.tags.contains(name) }.map { $0.id }
        guard groups.contains(name) || !members.isEmpty else { return nil }
        groups.removeAll { $0 == name }
        for i in projects.indices { projects[i].tags.removeAll { $0 == name } }
        let item = TrashedItem(deletedAt: now, payload: .group(name: name, memberProjectIDs: members))
        trash.insert(item, at: 0)
        return item.id
    }

    /// Soft-delete a playbook from a project.
    @discardableResult
    mutating func softDeletePlaybook(projectID: Project.ID, playbookID: Playbook.ID,
                                     now: Date = Date()) -> TrashedItem.ID? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let bi = projects[pi].playbooks.firstIndex(where: { $0.id == playbookID }) else { return nil }
        let pb = projects[pi].playbooks.remove(at: bi)
        let item = TrashedItem(deletedAt: now,
                               payload: .playbook(projectID: projectID,
                                                  projectName: projects[pi].name, playbook: pb))
        trash.insert(item, at: 0)
        return item.id
    }

    /// Restore a trashed item back into the live registry. No-op if the id is
    /// unknown; idempotent against duplicates (won't double-add).
    mutating func restoreTrash(_ id: TrashedItem.ID) {
        guard let idx = trash.firstIndex(where: { $0.id == id }) else { return }
        let item = trash.remove(at: idx)
        switch item.payload {
        case .project(let p):
            if !projects.contains(where: { $0.id == p.id }) { projects.append(p) }
        case .group(let name, let members):
            if !groups.contains(name) { groups.append(name) }
            for memberID in members {
                guard let i = projects.firstIndex(where: { $0.id == memberID }) else { continue }
                if !projects[i].tags.contains(name) { projects[i].tags.append(name) }
            }
        case .playbook(let projectID, _, let pb):
            guard let i = projects.firstIndex(where: { $0.id == projectID }) else { break }
            if !projects[i].playbooks.contains(where: { $0.id == pb.id }) {
                projects[i].playbooks.append(pb)
            }
        case .issue(let projectID, _, let issue):
            guard let i = projects.firstIndex(where: { $0.id == projectID }) else { break }
            if !projects[i].issues.contains(where: { $0.id == issue.id }) {
                projects[i].issues.append(issue)
            }
        }
        ensureGroupsForTags()
    }

    /// Drop trash items older than `retention`.
    mutating func purgeExpiredTrash(now: Date = Date(),
                                    retention: TimeInterval = StoreData.trashRetention) {
        trash.removeAll { now.timeIntervalSince($0.deletedAt) > retention }
    }

    // MARK: Issues & project-update feed (single-user; no human assignees)

    /// Create an issue under a project, assigning the next per-project number.
    /// Returns the created issue, or nil if the project is unknown.
    @discardableResult
    mutating func addIssue(projectID: Project.ID, title: String,
                           priority: IssuePriority = .none, body: String = "",
                           id: UUID = UUID(), attachments: [IssueAttachment] = [],
                           labels: [String] = [], now: Date = Date()) -> Issue? {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let issue = Issue(id: id, number: projects[i].nextIssueNumber, title: title,
                          status: .todo, priority: priority, body: body,
                          createdAt: now, updatedAt: now, attachments: attachments, labels: labels)
        projects[i].issues.append(issue)
        return issue
    }

    /// Move an issue to `toStatus` and position it before `beforeNumber` (or at
    /// the end of that status column if nil), renumbering the column's
    /// `sortOrder` to a clean 0…n. Drives kanban drag-reorder + cross-column move.
    @discardableResult
    mutating func moveIssue(projectID: Project.ID, number: Int, toStatus: IssueStatus,
                            before beforeNumber: Int?, now: Date = Date()) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              projects[pi].issues.contains(where: { $0.number == number }) else { return false }
        // Current display order of the destination column, excluding the moved issue.
        var order = projects[pi].issues
            .filter { $0.status == toStatus && $0.number != number }
            .sorted { ($0.sortOrder, $0.number) < ($1.sortOrder, $1.number) }
            .map(\.number)
        if let before = beforeNumber, let idx = order.firstIndex(of: before) {
            order.insert(number, at: idx)
        } else {
            order.append(number)
        }
        for i in projects[pi].issues.indices {
            if projects[pi].issues[i].number == number {
                if projects[pi].issues[i].status != toStatus {
                    projects[pi].issues[i].status = toStatus
                    projects[pi].issues[i].updatedAt = now
                }
            }
            if let pos = order.firstIndex(of: projects[pi].issues[i].number) {
                projects[pi].issues[i].sortOrder = Double(pos)
            }
        }
        return true
    }

    // MARK: Aggregates (dashboard / overview)

    /// Count of issues per status across every project.
    func issueStatusCounts() -> [IssueStatus: Int] {
        var counts: [IssueStatus: Int] = [:]
        for p in projects { for i in p.issues { counts[i.status, default: 0] += 1 } }
        return counts
    }

    /// Total open (actionable) issues across every project.
    var openIssueCount: Int {
        projects.reduce(0) { $0 + $1.issues.filter { $0.status.isOpen }.count }
    }

    /// All distinct labels used across a project's issues (sorted).
    func issueLabels(projectID: Project.ID) -> [String] {
        guard let p = projects.first(where: { $0.id == projectID }) else { return [] }
        return Array(Set(p.issues.flatMap(\.labels))).sorted { $0.lowercased() < $1.lowercased() }
    }

    // MARK: Milestones / cycles

    /// Add a milestone (or return the existing one with that name).
    @discardableResult
    mutating func addMilestone(projectID: Project.ID, name: String, due: Date?, now: Date = Date()) -> Milestone? {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        if let existing = projects[i].milestones.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return existing
        }
        let m = Milestone(name: n, due: due, createdAt: now)
        projects[i].milestones.append(m)
        return m
    }

    /// Delete a milestone and unassign it from every issue.
    @discardableResult
    mutating func removeMilestone(projectID: Project.ID, milestoneID: UUID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              projects[i].milestones.contains(where: { $0.id == milestoneID }) else { return false }
        projects[i].milestones.removeAll { $0.id == milestoneID }
        for j in projects[i].issues.indices where projects[i].issues[j].milestoneID == milestoneID {
            projects[i].issues[j].milestoneID = nil
        }
        return true
    }

    func milestone(projectID: Project.ID, named name: String) -> Milestone? {
        projects.first { $0.id == projectID }?
            .milestones.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Relations & subtasks

    /// Set (or clear, with nil) an issue's parent. Guards against cycles and
    /// self-parenting. Returns false if the issue/parent is missing or invalid.
    @discardableResult
    mutating func setIssueParent(projectID: Project.ID, number: Int, parent: Int?, now: Date = Date()) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ii = projects[pi].issues.firstIndex(where: { $0.number == number }) else { return false }
        if let parent {
            guard parent != number,
                  projects[pi].issues.contains(where: { $0.number == parent }),
                  !wouldCycle(setting: parent, for: number, in: projects[pi].issues) else { return false }
        }
        projects[pi].issues[ii].parent = parent
        projects[pi].issues[ii].updatedAt = now
        return true
    }

    /// True if making `parent` the parent of `number` would create a cycle
    /// (i.e. `number` is already an ancestor of `parent`).
    private func wouldCycle(setting parent: Int, for number: Int, in issues: [Issue]) -> Bool {
        var cur: Int? = parent
        var steps = 0
        while let c = cur, steps <= issues.count {
            if c == number { return true }
            cur = issues.first { $0.number == c }?.parent
            steps += 1
        }
        return false
    }

    /// Add a typed relation between two issues, writing the inverse on the target.
    @discardableResult
    mutating func addRelation(projectID: Project.ID, from: Int, kind: RelationKind, to: Int) -> Bool {
        guard from != to,
              let pi = projects.firstIndex(where: { $0.id == projectID }),
              projects[pi].issues.contains(where: { $0.number == from }),
              projects[pi].issues.contains(where: { $0.number == to }) else { return false }
        addLink(pi, on: from, IssueRelation(kind: kind, target: to))
        addLink(pi, on: to, IssueRelation(kind: kind.inverse, target: from))
        return true
    }

    @discardableResult
    mutating func removeRelation(projectID: Project.ID, from: Int, kind: RelationKind, to: Int) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return false }
        removeLink(pi, on: from, IssueRelation(kind: kind, target: to))
        removeLink(pi, on: to, IssueRelation(kind: kind.inverse, target: from))
        return true
    }

    private mutating func addLink(_ pi: Int, on number: Int, _ rel: IssueRelation) {
        guard let ii = projects[pi].issues.firstIndex(where: { $0.number == number }) else { return }
        if !projects[pi].issues[ii].relations.contains(rel) {
            projects[pi].issues[ii].relations.append(rel)
        }
    }

    private mutating func removeLink(_ pi: Int, on number: Int, _ rel: IssueRelation) {
        guard let ii = projects[pi].issues.firstIndex(where: { $0.number == number }) else { return }
        projects[pi].issues[ii].relations.removeAll { $0 == rel }
    }

    /// Mutate one issue (by per-project number) in place. Returns false if absent.
    @discardableResult
    mutating func updateIssue(projectID: Project.ID, number: Int, now: Date = Date(),
                              _ body: (inout Issue) -> Void) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ii = projects[pi].issues.firstIndex(where: { $0.number == number }) else { return false }
        body(&projects[pi].issues[ii])
        projects[pi].issues[ii].updatedAt = now
        return true
    }

    @discardableResult
    mutating func setIssueStatus(projectID: Project.ID, number: Int, status: IssueStatus,
                                 now: Date = Date()) -> Bool {
        updateIssue(projectID: projectID, number: number, now: now) { $0.status = status }
    }

    @discardableResult
    mutating func setIssuePriority(projectID: Project.ID, number: Int, priority: IssuePriority,
                                   now: Date = Date()) -> Bool {
        updateIssue(projectID: projectID, number: number, now: now) { $0.priority = priority }
    }

    /// Link an agent session/worktree to an issue and move it to In Progress.
    /// `host` is the SSH alias for a remote launch; local launches default to
    /// this machine's `HostIdentity` so a synced peer's reconcile sweep never
    /// mistakes the link for one of its own tmux sessions.
    @discardableResult
    mutating func linkIssueSession(projectID: Project.ID, number: Int, session: String,
                                   host: String? = nil,
                                   worktreePath: String? = nil, now: Date = Date()) -> Bool {
        updateIssue(projectID: projectID, number: number, now: now) {
            $0.status = .inProgress
            $0.activeSession = session
            $0.activeSessionHost = host ?? HostIdentity.current
            $0.worktreePath = worktreePath
        }
    }

    /// Which live-session bucket a link belongs to: "" = this machine's tmux
    /// (legacy nil links and links tagged with our own `HostIdentity`); anything
    /// else is the SSH alias a reconcile sweep must probe.
    static func linkHostBucket(_ host: String?) -> String {
        guard let host, !host.isEmpty, host != HostIdentity.current else { return "" }
        return host
    }

    /// Soft-delete an issue: move it to Trash. Returns the trash item id.
    @discardableResult
    mutating func softDeleteIssue(projectID: Project.ID, number: Int, now: Date = Date()) -> TrashedItem.ID? {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }),
              let ii = projects[pi].issues.firstIndex(where: { $0.number == number }) else { return nil }
        let issue = projects[pi].issues.remove(at: ii)
        let item = TrashedItem(deletedAt: now,
                               payload: .issue(projectID: projectID,
                                               projectName: projects[pi].name, issue: issue))
        trash.insert(item, at: 0)
        return item.id
    }

    /// Append an entry to a project's update feed. Returns the created update.
    @discardableResult
    mutating func addUpdate(projectID: Project.ID, body: String, kind: UpdateKind = .note,
                            issueNumber: Int? = nil, now: Date = Date()) -> ProjectUpdate? {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return nil }
        let update = ProjectUpdate(createdAt: now, body: body, kind: kind, issueNumber: issueNumber)
        projects[i].updates.insert(update, at: 0)   // newest first
        return update
    }

    /// When an agent's tmux session finishes, post an auto-update on any issue it
    /// was linked to and clear the link. Status is intentionally left unchanged
    /// (an agent finishing doesn't mean the issue is resolved). Returns the names
    /// of projects that got an update (for downstream notification/UI refresh).
    /// Reconcile issue↔agent links against the *live* tmux sessions of each
    /// host, keyed by `linkHostBucket` ("" = this machine). Any linked session
    /// that is absent from its host's live set = its agent ended, so post a
    /// finish update and clear the link. Robust to restarts and missed polls
    /// (unlike a previous-vs-now diff). A link whose bucket has NO entry in
    /// `live` is left alone — the caller couldn't probe that host, and an
    /// unreachable host must never clear links (fail-open, the v1.7 rule).
    /// Returns names of touched projects.
    @discardableResult
    mutating func reconcileAgentLinks(live: [String: Set<String>], now: Date = Date()) -> [String] {
        var touched: [String] = []
        for pi in projects.indices {
            for ii in projects[pi].issues.indices {
                guard let session = projects[pi].issues[ii].activeSession else { continue }
                let bucket = Self.linkHostBucket(projects[pi].issues[ii].activeSessionHost)
                guard let liveSet = live[bucket], !liveSet.contains(session) else { continue }
                let number = projects[pi].issues[ii].number
                let title = projects[pi].issues[ii].title
                projects[pi].issues[ii].activeSession = nil
                projects[pi].issues[ii].activeSessionHost = nil
                projects[pi].issues[ii].updatedAt = now
                projects[pi].updates.insert(
                    ProjectUpdate(createdAt: now, body: "Agent finished on #\(number) \(title).",
                                  kind: .agent, issueNumber: number), at: 0)
                touched.append(projects[pi].name)
            }
        }
        return touched
    }

    @discardableResult
    mutating func postAgentFinished(session: String, now: Date = Date()) -> [String] {
        var touched: [String] = []
        for pi in projects.indices {
            for ii in projects[pi].issues.indices where projects[pi].issues[ii].activeSession == session {
                let number = projects[pi].issues[ii].number
                let title = projects[pi].issues[ii].title
                projects[pi].issues[ii].activeSession = nil
                projects[pi].issues[ii].activeSessionHost = nil
                projects[pi].issues[ii].updatedAt = now
                let update = ProjectUpdate(createdAt: now,
                                           body: "Agent finished on #\(number) \(title).",
                                           kind: .agent, issueNumber: number)
                projects[pi].updates.insert(update, at: 0)
                touched.append(projects[pi].name)
            }
        }
        return touched
    }

    // MARK: Per-host local paths (multi-machine sync)

    /// On load: set each project's `localPath` to the value for `host`, so all the
    /// code that reads `localPath` transparently gets this machine's checkout.
    /// Legacy single-machine data (empty map) is adopted into the host's slot.
    mutating func resolveHostPaths(host: String) {
        for i in projects.indices {
            if projects[i].localPaths.isEmpty,
               let lp = projects[i].localPath, !lp.isEmpty {
                projects[i].localPaths[host] = lp   // adopt legacy path under this host
            }
            projects[i].localPath = projects[i].resolvedLocalPath(forHost: host)
        }
    }

    /// Before save: capture this machine's current `localPath` back into the
    /// per-host map (or clear its slot if the path was removed), so the synced
    /// file carries every host's own path without clobbering the others.
    mutating func captureHostPaths(host: String) {
        for i in projects.indices {
            if let lp = projects[i].localPath, !lp.isEmpty {
                projects[i].localPaths[host] = lp
            } else {
                projects[i].localPaths.removeValue(forKey: host)
            }
        }
    }

    /// Ensure every tag used by a project exists as a group, then sort groups —
    /// mirrors `ProjectStore.backfillGroups()`.
    mutating func ensureGroupsForTags() {
        for tag in projects.flatMap({ $0.tags }) where !groups.contains(tag) {
            groups.append(tag)
        }
        groups.sort { $0.lowercased() < $1.lowercased() }
    }
}

/// Owns projects + groups, persists to Application Support, and exposes the
/// currently-selected group (watchlist-style).
@MainActor
@Observable
final class ProjectStore {
    var projects: [Project] = []
    var groups: [String] = []
    /// Soft-deleted items awaiting restore or auto-purge (the Trash).
    var trash: [TrashedItem] = []
    /// The most recent reversible delete, surfaced as an "Undo" toast. Cleared
    /// when undone, when the item is restored/purged another way, or when the
    /// toast times out.
    var lastUndo: UndoToken?
    var selection: GroupSelection = .all
    var addRequested = false
    var importRequested = false
    var paletteRequested = false
    var trashRequested = false
    var lastError: String?
    var terminal: TerminalApp = .ghostty {
        didSet { PharosPrefs.shared.set(terminal.rawValue, forKey: "pharos.terminal") }
    }
    var editor: EditorApp = .vscode {
        didSet { PharosPrefs.shared.set(editor.rawValue, forKey: "pharos.editor") }
    }
    var appearance: AppearanceMode = .system {
        didSet { PharosPrefs.shared.set(appearance.rawValue, forKey: "pharos.appearance") }
    }
    var defaultYolo = true {
        didSet { PharosPrefs.shared.set(defaultYolo, forKey: "pharos.defaultYolo") }
    }
    var defaultTmux = false {
        didSet { PharosPrefs.shared.set(defaultTmux, forKey: "pharos.defaultTmux") }
    }
    var notifyOnFinish = true {
        didSet { PharosPrefs.shared.set(notifyOnFinish, forKey: "pharos.notifyOnFinish") }
    }
    var scanRoots: [String] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(scanRoots) {
                PharosPrefs.shared.set(String(decoding: data, as: UTF8.self), forKey: "pharos.scanRoots")
            }
        }
    }
    var claudeArgs = "" {
        didSet { PharosPrefs.shared.set(claudeArgs, forKey: "pharos.claudeArgs") }
    }
    var codexArgs = "" {
        didSet { PharosPrefs.shared.set(codexArgs, forKey: "pharos.codexArgs") }
    }
    /// SSH host alias or `user@host` for the peer machine. Empty = disabled.
    /// The paired peer Mac (SSH host / Tailscale IP) — used to reach its mesh
    /// broker for cross-host chat rooms (see MeshRemote).
    var peerHost = "" {
        didSet { PharosPrefs.shared.set(peerHost, forKey: "pharos.peerHost") }
    }
    /// Which Mac hosts the chat mesh — the synced store is the single source of
    /// truth, so both machines always read the same answer (Pharos#5 P2).
    /// Mutate via `setMeshHub(_:)`; refreshed by `load()` when iCloud syncs.
    private(set) var meshHubHostID: String?
    /// Whether THIS Mac is the mesh hub (drives the broker's TCP bind — see
    /// MeshHosting). Derived, never stored per-machine.
    var isMeshHub: Bool { meshHubHostID == HostIdentity.current }

    /// Claim or release the hub role for THIS Mac. Claiming overwrites whichever
    /// machine held it — there is exactly one hub per pairing; a deposed hub
    /// demotes itself on its next launch (PharosApp `.task`).
    func setMeshHub(_ on: Bool) {
        meshHubHostID = on ? HostIdentity.current : nil
        save()
    }


    /// The registry file. Resolved from the shared `DataLocation` (honoring the
    /// `pharos.dataDir` pref + `PHAROS_REGISTRY`) so the GUI and CLI always agree,
    /// and so switching to iCloud Drive re-points it live.
    private var fileURL: URL { PharosCore.registryURL }
    private var pollTask: Task<Void, Never>?
    /// Last modification date of projects.json we've observed/written, used by the
    /// external-edit watcher to avoid reloading our own saves in a loop.
    private var lastFileMtime: Date?
    private var fileWatchTask: Task<Void, Never>?

    init() {
        try? FileManager.default.createDirectory(
            at: PharosCore.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let d = PharosPrefs.shared
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
        // Migrate the pre-P2 per-machine hub flag into the synced store (one
        // shot): a Mac that had "Host mesh" ON claims the hub slot unless the
        // synced store already names one.
        if d.bool(forKey: "pharos.hostMesh") {
            d.removeObject(forKey: "pharos.hostMesh")
            if meshHubHostID == nil { setMeshHub(true) }
        }
        lastFileMtime = fileModificationDate()
        refreshRunningAgents()
        requestNotificationAuthorizationIfNeeded()
        startPolling()
        startFileWatch()
    }

    // MARK: External-edit watcher (live registry sync)

    /// The `pharos` CLI writes to the same `projects.json` from a separate
    /// process. Poll its modification date every ~2s and reload when it changes
    /// underneath us, so CLI-driven edits show up in the running GUI without a
    /// relaunch.
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
    /// last loaded/wrote — not only when it's strictly greater. An external (CLI)
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
        // nil = tmux unknown → skip this tick rather than falsely clearing links.
        let probed = await Task.detached(priority: .utility) { LaunchService.runningSessions() }.value
        guard let live = probed else { return }

        if notifyOnFinish {
            for sessionName in runningSessions.subtracting(live) {
                postFinishedNotification(sessionName: sessionName)
            }
        }
        // Reconcile issue↔agent links against each host's live set (restart-safe).
        if projects.contains(where: { $0.issues.contains { $0.activeSession != nil } }) {
            let map = await liveSessionMap(localLive: live)
            mutateStore { _ = $0.reconcileAgentLinks(live: map) }
        }

        // TODO: needs-input detection

        runningSessions = live
        updateDockBadge()
        await sweepMeshUnread()
    }

    /// Poke sweeper: an agent sitting stopped/idle WITH unread pending missed
    /// its turn-boundary delivery (it ignored the Stop-hook notice, or the
    /// message landed just as its turn ended) — the send-time poke in the
    /// chat view can't catch those. Poke it now; if it has no tmux pane, raise
    /// a macOS notification so the human nudges it. Each Mac sweeps only ITS
    /// OWN agents (host match), so paired Macs never double-poke; per-nick
    /// debounce stops a stuck agent from being hammered every poll tick.
    private var meshSweepDebounce: [String: Date] = [:]
    /// Limit ground-truth pane probes for Codex stale-busy correction. The
    /// normal store poll is frequent; SSH/tmux probes need only run every 10s.
    private var meshStateProbeDebounce: [String: Date] = [:]

    @MainActor
    private func sweepMeshUnread() async {
        let peer = peerHost
        let members = await Task.detached(priority: .utility) {
            MeshClient.sendIfUp(MeshRequest(cmd: "who"))?.members
        }.value
        guard let members else { return }
        let now = Date()
        for m in members {
            if m.kind == AgentKind.codex.rawValue,
               MeshSessionState(rawValue: m.state ?? "") == .busy,
               now.timeIntervalSince(meshStateProbeDebounce[m.nick] ?? .distantPast) > 10 {
                meshStateProbeDebounce[m.nick] = now
                Task.detached(priority: .utility) {
                    guard MeshPoke.codexBusyPaneIsIdle(m, peerHost: peer) else { return }
                    MeshClient.sendIfUp(MeshRequest(cmd: "mark", nick: m.nick,
                                                    state: MeshSessionState.stopped.rawValue,
                                                    expectedState: MeshSessionState.busy.rawValue,
                                                    expectedStateTs: m.stateTs))
                }
            }
            // stopped/idle poke on the hooks' word; UNKNOWN state is allowed
            // through because MeshPoke.nudge probes the pane first (post-broker-
            // restart limbo would otherwise deadlock: unknown ⇒ never poked ⇒
            // never reports ⇒ stays unknown). Codex busy is also allowed through
            // because its Stop hook can stay stale; nudge probes for an idle `›`
            // and rejects a genuinely Working pane. Claude busy/blocked/gone refuse.
            let st = MeshSessionState(rawValue: m.state ?? "")
            guard m.host == HostIdentity.current,
                  (m.unread ?? 0) > 0,
                  st?.pokeable == true || (st == nil && m.state == nil)
                    || (st == .busy && m.kind == AgentKind.codex.rawValue),
                  now.timeIntervalSince(meshSweepDebounce[m.nick] ?? .distantPast) > 120 else { continue }
            meshSweepDebounce[m.nick] = now
            if m.tmuxPane != nil {
                Task.detached(priority: .utility) { _ = MeshPoke.nudge(m, peerHost: peer) }
            } else {
                postMeshNudgeNotification(m)
            }
        }
    }

    private func postMeshNudgeNotification(_ m: MeshMemberInfo) {
        let content = UNMutableNotificationContent()
        content.title = "@\(m.nick) has unread mesh messages"
        let proj = m.project.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "its session"
        content.body = "It's idle but not in tmux, so Pharos can't poke it — "
                     + "nudge it yourself in \(proj) (it should run: pharos mesh recv \(m.nick))"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "pharos-mesh-nudge-\(m.nick)-\(Date().timeIntervalSince1970)",
            content: content, trigger: nil))
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
        var store = StoreData()
        if let decoded = try? decoder.decode(StoreData.self, from: data) {
            store = decoded
        } else if let legacy = try? decoder.decode([Project].self, from: data) {
            store = StoreData(projects: legacy, groups: [])   // migrate older flat-array format
        }
        // Resolve each project's localPath to THIS machine's checkout (per-host map).
        store.resolveHostPaths(host: HostIdentity.current)
        projects = store.projects
        groups = store.groups
        trash = store.trash
        meshHubHostID = store.meshHubHostID
        // Drop expired trash from the in-memory view; persistence catches up on
        // the next save (we don't write here to avoid churning the file watcher).
        trash.removeAll { Date().timeIntervalSince($0.deletedAt) > StoreData.trashRetention }
        backfillGroups()
        sweepAttachments()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var store = StoreData(projects: projects, groups: groups, trash: trash,
                              meshHubHostID: meshHubHostID)
        store.captureHostPaths(host: HostIdentity.current)   // record this host's paths
        if let data = try? encoder.encode(store) {
            try? data.write(to: fileURL, options: .atomic)
            // Stamp the file with an mtime WE choose and record that exact value,
            // rather than re-stat'ing (which could capture a concurrent CLI
            // write's mtime and then be mistaken for our own save). Any later CLI
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
    /// Forget a project (reversible). Its repo on disk is untouched — only
    /// Pharos's metadata moves to Trash, recoverable via Undo or the Trash view.
    func remove(_ project: Project) {
        var token: TrashedItem.ID?
        mutateStore { s in
            token = s.softDeleteProject(id: project.id)
            s.purgeExpiredTrash()
        }
        if let token { setUndo("Removed “\(project.name)”", itemID: token) }
        AuditLog.record(actor: .ui, action: "remove_project", detail: project.name)
    }

    func project(_ id: Project.ID) -> Project? { projects.first { $0.id == id } }

    /// Rename a project (GUI). Rejects a clash with a different project.
    func rename(_ projectID: Project.ID, to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        if projects.contains(where: { $0.id != projectID && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            reportError("A project named '\(n)' already exists.")
            return
        }
        mutateStore { s in
            if let i = s.projects.firstIndex(where: { $0.id == projectID }) { s.projects[i].name = n }
        }
    }

    /// Set (or clear) THIS machine's local checkout path for a project. Persists
    /// into the per-host map so it never clobbers another machine's path.
    func setLocalPath(_ projectID: Project.ID, path: String?) {
        mutateStore { s in
            guard let i = s.projects.firstIndex(where: { $0.id == projectID }) else { return }
            let trimmed = path?.trimmingCharacters(in: .whitespaces)
            s.projects[i].localPath = (trimmed?.isEmpty == false) ? trimmed : nil
        }
    }

    // MARK: Data location (local ↔ iCloud Drive)

    // Stored (not computed) so @Observable tracks them: the values derive from
    // `DataLocation` (UserDefaults-backed statics) which Observation can't see,
    // so relocateData refreshes these to drive the Settings radio's update.
    private(set) var dataLocationIsICloud: Bool = DataLocation.usingICloud
    private(set) var dataDirectoryPath: String = DataLocation.current.path
    var iCloudAvailable: Bool { DataLocation.iCloudAvailable }

    /// Move Pharos's data between Application Support and iCloud Drive. Seeds the
    /// target with the current registry only if it has none yet (so a second Mac
    /// *adopts* the already-synced data instead of overwriting it), then repoints
    /// and reloads. The source is left as a backup.
    func relocateData(toICloud: Bool) {
        guard let target = toICloud ? DataLocation.iCloudDirectory : DataLocation.appSupportDirectory else {
            reportError("iCloud Drive isn't enabled on this Mac (turn it on in System Settings).")
            return
        }
        let source = DataLocation.current
        guard target.standardizedFileURL != source.standardizedFileURL else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let sourceRegistry = source.appendingPathComponent("projects.json")
        let targetRegistry = target.appendingPathComponent("projects.json")
        if !fm.fileExists(atPath: targetRegistry.path), fm.fileExists(atPath: sourceRegistry.path) {
            try? fm.copyItem(at: sourceRegistry, to: targetRegistry)
        }
        DataLocation.setDirectory(toICloud ? target : nil)
        // Mirror the new location into the observed properties so the Settings
        // radio reflects the switch (the statics above aren't Observation-tracked).
        dataLocationIsICloud = DataLocation.usingICloud
        dataDirectoryPath = DataLocation.current.path
        // Re-point and reload from the new location.
        lastFileMtime = nil
        load()
        lastFileMtime = fileModificationDate()
        refreshAllGit()
    }
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

    /// Delete a group (reversible). Membership is captured so a restore re-tags
    /// exactly the projects that were in it.
    func removeGroup(_ name: String) {
        var token: TrashedItem.ID?
        mutateStore { s in
            token = s.softDeleteGroup(name)
            s.purgeExpiredTrash()
        }
        if selection == .group(name) { selection = .all }
        if let token {
            setUndo("Deleted group “\(name)”", itemID: token)
            AuditLog.record(actor: .ui, action: "delete_group", detail: name)
        }
    }

    /// Delete a project's playbook (reversible).
    func removePlaybook(projectID: Project.ID, playbook: Playbook) {
        var token: TrashedItem.ID?
        mutateStore { s in
            token = s.softDeletePlaybook(projectID: projectID, playbookID: playbook.id)
            s.purgeExpiredTrash()
        }
        if let token { setUndo("Deleted playbook “\(playbook.name)”", itemID: token) }
    }

    // MARK: Issues & project log

    func addIssue(_ projectID: Project.ID, id: UUID = UUID(), title: String,
                  body: String = "", priority: IssuePriority = .none,
                  attachments: [IssueAttachment] = [], labels: [String] = []) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        mutateStore {
            _ = $0.addIssue(projectID: projectID, title: t, priority: priority,
                            body: body, id: id, attachments: attachments, labels: labels)
        }
    }

    func addIssueLabel(_ projectID: Project.ID, number: Int, label: String) {
        let l = label.trimmingCharacters(in: .whitespaces)
        guard !l.isEmpty else { return }
        mutateStore {
            _ = $0.updateIssue(projectID: projectID, number: number) { issue in
                if !issue.labels.contains(where: { $0.caseInsensitiveCompare(l) == .orderedSame }) {
                    issue.labels.append(l)
                }
            }
        }
    }

    func removeIssueLabel(_ projectID: Project.ID, number: Int, label: String) {
        mutateStore {
            _ = $0.updateIssue(projectID: projectID, number: number) { issue in
                issue.labels.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame }
            }
        }
    }

    func setIssueMilestone(_ projectID: Project.ID, number: Int, milestoneID: UUID?) {
        mutateStore { _ = $0.updateIssue(projectID: projectID, number: number) { $0.milestoneID = milestoneID } }
    }

    @discardableResult
    func createMilestone(_ projectID: Project.ID, name: String, due: Date? = nil) -> Milestone? {
        var created: Milestone?
        mutateStore { created = $0.addMilestone(projectID: projectID, name: name, due: due) }
        return created
    }

    func removeMilestone(_ projectID: Project.ID, milestoneID: UUID) {
        mutateStore { _ = $0.removeMilestone(projectID: projectID, milestoneID: milestoneID) }
    }

    func setIssueParent(_ projectID: Project.ID, number: Int, parent: Int?) {
        mutateStore { _ = $0.setIssueParent(projectID: projectID, number: number, parent: parent) }
    }

    func addRelation(_ projectID: Project.ID, from: Int, kind: RelationKind, to: Int) {
        mutateStore { _ = $0.addRelation(projectID: projectID, from: from, kind: kind, to: to) }
    }

    func removeRelation(_ projectID: Project.ID, from: Int, kind: RelationKind, to: Int) {
        mutateStore { _ = $0.removeRelation(projectID: projectID, from: from, kind: kind, to: to) }
    }

    func setIssueStatus(_ projectID: Project.ID, number: Int, status: IssueStatus) {
        mutateStore { _ = $0.setIssueStatus(projectID: projectID, number: number, status: status) }
    }

    /// Kanban drag: move an issue to a status column, optionally before another
    /// card (reorder within / across columns), persisting the manual order.
    func moveIssue(_ projectID: Project.ID, number: Int, toStatus: IssueStatus, before: Int?) {
        mutateStore { _ = $0.moveIssue(projectID: projectID, number: number, toStatus: toStatus, before: before) }
    }

    /// Edit an issue's title and body (from the detail sheet).
    func setIssueContent(_ projectID: Project.ID, number: Int, title: String, body: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        mutateStore {
            _ = $0.updateIssue(projectID: projectID, number: number) { $0.title = t; $0.body = body }
        }
    }

    func setIssuePriority(_ projectID: Project.ID, number: Int, priority: IssuePriority) {
        mutateStore { _ = $0.setIssuePriority(projectID: projectID, number: number, priority: priority) }
    }

    func removeIssue(_ projectID: Project.ID, number: Int, title: String) {
        var token: TrashedItem.ID?
        mutateStore {
            token = $0.softDeleteIssue(projectID: projectID, number: number)
            $0.purgeExpiredTrash()
        }
        if let token { setUndo("Removed #\(number) “\(title)”", itemID: token) }
    }

    /// Attach files to an existing issue (GUI). Copies bytes into the issue's dir.
    func addAttachments(_ projectID: Project.ID, number: Int, urls: [URL]) {
        guard let issue = project(projectID)?.issues.first(where: { $0.number == number }) else { return }
        let issueID = issue.id
        var added: [IssueAttachment] = []
        for url in urls {
            if let a = try? AttachmentStore.add(fileAt: url, toIssue: issueID) { added.append(a) }
            else { reportError("Couldn't attach \(url.lastPathComponent).") }
        }
        guard !added.isEmpty else { return }
        mutateStore {
            _ = $0.updateIssue(projectID: projectID, number: number) { $0.attachments.append(contentsOf: added) }
        }
    }

    /// Remove one attachment from an issue and delete its file.
    func removeAttachment(_ projectID: Project.ID, number: Int, attachment: IssueAttachment) {
        if let issue = project(projectID)?.issues.first(where: { $0.number == number }) {
            try? FileManager.default.removeItem(at: AttachmentStore.fileURL(attachment, issueID: issue.id))
        }
        mutateStore {
            _ = $0.updateIssue(projectID: projectID, number: number) {
                $0.attachments.removeAll { $0.id == attachment.id }
            }
        }
    }

    func addUpdate(_ projectID: Project.ID, body: String) {
        let b = body.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return }
        mutateStore { _ = $0.addUpdate(projectID: projectID, body: b, kind: .note) }
    }

    /// Launch an agent ON an issue: link the session, move the issue to In
    /// Progress, then launch. When launched in tmux, `pollSessions` auto-posts an
    /// update to the project log once the session ends.
    func startAgentOnIssue(_ project: Project, number: Int, kind: AgentKind) {
        guard let path = project.localPath, !path.isEmpty else {
            reportError("'\(project.name)' has no local path."); return
        }
        let useTmux = project.tmux
        let tmuxName = LaunchService.tmuxSessionName(project, kind, issue: number)
        mutateStore { s in
            // Only link a trackable (tmux) session; otherwise just move to In Progress.
            if useTmux { _ = s.linkIssueSession(projectID: project.id, number: number, session: tmuxName) }
            else { _ = s.setIssueStatus(projectID: project.id, number: number, status: .inProgress) }
        }
        let extra = kind == .claude ? claudeArgs : codexArgs
        LaunchService.launchAgent(kind, atPath: path, yolo: project.yolo, tmux: useTmux,
                                  tmuxName: tmuxName, terminal: terminal, extraArgs: extra, source: .ui)
        refreshRunningAgents()
    }

    // MARK: Trash / undo

    /// Snapshot the registry into a `StoreData`, apply `body`, write the result
    /// back to the published arrays, and persist. All delete/restore paths funnel
    /// through here so the GUI and the CLI share one mutation implementation.
    private func mutateStore(_ body: (inout StoreData) -> Void) {
        var s = StoreData(projects: projects, groups: groups, trash: trash,
                          meshHubHostID: meshHubHostID)
        body(&s)
        projects = s.projects
        groups = s.groups
        trash = s.trash
        meshHubHostID = s.meshHubHostID
        save()
    }

    private func setUndo(_ message: String, itemID: TrashedItem.ID) {
        lastUndo = UndoToken(message: message, itemID: itemID)
    }

    /// Restore the most recently deleted item (the active Undo toast).
    func undoLastDelete() {
        guard let token = lastUndo else { return }
        restoreTrash(token.itemID)
    }

    /// Restore a specific trashed item back into the live registry.
    func restoreTrash(_ id: TrashedItem.ID) {
        mutateStore { $0.restoreTrash(id) }
        if lastUndo?.itemID == id { lastUndo = nil }
    }

    /// Permanently drop one trashed item.
    func purgeTrash(_ id: TrashedItem.ID) {
        mutateStore { s in s.trash.removeAll { $0.id == id } }
        if lastUndo?.itemID == id { lastUndo = nil }
        sweepAttachments()
    }

    /// Permanently drop everything in the Trash.
    func emptyTrash() {
        mutateStore { $0.trash.removeAll() }
        lastUndo = nil
        sweepAttachments()
    }

    /// Delete attachment directories for issues that no longer exist anywhere
    /// (neither live nor in the Trash) — orphan cleanup after a purge.
    func sweepAttachments() {
        var keep = Set<UUID>()
        for p in projects { for issue in p.issues { keep.insert(issue.id) } }
        for item in trash { if case .issue(_, _, let issue) = item.payload { keep.insert(issue.id) } }
        AttachmentStore.sweepOrphans(keepingIssueIDs: keep)
    }

    func requestTrash() { trashRequested = true }
    func dismissUndo() { lastUndo = nil }

    /// A request (from ⌘K) to open a specific issue. The owning project's detail
    /// view observes this and opens the issue. The nonce makes repeated requests
    /// to the same issue distinct so `onChange` fires every time.
    struct IssueRequest: Equatable {
        let projectID: Project.ID
        let number: Int
        let nonce: UUID
    }
    var requestedIssue: IssueRequest?

    func requestIssue(_ projectID: Project.ID, number: Int) {
        requestedIssue = IssueRequest(projectID: projectID, number: number, nonce: UUID())
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

    /// Kill a running agent's tmux session — local (host nil/this Mac) or on a
    /// paired Mac (`host`). Off-main (may SSH). Optimistically drops the session
    /// from `runningSessions` for instant UI feedback, then the reconcile sweep
    /// clears any linked issue and logs "Agent finished".
    func stopAgent(session: String, host: String? = nil) {
        runningSessions.remove(session)          // optimistic
        remoteRunningSessions.remove(session)
        updateDockBadge()
        let h = (host == nil || host == HostIdentity.current) ? nil : host
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
                do { return .success(try RemoteLaunch.kill(session: session, host: h)) }
                catch { return .failure(error) }
            }.value
            if case .failure(let e) = result { lastError = "Couldn't stop \(session): \(e)" }
            refreshRunningAgents()               // authoritative re-probe + reconcile
        }
    }

    /// Queries tmux for live sessions and updates `runningSessions`.
    func refreshRunningAgents() {
        Task {
            let probed = await Task.detached(priority: .utility) { LaunchService.runningSessions() }.value
            guard let live = probed else { return }   // tmux unknown → keep what we have
            runningSessions = live
            updateDockBadge()
            // Self-heal stale links on launch / manual refresh / after a launch.
            if projects.contains(where: { $0.issues.contains { $0.activeSession != nil } }) {
                let map = await liveSessionMap(localLive: live)
                mutateStore { _ = $0.reconcileAgentLinks(live: map) }
            }
        }
    }

    /// Recent remote live-set probes, so the 10s poll doesn't SSH every tick.
    private var remoteLiveCache: [String: (stamp: Date, live: Set<String>?)] = [:]

    /// Live sessions on the remote hosts that issue links point at (refreshed
    /// by the same probes that feed reconcile). Lets the GUI badge a
    /// remotely-launched issue as running even though local tmux knows nothing.
    private(set) var remoteRunningSessions: Set<String> = []

    /// Live sessions across every probed host — what issue "running" badges use.
    var allRunningSessions: Set<String> { runningSessions.union(remoteRunningSessions) }

    /// Assemble the per-host live-session map for `reconcileAgentLinks`: the
    /// local tmux set under "" plus one probe per remote host that any link
    /// points at (30s cache). A host that can't be probed is simply ABSENT from
    /// the map — reconcile then skips its links (fail-open, the v1.7 rule).
    private func liveSessionMap(localLive: Set<String>?) async -> [String: Set<String>] {
        var map: [String: Set<String>] = [:]
        if let localLive { map[""] = localLive }
        let hosts = Set(projects.flatMap { p in
            p.issues.compactMap { i in
                i.activeSession != nil ? StoreData.linkHostBucket(i.activeSessionHost) : nil
            }
        }).subtracting([""])
        for host in hosts {
            if let cached = remoteLiveCache[host], Date().timeIntervalSince(cached.stamp) < 30 {
                if let liveSet = cached.live { map[host] = liveSet }
                continue
            }
            let probed = await Task.detached(priority: .utility) { RemoteLaunch.runningSessions(host: host) }.value
            remoteLiveCache[host] = (Date(), probed)
            if let probed { map[host] = probed }
        }
        remoteRunningSessions = map.filter { $0.key != "" }.values.reduce(into: []) { $0.formUnion($1) }
        return map
    }

    /// Mirror the running-agent count onto the Dock icon badge (glanceable status).
    private func updateDockBadge() {
        let n = runningSessions.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// Returns true if a Pharos tmux session for this project + agent kind is live.
    func isRunning(_ project: Project, _ kind: AgentKind) -> Bool {
        runningSessions.contains(LaunchService.tmuxSessionName(project, kind))
    }

    /// Returns true if ANY Pharos agent session is live for this project.
    func hasRunningAgent(_ project: Project) -> Bool {
        // Prefix match so per-issue sessions (pharos-<slug>-claude-i3) count too.
        let prefix = LaunchService.tmuxSessionPrefix(project)
        return runningSessions.contains { $0.hasPrefix(prefix) }
    }
}
