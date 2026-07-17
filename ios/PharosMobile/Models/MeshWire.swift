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
    var stateReason: String?
    var expectedState: String?
    var expectedStateTs: Double?
    var kind: String?
    var replyToID: String?
    var attachments: [MeshAttachment]?
    var attachment: MeshAttachment?
    var attachmentID: String?
    var payload: String?
    var expectedRevision: String?
    var cursor: UInt64?
    var authToken: String?
    var nodeID: String?
    var commandID: String?
    var action: String?
    var idempotencyKey: String?
    var deadline: Double?
    var retryAt: Double?
    var maxAttempts: Int?

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

struct MeshEvent: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case message, poke, roster, registry, nodeCommand }
    var id: UInt64 { sequence }
    var sequence: UInt64
    var kind: Kind
    var ts: Double
    var room: String?
    var message: MeshMessage?
    var member: MeshMember?
}

struct MeshMessage: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var from: String
    var room: String
    var text: String
    var ts: Double
    var to: [String]
    var replyTo: MeshReply?
    var attachments: [MeshAttachment]?

    var date: Date { Date(timeIntervalSince1970: ts) }

    private enum CodingKeys: String, CodingKey {
        case id, from, room, text, ts, to, replyTo, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        room = try container.decode(String.self, forKey: .room)
        text = try container.decode(String.self, forKey: .text)
        ts = try container.decode(Double.self, forKey: .ts)
        to = try container.decodeIfPresent([String].self, forKey: .to) ?? []
        replyTo = try container.decodeIfPresent(MeshReply.self, forKey: .replyTo)
        attachments = try container.decodeIfPresent([MeshAttachment].self, forKey: .attachments)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "legacy|\(room)|\(ts)|\(from)"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(from, forKey: .from)
        try container.encode(room, forKey: .room)
        try container.encode(text, forKey: .text)
        try container.encode(ts, forKey: .ts)
        try container.encode(to, forKey: .to)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encodeIfPresent(attachments, forKey: .attachments)
    }
}

struct MeshReply: Codable, Sendable, Equatable {
    var messageID: String
    var from: String
    var preview: String
    var ts: Double
}

struct MeshAttachment: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var mimeType: String
    var byteSize: Int
    var sha256: String
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
    var stateReason: String?
    var unread: Int?
    var kind: String?
    var tailscaleIP: String?
    var rooms: [String]
    var lastSeen: Double
    var nodeOnline: Bool?
}

struct MeshNodeInfo: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var host: String
    var tailscaleIP: String?
    var lastSeen: Double
    var buildID: String?
}

struct MeshNodeCommand: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var nodeID: String
    var action: String
    var payload: String?
    var idempotencyKey: String
    var state: String
    var createdAt: Double
    var updatedAt: Double
    var deadline: Double
    var result: String?
    var attempts: Int
    var maxAttempts: Int
    var nextAttemptAt: Double
}

struct MeshPairingCredential: Codable, Sendable, Equatable {
    var brokerID: String
    var controlToken: String
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
    var capabilities: [String]?
    var attachment: MeshAttachment?
    var revision: String?
    var events: [MeshEvent]?
    var cursor: UInt64?
    var nodes: [MeshNodeInfo]?
    var command: MeshNodeCommand?
    var commands: [MeshNodeCommand]?
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
