import Foundation
import Observation
import PharosMeshReplica

@Observable
@MainActor
final class RoomStore {
    private let settings: AppSettings
    private let distributedMesh: DistributedMeshSupport
    private let mesh = MeshTCPClient()
    let isDemo: Bool
    private let demoProjects: [RemoteProject]
    private let demoIssues: [RemoteIssue]

    private(set) var rooms: [MeshRoom] = []
    var selectedRoom: String?
    /// Whether a poll may auto-open the first room when nothing is selected.
    /// MainTabView sets this from the horizontal size class: a two-column iPad
    /// layout wants a default detail selection, but a compact iPhone must be
    /// able to sit on the room list (and reach Settings) without every refresh
    /// force-pushing the conversation back on top. Defaults to the compact-safe
    /// value so the app-wide poll can't auto-dive before a view sets it.
    var autoSelectsFirstRoom = false
    private(set) var messages: [MeshMessage] = []
    private(set) var members: [String: MeshMember] = [:]
    private(set) var isRefreshing = false
    private(set) var notice: String?
    private(set) var error: String?
    /// True while older pages likely remain above the loaded window.
    private(set) var hasMoreHistory = false
    private(set) var isLoadingOlder = false
    private var capabilities: Set<String>?
    /// Messages fetched per page. The window starts as the latest page and
    /// grows upward only when the user pulls for older history.
    private static let historyPageSize = 50
    /// Window cap for brokers without history paging (previous behavior).
    private static let legacyHistoryLimit = 200
    private static let projectsCacheKey = "pharos.mobile.registry.projects.v1"
    private static let issuesCacheKey = "pharos.mobile.registry.issues.v1"

    init(settings: AppSettings, identities: SSHIdentityStore,
         distributedMesh: DistributedMeshSupport,
         demoData: PharosDemoData? = nil) {
        self.settings = settings
        self.distributedMesh = distributedMesh
        isDemo = demoData != nil
        demoProjects = demoData?.projects ?? []
        demoIssues = demoData?.issues ?? []
        if let demoData {
            rooms = demoData.rooms
            selectedRoom = demoData.selectedRoom
            messages = demoData.messages
            members = demoData.members
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        guard !usesDistributedRegistry else {
            guard !isRefreshing else { return }
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                let nextRooms = try await distributedMesh.rooms()
                rooms = nextRooms
                var allMemberships: [MeshMember] = []
                for room in nextRooms {
                    let roomMembers = try await distributedMesh.members(in: room)
                    allMemberships.append(contentsOf: roomMembers.map {
                        distributedMember($0, room: room.name)
                    })
                }
                members = RosterIndex.byNick(allMemberships)
                if let selectedRoom,
                   !nextRooms.contains(where: { $0.name == selectedRoom }) {
                    self.selectedRoom = nil
                }
                if selectedRoom == nil, autoSelectsFirstRoom {
                    selectedRoom = nextRooms.first?.name
                }
                if let selectedRoom {
                    try await loadLatestPage(for: selectedRoom)
                } else {
                    messages = []
                    hasMoreHistory = false
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        guard !settings.mesh.host.isEmpty, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let list = request(MeshRequest(cmd: "list"))
            async let roster = request(MeshRequest(cmd: "who"))
            let (listResponse, rosterResponse) = try await (list, roster)
            let nextRooms = listResponse.rooms ?? []
            let nextMembers = RosterIndex.byNick(rosterResponse.members ?? [])
            if rooms != nextRooms { rooms = nextRooms }
            if members != nextMembers { members = nextMembers }
            // Drop a selection whose room disappeared, but never force-select a
            // room the user didn't pick on compact layouts — that is what kept
            // bouncing iPhone back into the conversation and away from Settings.
            if let selectedRoom, !rooms.contains(where: { $0.name == selectedRoom }) {
                self.selectedRoom = nil
            }
            if selectedRoom == nil, autoSelectsFirstRoom {
                selectedRoom = rooms.first?.name
            }
            if let selectedRoom {
                try await loadLatestPage(for: selectedRoom)
            } else {
                if !messages.isEmpty { messages = [] }
                hasMoreHistory = false
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Foreground Broker event loop. The server holds each request until a
    /// change occurs, then the durable room/roster/history snapshot is reloaded.
    /// A timeout refresh is the reconnect safety net.
    func watchEvents() async {
        guard !isDemo, !usesDistributedRegistry else { return }
        var cursor: UInt64?
        while !Task.isCancelled {
            do {
                var eventRequest = MeshRequest(cmd: "events")
                eventRequest.cursor = cursor
                eventRequest.timeoutMs = 25_000
                let response = try await request(eventRequest)
                if let next = response.cursor { cursor = next }
                await refresh()
            } catch is CancellationError {
                return
            } catch {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func select(room: String) async {
        if selectedRoom != room {
            messages = []
            hasMoreHistory = false
        }
        selectedRoom = room
        if isDemo { return }
        do {
            try await loadLatestPage(for: room)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// Fetch the newest page and graft it onto the loaded window. Older pages
    /// the user already pulled in stay; only the overlapping tail is replaced.
    /// If the window doesn't reach the new page (a gap after backgrounding),
    /// the window resets to the latest page — the user can pull up to re-page.
    private func loadLatestPage(for room: String) async throws {
        if usesDistributedRegistry {
            guard let target = roomInfo(named: room) else {
                throw DistributedRoomStoreError.roomNotFound
            }
            let tail = try await distributedMesh.messages(
                in: target, limit: Self.historyPageSize
            )
            guard selectedRoom == room else { return }
            messages = tail
            hasMoreHistory = tail.count == Self.historyPageSize
            return
        }
        let paged = await supportsHistoryPaging()
        let limit = paged ? Self.historyPageSize : Self.legacyHistoryLimit
        let tail = try await request(MeshRequest(cmd: "history", room: room, limit: limit)).messages ?? []
        guard selectedRoom == room else { return }
        guard let anchor = tail.first else {
            if !messages.isEmpty { messages = [] }
            hasMoreHistory = false
            return
        }
        let next: [MeshMessage]
        if let overlap = messages.firstIndex(where: { $0.id == anchor.id }) {
            next = Array(messages[..<overlap]) + tail
        } else {
            next = tail
            hasMoreHistory = paged && tail.count == limit
        }
        if messages != next { messages = next }
        if !paged { hasMoreHistory = false }
    }

    /// Pull one page of history older than the current window (scroll-up).
    func loadOlderMessages() async {
        guard !isLoadingOlder, hasMoreHistory,
              let room = selectedRoom, let anchor = messages.first?.id else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            if usesDistributedRegistry {
                guard let target = roomInfo(named: room) else {
                    throw DistributedRoomStoreError.roomNotFound
                }
                let requestedLimit = messages.count + Self.historyPageSize
                let expanded = try await distributedMesh.messages(
                    in: target, limit: requestedLimit
                )
                guard selectedRoom == room, messages.first?.id == anchor else { return }
                messages = expanded
                hasMoreHistory = expanded.count == requestedLimit
                error = nil
                return
            }
            var page = MeshRequest(cmd: "history", room: room, limit: Self.historyPageSize)
            page.beforeID = anchor
            let older = try await request(page).messages ?? []
            guard selectedRoom == room, messages.first?.id == anchor else { return }
            hasMoreHistory = older.count == Self.historyPageSize
            if !older.isEmpty { messages = older + messages }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func createRoom(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            if usesDistributedRegistry {
                let created = try await distributedMesh.createRoom(named: trimmed)
                selectedRoom = created.name
                _ = await distributedMesh.synchronizeOnce()
                await refresh()
                return
            }
            _ = try await request(MeshRequest(cmd: "create", room: trimmed))
            selectedRoom = trimmed
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func send(_ text: String, replyTo: MeshMessage? = nil,
              attachments: [MeshAttachment] = []) async -> Bool {
        guard let room = selectedRoom else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        if replyTo != nil || !attachments.isEmpty {
            guard await supportsAdvancedMessages() else {
                error = "Update the Mesh broker before sending replies or attachments."
                return false
            }
        }
        let targets = MentionParser.targets(in: trimmed)
        do {
            if usesDistributedRegistry {
                guard let target = roomInfo(named: room) else {
                    throw DistributedRoomStoreError.roomNotFound
                }
                _ = try await distributedMesh.send(
                    trimmed, in: target, to: targets,
                    replyTo: replyTo.map {
                        MeshReply(
                            messageID: $0.stableID, from: $0.from,
                            preview: String($0.text.prefix(160)), ts: $0.ts
                        )
                    }, attachments: attachments
                )
                _ = await distributedMesh.synchronizeOnce()
                try await loadLatestPage(for: room)
                error = nil
                return true
            }
            var outgoing = MeshRequest(cmd: "say", room: room, nick: "human", text: trimmed,
                                       to: targets.isEmpty ? nil : targets)
            outgoing.replyToID = replyTo?.id
            outgoing.attachments = attachments.isEmpty ? nil : attachments
            let response = try await request(outgoing)
            try await loadLatestPage(for: room)
            error = nil
            notice = response.note
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func insertMention(_ nick: String, into draft: inout String) {
        let separator = draft.isEmpty || draft.last?.isWhitespace == true ? "" : " "
        draft += "\(separator)@\(nick) "
    }

    func dismissNotice() { notice = nil }

    func uploadAttachment(data: Data, name: String, mimeType: String) async -> MeshAttachment? {
        if usesDistributedRegistry {
            do {
                let attachment = try await distributedMesh.uploadAttachment(
                    data: data, name: name, mediaType: mimeType
                )
                _ = await distributedMesh.synchronizeOnce()
                error = nil
                return attachment
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
        guard await supportsAdvancedMessages() else {
            error = "Update the Mesh broker before uploading attachments."
            return nil
        }
        do {
            let attachment = try await mesh.uploadAttachment(data: data, name: name, mimeType: mimeType,
                                                             host: settings.mesh.host, port: settings.mesh.port)
            error = nil
            return attachment
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func downloadAttachment(_ attachment: MeshAttachment) async -> URL? {
        do {
            let metadata: MeshAttachment
            let data: Data
            if usesDistributedRegistry {
                metadata = attachment
                data = try await distributedMesh.attachmentData(attachment)
            } else {
                (metadata, data) = try await mesh.downloadAttachment(
                    id: attachment.id, host: settings.mesh.host,
                    port: settings.mesh.port
                )
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PharosMeshAttachments", isDirectory: true)
                .appendingPathComponent(metadata.id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(metadata.name)
            try data.write(to: destination, options: .atomic)
            error = nil
            return destination
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func refreshAfterRemoteAction() async { await refresh() }

    /// Fetch Broker-owned project data. When temporarily offline, return the
    /// last successful payload; SSH Hosts are never used as registry replicas.
    func fetchProjectsOverMesh() async -> [RemoteProject]? {
        if isDemo { return demoProjects }
        if usesDistributedRegistry {
            do {
                let projects = try await distributedMesh.projects()
                error = nil
                return projects
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
        guard !settings.mesh.host.isEmpty else { return cachedProjects() }
        guard let payload = try? await request(MeshRequest(cmd: "projects")).payload else {
            return cachedProjects()
        }
        UserDefaults.standard.set(payload, forKey: Self.projectsCacheKey)
        return RemoteAgentService.parseProjects(payload)
    }

    func fetchIssuesOverMesh() async -> [RemoteIssue]? {
        if isDemo { return demoIssues }
        if usesDistributedRegistry {
            do {
                let issues = try await distributedMesh.issues()
                error = nil
                return issues
            } catch {
                self.error = error.localizedDescription
                return nil
            }
        }
        guard !settings.mesh.host.isEmpty else { return cachedIssues() }
        guard let payload = try? await request(MeshRequest(cmd: "issues")).payload else {
            return cachedIssues()
        }
        UserDefaults.standard.set(payload, forKey: Self.issuesCacheKey)
        return RemoteAgentService.parseIssues(payload)
    }

    func issueAttachmentData(
        _ attachment: RemoteIssueAttachment
    ) async -> Data? {
        guard usesDistributedRegistry else {
            error = "Issue attachments require the distributed Mesh runtime."
            return nil
        }
        do {
            let data = try await distributedMesh.issueAttachmentData(attachment)
            error = nil
            return data
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Add a portable project directly to the shared replicated registry. Host
    /// paths remain host-local and are intentionally not accepted from iOS.
    func addProject(
        name: String, githubRemote: String?, notes: String, tags: [String],
        yolo: Bool = true, tmux: Bool = false,
        playbooks: [RemotePlaybook] = [], milestones: [RemoteMilestone] = []
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.addProject(
                    name: trimmedName, githubRemote: githubRemote,
                    notes: notes, tags: tags, yolo: yolo, tmux: tmux,
                    playbooks: playbooks, milestones: milestones
                )
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard !projects.contains(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame
            }) else {
                throw RegistryMutationError.message("A project named \(trimmedName) already exists.")
            }
            var project: [String: Any] = [
                "id": UUID().uuidString,
                "name": trimmedName,
                "tags": tags,
                "notes": notes.trimmingCharacters(in: .whitespacesAndNewlines),
                "yolo": yolo,
                "tmux": tmux,
                "playbooks": [],
                "issues": [],
                "updates": [],
                "milestones": []
            ]
            if let remote = githubRemote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
                project["githubRemote"] = remote
            }
            projects.append(project)
            root["projects"] = projects
        }
    }

    func addIssue(
        to projectName: String, title: String, body: String = "",
        status: String = "todo", priority: String = "none",
        labels: [String] = [], milestoneID: String? = nil,
        parent: Int? = nil, relations: [RemoteIssueRelation] = [],
        pendingAttachments: [PendingRemoteAttachment] = []
    ) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.addIssue(
                    to: projectName, title: trimmed, body: body,
                    status: status, priority: priority, labels: labels,
                    milestoneID: milestoneID, parent: parent,
                    relations: relations,
                    pendingAttachments: pendingAttachments
                )
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let index = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(projectName) == .orderedSame
            }) else {
                throw RegistryMutationError.message("Project not found. Reload and try again.")
            }
            var issues = projects[index]["issues"] as? [[String: Any]] ?? []
            let nextNumber = (issues.compactMap { $0["number"] as? Int }.max() ?? 0) + 1
            issues.append([
                "id": UUID().uuidString,
                "number": nextNumber,
                "title": trimmed,
                "status": status,
                "priority": priority,
                "body": body,
                "labels": labels,
                "attachments": [],
                "relations": [],
                "sortOrder": Double(issues.count)
            ])
            projects[index]["issues"] = issues
            root["projects"] = projects
        }
    }

    func updateIssue(
        _ issue: RemoteIssue, title: String, body: String,
        status: String, priority: String, labels: [String],
        milestoneID: String?, parent: Int?,
        relations: [RemoteIssueRelation],
        attachments: [RemoteIssueAttachment],
        pendingAttachments: [PendingRemoteAttachment]
    ) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.updateIssue(
                    issue, title: trimmedTitle, body: body,
                    status: status, priority: priority, labels: labels,
                    milestoneID: milestoneID, parent: parent,
                    relations: relations, attachments: attachments,
                    pendingAttachments: pendingAttachments
                )
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let projectIndex = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(issue.project) == .orderedSame
            }) else {
                throw RegistryMutationError.message("Project not found. Reload and try again.")
            }
            var issues = projects[projectIndex]["issues"] as? [[String: Any]] ?? []
            guard let issueIndex = issues.firstIndex(where: { $0["number"] as? Int == issue.number }) else {
                throw RegistryMutationError.message("Issue not found. Reload and try again.")
            }
            issues[issueIndex]["title"] = trimmedTitle
            issues[issueIndex]["body"] = body.trimmingCharacters(in: .whitespacesAndNewlines)
            issues[issueIndex]["status"] = status
            issues[issueIndex]["priority"] = priority
            issues[issueIndex]["labels"] = labels
            if let milestoneID { issues[issueIndex]["milestoneID"] = milestoneID }
            else { issues[issueIndex].removeValue(forKey: "milestoneID") }
            if let parent { issues[issueIndex]["parent"] = parent }
            else { issues[issueIndex].removeValue(forKey: "parent") }
            projects[projectIndex]["issues"] = issues
            root["projects"] = projects
        }
    }

    // MARK: Edit / delete existing content

    /// Edit an existing project's portable fields. Host-local paths remain
    /// device-local and are never touched here.
    func updateProject(
        _ original: RemoteProject, name: String, githubRemote: String?,
        notes: String, tags: [String], yolo: Bool, tmux: Bool,
        playbooks: [RemotePlaybook], milestones: [RemoteMilestone]
    ) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.updateProject(
                    original, name: trimmedName, githubRemote: githubRemote,
                    notes: notes, tags: tags, yolo: yolo, tmux: tmux,
                    playbooks: playbooks, milestones: milestones
                )
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let index = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(original.name) == .orderedSame
            }) else { throw RegistryMutationError.message("Project not found. Reload and try again.") }
            if trimmedName.localizedCaseInsensitiveCompare(original.name) != .orderedSame,
               projects.contains(where: { ($0["name"] as? String)?.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame }) {
                throw RegistryMutationError.message("A project named \(trimmedName) already exists.")
            }
            projects[index]["name"] = trimmedName
            projects[index]["notes"] = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            projects[index]["tags"] = tags
            projects[index]["yolo"] = yolo
            projects[index]["tmux"] = tmux
            let remote = githubRemote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if remote.isEmpty { projects[index].removeValue(forKey: "githubRemote") }
            else { projects[index]["githubRemote"] = remote }
            root["projects"] = projects
        }
    }

    /// Soft-delete a project: move it to the shared Trash (recoverable from
    /// Pharos on Mac), mirroring the desktop's "forget, don't destroy" model.
    /// The removed dict is relocated verbatim so its payload can't corrupt the
    /// StoreData decode.
    func deleteProject(_ project: RemoteProject) async -> Bool {
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.deleteProject(project)
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let idx = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(project.name) == .orderedSame
            }) else { throw RegistryMutationError.message("Project not found. Reload and try again.") }
            let removed = projects.remove(at: idx)
            root["projects"] = projects
            var trash = root["trash"] as? [[String: Any]] ?? []
            trash.insert([
                "id": UUID().uuidString,
                "deletedAt": Date().timeIntervalSinceReferenceDate,
                "payload": ["project": ["_0": removed]]
            ], at: 0)
            root["trash"] = trash
        }
    }

    /// Post a progress update (note) to a project — the core "record progress"
    /// PM action, previously impossible from iOS.
    func addProjectUpdate(to projectName: String, body: String) async -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.addProjectUpdate(
                    to: projectName, body: trimmed
                )
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let index = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(projectName) == .orderedSame
            }) else { throw RegistryMutationError.message("Project not found. Reload and try again.") }
            var updates = projects[index]["updates"] as? [[String: Any]] ?? []
            // ProjectUpdate uses synthesized Codable on the desktop, so every
            // non-optional field must be present or StoreData decode throws and
            // the desktop silently drops the whole registry. createdAt is a
            // .deferredToDate Double (timeIntervalSinceReferenceDate). Insert at
            // the front to match the desktop's newest-first feed.
            updates.insert([
                "id": UUID().uuidString,
                "createdAt": Date().timeIntervalSinceReferenceDate,
                "body": trimmed,
                "kind": "note"
            ], at: 0)
            projects[index]["updates"] = updates
            root["projects"] = projects
        }
    }

    /// Soft-delete an issue: relocate it to the shared Trash (recoverable from
    /// Pharos on Mac). The removed dict is moved verbatim into the payload.
    func deleteIssue(_ issue: RemoteIssue) async -> Bool {
        if usesDistributedRegistry {
            return await distributedMutation {
                try await self.distributedMesh.deleteIssue(issue)
            }
        }
        return await mutateRegistry { root in
            var projects = root["projects"] as? [[String: Any]] ?? []
            guard let pi = projects.firstIndex(where: {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare(issue.project) == .orderedSame
            }) else { throw RegistryMutationError.message("Project not found. Reload and try again.") }
            var issues = projects[pi]["issues"] as? [[String: Any]] ?? []
            guard let ii = issues.firstIndex(where: { $0["number"] as? Int == issue.number }) else {
                throw RegistryMutationError.message("Issue not found. Reload and try again.")
            }
            let removed = issues.remove(at: ii)
            projects[pi]["issues"] = issues
            let projectID = (projects[pi]["id"] as? String) ?? UUID().uuidString
            let projectName = (projects[pi]["name"] as? String) ?? issue.project
            root["projects"] = projects
            var trash = root["trash"] as? [[String: Any]] ?? []
            trash.insert([
                "id": UUID().uuidString,
                "deletedAt": Date().timeIntervalSinceReferenceDate,
                "payload": ["issue": ["issue": removed, "projectID": projectID, "projectName": projectName]]
            ], at: 0)
            root["trash"] = trash
        }
    }

    // MARK: Room administration (broker commands)

    @discardableResult
    func renameRoom(_ room: String, to newName: String) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != room else { return false }
        if usesDistributedRegistry {
            guard let target = roomInfo(named: room) else {
                error = DistributedRoomStoreError.roomNotFound.localizedDescription
                return false
            }
            return await distributedRoomCommand({
                try await self.distributedMesh.renameRoom(target, to: trimmed)
            }) {
                if self.selectedRoom == room { self.selectedRoom = trimmed }
            }
        }
        var req = MeshRequest(cmd: "rename", room: room)
        req.text = trimmed
        return await roomCommand(req) { if self.selectedRoom == room { self.selectedRoom = trimmed } }
    }

    @discardableResult
    func deleteRoom(_ room: String) async -> Bool {
        if usesDistributedRegistry {
            guard let target = roomInfo(named: room) else {
                error = DistributedRoomStoreError.roomNotFound.localizedDescription
                return false
            }
            return await distributedRoomCommand({
                try await self.distributedMesh.deleteRoom(target)
            }) {
                if self.selectedRoom == room { self.selectedRoom = nil }
            }
        }
        return await roomCommand(MeshRequest(cmd: "delete", room: room)) {
            if self.selectedRoom == room { self.selectedRoom = nil }
        }
    }

    @discardableResult
    func removeMember(_ nick: String, memberID: String, from room: String) async -> Bool {
        if usesDistributedRegistry {
            guard let target = roomInfo(named: room) else {
                error = DistributedRoomStoreError.roomNotFound.localizedDescription
                return false
            }
            return await distributedRoomCommand({
                try await self.distributedMesh.removeMember(memberID, from: target)
            }) {}
        }
        var req = MeshRequest(cmd: "leave", room: room, nick: nick)
        req.memberID = memberID
        return await roomCommand(req) {}
    }

    @discardableResult
    func renameMember(_ nick: String, to newNick: String, memberID: String, in room: String) async -> Bool {
        let trimmed = newNick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != nick else { return false }
        if usesDistributedRegistry {
            guard let target = roomInfo(named: room) else {
                error = DistributedRoomStoreError.roomNotFound.localizedDescription
                return false
            }
            return await distributedRoomCommand({
                try await self.distributedMesh.renameMember(
                    memberID, in: target, to: trimmed
                )
            }) {}
        }
        var req = MeshRequest(cmd: "rename-member", room: room, nick: nick)
        req.memberID = memberID
        req.text = trimmed
        return await roomCommand(req) {}
    }

    private func roomCommand(_ req: MeshRequest, onSuccess: @MainActor () -> Void) async -> Bool {
        do {
            let response = try await request(req)
            guard response.ok else {
                error = response.error ?? "The Broker rejected the change."
                return false
            }
            onSuccess()
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func distributedRoomCommand(
        _ command: () async throws -> Void,
        onSuccess: @MainActor () -> Void
    ) async -> Bool {
        do {
            try await command()
            _ = await distributedMesh.synchronizeOnce()
            onSuccess()
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: Agent lifecycle

    /// Stop an agent by enqueuing a durable stopSession command on its Host
    /// node (same path the desktop uses). Requires a paired Broker (control
    /// token) and the member's Host node to be online.
    @discardableResult
    func stopAgent(_ member: MeshMember) async -> Bool {
        if usesDistributedRegistry {
            do {
                try await distributedMesh.stopAgent(memberID: member.id)
                try await distributedMesh.removeMemberFromAllRooms(member.id)
                error = nil
                await refresh()
                return true
            } catch {
                self.error = error.localizedDescription
                return false
            }
        }
        do {
            let nodes = try await request(MeshRequest(cmd: "node-list")).nodes ?? []
            let target = nodes.first { node in
                if let ip = member.tailscaleIP, !ip.isEmpty, let nip = node.tailscaleIP, !nip.isEmpty {
                    return ip == nip
                }
                return node.host.lowercased() == (member.host ?? "").lowercased()
            }
            guard let node = target else {
                error = "The agent's Host node is offline."
                return false
            }
            var enqueue = MeshRequest(cmd: "node-command-enqueue")
            enqueue.memberID = member.id
            enqueue.nodeID = node.id
            enqueue.action = "stopSession"
            enqueue.payload = "{\"memberID\":\"\(member.id)\"}"
            enqueue.idempotencyKey = "ios-stop:\(node.id):\(member.id):\(UUID().uuidString)"
            let response = try await request(enqueue)
            guard response.ok else {
                error = response.error ?? "Could not stop the agent."
                return false
            }
            error = nil
            await refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func mutateRegistry(_ mutation: (inout [String: Any]) throws -> Void) async -> Bool {
        guard !settings.mesh.host.isEmpty else {
            error = "Connect to your Broker before changing project data."
            return false
        }
        do {
            for attempt in 0..<2 {
                let snapshot = try await request(MeshRequest(cmd: "registry-get"))
                guard let payload = snapshot.payload, let revision = snapshot.revision,
                      let data = payload.data(using: .utf8),
                      var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RegistryMutationError.message("The Broker returned an invalid project registry.")
                }
                try mutation(&root)
                let encoded = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
                guard let nextPayload = String(data: encoded, encoding: .utf8) else {
                    throw RegistryMutationError.message("Could not encode the project registry.")
                }
                var write = MeshRequest(cmd: "registry-put")
                write.payload = nextPayload
                write.expectedRevision = revision
                let response = try await request(write)
                if response.ok {
                    UserDefaults.standard.removeObject(forKey: Self.projectsCacheKey)
                    UserDefaults.standard.removeObject(forKey: Self.issuesCacheKey)
                    error = nil
                    return true
                }
                if response.error == "registry conflict", attempt == 0 { continue }
                throw RegistryMutationError.message(response.error ?? "The Broker rejected the change.")
            }
            throw RegistryMutationError.message("The project registry changed repeatedly. Try again.")
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private var usesDistributedRegistry: Bool {
        PharosMeshRuntimeMode.usesDistributedMesh
    }

    private func roomInfo(named name: String) -> MeshRoom? {
        rooms.first { $0.name == name }
    }

    private func distributedMember(
        _ member: DistributedChatMember, room: String
    ) -> MeshMember {
        MeshMember(
            id: member.id, nick: member.nick,
            rooms: [room], lastSeen: 0, nodeOnline: nil
        )
    }

    private func distributedMutation(
        _ mutation: () async throws -> Void
    ) async -> Bool {
        do {
            try await mutation()
            _ = await distributedMesh.synchronizeOnce()
            error = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func cachedProjects() -> [RemoteProject]? {
        UserDefaults.standard.string(forKey: Self.projectsCacheKey).map(RemoteAgentService.parseProjects)
    }

    private func cachedIssues() -> [RemoteIssue]? {
        UserDefaults.standard.string(forKey: Self.issuesCacheKey).map(RemoteAgentService.parseIssues)
    }

    private func request(_ request: MeshRequest) async throws -> MeshResponse {
        guard !isDemo else { throw DemoNetworkError.disabled }
        guard !usesDistributedRegistry else {
            throw LegacyBrokerDisabledError.distributedMode
        }
        var authenticated = request
        if authenticated.authToken == nil, !settings.mesh.controlToken.isEmpty {
            authenticated.authToken = settings.mesh.controlToken
        }
        return try await mesh.send(authenticated, host: settings.mesh.host, port: settings.mesh.port)
    }

    private func supportsAdvancedMessages() async -> Bool {
        await capabilitySet().contains("mesh-v2")
    }

    private func supportsHistoryPaging() async -> Bool {
        await capabilitySet().contains("history-page-v1")
    }

    private func capabilitySet() async -> Set<String> {
        if let capabilities { return capabilities }
        guard let response = try? await request(MeshRequest(cmd: "capabilities")) else { return [] }
        let values = Set(response.capabilities ?? [])
        capabilities = values
        return values
    }

}

private enum DemoNetworkError: LocalizedError {
    case disabled
    var errorDescription: String? { "Network access is disabled in demo mode." }
}

private enum LegacyBrokerDisabledError: LocalizedError {
    case distributedMode
    var errorDescription: String? {
        "This feature has not moved to device-to-device Mesh yet. The retired Broker will not be contacted."
    }
}

private enum DistributedRoomStoreError: LocalizedError {
    case roomNotFound

    var errorDescription: String? {
        switch self {
        case .roomNotFound:
            "Room not found in the local replica. Sync and try again."
        }
    }
}

private enum RegistryMutationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        guard case .message(let message) = self else { return nil }
        return message
    }
}
