import Foundation
import Observation

@Observable
@MainActor
final class RoomStore {
    private let settings: AppSettings
    private let mesh = MeshTCPClient()

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
    private var capabilities: Set<String>?
    private static let projectsCacheKey = "pharos.mobile.registry.projects.v1"
    private static let issuesCacheKey = "pharos.mobile.registry.issues.v1"

    init(settings: AppSettings, identities: SSHIdentityStore) {
        self.settings = settings
    }

    func refresh() async {
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
                let nextMessages = try await request(MeshRequest(cmd: "history", room: selectedRoom, limit: 200)).messages ?? []
                if messages != nextMessages { messages = nextMessages }
            } else {
                if !messages.isEmpty { messages = [] }
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
        selectedRoom = room
        do {
            let nextMessages = try await request(MeshRequest(cmd: "history", room: room, limit: 200)).messages ?? []
            if messages != nextMessages { messages = nextMessages }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func createRoom(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
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
            var outgoing = MeshRequest(cmd: "say", room: room, nick: "human", text: trimmed,
                                       to: targets.isEmpty ? nil : targets)
            outgoing.replyToID = replyTo?.id
            outgoing.attachments = attachments.isEmpty ? nil : attachments
            _ = try await request(outgoing)
            let nextMessages = try await request(MeshRequest(cmd: "history", room: room, limit: 200)).messages ?? []
            if messages != nextMessages { messages = nextMessages }
            error = nil
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
            let (metadata, data) = try await mesh.downloadAttachment(id: attachment.id,
                                                                     host: settings.mesh.host,
                                                                     port: settings.mesh.port)
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
        guard !settings.mesh.host.isEmpty else { return cachedProjects() }
        guard let payload = try? await request(MeshRequest(cmd: "projects")).payload else {
            return cachedProjects()
        }
        UserDefaults.standard.set(payload, forKey: Self.projectsCacheKey)
        return RemoteAgentService.parseProjects(payload)
    }

    func fetchIssuesOverMesh() async -> [RemoteIssue]? {
        guard !settings.mesh.host.isEmpty else { return cachedIssues() }
        guard let payload = try? await request(MeshRequest(cmd: "issues")).payload else {
            return cachedIssues()
        }
        UserDefaults.standard.set(payload, forKey: Self.issuesCacheKey)
        return RemoteAgentService.parseIssues(payload)
    }

    /// Add a portable project directly to the Broker-owned registry. Host paths
    /// remain host-local and are intentionally not accepted from iOS.
    func addProject(name: String, githubRemote: String?, notes: String, tags: [String]) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
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
                "yolo": true,
                "tmux": false,
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

    func addIssue(to projectName: String, title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
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
                "status": "todo",
                "priority": "none",
                "body": "",
                "labels": [],
                "attachments": [],
                "relations": [],
                "sortOrder": Double(issues.count)
            ])
            projects[index]["issues"] = issues
            root["projects"] = projects
        }
    }

    func updateIssue(_ issue: RemoteIssue, title: String, body: String,
                     status: String, priority: String, labels: [String]) async -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
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
            projects[projectIndex]["issues"] = issues
            root["projects"] = projects
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

    private func cachedProjects() -> [RemoteProject]? {
        UserDefaults.standard.string(forKey: Self.projectsCacheKey).map(RemoteAgentService.parseProjects)
    }

    private func cachedIssues() -> [RemoteIssue]? {
        UserDefaults.standard.string(forKey: Self.issuesCacheKey).map(RemoteAgentService.parseIssues)
    }

    private func request(_ request: MeshRequest) async throws -> MeshResponse {
        try await mesh.send(request, host: settings.mesh.host, port: settings.mesh.port)
    }

    private func supportsAdvancedMessages() async -> Bool {
        if let capabilities { return capabilities.contains("mesh-v2") }
        guard let response = try? await request(MeshRequest(cmd: "capabilities")) else { return false }
        let values = Set(response.capabilities ?? [])
        capabilities = values
        return values.contains("mesh-v2")
    }

}

private enum RegistryMutationError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        guard case .message(let message) = self else { return nil }
        return message
    }
}
