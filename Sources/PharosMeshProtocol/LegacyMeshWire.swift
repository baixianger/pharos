import Foundation

// Existing newline-delimited JSON contract. These values remain transport
// neutral so the legacy socket and Iroh stream adapters encode identical data.

public struct MeshRequest: Codable, Sendable, Equatable {
    public var cmd: String
    public var room: String?
    public var nick: String?
    public var memberID: String?
    public var text: String?
    public var to: [String]?
    public var timeoutMs: Int?
    public var limit: Int?
    public var project: String?
    public var session: String?
    public var host: String?
    public var tmuxPane: String?
    public var tmuxSocket: String?
    public var state: String?
    public var stateReason: String?
    public var expectedState: String?
    public var expectedStateTs: Double?
    public var kind: String?
    public var tailscaleIP: String?
    public var beforeID: String?
    public var replyToID: String?
    public var attachments: [MeshAttachment]?
    public var attachment: MeshAttachment?
    public var attachmentID: String?
    public var payload: String?
    public var expectedRevision: String?
    public var cursor: UInt64?
    public var authToken: String?
    public var nodeID: String?
    public var commandID: String?
    public var action: String?
    public var idempotencyKey: String?
    public var deadline: Double?
    public var retryAt: Double?
    public var maxAttempts: Int?

    public init(cmd: String, room: String? = nil, nick: String? = nil, memberID: String? = nil,
                text: String? = nil, to: [String]? = nil, timeoutMs: Int? = nil, limit: Int? = nil,
                project: String? = nil, session: String? = nil, host: String? = nil,
                tmuxPane: String? = nil, tmuxSocket: String? = nil, state: String? = nil,
                stateReason: String? = nil, expectedState: String? = nil,
                expectedStateTs: Double? = nil, kind: String? = nil,
                tailscaleIP: String? = nil, beforeID: String? = nil, replyToID: String? = nil,
                attachments: [MeshAttachment]? = nil, attachment: MeshAttachment? = nil,
                attachmentID: String? = nil, payload: String? = nil,
                expectedRevision: String? = nil, cursor: UInt64? = nil,
                authToken: String? = nil, nodeID: String? = nil, commandID: String? = nil,
                action: String? = nil, idempotencyKey: String? = nil, deadline: Double? = nil,
                retryAt: Double? = nil, maxAttempts: Int? = nil) {
        self.cmd = cmd; self.room = room; self.nick = nick; self.memberID = memberID
        self.text = text; self.to = to; self.timeoutMs = timeoutMs; self.limit = limit
        self.project = project; self.session = session; self.host = host; self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket; self.state = state; self.stateReason = stateReason
        self.expectedState = expectedState; self.expectedStateTs = expectedStateTs
        self.kind = kind; self.tailscaleIP = tailscaleIP; self.beforeID = beforeID
        self.replyToID = replyToID; self.attachments = attachments; self.attachment = attachment
        self.attachmentID = attachmentID; self.payload = payload
        self.expectedRevision = expectedRevision; self.cursor = cursor; self.authToken = authToken
        self.nodeID = nodeID; self.commandID = commandID; self.action = action
        self.idempotencyKey = idempotencyKey; self.deadline = deadline
        self.retryAt = retryAt; self.maxAttempts = maxAttempts
    }
}

public struct MeshEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case message, poke, roster, registry, nodeCommand }
    public var id: UInt64 { sequence }
    public var sequence: UInt64
    public var kind: Kind
    public var ts: Double
    public var room: String?
    public var message: MeshMsg?
    public var member: MeshMemberInfo?

    public init(sequence: UInt64, kind: Kind, ts: Double = Date().timeIntervalSince1970,
                room: String? = nil, message: MeshMsg? = nil, member: MeshMemberInfo? = nil) {
        self.sequence = sequence; self.kind = kind; self.ts = ts
        self.room = room; self.message = message; self.member = member
    }
}

public enum MeshNodeCommandAction: String, Codable, Sendable, CaseIterable {
    case spawnAgent, stopSession, poke, reconcile
}

public enum MeshNodeCommandState: String, Codable, Sendable {
    case queued, accepted, running, succeeded, failed, expired, canceled
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .expired, .canceled: true
        default: false
        }
    }
}

public struct MeshNodeCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var nodeID: String
    public var action: MeshNodeCommandAction
    public var payload: String?
    public var idempotencyKey: String
    public var state: MeshNodeCommandState
    public var createdAt: Double
    public var updatedAt: Double
    public var deadline: Double
    public var result: String?
    public var attempts: Int
    public var maxAttempts: Int
    public var nextAttemptAt: Double

    public init(id: String = UUID().uuidString, nodeID: String, action: MeshNodeCommandAction,
                payload: String?, idempotencyKey: String, state: MeshNodeCommandState = .queued,
                createdAt: Double = Date().timeIntervalSince1970,
                updatedAt: Double = Date().timeIntervalSince1970, deadline: Double,
                result: String? = nil, attempts: Int = 0, maxAttempts: Int = 120,
                nextAttemptAt: Double? = nil) {
        self.id = id; self.nodeID = nodeID; self.action = action; self.payload = payload
        self.idempotencyKey = idempotencyKey; self.state = state
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deadline = deadline
        self.result = result; self.attempts = attempts; self.maxAttempts = maxAttempts
        self.nextAttemptAt = nextAttemptAt ?? createdAt
    }
}

public struct MeshNodePokePayload: Codable, Sendable, Equatable {
    public var memberID: String
    public var requireUnread: Bool
    public init(memberID: String, requireUnread: Bool = true) {
        self.memberID = memberID; self.requireUnread = requireUnread
    }
}

public struct MeshNodeStopPayload: Codable, Sendable, Equatable {
    public var memberID: String
    public init(memberID: String) { self.memberID = memberID }
}

public struct MeshNodeSpawnPayload: Codable, Sendable, Equatable {
    public var projectID: String
    public var sessionName: String
    public var agent: String
    public var yolo: Bool
    public var room: String?
    public var nick: String?
    public init(projectID: String, sessionName: String, agent: String, yolo: Bool,
                room: String? = nil, nick: String? = nil) {
        self.projectID = projectID; self.sessionName = sessionName; self.agent = agent
        self.yolo = yolo; self.room = room; self.nick = nick
    }
}

public struct MeshPairingCredential: Codable, Sendable, Equatable {
    public var brokerID: String
    public var controlToken: String
    public init(brokerID: String, controlToken: String) {
        self.brokerID = brokerID; self.controlToken = controlToken
    }
}

public enum MeshSessionState: String, Codable, Sendable {
    case busy, blocked, stopped, idle, gone
    public var pokeable: Bool { self == .stopped || self == .idle }
}

public struct MeshReply: Codable, Sendable, Equatable {
    public var messageID: String
    public var from: String
    public var preview: String
    public var ts: Double
    public init(messageID: String, from: String, preview: String, ts: Double) {
        self.messageID = messageID; self.from = from; self.preview = preview; self.ts = ts
    }
}

public struct MeshAttachment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var byteSize: Int
    public var sha256: String
    public init(id: String = UUID().uuidString, name: String, mimeType: String,
                byteSize: Int, sha256: String) {
        self.id = id; self.name = name; self.mimeType = mimeType
        self.byteSize = byteSize; self.sha256 = sha256
    }
}

public struct MeshMsg: Codable, Sendable, Equatable, Identifiable {
    public var id: String?
    public var from: String
    public var room: String
    public var text: String
    public var ts: Double
    public var to: [String]
    public var replyTo: MeshReply?
    public var attachments: [MeshAttachment]?

    public init(id: String? = nil, from: String, room: String, text: String, ts: Double,
                to: [String], replyTo: MeshReply? = nil, attachments: [MeshAttachment]? = nil) {
        self.id = id; self.from = from; self.room = room; self.text = text; self.ts = ts
        self.to = to; self.replyTo = replyTo; self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey { case id, from, room, text, ts, to, replyTo, attachments }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        from = try values.decode(String.self, forKey: .from)
        room = try values.decode(String.self, forKey: .room)
        text = try values.decode(String.self, forKey: .text)
        ts = try values.decode(Double.self, forKey: .ts)
        to = try values.decodeIfPresent([String].self, forKey: .to) ?? []
        replyTo = try values.decodeIfPresent(MeshReply.self, forKey: .replyTo)
        attachments = try values.decodeIfPresent([MeshAttachment].self, forKey: .attachments)
    }
    public var stableID: String { id ?? "legacy|\(room)|\(ts)|\(from)" }
    public var date: Date { Date(timeIntervalSince1970: ts) }
}

public struct MeshRoomInfo: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var name: String
    public var members: [String]
    public var id: String { name }
    public init(name: String, members: [String]) { self.name = name; self.members = members }
}

public struct MeshUnread: Codable, Sendable {
    public var v: Int
    public var memberID: String
    public var nick: String
    public var count: Int
    public var rooms: [String: Int]
    public var messages: [MeshMsg]
    public var updatedTs: Double
    public init(v: Int, memberID: String, nick: String, count: Int, rooms: [String: Int],
                messages: [MeshMsg], updatedTs: Double) {
        self.v = v; self.memberID = memberID; self.nick = nick; self.count = count
        self.rooms = rooms; self.messages = messages; self.updatedTs = updatedTs
    }
}

public struct MeshPresenceEntry: Codable, Sendable {
    /// Stable owner for control-plane actions. Unlike host names and overlay
    /// addresses, this survives computer renames and missing Tailscale probes.
    public var nodeID: String?
    public var project: String?
    public var session: String?
    public var host: String?
    public var tmuxPane: String?
    public var tmuxSocket: String?
    public var state: String?
    public var stateTs: Double?
    public var stateReason: String?
    public var kind: String?
    public var tailscaleIP: String?
    public var aliases: [String: String]
    public var rooms: [String]
    public var lastSeen: Double
    public var online: Bool
    public init(nodeID: String? = nil, project: String? = nil, session: String? = nil, host: String? = nil,
                tmuxPane: String? = nil, tmuxSocket: String? = nil,
                state: String? = nil, stateTs: Double? = nil, stateReason: String? = nil,
                kind: String? = nil, tailscaleIP: String? = nil,
                aliases: [String: String], rooms: [String], lastSeen: Double, online: Bool) {
        self.nodeID = nodeID; self.project = project; self.session = session; self.host = host; self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket; self.state = state; self.stateTs = stateTs
        self.stateReason = stateReason; self.kind = kind; self.tailscaleIP = tailscaleIP
        self.aliases = aliases; self.rooms = rooms; self.lastSeen = lastSeen; self.online = online
    }
}

public struct MeshMemberInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var nick: String
    public var nodeID: String?
    public var project: String?
    public var session: String?
    public var host: String?
    public var tmuxPane: String?
    public var tmuxSocket: String?
    public var state: String?
    public var stateTs: Double?
    public var stateReason: String?
    public var unread: Int?
    public var kind: String?
    public var tailscaleIP: String?
    public var rooms: [String]
    public var lastSeen: Double
    public var nodeOnline: Bool?
    public init(id: String, nick: String, nodeID: String? = nil,
                project: String? = nil, session: String? = nil,
                host: String? = nil, tmuxPane: String? = nil, tmuxSocket: String? = nil,
                state: String? = nil, stateTs: Double? = nil, stateReason: String? = nil,
                unread: Int? = nil, kind: String? = nil, tailscaleIP: String? = nil,
                rooms: [String], lastSeen: Double, nodeOnline: Bool? = nil) {
        self.id = id; self.nick = nick; self.nodeID = nodeID
        self.project = project; self.session = session
        self.host = host; self.tmuxPane = tmuxPane; self.tmuxSocket = tmuxSocket
        self.state = state; self.stateTs = stateTs; self.stateReason = stateReason
        self.unread = unread; self.kind = kind; self.tailscaleIP = tailscaleIP
        self.rooms = rooms; self.lastSeen = lastSeen; self.nodeOnline = nodeOnline
    }
}

public struct MeshNodeInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var host: String
    public var tailscaleIP: String?
    public var lastSeen: Double
    public var buildID: String?
    public init(id: String, host: String, tailscaleIP: String?, lastSeen: Double,
                buildID: String? = nil) {
        self.id = id; self.host = host; self.tailscaleIP = tailscaleIP
        self.lastSeen = lastSeen; self.buildID = buildID
    }
}

public struct MeshPresence: Codable, Sendable {
    public var v: Int
    public var members: [String: MeshPresenceEntry]
    public init(v: Int, members: [String: MeshPresenceEntry]) { self.v = v; self.members = members }
}

public struct MeshResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var rooms: [MeshRoomInfo]?
    public var messages: [MeshMsg]?
    public var members: [MeshMemberInfo]?
    public var note: String?
    public var memberID: String?
    public var payload: String?
    public var capabilities: [String]?
    public var attachment: MeshAttachment?
    public var revision: String?
    public var events: [MeshEvent]?
    public var cursor: UInt64?
    public var nodes: [MeshNodeInfo]?
    public var command: MeshNodeCommand?
    public var commands: [MeshNodeCommand]?
    public init(ok: Bool, error: String? = nil, rooms: [MeshRoomInfo]? = nil,
                messages: [MeshMsg]? = nil, members: [MeshMemberInfo]? = nil,
                note: String? = nil, memberID: String? = nil, payload: String? = nil,
                capabilities: [String]? = nil, attachment: MeshAttachment? = nil,
                revision: String? = nil, events: [MeshEvent]? = nil, cursor: UInt64? = nil,
                nodes: [MeshNodeInfo]? = nil, command: MeshNodeCommand? = nil,
                commands: [MeshNodeCommand]? = nil) {
        self.ok = ok; self.error = error; self.rooms = rooms; self.messages = messages
        self.members = members; self.note = note; self.memberID = memberID; self.payload = payload
        self.capabilities = capabilities; self.attachment = attachment; self.revision = revision
        self.events = events; self.cursor = cursor; self.nodes = nodes
        self.command = command; self.commands = commands
    }
    public static func okay(_ note: String? = nil) -> MeshResponse { .init(ok: true, note: note) }
    public static func fail(_ error: String) -> MeshResponse { .init(ok: false, error: error) }
}
