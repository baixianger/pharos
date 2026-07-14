import Foundation
import Observation

@Observable
@MainActor
final class RoomStore {
    private let settings: AppSettings
    private let identities: SSHIdentityStore
    private let mesh = MeshTCPClient()
    private let ssh = SSHTmuxPokeService()

    private(set) var rooms: [MeshRoom] = []
    var selectedRoom: String?
    private(set) var messages: [MeshMessage] = []
    private(set) var members: [String: MeshMember] = [:]
    private(set) var isRefreshing = false
    private(set) var notice: String?
    private(set) var error: String?

    init(settings: AppSettings, identities: SSHIdentityStore) {
        self.settings = settings
        self.identities = identities
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
            if selectedRoom == nil || !rooms.contains(where: { $0.name == selectedRoom }) {
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

    func send(_ text: String) async -> Bool {
        guard let room = selectedRoom else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let targets = MentionParser.targets(in: trimmed)
        do {
            let response = try await request(MeshRequest(cmd: "say", room: room, nick: "human", text: trimmed,
                                                         to: targets.isEmpty ? nil : targets))
            let nextMessages = try await request(MeshRequest(cmd: "history", room: room, limit: 200)).messages ?? []
            if messages != nextMessages { messages = nextMessages }
            error = nil
            if let targets = response.members { await pokeEligibleTargets(targets) }
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

    func refreshAfterRemoteAction() async { await refresh() }

    private func request(_ request: MeshRequest) async throws -> MeshResponse {
        try await mesh.send(request, host: settings.mesh.host, port: settings.mesh.port)
    }

    private func pokeEligibleTargets(_ targets: [MeshMember]) async {
        var results: [String] = []
        for member in targets {
            guard MeshSessionState(rawValue: member.state ?? "")?.isPokeCandidate == true else { continue }
            guard let profile = settings.sshHost(for: member.host) else {
                results.append("@\(member.nick): delivered; no SSH mapping for \(member.host ?? "unknown host")")
                continue
            }
            guard let identityID = profile.identityID,
                  let key = try? identities.privateKey(for: identityID) else {
                results.append("@\(member.nick): delivered; SSH identity unavailable")
                continue
            }
            do {
                try await ssh.poke(member: member, profile: profile, privateKey: key)
                results.append("⚡ poked @\(member.nick)")
            } catch {
                results.append("@\(member.nick): delivered; poke skipped — \(error.localizedDescription)")
            }
        }
        if !results.isEmpty { notice = results.joined(separator: "\n") }
    }
}
