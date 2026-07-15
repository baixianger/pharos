import Foundation

struct MeshRequest: Codable, Sendable, Equatable {
    var cmd: String
    var room: String?
    var nick: String?
    var memberID: String?
    var text: String?
    var to: [String]?
    var timeoutMs: Int?
    var limit: Int?
    var project: String?
    var session: String?
    var host: String?
    var tmuxPane: String?
    var tmuxSocket: String? = nil
    var state: String?
    var expectedState: String?
    var expectedStateTs: Double?
    var kind: String?

    init(cmd: String, room: String? = nil, nick: String? = nil, text: String? = nil,
         to: [String]? = nil, limit: Int? = nil) {
        self.cmd = cmd
        self.room = room
        self.nick = nick
        self.text = text
        self.to = to
        self.limit = limit
    }
}

struct MeshMessage: Codable, Sendable, Equatable, Identifiable {
    var from: String
    var room: String
    var text: String
    var ts: Double
    var to: [String]

    var id: String { "\(room)|\(ts)|\(from)|\(text)" }
    var date: Date { Date(timeIntervalSince1970: ts) }
}

struct MeshRoom: Codable, Sendable, Equatable, Identifiable, Hashable {
    var name: String
    var members: [String]
    var id: String { name }
}

struct MeshMember: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var nick: String
    var project: String?
    var session: String?
    var host: String?
    var tmuxPane: String?
    var tmuxSocket: String? = nil
    var state: String?
    var stateTs: Double?
    var unread: Int?
    var kind: String?
    var tailscaleIP: String?
    var rooms: [String]
    var lastSeen: Double
}

struct MeshResponse: Codable, Sendable, Equatable {
    var ok: Bool
    var error: String?
    var rooms: [MeshRoom]?
    var messages: [MeshMessage]?
    var members: [MeshMember]?
    var note: String?
    var memberID: String?
    var payload: String?
}

enum MentionParser {
    static func targets(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9._-]+)"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            let nick = String(text[r])
            return seen.insert(nick).inserted ? nick : nil
        }
    }
}

enum MeshSessionState: String, Sendable {
    case busy, blocked, stopped, idle, gone
    var isPokeCandidate: Bool { self == .stopped || self == .idle }
}

enum RosterIndex {
    /// `who` returns one row per room membership, so an agent joined to several
    /// rooms legitimately appears more than once. Keep its newest presence row
    /// instead of using Dictionary(uniqueKeysWithValues:), which traps.
    static func byNick(_ members: [MeshMember]) -> [String: MeshMember] {
        members.reduce(into: [:]) { result, member in
            if result[member.nick] == nil || member.lastSeen >= result[member.nick]!.lastSeen {
                result[member.nick] = member
            }
        }
    }
}
