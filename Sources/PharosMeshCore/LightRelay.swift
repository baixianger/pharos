import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Lightweight tier
//
// `LightRelay` is the deep module for the no-intubation messaging tier.
// Delivery is point-to-point by member id. A new send mints a thread; a reply
// inherits that thread from the reply-id. Participants are derived from who
// has sent or received, never stored as a roster. Route priority, hop
// accounting, expiry, the single-writer queue, and the append-only log stay
// behind that interface. The full Broker / Host Runtime path is a different
// module and is not consulted here.

public enum LightRouteAccess: String, Codable, Sendable {
    case read
    case write
}

public struct LightRoute: Codable, Equatable, Sendable {
    public var id: String
    public var access: LightRouteAccess
    public var fallback: Bool
    public var summary: String

    public init(id: String, access: LightRouteAccess, fallback: Bool, summary: String) {
        self.id = id
        self.access = access
        self.fallback = fallback
        self.summary = summary
    }

    /// A route named by a caller that does not know the driver's catalog.
    public static func named(_ id: String) -> LightRoute {
        let fallback = id == "tmux"
        let summary = fallback
            ? "last resort: tmux send-keys and capture-pane."
            : "registered route \(id)"
        return LightRoute(
            id: id,
            access: id == "files" ? .read : .write,
            fallback: fallback,
            summary: summary
        )
    }
}

public struct LightTmuxBinding: Codable, Equatable, Sendable {
    public var session: String        // tmux session name, e.g. "pharos-alice"
    public var cwd: String            // working directory the CLI runs in
    public var model: String?         // model label passed at launch (agy), nil = app default
    public var agentPID: Int32?       // pid of the CLI process inside the pane
    public var agentStarted: String?  // process start time (`ps -o lstart=`) to guard against pid reuse
    public var launchedAt: Date?
    public var endedAt: Date?         // set when Pharos observed the tmux session gone
    public var autoRevive: Bool?      // opt-in per member, default nil/false
    public var endedReason: String?   // "stopped" (explicit member stop), "exited" (agent/tmux went away on its own)

    public init(
        session: String,
        cwd: String,
        model: String? = nil,
        agentPID: Int32? = nil,
        agentStarted: String? = nil,
        launchedAt: Date? = nil,
        endedAt: Date? = nil,
        autoRevive: Bool? = nil,
        endedReason: String? = nil
    ) {
        self.session = session
        self.cwd = cwd
        self.model = model
        self.agentPID = agentPID
        self.agentStarted = agentStarted
        self.launchedAt = launchedAt
        self.endedAt = endedAt
        self.autoRevive = autoRevive
        self.endedReason = endedReason
    }
}

public struct LightMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var host: String
    public var app: String
    public var project: String
    public var sessionID: String
    public var routes: [LightRoute]
    public var tmux: LightTmuxBinding?

    public init(name: String, host: String, app: String, project: String, sessionID: String, routes: [LightRoute], tmux: LightTmuxBinding? = nil) {
        self.name = name
        self.host = host
        self.app = app
        self.project = project
        self.sessionID = sessionID
        self.routes = routes
        self.tmux = tmux
    }
}

/// A thread is an email-style conversation id, not a room. It stores who sent
/// the first message (the hop-limit notify target) and nothing about who else
/// has been copied. Participants are derived when someone lists or shows it.
public struct LightThread: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var originator: String
    public var hopLimit: Int
    public var stopped: Bool
    public var createdAt: Date
    /// Intent of the opening message. Nil in threads written before intents existed (read as ask).
    public var intent: LightIntent?
    /// `send --deliver`: replies to the originator wake its session instead of only being recorded.
    public var deliverReplies: Bool?
    /// Discuss only: reply cap and replies used so far.
    public var rounds: Int?
    public var roundsUsed: Int?
    /// Discuss only: the discussion ended (DONE or round cap). Replies are recorded, not delivered.
    public var closed: Bool?
    /// Discuss only: the one-line conclusion recorded after it closed.
    public var conclusion: String?

    public init(id: String, originator: String, hopLimit: Int, stopped: Bool, createdAt: Date,
                intent: LightIntent? = nil, deliverReplies: Bool? = nil, rounds: Int? = nil,
                roundsUsed: Int? = nil, closed: Bool? = nil, conclusion: String? = nil) {
        self.id = id
        self.originator = originator
        self.hopLimit = hopLimit
        self.stopped = stopped
        self.createdAt = createdAt
        self.intent = intent
        self.deliverReplies = deliverReplies
        self.rounds = rounds
        self.roundsUsed = roundsUsed
        self.closed = closed
        self.conclusion = conclusion
    }
}

/// Why a message was sent. Addressing (`--to` / `--cc`) says who gets it;
/// intent says what the recipient is expected to do with it.
public enum LightIntent: String, Codable, Sendable, CaseIterable {
    /// Delivered; a reply is expected.
    case ask
    /// Delivered as a notification; the recipient should not reply just to acknowledge.
    case inform
    /// A reply to an ask. Recorded for the asker; delivered only on `--deliver`.
    case answer
    /// Back-and-forth, delivered each turn, capped by `--rounds`; DONE ends it.
    case discuss

    public var expectsReply: Bool { self == .ask || self == .discuss }

    public static func parse(_ raw: String?) -> LightIntent? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "fyi": return .inform
        case "discussion": return .discuss
        default: return LightIntent(rawValue: value)
        }
    }
}

/// Structured form of one delivery. Session drivers type `prompt` into the app;
/// a webhook member receives this JSON as the POST body.
public struct LightEnvelope: Codable, Equatable, Sendable {
    public var replyId: String
    public var threadId: String
    public var from: String
    public var to: String
    public var cc: [String]
    public var intent: String
    public var text: String
    public var hop: Int
    public var hopLimit: Int
    public var round: Int?
    public var rounds: Int?
    public var expectsReply: Bool
    /// How to answer, when an answer is expected: `pharos reply r_xxx -- "<text>"`.
    public var replyCommand: String?
    /// The full text a session driver delivers (message plus Pharos header).
    public var prompt: String

    public init(replyId: String, threadId: String, from: String, to: String, cc: [String], intent: String,
                text: String, hop: Int, hopLimit: Int, round: Int? = nil, rounds: Int? = nil,
                expectsReply: Bool, replyCommand: String?, prompt: String) {
        self.replyId = replyId
        self.threadId = threadId
        self.from = from
        self.to = to
        self.cc = cc
        self.intent = intent
        self.text = text
        self.hop = hop
        self.hopLimit = hopLimit
        self.round = round
        self.rounds = rounds
        self.expectsReply = expectsReply
        self.replyCommand = replyCommand
        self.prompt = prompt
    }
}

public enum LightThreadKind: String, Codable, Sendable {
    /// Two participants (or fewer). Rendered as a direct message.
    case direct
    /// Three or more participants. Rendered as a group. Same delivery path.
    case group
}

/// Read-only view. `participants` is computed from the log and is not persisted.
public struct LightThreadView: Codable, Equatable, Sendable, Identifiable {
    public var id: String { thread.id }
    public var thread: LightThread
    public var participants: [String]
    public var kind: LightThreadKind

    public init(thread: LightThread, participants: [String], kind: LightThreadKind) {
        self.thread = thread
        self.participants = participants
        self.kind = kind
    }
}

public enum LightDeliveryState: String, Codable, Sendable {
    case queued
    case delivered
    case deferred
    case failed
    case expired
    case suppressed
    /// Not delivered into the session: kept in the thread for `wait` / `read` / `thread show`.
    case recorded
}

public enum LightLogKind: String, Codable, Sendable {
    case message
    case delivery
    case notice
}

public struct LightLogEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: LightLogKind
    public var threadID: String
    public var from: String?
    public var text: String
    public var mentions: [String]
    public var replyTo: String?
    public var hop: Int?
    public var to: String?
    public var replyID: String?
    public var state: LightDeliveryState?
    public var route: String?
    public var fallback: Bool?
    public var liveVerified: Bool?
    public var header: String?
    public var at: Date
    public var intent: LightIntent?
    /// Message entries: explicit addressees (`--to`, or the member a reply answers) and copies (`--cc`).
    public var recipients: [String]?
    public var cc: [String]?
    /// Reply messages: `reply` when the member ran `pharos reply`, `harvest` when Pharos read
    /// the answer from the member's session. Nil for older logs and for sends.
    public var via: String?

    public init(id: String, kind: LightLogKind, threadID: String, from: String? = nil, text: String,
                mentions: [String] = [], replyTo: String? = nil, hop: Int? = nil, to: String? = nil,
                replyID: String? = nil, state: LightDeliveryState? = nil, route: String? = nil,
                fallback: Bool? = nil, liveVerified: Bool? = nil, header: String? = nil, at: Date,
                intent: LightIntent? = nil, recipients: [String]? = nil, cc: [String]? = nil, via: String? = nil) {
        self.via = via
        self.intent = intent
        self.recipients = recipients
        self.cc = cc
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.from = from
        self.text = text
        self.mentions = mentions
        self.replyTo = replyTo
        self.hop = hop
        self.to = to
        self.replyID = replyID
        self.state = state
        self.route = route
        self.fallback = fallback
        self.liveVerified = liveVerified
        self.header = header
        self.at = at
    }
}

public struct LightDelivery: Codable, Equatable, Sendable {
    public var to: String
    public var replyID: String
    public var state: LightDeliveryState
    public var route: String?
    public var fallback: Bool
    public var liveVerified: Bool
    public var header: String
    public var detail: String
    /// `mesh`, `ssh`, `queued` (waiting in the node's inbox), or nil (this machine).
    public var via: String?
    /// Queued because the member is waiting on a human (needs_human).
    public var attention: LightAttention?

    public init(to: String, replyID: String, state: LightDeliveryState, route: String?, fallback: Bool,
                liveVerified: Bool, header: String, detail: String, via: String? = nil,
                attention: LightAttention? = nil) {
        self.via = via
        self.attention = attention
        self.to = to
        self.replyID = replyID
        self.state = state
        self.route = route
        self.fallback = fallback
        self.liveVerified = liveVerified
        self.header = header
        self.detail = detail
    }
}

public struct LightSendResult: Codable, Equatable, Sendable {
    public var threadID: String
    public var from: String
    public var hop: Int
    public var hopLimit: Int
    public var stopped: Bool
    public var forwarded: Bool
    public var deliveries: [LightDelivery]
    public var unresolved: [String]
    public var notice: String?
    public var intent: LightIntent?
    /// Registered members named with `@` in the body but not addressed. Never delivered.
    public var hints: [String]?
    /// Discuss only: this reply ended the discussion.
    public var closed: Bool?

    public init(threadID: String, from: String, hop: Int, hopLimit: Int, stopped: Bool, forwarded: Bool = false,
                deliveries: [LightDelivery], unresolved: [String], notice: String?,
                intent: LightIntent? = nil, hints: [String]? = nil, closed: Bool? = nil) {
        self.intent = intent
        self.hints = hints
        self.closed = closed
        self.threadID = threadID
        self.from = from
        self.hop = hop
        self.hopLimit = hopLimit
        self.stopped = stopped
        self.forwarded = forwarded
        self.deliveries = deliveries
        self.unresolved = unresolved
        self.notice = notice
    }
}

public struct LightWaitResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case replied
        case expired
        case unknown
    }

    public var replyID: String
    public var status: Status
    public var text: String?
    public var send: LightSendResult?
    /// Reply-id issued to the waiting member for this answer, when one was recorded.
    public var nextReplyID: String?
    /// Pending because the recipient is waiting on a human; Pharos does not read its session meanwhile.
    public var attention: LightAttention?

    public init(replyID: String, status: Status, text: String?, send: LightSendResult?, nextReplyID: String? = nil,
                attention: LightAttention? = nil) {
        self.nextReplyID = nextReplyID
        self.attention = attention
        self.replyID = replyID
        self.status = status
        self.text = text
        self.send = send
    }
}

public struct LightRejection: Codable, Equatable, Sendable {
    public var replyID: String
    public var reason: String
    public var at: Date

    public init(replyID: String, reason: String, at: Date) {
        self.replyID = replyID
        self.reason = reason
        self.at = at
    }
}

public struct LightSweepReport: Codable, Equatable, Sendable {
    public var expiredReplies: Int
    public var expiredQueued: Int
    public var flushed: Int
    public var notices: Int
    public var expiredInbox: Int
    /// needs_human states whose TTL ended.
    public var expiredAttention: Int

    public init(expiredReplies: Int, expiredQueued: Int, flushed: Int, notices: Int, expiredInbox: Int = 0,
                expiredAttention: Int = 0) {
        self.expiredAttention = expiredAttention
        self.expiredReplies = expiredReplies
        self.expiredQueued = expiredQueued
        self.flushed = flushed
        self.notices = notices
        self.expiredInbox = expiredInbox
    }
}

/// One durable job waiting on a Pharos node. The Broker keeps a single inbox
/// per node inside the same store as the session outbox. At-least-once: a job
/// stays until `ack`. A repeated id is ignored.
public struct LightNodeJob: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var node: String
    public var kind: String
    public var payload: String
    public var enqueuedAt: Date
    public var expiresAt: Date
    /// How many times a pull has handed this job out. Ack has not happened yet.
    public var deliveries: Int

    public init(id: String, node: String, kind: String, payload: String, enqueuedAt: Date,
                expiresAt: Date, deliveries: Int) {
        self.id = id
        self.node = node
        self.kind = kind
        self.payload = payload
        self.enqueuedAt = enqueuedAt
        self.expiresAt = expiresAt
        self.deliveries = deliveries
    }
}

public struct LightEnqueueResult: Equatable, Sendable {
    public var job: LightNodeJob
    public var duplicate: Bool

    public init(job: LightNodeJob, duplicate: Bool) {
        self.job = job
        self.duplicate = duplicate
    }
}

/// Presence for one Pharos node. Online means a heartbeat newer than
/// `LightRelay.nodeHeartbeatWindow` (the same 70s window as the Broker node list).
public struct LightNodeStatus: Equatable, Sendable {
    public var host: String
    public var online: Bool
    public var lastSeen: Date?

    public init(host: String, online: Bool, lastSeen: Date?) {
        self.host = host
        self.online = online
        self.lastSeen = lastSeen
    }
}

/// Node liveness provider, querying e.g. the Broker roster.
public protocol LightNodeLiveness: Sendable {
    func nodeStatus(_ host: String) -> LightNodeStatus?
}

public struct LightLimits: Equatable, Sendable {
    public var replyTTL: TimeInterval
    public var queueTTL: TimeInterval
    public var hopLimit: Int

    public init(replyTTL: TimeInterval = 24 * 60 * 60, queueTTL: TimeInterval = 72 * 60 * 60, hopLimit: Int = 8) {
        self.replyTTL = replyTTL
        self.queueTTL = queueTTL
        self.hopLimit = hopLimit
    }
}

public struct LightDriveResult: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case delivered
        case busy
        case deferred
        case failed
        /// The member's Pharos node is not on the mesh and SSH did not reach it: park in its inbox.
        case offline
    }

    public var state: State
    public var route: String?
    public var fallback: Bool
    /// True only when the adapter itself observed a completed app turn.
    /// The shipped external adapter leaves this false: live app sends are not certified.
    public var liveVerified: Bool
    public var detail: String
    /// How the delivery reached the member's node: `mesh`, `ssh`, or nil (this machine).
    public var via: String?

    public init(state: State, route: String?, fallback: Bool, liveVerified: Bool, detail: String, via: String? = nil) {
        self.state = state
        self.route = route
        self.fallback = fallback
        self.liveVerified = liveVerified
        self.detail = detail
        self.via = via
    }
}

/// Session wake/read seam. Two adapters make it real: an in-memory fake in tests,
/// and the external planner in PharosRuntime. The relay does not switch on app brand.
public protocol LightSessionDriver: Sendable {
    func deliver(member: LightMember, body: String) -> LightDriveResult
    /// Structured delivery. The default types `envelope.prompt` through `deliver(member:body:)`.
    func deliver(member: LightMember, envelope: LightEnvelope) -> LightDriveResult
    /// Text the session produced after `since`, only when the adapter can tell
    /// new text from older history. Return nil rather than a stale pane.
    func readReply(member: LightMember, since: Date) -> String?
}

extension LightSessionDriver {
    public func deliver(member: LightMember, envelope: LightEnvelope) -> LightDriveResult {
        deliver(member: member, body: envelope.prompt)
    }
}

public struct IdleLightDriver: LightSessionDriver {
    public init() {}

    public func deliver(member: LightMember, body: String) -> LightDriveResult {
        LightDriveResult(state: .deferred, route: nil, fallback: false, liveVerified: false,
                         detail: "no session driver configured")
    }

    public func readReply(member: LightMember, since: Date) -> String? { nil }
}

public struct LightForwardResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String
    public var exitCode: Int32?

    public init(ok: Bool, message: String, exitCode: Int32? = nil) {
        self.ok = ok
        self.message = message
        self.exitCode = exitCode
    }
}

/// Non-broker hosts inject a forwarder. Returning nil means this process owns the ledger.
public protocol LightReplyForwarding: Sendable {
    func forward(replyID: String, text: String) -> LightForwardResult?
    /// Forward `pharos <arguments>` and return the Broker's stdout and exit code.
    /// The default does nothing, so a reply-only forwarder stays local for read and wait.
    func forwardCommand(_ arguments: [String]) -> LightForwardResult?
}

extension LightReplyForwarding {
    public func forwardCommand(_ arguments: [String]) -> LightForwardResult? { nil }
}

public enum LightRelayError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case invalidHost(String)
    case invalidApp(String)
    case invalidProject(String)
    case invalidSession(String)
    case duplicateMember(String)
    case unknownMember(String)
    case unknownThread(String)
    case noRecipients
    case invalidLimit
    case emptyText
    case unknownReply(String)
    case expiredReply(String)
    case consumedReply(String)
    case malformedReply(String)
    case threadStopped(String)
    case webhookNotLoopback
    case forwardFailed(String)
    case corruptStore(String)
    case invalidJob(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let value): "invalid member name \(value)"
        case .invalidHost(let value): "invalid host label \(value)"
        case .invalidApp(let value): "invalid app \(value)"
        case .invalidProject(let value): "invalid project \(value)"
        case .invalidSession(let value): "invalid session id \(value)"
        case .duplicateMember(let value): "member \(value) is already registered to a different session"
        case .unknownMember(let value): "unknown member \(value)"
        case .unknownThread(let value): "unknown thread \(value)"
        case .noRecipients: "a message needs at least one other recipient"
        case .invalidLimit: "hop limit must be at least 1"
        case .emptyText: "message text is empty"
        case .unknownReply(let value): "unknown reply-id \(value)"
        case .expiredReply(let value): "expired reply-id \(value)"
        case .consumedReply(let value): "reply-id \(value) was already used"
        case .malformedReply(let value): "malformed reply-id \(value)"
        case .threadStopped(let value): "thread \(value) is stopped"
        case .webhookNotLoopback: "the reply webhook must use 127.0.0.1, localhost, or ::1"
        case .forwardFailed(let value): "forwarding the reply failed: \(value)"
        case .corruptStore(let value): "light-relay store is unreadable (\(value))"
        case .invalidJob(let value): "invalid request id \(value)"
        }
    }
}

public enum LightTokens {
    public static func make(_ prefix: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        let body = (0..<12).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }
        return prefix + "_" + String(body)
    }

    public static func isValid(_ value: String, prefix: String) -> Bool {
        let head = prefix + "_"
        guard value.hasPrefix(head) else { return false }
        let rest = value.dropFirst(head.count)
        guard (8...64).contains(rest.count) else { return false }
        return rest.allSatisfy { $0.isLetter && $0.isLowercase || $0.isNumber }
    }
}

/// `@name` tokens in a body. Not an addressing mechanism: recipients come only from
/// `--to` / `--cc`. The relay uses the tokens to hint at members that were named but not copied.
public enum LightMentions {
    /// `@name` tokens, in order, de-duplicated, lowercased.
    /// An `@` inside a larger token (an email address) is ignored.
    /// `@all` is not special: there is no roster to expand.
    public static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@" {
                let boundary: Bool
                if index == text.startIndex {
                    boundary = true
                } else {
                    let previous = text[text.index(before: index)]
                    boundary = !(previous.isLetter || previous.isNumber || previous == "_" || previous == "." || previous == "-")
                }
                if boundary {
                    var cursor = text.index(after: index)
                    var count = 0
                    while cursor < text.endIndex, count < 64 {
                        let character = text[cursor]
                        if character.isLetter || character.isNumber || character == "_" || character == "." || character == "-" {
                            cursor = text.index(after: cursor)
                            count += 1
                        } else {
                            break
                        }
                    }
                    if count > 0 {
                        let raw = String(text[text.index(after: index)..<cursor]).lowercased()
                        if seen.insert(raw).inserted { out.append(raw) }
                        index = cursor
                        continue
                    }
                }
            }
            index = text.index(after: index)
        }
        return out
    }
}

public enum LightWebhook {
    public static func loopback(_ raw: String?) throws -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost" || host == "::1",
              url.scheme == "http" || url.scheme == "https" else {
            throw LightRelayError.webhookNotLoopback
        }
        return trimmed
    }
}

public enum LightWebhookIntake {
    public static func accept(_ data: Data, relay: LightRelay) throws -> LightSendResult {
        struct Body: Decodable {
            var replyId: String
            var text: String
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return try relay.reply(body.replyId, text: body.text)
    }
}

/// Broker-owned directory, thread log, reply-id ledger, and single-writer outbox.
public final class LightRelay: @unchecked Sendable {
    /// True when this process may create files in the store (false inside a sandbox
    /// that blocks it). Probes with a real create, which the sandbox decides.
    public static func storeIsWritable(_ store: URL) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: store.path) {
            guard (try? fm.createDirectory(at: store, withIntermediateDirectories: true)) != nil else { return false }
        }
        let probe = store.appendingPathComponent(".probe-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        unlink(probe.path)
        return true
    }

    public static func defaultStoreURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["PHAROS_LIGHT_RELAY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Pharos/light-relay", isDirectory: true)
    }

    private let store: URL
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) -> Void
    private let makeToken: @Sendable (String) -> String
    private let driver: any LightSessionDriver
    private let forwarder: (any LightReplyForwarding)?
    private let webhook: String?
    private let limits: LightLimits
    private let liveness: (any LightNodeLiveness)?
    private let lock = NSLock()

    private var members: [String: LightMember] = [:]
    private var threads: [String: LightThread] = [:]
    private var ledger: [String: Ticket] = [:]
    private var outbox: [OutboxItem] = []
    private var inbox: [LightNodeJob] = []
    private var nodeSeen: [String: Date] = [:]
    private var appliedJobs: [String: Date] = [:]
    private var logs: [String: [LightLogEntry]] = [:]
    private var rejectionLog: [LightRejection] = []
    private var inflight: Set<String> = []
    /// needs_human by member name. Active while `expiresAt` is ahead.
    private var attention: [String: LightAttention] = [:]

    public init(store: URL,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                makeToken: @escaping @Sendable (String) -> String = { LightTokens.make($0) },
                driver: any LightSessionDriver = IdleLightDriver(),
                forwarder: (any LightReplyForwarding)? = nil,
                webhook: String? = nil,
                limits: LightLimits = LightLimits(),
                liveness: (any LightNodeLiveness)? = nil) throws {
        self.store = store
        self.now = now
        self.sleep = sleep
        self.makeToken = makeToken
        self.driver = driver
        self.forwarder = forwarder
        self.webhook = try LightWebhook.loopback(webhook)
        self.limits = limits
        self.liveness = liveness
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        chmod(store.path, 0o700)
        try load()
        stamp = stateStamp()
    }

    // MARK: Directory

    @discardableResult
    public func register(_ member: LightMember) throws -> LightMember {
        try sync {
            let name = try Self.validateName(member.name)
            let host = try Self.validateLabel(member.host, failure: LightRelayError.invalidHost)
            let app = try Self.validateLabel(member.app, failure: LightRelayError.invalidApp)
            let project = try Self.validateProject(member.project)
            let session = try Self.validateSession(member.sessionID)
            var stored = member
            stored.name = name
            stored.host = host
            stored.app = app
            stored.project = project
            stored.sessionID = session
            if var existing = members[name] {
                let same = existing.sessionID == session && existing.app == app
                    && existing.host == host && existing.project == project
                guard same else { throw LightRelayError.duplicateMember(name) }
                if !stored.routes.isEmpty { existing.routes = stored.routes }
                if let t = stored.tmux { existing.tmux = t }
                members[name] = existing
                try persistLocked()
                return existing
            }
            members[name] = stored
            try persistLocked()
            return stored
        }
    }

    public func listMembers() -> [LightMember] {
        sync { members.values.sorted { $0.name < $1.name } }
    }

    public func member(named name: String) -> LightMember? {
        sync { members[name] }
    }

    public func updateTmux(member name: String, _ binding: LightTmuxBinding?) throws {
        try sync {
            guard var existing = members[name] else { throw LightRelayError.unknownMember(name) }
            existing.tmux = binding
            members[name] = existing
            try persistLocked()
        }
    }

    // MARK: Threads
    //
    // Threads are not created on their own. `send` mints one. `reply` inherits
    // the thread id from the reply-id it answers. `listThreads` / `show` derive
    // participants from the append-only log.

    public func listThreads() -> [LightThreadView] {
        sync { threads.values.sorted { $0.createdAt < $1.createdAt }.map { viewLocked($0) } }
    }

    public func show(thread threadID: String) throws -> LightThreadView {
        try sync {
            guard let thread = threads[threadID] else { throw LightRelayError.unknownThread(threadID) }
            return viewLocked(thread)
        }
    }

    public func read(thread threadID: String) throws -> [LightLogEntry] {
        try sync {
            guard threads[threadID] != nil else { throw LightRelayError.unknownThread(threadID) }
            return logs[threadID] ?? []
        }
    }

    /// The log of the thread that issued `replyID`. A miss is not a rejection:
    /// reading is not an attempt to answer.
    public func read(replyID: String) throws -> [LightLogEntry] {
        try sync {
            guard LightTokens.isValid(replyID, prefix: "r") else { throw LightRelayError.malformedReply(replyID) }
            guard let ticket = ledger[replyID] else { throw LightRelayError.unknownReply(replyID) }
            guard threads[ticket.threadID] != nil else { throw LightRelayError.unknownThread(ticket.threadID) }
            return logs[ticket.threadID] ?? []
        }
    }

    public func rejections() -> [LightRejection] {
        sync { rejectionLog }
    }

    /// When a forwarder owns the ledger, run `pharos <command> <arguments>` there.
    public func forwardCommand(command: String, arguments: [String]) -> LightCLIResult? {
        guard let result = forwarder?.forwardCommand([command] + arguments) else { return nil }
        let code = result.exitCode ?? (result.ok ? 0 : 1)
        return LightCLIResult(exitCode: code, text: result.message)
    }

    // MARK: Send / reply

    /// Default reply cap for `--intent discuss`.
    public static let defaultDiscussRounds = 4

    /// A new message (not a reply). Mints a thread id and delivers one copy to
    /// each `to` and `cc` member. `@` tokens in `text` are plain text: a registered
    /// member named that way but not addressed comes back in `hints`, never as a delivery.
    public func send(from name: String, to recipients: [String], cc: [String] = [], text: String,
                     intent: LightIntent = .ask, deliverReplies: Bool = false, rounds: Int? = nil,
                     ttl: TimeInterval? = nil, once: Bool = false, hopLimit: Int? = nil) throws -> LightSendResult {
        let plan = try sync { () -> SendPlan in
            try planSendLocked(from: name, recipients: recipients, cc: cc, text: text, intent: intent,
                               deliverReplies: deliverReplies, rounds: rounds, ttl: ttl, once: once, hopLimit: hopLimit)
        }
        return try fanout(plan)
    }

    /// Answer a reply-id. The answer goes back only to the member who sent the message,
    /// plus each `cc`. Outside an open discussion, an `answer` / `inform` reply to the
    /// sender is recorded in the thread and not delivered unless `deliver` (or the
    /// original `send --deliver`) asks for it. An `ask` reply is always delivered.
    public func reply(_ replyID: String, text: String, cc: [String] = [], intent: LightIntent? = nil,
                      deliver: Bool = false, ttl: TimeInterval? = nil, once: Bool = false,
                      harvested: Bool = false) throws -> LightSendResult {
        if let forwarder, let forwarded = forwarder.forward(replyID: replyID, text: text) {
            guard forwarded.ok else { throw LightRelayError.forwardFailed(forwarded.message) }
            return LightSendResult(threadID: "", from: "", hop: 0, hopLimit: 0, stopped: false,
                                   forwarded: true, deliveries: [], unresolved: [], notice: forwarded.message)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LightRelayError.emptyText }
        let decision = try sync { () -> ReplyDecision in
            try decideReplyLocked(replyID, text: trimmed, cc: cc, intent: intent, deliver: deliver, ttl: ttl, once: once,
                                  via: harvested ? "harvest" : "reply")
        }
        switch decision {
        case .finished(let result):
            return result
        case .fanout(let plan):
            return try fanout(plan)
        }
    }

    public func wait(replyID: String, timeout: TimeInterval) throws -> LightWaitResult {
        let start = now()
        var delay: TimeInterval = 0.5
        var waited: TimeInterval = 0
        while true {
            if let logged = try loggedReply(replyID) {
                return LightWaitResult(replyID: replyID, status: .replied, text: logged, send: nil,
                                       nextReplyID: nextReplyID(after: replyID))
            }
            let probe = try sync { () -> WaitProbe in
                try probeReplyLocked(replyID)
            }
            switch probe {
            case .unknown:
                return LightWaitResult(replyID: replyID, status: .unknown, text: nil, send: nil)
            case .expired:
                return LightWaitResult(replyID: replyID, status: .expired, text: nil, send: nil)
            case .pending:
                break
            case .readable(let member, let since):
                if let text = driver.readReply(member: member, since: since)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    // A harvested reply goes only to the original sender. It is never copied.
                    let send = try reply(replyID, text: text, harvested: true)
                    let logged = try loggedReply(replyID)
                    return LightWaitResult(replyID: replyID, status: .replied, text: logged ?? text, send: send,
                                           nextReplyID: nextReplyID(after: replyID))
                }
            }
            let elapsed = max(now().timeIntervalSince(start), waited)
            if timeout <= 0 || elapsed >= timeout {
                return LightWaitResult(replyID: replyID, status: .pending, text: nil, send: nil,
                                       attention: recipientAttention(replyID))
            }
            let step = min(delay, timeout - elapsed)
            sleep(step)
            waited += step
            delay = min(delay * 2, 10.0)
        }
    }

    @discardableResult
    public func sweep() -> LightSweepReport {
        let report = sync { expireLocked() }
        let flushed = pump()
        return LightSweepReport(expiredReplies: report.expiredReplies, expiredQueued: report.expiredQueued,
                                flushed: flushed, notices: report.notices, expiredInbox: report.expiredInbox,
                                expiredAttention: report.expiredAttention)
    }

    // MARK: needs_human
    //
    // Recorded and reported only. Pharos never approves or denies. Matching is by
    // session id (and app label when the source gives one); no app is special here.

    /// Record or clear needs_human for every member registered to `report.sessionID`.
    @discardableResult
    public func reportAttention(_ report: LightAttentionReport) throws -> LightAttentionOutcome {
        try sync {
            let session = try Self.validateSession(report.sessionID)
            let app = report.app.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matched = members.values
                .filter { $0.sessionID == session && (app.isEmpty || $0.app == app) }
                .sorted { $0.name < $1.name }
            var outcome = LightAttentionOutcome(state: report.state, unmatched: matched.isEmpty)
            guard !matched.isEmpty else { return outcome }
            let moment = now()
            let seenAt = min(report.at ?? moment, moment)
            let source = report.source.isEmpty ? "hook" : report.source
            for member in matched {
                let current = attention[member.name].flatMap { $0.expiresAt > moment ? $0 : nil }
                switch report.state {
                case .needsHuman:
                    let ttl = max(1, report.ttl ?? (source == "poll" ? LightAttention.pollTTL : LightAttention.defaultTTL))
                    let what = LightAttention.clip(report.what)
                    attention[member.name] = LightAttention(
                        member: member.name, what: what.isEmpty ? (current?.what ?? "") : what,
                        host: report.host.isEmpty ? (current?.host ?? member.host) : report.host,
                        sessionID: session, app: member.app,
                        // A poll refreshing a hook's state keeps the hook as owner.
                        source: current?.source == "hook" ? "hook" : source,
                        since: current?.since ?? seenAt, seen: moment,
                        // A short poll refresh never cuts a longer hook TTL.
                        expiresAt: max(current?.expiresAt ?? moment, moment.addingTimeInterval(ttl)))
                    outcome.recorded.append(member.name)
                case .clear:
                    guard let current else {
                        attention[member.name] = nil
                        continue
                    }
                    // A poll that sees nothing does not undo what a hook pushed.
                    if source == "poll", current.source == "hook" { continue }
                    attention[member.name] = nil
                    outcome.cleared.append(member.name)
                }
            }
            try persistLocked()
            return outcome
        }
    }

    /// The member's needs_human state, when active.
    public func attention(for name: String) -> LightAttention? {
        sync { heldLocked(name) }
    }

    /// Every active needs_human state, oldest first.
    public func activeAttention() -> [LightAttention] {
        sync {
            let moment = now()
            return attention.values.filter { $0.expiresAt > moment }.sorted { $0.since < $1.since }
        }
    }

    /// Members worth polling for an approval prompt: a state is recorded for them
    /// (so a still-open prompt outlives a lapsed hook TTL and a closed one clears),
    /// a queued message or an open ask is waiting on them.
    public func attentionCandidates() -> [LightMember] {
        sync {
            let moment = now()
            // Rank: a recorded state first (it must be refreshed or cleared), then queued
            // messages, then open asks, so a pass limit never drops the member that matters.
            var rank: [String: Int] = [:]
            func note(_ name: String, _ value: Int) { rank[name] = min(rank[name] ?? value, value) }
            for state in attention.values where state.expiresAt > moment { note(state.member, 0) }
            for item in outbox { note(item.to, 1) }
            for ticket in ledger.values where !ticket.consumed && ticket.expiresAt > moment && ticket.harvest != false {
                note(ticket.to, 2)
            }
            return rank.keys.compactMap { members[$0] }
                .sorted { (rank[$0.name] ?? 3, $0.name) < (rank[$1.name] ?? 3, $1.name) }
        }
    }

    private func recipientAttention(_ replyID: String) -> LightAttention? {
        sync { ledger[replyID].flatMap { heldLocked($0.to) } }
    }

    private func heldLocked(_ name: String) -> LightAttention? {
        guard let state = attention[name], state.expiresAt > now() else { return nil }
        return state
    }

    private func holdNoticeLocked(_ target: PreparedTarget, _ state: LightAttention) throws {
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .notice, threadID: target.ticket.threadID, from: target.member.name,
            text: "needs_human \(target.member.name): \(state.describe(at: now())); message queued until it proceeds",
            to: target.member.name, replyID: target.ticket.replyID, at: now()
        ))
    }

    static func holdDetail(_ state: LightAttention, at moment: Date) -> String {
        "needs_human: \(state.describe(at: moment)); queued until it proceeds"
    }

    // MARK: Node inbox
    //
    // One queue per node, in this same store. A node pulls on heartbeat.
    // Ack removes the job. The queue TTL is the outbox TTL (72h). A second
    // enqueue or ack of the same id does nothing.

    /// Same liveness window the Broker uses when it drops a node heartbeat.
    public static let nodeHeartbeatWindow: TimeInterval = 70

    public static func lastSeenAgo(_ lastSeen: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(lastSeen)))
        return "last seen \(seconds)s ago"
    }

    public static func nodeOfflineMessage(lastSeen: Date?, now: Date) -> String {
        guard let lastSeen else {
            return "Pharos node offline; never seen"
        }
        let ago = lastSeenAgo(lastSeen, now: now)
        let iso = ISO8601DateFormatter().string(from: lastSeen)
        return "Pharos node offline; \(ago) (\(iso))"
    }

    /// Nodes that have jobs waiting in their inbox.
    public func inboxNodes() -> [String] {
        sync { Array(Set(inbox.map(\.node))).sorted() }
    }

    /// Record a node heartbeat seen elsewhere (the Broker roster) without pulling.
    public func noteNodeSeen(_ host: String, at moment: Date) {
        sync {
            guard let name = try? Self.validateLabel(host, failure: LightRelayError.invalidHost) else { return }
            if let seen = nodeSeen[name], seen >= moment { return }
            nodeSeen[name] = moment
            try? persistLocked()
        }
    }

    /// Open asks Pharos may still read from a session: not answered, not expired,
    /// harvestable, issued within `maxAge`. Newest first, at most `limit`.
    public func pendingHarvest(maxAge: TimeInterval, limit: Int) -> [String] {
        sync {
            let moment = now()
            let open = ledger.values.filter { ticket in
                guard !ticket.consumed, ticket.harvest != false, ticket.expiresAt > moment,
                      moment.timeIntervalSince(ticket.issuedAt) <= maxAge, members[ticket.to] != nil,
                      heldLocked(ticket.to) == nil else { return false }
                let answered = logs[ticket.threadID]?.contains { $0.kind == .message && $0.replyTo == ticket.replyID } ?? false
                return !answered
            }
            return open.sorted { $0.issuedAt > $1.issuedAt }.prefix(max(0, limit)).map(\.replyID)
        }
    }

    /// Deliver one parked `deliver` job (its node is back) and ack it when the session took it.
    @discardableResult
    public func redeliverParked(_ job: LightNodeJob) -> LightDriveResult? {
        if sync({ ledger[job.id].flatMap { heldLocked($0.to) } }) != nil { return nil }
        let target: (LightMember, LightEnvelope, String, Int)? = sync {
            guard job.kind == "deliver", let ticket = ledger[job.id], let member = members[ticket.to] else { return nil }
            let header = logs[ticket.threadID]?.last { $0.kind == .delivery && $0.replyID == job.id }?.header ?? ""
            let envelope = LightEnvelope(replyId: ticket.replyID, threadId: ticket.threadID, from: ticket.from, to: ticket.to,
                                         cc: [], intent: (ticket.intent ?? .ask).rawValue, text: job.payload,
                                         hop: ticket.hop, hopLimit: threads[ticket.threadID]?.hopLimit ?? ticket.hop,
                                         expectsReply: ticket.harvest != false,
                                         replyCommand: "pharos reply \(ticket.replyID) -- \"...\"", prompt: job.payload)
            return (member, envelope, header, ticket.hop)
        }
        guard let target else {
            if !sync({ ledger[job.id] != nil }) { _ = ack(job: job.id) }
            return nil
        }
        let (member, envelope, header, hop) = target
        let result = driver.deliver(member: member, envelope: envelope)
        guard result.state == .delivered || result.state == .deferred else { return result }
        sync {
            try? appendDeliveryLocked(threadID: envelope.threadId, to: member.name, replyID: job.id,
                                      state: Self.deliveryState(result.state), route: result.route,
                                      fallback: result.fallback, liveVerified: result.liveVerified,
                                      header: header, hop: hop)
        }
        _ = ack(job: job.id)
        return result
    }

    public func nodeStatus(_ host: String) -> LightNodeStatus {
        sync { nodeStatusLocked(host) }
    }

    /// Record a heartbeat and hand back every job still waiting on that node.
    @discardableResult
    public func heartbeat(node host: String) throws -> [LightNodeJob] {
        try pull(node: host)
    }

    /// Pull is the reconnect path: it records the heartbeat, then returns
    /// unacked jobs. Pulling again before ack delivers the same ids again.
    public func pull(node host: String) throws -> [LightNodeJob] {
        try sync {
            let name = try Self.validateLabel(host, failure: LightRelayError.invalidHost)
            nodeSeen[name] = now()
            let jobs = try collectPullLocked(name)
            try persistLocked()
            return jobs
        }
    }

    public func nodeJob(_ id: String) -> LightNodeJob? {
        sync { inbox.first { $0.id == id } }
    }

    public func nodeJobWasApplied(_ id: String) -> Bool {
        sync { appliedJobs[id] != nil }
    }

    @discardableResult
    public func enqueueNodeJob(id: String? = nil, node: String, kind: String, payload: String) throws -> LightEnqueueResult {
        try sync { try enqueueNodeJobLocked(id: id, node: node, kind: kind, payload: payload) }
    }

    /// Removes the job. A second ack, or an unknown id, returns false and changes nothing.
    @discardableResult
    public func ack(job id: String) -> Bool {
        sync {
            if appliedJobs[id] != nil { return false }
            guard let index = inbox.firstIndex(where: { $0.id == id }) else { return false }
            inbox.remove(at: index)
            appliedJobs[id] = now()
            try? persistLocked()
            return true
        }
    }

    @discardableResult
    public func pump() -> Int {
        var flushed = 0
        var blocked = Set<String>()
        while true {
            let claim: Claim? = sync { claimNextLocked(skipping: blocked) }
            guard let claim else { break }
            let result = driver.deliver(member: claim.member, envelope: claim.item.envelope ?? Self.bareEnvelope(claim.item))
            let delivered = sync { finishClaimLocked(claim, result: result, blocked: &blocked) }
            if delivered { flushed += 1 }
        }
        return flushed
    }

    // MARK: Planning

    private struct Ticket: Codable, Equatable {
        var replyID: String
        var threadID: String
        var from: String
        var to: String
        var hop: Int
        var expiresAt: Date
        var once: Bool
        var consumed: Bool
        var terminal: Bool
        var issuedAt: Date
        var intent: LightIntent?
        /// False when the ticket was issued with a notification (inform, answer, cc, recorded)
        /// or to a webhook member: `wait` must not harvest session text for it. Nil reads as true.
        var harvest: Bool?
        /// Replies on this ticket wake the member who sent it (`--deliver`).
        var deliverReply: Bool?
        /// This ticket asks for the one-line conclusion of a closed discussion.
        var conclusion: Bool?
    }

    private struct OutboxItem: Codable, Equatable {
        var id: String
        var threadID: String
        var to: String
        var replyID: String
        var body: String
        var header: String
        var hop: Int
        var fallbackRoute: String?
        var enqueuedAt: Date
        var expiresAt: Date
        var envelope: LightEnvelope?
    }

    private struct NodeSeen: Codable, Equatable {
        var host: String
        var lastSeen: Date
    }

    private struct AppliedJob: Codable, Equatable {
        var id: String
        var at: Date
    }

    private struct Snapshot: Codable {
        var version: Int
        var members: [LightMember]
        var threads: [LightThread]
        var ledger: [Ticket]
        var outbox: [OutboxItem]
        var inbox: [LightNodeJob]
        var nodes: [NodeSeen]
        var applied: [AppliedJob]
        var attention: [LightAttention] = []

        private enum CodingKeys: String, CodingKey {
            case version, members, threads, ledger, outbox, inbox, nodes, applied, attention
        }

        init(version: Int, members: [LightMember], threads: [LightThread], ledger: [Ticket],
             outbox: [OutboxItem], inbox: [LightNodeJob], nodes: [NodeSeen], applied: [AppliedJob],
             attention: [LightAttention] = []) {
            self.attention = attention
            self.version = version
            self.members = members
            self.threads = threads
            self.ledger = ledger
            self.outbox = outbox
            self.inbox = inbox
            self.nodes = nodes
            self.applied = applied
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            members = try container.decode([LightMember].self, forKey: .members)
            threads = try container.decode([LightThread].self, forKey: .threads)
            ledger = try container.decode([Ticket].self, forKey: .ledger)
            outbox = try container.decode([OutboxItem].self, forKey: .outbox)
            inbox = try container.decodeIfPresent([LightNodeJob].self, forKey: .inbox) ?? []
            nodes = try container.decodeIfPresent([NodeSeen].self, forKey: .nodes) ?? []
            applied = try container.decodeIfPresent([AppliedJob].self, forKey: .applied) ?? []
            attention = try container.decodeIfPresent([LightAttention].self, forKey: .attention) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(members, forKey: .members)
            try container.encode(threads, forKey: .threads)
            try container.encode(ledger, forKey: .ledger)
            try container.encode(outbox, forKey: .outbox)
            try container.encode(inbox, forKey: .inbox)
            try container.encode(nodes, forKey: .nodes)
            try container.encode(applied, forKey: .applied)
            if !attention.isEmpty { try container.encode(attention, forKey: .attention) }
        }
    }

    private struct SendPlan {
        var threadID: String
        var from: String
        var hop: Int
        var hopLimit: Int
        var stopped: Bool
        var unresolved: [String]
        var notice: String?
        var targets: [PreparedTarget]
        var intent: LightIntent? = nil
        var hints: [String]? = nil
        var closed: Bool? = nil
    }

    private struct PreparedTarget {
        var member: LightMember
        var ticket: Ticket
        var body: String
        var header: String
        var queued: Bool
        var envelope: LightEnvelope
        /// Kept in the thread only; the driver is not called.
        var record: Bool = false
        /// Queued because the member is waiting on a human.
        var hold: LightAttention? = nil
    }

    /// How one copy of a message is addressed and what its header asks for.
    private struct TargetSpec {
        var intent: LightIntent
        /// The member is on `--cc`: an FYI copy, no reply expected.
        var copied = false
        /// Hop-limit notice: invites nothing.
        var terminal = false
        /// Record in the thread instead of waking the session.
        var record = false
        /// Replies on this copy wake the sender (`--deliver`).
        var deliverReply = false
        /// The copy asks for a closed discussion's one-line conclusion; `note` says why it closed.
        var conclusion = false
        var note: String? = nil
        /// Everyone copied on this message, for the envelope.
        var cc: [String] = []
        /// Discuss: the round the recipient's reply would be.
        var round: Int? = nil

        var expectsReply: Bool {
            if terminal || copied || record { return false }
            return conclusion || intent.expectsReply
        }
    }

    private enum ReplyDecision {
        case finished(LightSendResult)
        case fanout(SendPlan)
    }

    private enum WaitProbe {
        case unknown
        case expired
        case pending
        case readable(LightMember, Date)
    }

    private struct Claim {
        var index: Int
        var item: OutboxItem
        var member: LightMember
    }

    private func fanout(_ plan: SendPlan) throws -> LightSendResult {
        var deliveries: [LightDelivery] = []
        for target in plan.targets where target.record {
            deliveries.append(LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: .recorded,
                                            route: nil, fallback: false, liveVerified: false, header: target.header,
                                            detail: "recorded in the thread; not delivered (use --deliver to wake the sender)"))
        }
        for target in plan.targets where !target.queued && !target.record {
            deliveries.append(try deliverNow(target))
        }
        for target in plan.targets where target.queued && !target.record {
            deliveries.append(queuedDelivery(target))
        }
        // A message to a member waiting on a human stays queued: do not let this
        // send's pump hand it over before the state clears.
        _ = pump()
        let refreshed = try refresh(deliveries, threadID: plan.threadID)
        return LightSendResult(threadID: plan.threadID, from: plan.from, hop: plan.hop, hopLimit: plan.hopLimit,
                               stopped: plan.stopped, deliveries: refreshed, unresolved: plan.unresolved,
                               notice: plan.notice, intent: plan.intent, hints: plan.hints, closed: plan.closed)
    }

    private static func bareEnvelope(_ item: OutboxItem) -> LightEnvelope {
        LightEnvelope(replyId: item.replyID, threadId: item.threadID, from: "", to: item.to, cc: [], intent: LightIntent.ask.rawValue,
                      text: item.body, hop: item.hop, hopLimit: item.hop, expectsReply: true,
                      replyCommand: "pharos reply \(item.replyID) -- \"...\"", prompt: item.body)
    }

    private func deliverNow(_ target: PreparedTarget) throws -> LightDelivery {
        // needs_human holds the message before any route or node-liveness decision.
        let waiting = try sync { () -> LightAttention? in
            guard let state = heldLocked(target.member.name) else { return nil }
            var queued = target
            queued.hold = state
            try enqueueLocked(queued, routeNote: nil)
            try holdNoticeLocked(queued, state)
            return state
        }
        if let waiting {
            var queued = target
            queued.hold = waiting
            return queuedDelivery(queued)
        }
        let parked = try sync { () -> LightNodeStatus? in
            let status = nodeStatusLocked(target.member.host)
            guard status.lastSeen != nil, !status.online else { return nil }
            _ = try enqueueNodeJobLocked(id: target.ticket.replyID, node: target.member.host,
                                         kind: "deliver", payload: target.body)
            try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                     replyID: target.ticket.replyID, state: .queued, route: nil,
                                     fallback: false, liveVerified: false, header: target.header,
                                     hop: target.ticket.hop)
            return status
        }
        if let parked {
            return LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: .queued,
                                 route: nil, fallback: false, liveVerified: false, header: target.header,
                                 detail: Self.nodeOfflineMessage(lastSeen: parked.lastSeen, now: now()), via: "queued")
        }
        let claim = try sync { () -> Claim? in
            if outbox.contains(where: { $0.to == target.member.name }) || inflight.contains(target.member.name) {
                try enqueueLocked(target, routeNote: nil)
                return nil
            }
            inflight.insert(target.member.name)
            return nil
        }
        _ = claim
        let held = sync { inflight.contains(target.member.name) && !outbox.contains(where: { $0.replyID == target.ticket.replyID }) }
        if !held {
            return queuedDelivery(target)
        }
        let result = driver.deliver(member: target.member, envelope: target.envelope)
        return try sync {
            inflight.remove(target.member.name)
            if result.state == .busy {
                try enqueueLocked(target, routeNote: result.route)
                return queuedDelivery(target, detail: result.detail)
            }
            if result.state == .offline {
                // Mesh and SSH both missed the member's node: wait in its inbox on the Broker.
                _ = try enqueueNodeJobLocked(id: target.ticket.replyID, node: target.member.host,
                                             kind: "deliver", payload: target.body)
                try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                         replyID: target.ticket.replyID, state: .queued, route: nil,
                                         fallback: false, liveVerified: false, header: target.header,
                                         hop: target.ticket.hop)
                var queued = queuedDelivery(target, detail: result.detail)
                queued.via = "queued"
                return queued
            }
            let state = Self.deliveryState(result.state)
            try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                     replyID: target.ticket.replyID, state: state, route: result.route,
                                     fallback: result.fallback, liveVerified: result.liveVerified,
                                     header: target.header, hop: target.ticket.hop)
            return LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: state,
                                 route: result.route, fallback: result.fallback, liveVerified: result.liveVerified,
                                 header: target.header, detail: result.detail, via: result.via)
        }
    }

    private func queuedDelivery(_ target: PreparedTarget, detail: String = "queued behind the session writer") -> LightDelivery {
        if let hold = target.hold {
            return LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: .queued, route: nil,
                                 fallback: false, liveVerified: false, header: target.header,
                                 detail: Self.holdDetail(hold, at: now()), attention: hold)
        }
        return LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: .queued, route: nil,
                             fallback: false, liveVerified: false, header: target.header, detail: detail)
    }

    private func refresh(_ deliveries: [LightDelivery], threadID: String) throws -> [LightDelivery] {
        sync {
            deliveries.map { delivery in
                let latest = (logs[threadID] ?? []).last { $0.replyID == delivery.replyID && $0.kind == .delivery }
                guard let latest, let state = latest.state else { return delivery }
                return LightDelivery(to: delivery.to, replyID: delivery.replyID, state: state, route: latest.route,
                                     fallback: latest.fallback ?? delivery.fallback,
                                     liveVerified: latest.liveVerified ?? false, header: delivery.header,
                                     detail: delivery.detail, via: delivery.via, attention: delivery.attention)
            }
        }
    }

    private func planSendLocked(from name: String, recipients: [String], cc: [String], text: String,
                                intent: LightIntent, deliverReplies: Bool, rounds: Int?,
                                ttl: TimeInterval?, once: Bool, hopLimit: Int?) throws -> SendPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LightRelayError.emptyText }
        let sender = try Self.validateName(name)
        guard members[sender] != nil else { throw LightRelayError.unknownMember(sender) }
        let limit = hopLimit ?? limits.hopLimit
        guard limit >= 1 else { throw LightRelayError.invalidLimit }
        if let rounds, rounds < 1 { throw LightRelayError.invalidLimit }
        var targets: [String] = []
        for raw in recipients {
            let id = try Self.validateName(raw)
            if id == sender { continue }
            guard members[id] != nil else { throw LightRelayError.unknownMember(id) }
            if !targets.contains(id) { targets.append(id) }
        }
        guard !targets.isEmpty else { throw LightRelayError.noRecipients }
        var copies: [String] = []
        for raw in cc {
            let id = try Self.validateName(raw)
            if id == sender || targets.contains(id) { continue }
            guard members[id] != nil else { throw LightRelayError.unknownMember(id) }
            if !copies.contains(id) { copies.append(id) }
        }
        let discuss = intent == .discuss
        let thread = LightThread(id: try tokenLocked("t"), originator: sender, hopLimit: limit,
                                 stopped: false, createdAt: now(), intent: intent,
                                 deliverReplies: deliverReplies ? true : nil,
                                 rounds: discuss ? (rounds ?? Self.defaultDiscussRounds) : nil,
                                 roundsUsed: discuss ? 0 : nil)
        threads[thread.id] = thread
        logs[thread.id] = []
        let hints = hintsLocked(trimmed, addressed: targets + copies + [sender])
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: sender, text: trimmed,
            hop: 1, at: now(), intent: intent, recipients: targets, cc: copies.isEmpty ? nil : copies
        ))
        var prepared: [PreparedTarget] = []
        for target in targets {
            guard let member = members[target] else { throw LightRelayError.unknownMember(target) }
            let spec = TargetSpec(intent: intent, deliverReply: deliverReplies, cc: copies, round: discuss ? 1 : nil)
            prepared.append(try prepareTargetLocked(member: member, from: sender, thread: thread, hop: 1,
                                                   ttl: ttl, once: once, text: trimmed, spec: spec))
        }
        for copy in copies {
            guard let member = members[copy] else { throw LightRelayError.unknownMember(copy) }
            let spec = TargetSpec(intent: intent, copied: true, deliverReply: deliverReplies, cc: copies)
            prepared.append(try prepareTargetLocked(member: member, from: sender, thread: thread, hop: 1,
                                                   ttl: ttl, once: once, text: trimmed, spec: spec))
        }
        try persistLocked()
        return SendPlan(threadID: thread.id, from: sender, hop: 1, hopLimit: thread.hopLimit, stopped: false,
                        unresolved: [], notice: nil, targets: prepared, intent: intent,
                        hints: hints.isEmpty ? nil : hints)
    }

    /// Registered members named with `@` in `text` that are not addressed. Hints only.
    private func hintsLocked(_ text: String, addressed: [String]) -> [String] {
        LightMentions.tokens(in: text).filter { members[$0] != nil && !addressed.contains($0) }
    }

    /// A discussion turn that is just `DONE` (any case, optional punctuation) ends it.
    static func isDone(_ text: String) -> Bool {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = upper.drop { !$0.isLetter }
        guard letters.hasPrefix("DONE") else { return false }
        guard let next = letters.dropFirst(4).first else { return true }
        return !(next.isLetter || next.isNumber)
    }

    private func prepareTargetLocked(member: LightMember, from: String, thread: LightThread, hop: Int,
                                     ttl: TimeInterval?, once: Bool, text: String, spec: TargetSpec) throws -> PreparedTarget {
        let replyTTL = ttl ?? limits.replyTTL
        let issued = now()
        let replyID = try tokenLocked("r")
        let expects = spec.expectsReply
        let ticket = Ticket(replyID: replyID, threadID: thread.id, from: from, to: member.name, hop: hop,
                            expiresAt: issued.addingTimeInterval(replyTTL), once: once, consumed: false,
                            terminal: spec.terminal, issuedAt: issued, intent: spec.intent,
                            harvest: expects && member.app != "webhook",
                            deliverReply: spec.deliverReply ? true : nil,
                            conclusion: spec.conclusion ? true : nil)
        ledger[replyID] = ticket
        // A hop-limit notice is terminal. It must not invite another `pharos reply`.
        let header = headerLocked(from: from, thread: thread, replyID: replyID, hop: hop, spec: spec)
        let body = text + "\n\n" + header
        let envelope = LightEnvelope(
            replyId: replyID, threadId: thread.id, from: from, to: member.name, cc: spec.cc,
            intent: spec.intent.rawValue, text: text, hop: hop, hopLimit: thread.hopLimit,
            round: spec.round, rounds: spec.round == nil ? nil : (thread.rounds ?? Self.defaultDiscussRounds),
            expectsReply: expects,
            replyCommand: spec.terminal ? nil : "pharos reply \(replyID) -- \"...\"",
            prompt: body
        )
        if spec.record {
            try appendDeliveryLocked(threadID: thread.id, to: member.name, replyID: replyID, state: .recorded,
                                     route: nil, fallback: false, liveVerified: false, header: header, hop: hop)
            return PreparedTarget(member: member, ticket: ticket, body: body, header: header, queued: false,
                                  envelope: envelope, record: true)
        }
        let hold = heldLocked(member.name)
        let queued = hold != nil || outbox.contains(where: { $0.to == member.name }) || inflight.contains(member.name)
        if queued {
            let target = PreparedTarget(member: member, ticket: ticket, body: body, header: header, queued: true,
                                        envelope: envelope, hold: hold)
            try enqueueLocked(target, routeNote: nil)
            if let hold { try holdNoticeLocked(target, hold) }
            return target
        }
        return PreparedTarget(member: member, ticket: ticket, body: body, header: header, queued: false, envelope: envelope)
    }

    private func enqueueLocked(_ target: PreparedTarget, routeNote: String?) throws {
        if outbox.contains(where: { $0.replyID == target.ticket.replyID }) {
            return
        }
        let item = OutboxItem(id: try tokenLocked("q"), threadID: target.ticket.threadID, to: target.member.name,
                              replyID: target.ticket.replyID, body: target.body, header: target.header,
                              hop: target.ticket.hop, fallbackRoute: routeNote, enqueuedAt: now(),
                              expiresAt: now().addingTimeInterval(limits.queueTTL), envelope: target.envelope)
        outbox.append(item)
        try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                 replyID: target.ticket.replyID, state: .queued, route: routeNote,
                                 fallback: false, liveVerified: false, header: target.header, hop: target.ticket.hop)
    }

    private func decideReplyLocked(_ replyID: String, text: String, cc rawCC: [String], intent requested: LightIntent?,
                                   deliver: Bool, ttl: TimeInterval?, once: Bool, via: String? = nil) throws -> ReplyDecision {
        if !LightTokens.isValid(replyID, prefix: "r") {
            try rejectLocked(replyID, reason: "malformed")
            throw LightRelayError.malformedReply(replyID)
        }
        guard var ticket = ledger[replyID] else {
            try rejectLocked(replyID, reason: "unknown")
            throw LightRelayError.unknownReply(replyID)
        }
        if ticket.consumed {
            try rejectLocked(replyID, reason: "consumed", threadID: ticket.threadID)
            throw LightRelayError.consumedReply(replyID)
        }
        if ticket.expiresAt <= now() {
            ledger[replyID] = nil
            try rejectLocked(replyID, reason: "expired", threadID: ticket.threadID)
            try persistLocked()
            throw LightRelayError.expiredReply(replyID)
        }
        guard var thread = threads[ticket.threadID] else { throw LightRelayError.unknownThread(ticket.threadID) }
        // A member that runs `pharos reply` is no longer waiting on a human.
        if via == "reply", attention[ticket.to] != nil { attention[ticket.to] = nil }
        var ccNames: [String] = []
        for raw in rawCC {
            let id = try Self.validateName(raw)
            guard members[id] != nil else { throw LightRelayError.unknownMember(id) }
            if id != ticket.to, !ccNames.contains(id) { ccNames.append(id) }
        }
        if ticket.conclusion == true {
            ticket.consumed = true
            ledger[replyID] = ticket
            thread.conclusion = text
            threads[thread.id] = thread
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
                replyTo: replyID, hop: ticket.hop, at: now(), intent: .inform, via: via
            ))
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .notice, threadID: thread.id, from: ticket.to,
                text: "Conclusion (\(ticket.to)): \(text)", at: now()
            ))
            try persistLocked()
            return .finished(LightSendResult(threadID: thread.id, from: ticket.to, hop: ticket.hop,
                                             hopLimit: thread.hopLimit, stopped: thread.stopped, deliveries: [],
                                             unresolved: [], notice: "conclusion recorded", intent: .inform,
                                             closed: true))
        }
        if ticket.terminal {
            ticket.consumed = true
            ledger[replyID] = ticket
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
                replyTo: replyID, hop: ticket.hop, at: now(), intent: requested ?? .answer, via: via
            ))
            try persistLocked()
            return .finished(LightSendResult(threadID: thread.id, from: ticket.to, hop: ticket.hop,
                                             hopLimit: thread.hopLimit, stopped: thread.stopped, deliveries: [],
                                             unresolved: [], notice: nil))
        }
        if thread.stopped {
            try rejectLocked(replyID, reason: "stopped", threadID: thread.id)
            throw LightRelayError.threadStopped(thread.id)
        }
        let discussOpen = thread.intent == .discuss && thread.closed != true
        let replyIntent = requested ?? (discussOpen ? .discuss : .answer)
        let nextHop = ticket.hop + 1
        if nextHop > thread.hopLimit {
            ticket.consumed = true
            ledger[replyID] = ticket
            thread.stopped = true
            if discussOpen { thread.closed = true }
            threads[thread.id] = thread
            let notice = "Hop limit \(thread.hopLimit) reached. Thread stopped. Last reply from \(ticket.to): \(text)"
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
                replyTo: replyID, hop: ticket.hop, at: now(), intent: replyIntent, recipients: [ticket.from], via: via
            ))
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .notice, threadID: thread.id, from: thread.originator, text: notice,
                to: thread.originator, at: now()
            ))
            var targets: [PreparedTarget] = []
            if thread.originator != ticket.to, let owner = members[thread.originator] {
                targets.append(try prepareTargetLocked(member: owner, from: ticket.to, thread: thread, hop: ticket.hop,
                                                       ttl: ttl, once: true, text: notice,
                                                       spec: TargetSpec(intent: .inform, terminal: true)))
            }
            try persistLocked()
            return .fanout(SendPlan(threadID: thread.id, from: ticket.to, hop: ticket.hop, hopLimit: thread.hopLimit,
                                    stopped: true, unresolved: [], notice: notice, targets: targets,
                                    intent: replyIntent, closed: discussOpen ? true : nil))
        }
        if ticket.once {
            ticket.consumed = true
        } else {
            ticket.hop = nextHop
        }
        ledger[replyID] = ticket
        let hints = hintsLocked(text, addressed: [ticket.from, ticket.to] + ccNames)
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
            replyTo: replyID, hop: nextHop, at: now(), intent: replyIntent,
            recipients: ticket.from == ticket.to ? [] : [ticket.from], cc: ccNames.isEmpty ? nil : ccNames, via: via
        ))
        var targets: [PreparedTarget] = []
        var notice: String? = nil
        var closed: Bool? = nil
        let back = ticket.from != ticket.to ? members[ticket.from] : nil
        if discussOpen {
            // Each reply in an open discussion is one round. DONE or the cap closes it,
            // and the originator is asked for a one-line conclusion.
            let cap = thread.rounds ?? Self.defaultDiscussRounds
            let used = (thread.roundsUsed ?? 0) + 1
            thread.roundsUsed = used
            let done = Self.isDone(text)
            if done || used >= cap {
                thread.closed = true
                closed = true
                let reason = done ? "\(ticket.to) answered DONE" : "round cap \(cap) reached"
                notice = "Discussion closed: \(reason)."
                threads[thread.id] = thread
                try appendLocked(LightLogEntry(
                    id: try tokenLocked("m"), kind: .notice, threadID: thread.id, from: thread.originator,
                    text: notice ?? "", to: thread.originator, at: now()
                ))
                if let owner = members[thread.originator] {
                    let last = done ? "" : " Last message from \(ticket.to): \(text)"
                    targets.append(try prepareTargetLocked(
                        member: owner, from: ticket.to, thread: thread, hop: nextHop, ttl: ttl, once: true,
                        text: "Discussion closed: \(reason).\(last)",
                        spec: TargetSpec(intent: .inform, conclusion: true, note: reason)))
                }
            } else {
                threads[thread.id] = thread
                if let back {
                    targets.append(try prepareTargetLocked(
                        member: back, from: ticket.to, thread: thread, hop: nextHop, ttl: ttl, once: once, text: text,
                        spec: TargetSpec(intent: .discuss, cc: ccNames, round: used + 1)))
                }
            }
        } else {
            threads[thread.id] = thread
            // The answer goes back to the sender. It wakes the sender only on --deliver
            // (here or on the original send) or when it is itself a question.
            let wake = deliver || ticket.deliverReply == true || replyIntent == .ask
            if let back {
                targets.append(try prepareTargetLocked(
                    member: back, from: ticket.to, thread: thread, hop: nextHop, ttl: ttl, once: once, text: text,
                    spec: TargetSpec(intent: replyIntent, record: !wake, deliverReply: thread.deliverReplies == true,
                                     cc: ccNames)))
            }
        }
        for name in ccNames where name != ticket.from {
            guard let member = members[name] else { continue }
            targets.append(try prepareTargetLocked(
                member: member, from: ticket.to, thread: thread, hop: nextHop, ttl: ttl, once: once, text: text,
                spec: TargetSpec(intent: replyIntent == .discuss ? .inform : replyIntent, copied: true, cc: ccNames)))
        }
        try persistLocked()
        return .fanout(SendPlan(threadID: thread.id, from: ticket.to, hop: nextHop, hopLimit: thread.hopLimit,
                                stopped: false, unresolved: [], notice: notice, targets: targets,
                                intent: replyIntent, hints: hints.isEmpty ? nil : hints, closed: closed))
    }

    private func probeReplyLocked(_ replyID: String) throws -> WaitProbe {
        if !LightTokens.isValid(replyID, prefix: "r") {
            try rejectLocked(replyID, reason: "malformed")
            return .unknown
        }
        guard let ticket = ledger[replyID] else {
            try rejectLocked(replyID, reason: "unknown")
            return .unknown
        }
        if ticket.expiresAt <= now() {
            return .expired
        }
        if ticket.consumed {
            return .pending
        }
        // No reply is expected (FYI, answer, cc, recorded, webhook): session text is not a reply.
        if ticket.harvest == false {
            return .pending
        }
        guard let member = members[ticket.to] else { return .pending }
        // Waiting on a human: its session text is not an answer yet.
        if heldLocked(member.name) != nil { return .pending }
        return .readable(member, ticket.issuedAt)
    }

    private func loggedReply(_ replyID: String) throws -> String? {
        sync {
            guard let ticket = ledger[replyID] else { return nil }
            return logs[ticket.threadID]?.last { $0.kind == .message && $0.replyTo == replyID }?.text
        }
    }

    /// The reply-id issued back to the waiting member for the answer to `replyID`.
    private func nextReplyID(after replyID: String) -> String? {
        sync {
            guard let ticket = ledger[replyID], let log = logs[ticket.threadID],
                  let index = log.lastIndex(where: { $0.kind == .message && $0.replyTo == replyID }) else { return nil }
            return log[(index + 1)...].first { $0.kind == .delivery && $0.to == ticket.from }?.replyID
        }
    }

    private func claimNextLocked(skipping blocked: Set<String>) -> Claim? {
        parkOfflineOutboxLocked()
        for (index, item) in outbox.enumerated() {
            if blocked.contains(item.to) || inflight.contains(item.to) { continue }
            if heldLocked(item.to) != nil { continue }
            guard let member = members[item.to] else { continue }
            if ledger[item.replyID] == nil { continue }
            outbox.remove(at: index)
            inflight.insert(item.to)
            return Claim(index: index, item: item, member: member)
        }
        return nil
    }

    private func finishClaimLocked(_ claim: Claim, result: LightDriveResult, blocked: inout Set<String>) -> Bool {
        inflight.remove(claim.item.to)
        if result.state == .busy {
            let index = min(claim.index, outbox.count)
            outbox.insert(claim.item, at: index)
            blocked.insert(claim.item.to)
            return false
        }
        if result.state == .offline, let member = members[claim.item.to] {
            _ = try? enqueueNodeJobLocked(id: claim.item.replyID, node: member.host, kind: "deliver",
                                          payload: claim.item.body)
            blocked.insert(claim.item.to)
            return false
        }
        let state = Self.deliveryState(result.state)
        try? appendDeliveryLocked(threadID: claim.item.threadID, to: claim.item.to, replyID: claim.item.replyID,
                                 state: state, route: result.route, fallback: result.fallback,
                                 liveVerified: result.liveVerified, header: claim.item.header, hop: claim.item.hop)
        return state == .delivered || state == .deferred
    }

    private struct ExpireReport {
        var expiredReplies: Int
        var expiredQueued: Int
        var notices: Int
        var expiredInbox: Int
        var expiredAttention: Int = 0
    }

    private func expireLocked() -> ExpireReport {
        let moment = now()
        let lapsed = attention.filter { $0.value.expiresAt <= moment }.map(\.key)
        for name in lapsed { attention[name] = nil }
        var expiredReplies = 0
        var expiredQueued = 0
        var notices = 0
        var expiredInbox = 0
        let staleInbox = inbox.filter { $0.expiresAt <= moment }
        if !staleInbox.isEmpty {
            let staleIDs = Set(staleInbox.map(\.id))
            inbox.removeAll { staleIDs.contains($0.id) }
            expiredInbox = staleInbox.count
        }
        let staleApplied = appliedJobs.filter { $0.value.addingTimeInterval(limits.queueTTL) <= moment }
        for id in staleApplied.keys { appliedJobs[id] = nil }
        let stale = outbox.filter { item in
            item.expiresAt <= moment || (ledger[item.replyID]?.expiresAt ?? .distantPast) <= moment
        }
        for item in stale {
            outbox.removeAll { $0.replyID == item.replyID }
            ledger[item.replyID] = nil
            expiredQueued += 1
            let thread = threads[item.threadID]
            let owner = thread?.originator
            let notice = "Queued message for \(item.to) expired before delivery."
            if let thread {
                try? appendLocked(LightLogEntry(
                    id: try tokenLocked("m"), kind: .notice, threadID: thread.id, from: owner, text: notice,
                    to: owner, at: moment
                ))
                try? appendDeliveryLocked(threadID: thread.id, to: item.to, replyID: item.replyID, state: .expired,
                                         route: nil, fallback: false, liveVerified: false, header: item.header,
                                         hop: item.hop)
                notices += 1
            }
        }
        let dead = ledger.values.filter { $0.expiresAt <= moment }
        for ticket in dead {
            ledger[ticket.replyID] = nil
            expiredReplies += 1
        }
        if expiredQueued > 0 || expiredReplies > 0 || expiredInbox > 0 || !staleApplied.isEmpty || !lapsed.isEmpty {
            try? persistLocked()
        }
        return ExpireReport(expiredReplies: expiredReplies, expiredQueued: expiredQueued, notices: notices,
                            expiredInbox: expiredInbox, expiredAttention: lapsed.count)
    }

    private func headerLocked(from: String, thread: LightThread, replyID: String, hop: Int, spec: TargetSpec) -> String {
        var tag = "[pharos from=\(from) thread=\(thread.id) reply-id=\(replyID) hop=\(hop)/\(thread.hopLimit) intent=\(spec.intent.rawValue)"
        if spec.copied { tag += " cc" }
        if let round = spec.round { tag += " round=\(round)/\(thread.rounds ?? Self.defaultDiscussRounds)" }
        tag += "]"
        var lines = [tag]
        if spec.terminal || spec.record { return tag }
        let command = "`pharos reply \(replyID) \"...\"`"
        let harvest = "Pharos reads this session if you cannot run that command. After answering with pharos reply, say nothing about it in your own chat (not even that you replied) unless someone asks."
        if spec.conclusion {
            lines.append("The discussion is closed (\(spec.note ?? "ended")). Reply with a one-line conclusion: \(command). It is recorded in the thread, not sent to anyone. \(harvest)")
        } else if spec.copied {
            lines.append("You are copied. This is an FYI; do not reply unless you need clarification.")
        } else {
            switch spec.intent {
            case .ask:
                lines.append("Reply with \(command). \(harvest)")
            case .inform:
                lines.append("This is an FYI; do not reply unless you need clarification.")
            case .answer:
                lines.append("This is an answer; do not reply unless you need clarification.")
            case .discuss:
                lines.append("Discussion: reply with \(command) only if you add something new; otherwise answer DONE. \(harvest)")
            }
        }
        if spec.expectsReply, let webhook {
            lines.append("Or POST {\"replyId\":\"\(replyID)\",\"text\":\"...\"} to \(webhook).")
        }
        return lines.joined(separator: "\n")
    }

    private func rejectLocked(_ replyID: String, reason: String, threadID: String? = nil) throws {
        let entry = LightRejection(replyID: replyID, reason: reason, at: now())
        rejectionLog.append(entry)
        try appendRejectionLocked(entry)
        if let threadID, threads[threadID] != nil {
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .notice, threadID: threadID, text: "rejected reply-id \(replyID): \(reason)",
                replyID: replyID, at: now()
            ))
        }
        try persistLocked()
    }

    private func appendDeliveryLocked(threadID: String, to: String, replyID: String, state: LightDeliveryState,
                                      route: String?, fallback: Bool, liveVerified: Bool, header: String, hop: Int) throws {
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .delivery, threadID: threadID, text: state.rawValue,
            hop: hop, to: to, replyID: replyID, state: state, route: route, fallback: fallback,
            liveVerified: liveVerified, header: header, at: now()
        ))
        try persistLocked()
    }

    private func appendLocked(_ entry: LightLogEntry) throws {
        logs[entry.threadID, default: []].append(entry)
        let url = logURL(entry.threadID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(entry) + Data([0x0A])
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
        chmod(url.path, 0o600)
    }

    private func tokenLocked(_ prefix: String) throws -> String {
        for _ in 0..<8 {
            let token = makeToken(prefix)
            if LightTokens.isValid(token, prefix: prefix) { return token }
        }
        throw LightRelayError.corruptStore("token generator")
    }

    /// One writer at a time across processes too: a CLI send, the node's background
    /// poller and a forwarded reply share this store. Under the file lock the state is
    /// reloaded when another process changed it, so no update is lost to a stale snapshot.
    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let fd = open(store.appendingPathComponent(".lock").path, O_RDWR | O_CREAT, 0o600)
        if fd >= 0 { _ = flock(fd, LOCK_EX) }
        defer {
            stamp = stateStamp()
            if fd >= 0 { _ = flock(fd, LOCK_UN); close(fd) }
        }
        let current = stateStamp()
        if current != stamp { try? reloadLocked() }
        return try body()
    }

    private struct StateStamp: Equatable {
        var modified: Double
        var size: Int64
        var inode: UInt64
    }

    private var stamp: StateStamp?

    private func stateStamp() -> StateStamp? {
        var info = stat()
        guard stat(stateURL.path, &info) == 0 else { return nil }
        #if canImport(Darwin)
        let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        #else
        let modified = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
        #endif
        return StateStamp(modified: modified, size: Int64(info.st_size), inode: UInt64(info.st_ino))
    }

    private func reloadLocked() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        logs = [:]
        try load()
    }

    private static func deliveryState(_ state: LightDriveResult.State) -> LightDeliveryState {
        switch state {
        case .delivered: .delivered
        case .busy: .queued
        case .offline: .queued
        case .deferred: .deferred
        case .failed: .failed
        }
    }

    private func viewLocked(_ thread: LightThread) -> LightThreadView {
        let people = participantsLocked(thread)
        let kind: LightThreadKind = people.count >= 3 ? .group : .direct
        return LightThreadView(thread: thread, participants: people, kind: kind)
    }

    /// Originator, then each sender and each delivery target, first time seen.
    /// Only registered members count. The list is not written to the snapshot.
    private func participantsLocked(_ thread: LightThread) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func add(_ name: String?) {
            guard let name, members[name] != nil, seen.insert(name).inserted else { return }
            out.append(name)
        }
        add(thread.originator)
        for entry in logs[thread.id] ?? [] {
            switch entry.kind {
            case .message: add(entry.from)
            case .delivery: add(entry.to)
            case .notice: break
            }
        }
        return out
    }

    static func validateName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw LightRelayError.invalidName(value)
        }
        return value
    }

    static func validateLabel(_ raw: String, failure: (String) -> LightRelayError) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw failure(value)
        }
        return value
    }

    static func validateProject(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z0-9][a-z0-9_-]{0,62}$"#, options: .regularExpression) != nil else {
            throw LightRelayError.invalidProject(value)
        }
        return value
    }

    private static func validateSession(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil,
              !value.contains("/"), !value.contains("~"), !value.contains("@") else {
            throw LightRelayError.invalidSession(value)
        }
        return value
    }

    private func nodeStatusLocked(_ host: String) -> LightNodeStatus {
        // Router caches the roster for 5s, keeping lock hold time bounded.
        if let liveness, let status = liveness.nodeStatus(host), let seen = status.lastSeen {
            let online = now().timeIntervalSince(seen) < Self.nodeHeartbeatWindow
            if seen > (nodeSeen[host] ?? .distantPast) {
                nodeSeen[host] = seen
            }
            return LightNodeStatus(host: status.host, online: online, lastSeen: seen)
        }
        guard let seen = nodeSeen[host] else {
            return LightNodeStatus(host: host, online: false, lastSeen: nil)
        }
        let online = now().timeIntervalSince(seen) < Self.nodeHeartbeatWindow
        return LightNodeStatus(host: host, online: online, lastSeen: seen)
    }

    private func enqueueNodeJobLocked(id explicit: String?, node: String, kind: String, payload: String,
                                      persist: Bool = true) throws -> LightEnqueueResult {
        let name = try Self.validateLabel(node, failure: LightRelayError.invalidHost)
        let trimmedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKind.isEmpty, trimmedKind.count <= 64 else { throw LightRelayError.invalidJob(kind) }
        let id: String
        if let explicit {
            guard Self.isJobID(explicit) else { throw LightRelayError.invalidJob(explicit) }
            id = explicit
        } else {
            id = try tokenLocked("n")
        }
        if let existing = inbox.first(where: { $0.id == id }) {
            return LightEnqueueResult(job: existing, duplicate: true)
        }
        if appliedJobs[id] != nil {
            let ghost = LightNodeJob(id: id, node: name, kind: trimmedKind, payload: payload, enqueuedAt: now(),
                                    expiresAt: now(), deliveries: 0)
            return LightEnqueueResult(job: ghost, duplicate: true)
        }
        let issued = now()
        let job = LightNodeJob(id: id, node: name, kind: trimmedKind, payload: payload, enqueuedAt: issued,
                               expiresAt: issued.addingTimeInterval(limits.queueTTL), deliveries: 0)
        inbox.append(job)
        if persist { try persistLocked() }
        return LightEnqueueResult(job: job, duplicate: false)
    }

    private func collectPullLocked(_ node: String) throws -> [LightNodeJob] {
        let moment = now()
        let expired = inbox.filter { $0.expiresAt <= moment }
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            inbox.removeAll { ids.contains($0.id) }
        }
        var handed: [LightNodeJob] = []
        for index in inbox.indices where inbox[index].node == node {
            inbox[index].deliveries += 1
            handed.append(inbox[index])
        }
        return handed
    }

    private func parkOfflineOutboxLocked() {
        var kept: [OutboxItem] = []
        var moved = false
        for item in outbox {
            // Held for a human: stays in the outbox whatever the node's liveness says.
            if let member = members[item.to], heldLocked(member.name) == nil {
                let status = nodeStatusLocked(member.host)
                if status.lastSeen != nil && !status.online {
                    do {
                        _ = try enqueueNodeJobLocked(id: item.replyID, node: member.host, kind: "deliver",
                                                     payload: item.body, persist: false)
                        moved = true
                        continue
                    } catch {
                        kept.append(item)
                        continue
                    }
                }
            }
            kept.append(item)
        }
        if moved {
            outbox = kept
            try? persistLocked()
        }
    }

    private static func isJobID(_ value: String) -> Bool {
        LightTokens.isValid(value, prefix: "n")
            || LightTokens.isValid(value, prefix: "q")
            || LightTokens.isValid(value, prefix: "r")
    }

    // MARK: Disk

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    private var stateURL: URL { store.appendingPathComponent("state.json") }
    private func logURL(_ threadID: String) -> URL {
        store.appendingPathComponent("logs", isDirectory: true).appendingPathComponent(threadID + ".jsonl")
    }
    private var rejectionURL: URL { store.appendingPathComponent("rejections.jsonl") }

    private func load() throws {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        let data = try Data(contentsOf: stateURL)
        let snapshot: Snapshot
        do {
            snapshot = try Self.makeDecoder().decode(Snapshot.self, from: data)
        } catch {
            throw LightRelayError.corruptStore("state.json")
        }
        guard snapshot.version == 2 || snapshot.version == 3 else { throw LightRelayError.corruptStore("state.json") }
        members = Dictionary(uniqueKeysWithValues: snapshot.members.map { ($0.name, $0) })
        threads = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.id, $0) })
        ledger = Dictionary(uniqueKeysWithValues: snapshot.ledger.map { ($0.replyID, $0) })
        outbox = snapshot.outbox
        inbox = snapshot.inbox
        nodeSeen = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.host, $0.lastSeen) })
        appliedJobs = Dictionary(uniqueKeysWithValues: snapshot.applied.map { ($0.id, $0.at) })
        attention = Dictionary(snapshot.attention.map { ($0.member, $0) }, uniquingKeysWith: { $1 })
        for thread in snapshot.threads {
            logs[thread.id] = try readJSONL(logURL(thread.id))
        }
        rejectionLog = try readJSONL(rejectionURL)
    }

    private func persistLocked() throws {
        let snapshot = Snapshot(version: 3, members: members.values.sorted { $0.name < $1.name },
                                threads: threads.values.sorted { $0.id < $1.id },
                                ledger: ledger.values.sorted { $0.replyID < $1.replyID },
                                outbox: outbox,
                                inbox: inbox.sorted { $0.id < $1.id },
                                nodes: nodeSeen.map { NodeSeen(host: $0.key, lastSeen: $0.value) }.sorted { $0.host < $1.host },
                                applied: appliedJobs.map { AppliedJob(id: $0.key, at: $0.value) }.sorted { $0.id < $1.id },
                                attention: attention.values.sorted { $0.member < $1.member })
        let data = try Self.makeEncoder().encode(snapshot)
        try data.write(to: stateURL, options: .atomic)
        chmod(stateURL.path, 0o600)
    }

    private func appendRejectionLocked(_ entry: LightRejection) throws {
        let data = try Self.makeEncoder().encode(entry) + Data([0x0A])
        if FileManager.default.fileExists(atPath: rejectionURL.path) {
            let handle = try FileHandle(forWritingTo: rejectionURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: rejectionURL, options: .atomic)
        }
        chmod(rejectionURL.path, 0o600)
    }

    private func readJSONL<T: Decodable>(_ url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [T] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8) else { continue }
            if let row = try? Self.makeDecoder().decode(T.self, from: data) {
                rows.append(row)
            }
        }
        return rows
    }
}
