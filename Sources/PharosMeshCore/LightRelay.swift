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

public struct LightMember: Codable, Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var host: String
    public var app: String
    public var project: String
    public var sessionID: String
    public var routes: [LightRoute]

    public init(name: String, host: String, app: String, project: String, sessionID: String, routes: [LightRoute]) {
        self.name = name
        self.host = host
        self.app = app
        self.project = project
        self.sessionID = sessionID
        self.routes = routes
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

    public init(id: String, originator: String, hopLimit: Int, stopped: Bool, createdAt: Date) {
        self.id = id
        self.originator = originator
        self.hopLimit = hopLimit
        self.stopped = stopped
        self.createdAt = createdAt
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

    public init(id: String, kind: LightLogKind, threadID: String, from: String? = nil, text: String,
                mentions: [String] = [], replyTo: String? = nil, hop: Int? = nil, to: String? = nil,
                replyID: String? = nil, state: LightDeliveryState? = nil, route: String? = nil,
                fallback: Bool? = nil, liveVerified: Bool? = nil, header: String? = nil, at: Date) {
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

    public init(to: String, replyID: String, state: LightDeliveryState, route: String?, fallback: Bool,
                liveVerified: Bool, header: String, detail: String) {
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

    public init(threadID: String, from: String, hop: Int, hopLimit: Int, stopped: Bool, forwarded: Bool = false,
                deliveries: [LightDelivery], unresolved: [String], notice: String?) {
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

    public init(replyID: String, status: Status, text: String?, send: LightSendResult?) {
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

    public init(expiredReplies: Int, expiredQueued: Int, flushed: Int, notices: Int, expiredInbox: Int = 0) {
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
    }

    public var state: State
    public var route: String?
    public var fallback: Bool
    /// True only when the adapter itself observed a completed app turn.
    /// The shipped external adapter leaves this false: live app sends are not certified.
    public var liveVerified: Bool
    public var detail: String

    public init(state: State, route: String?, fallback: Bool, liveVerified: Bool, detail: String) {
        self.state = state
        self.route = route
        self.fallback = fallback
        self.liveVerified = liveVerified
        self.detail = detail
    }
}

/// Session wake/read seam. Two adapters make it real: an in-memory fake in tests,
/// and the external planner in PharosRuntime. The relay does not switch on app brand.
public protocol LightSessionDriver: Sendable {
    func deliver(member: LightMember, body: String) -> LightDriveResult
    /// Text the session produced after `since`, only when the adapter can tell
    /// new text from older history. Return nil rather than a stale pane.
    func readReply(member: LightMember, since: Date) -> String?
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

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

/// Non-broker hosts inject a forwarder. Returning nil means this process owns the ledger.
public protocol LightReplyForwarding: Sendable {
    func forward(replyID: String, text: String) -> LightForwardResult?
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

    public init(store: URL,
                now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                makeToken: @escaping @Sendable (String) -> String = { LightTokens.make($0) },
                driver: any LightSessionDriver = IdleLightDriver(),
                forwarder: (any LightReplyForwarding)? = nil,
                webhook: String? = nil,
                limits: LightLimits = LightLimits()) throws {
        self.store = store
        self.now = now
        self.sleep = sleep
        self.makeToken = makeToken
        self.driver = driver
        self.forwarder = forwarder
        self.webhook = try LightWebhook.loopback(webhook)
        self.limits = limits
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        chmod(store.path, 0o700)
        try load()
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

    // MARK: Send / reply

    /// A new message (not a reply). Mints a thread id and delivers one copy to
    /// each recipient. `@` tokens in `text` are body text, not extra recipients.
    public func send(from name: String, to recipients: [String], text: String,
                     ttl: TimeInterval? = nil, once: Bool = false, hopLimit: Int? = nil) throws -> LightSendResult {
        let plan = try sync { () -> SendPlan in
            try planSendLocked(from: name, recipients: recipients, text: text, ttl: ttl, once: once, hopLimit: hopLimit)
        }
        return try fanout(plan)
    }

    public func reply(_ replyID: String, text: String, ttl: TimeInterval? = nil, once: Bool = false) throws -> LightSendResult {
        if let forwarder, let forwarded = forwarder.forward(replyID: replyID, text: text) {
            guard forwarded.ok else { throw LightRelayError.forwardFailed(forwarded.message) }
            return LightSendResult(threadID: "", from: "", hop: 0, hopLimit: 0, stopped: false,
                                   forwarded: true, deliveries: [], unresolved: [], notice: forwarded.message)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LightRelayError.emptyText }
        let decision = try sync { () -> ReplyDecision in
            try decideReplyLocked(replyID, text: trimmed, ttl: ttl, once: once)
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
        var polls = 0
        while true {
            polls += 1
            if let logged = try loggedReply(replyID) {
                return LightWaitResult(replyID: replyID, status: .replied, text: logged, send: nil)
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
                    let send = try reply(replyID, text: text)
                    let logged = try loggedReply(replyID)
                    return LightWaitResult(replyID: replyID, status: .replied, text: logged ?? text, send: send)
                }
            }
            if timeout <= 0 || now().timeIntervalSince(start) >= timeout || polls >= 10_000 {
                return LightWaitResult(replyID: replyID, status: .pending, text: nil, send: nil)
            }
            sleep(0.02)
        }
    }

    @discardableResult
    public func sweep() -> LightSweepReport {
        let report = sync { expireLocked() }
        let flushed = pump()
        return LightSweepReport(expiredReplies: report.expiredReplies, expiredQueued: report.expiredQueued,
                                flushed: flushed, notices: report.notices, expiredInbox: report.expiredInbox)
    }

    // MARK: Node inbox
    //
    // One queue per node, in this same store. A node pulls on heartbeat.
    // Ack removes the job. The queue TTL is the outbox TTL (72h). A second
    // enqueue or ack of the same id does nothing.

    /// Same liveness window the Broker uses when it drops a node heartbeat.
    public static let nodeHeartbeatWindow: TimeInterval = 70

    public static func nodeOfflineMessage(lastSeen: Date?) -> String {
        if let lastSeen {
            return "node offline; last-seen \(Int(lastSeen.timeIntervalSince1970))"
        }
        return "node offline; last-seen never"
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
            let result = driver.deliver(member: claim.member, body: claim.item.body)
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

        private enum CodingKeys: String, CodingKey {
            case version, members, threads, ledger, outbox, inbox, nodes, applied
        }

        init(version: Int, members: [LightMember], threads: [LightThread], ledger: [Ticket],
             outbox: [OutboxItem], inbox: [LightNodeJob], nodes: [NodeSeen], applied: [AppliedJob]) {
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
    }

    private struct PreparedTarget {
        var member: LightMember
        var ticket: Ticket
        var body: String
        var header: String
        var queued: Bool
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
        for target in plan.targets where !target.queued {
            deliveries.append(try deliverNow(target))
        }
        for target in plan.targets where target.queued {
            deliveries.append(queuedDelivery(target))
        }
        _ = pump()
        let refreshed = try refresh(deliveries, threadID: plan.threadID)
        return LightSendResult(threadID: plan.threadID, from: plan.from, hop: plan.hop, hopLimit: plan.hopLimit,
                               stopped: plan.stopped, deliveries: refreshed, unresolved: plan.unresolved,
                               notice: plan.notice)
    }

    private func deliverNow(_ target: PreparedTarget) throws -> LightDelivery {
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
                                 detail: Self.nodeOfflineMessage(lastSeen: parked.lastSeen))
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
        let result = driver.deliver(member: target.member, body: target.body)
        return try sync {
            inflight.remove(target.member.name)
            if result.state == .busy {
                try enqueueLocked(target, routeNote: result.route)
                return queuedDelivery(target, detail: result.detail)
            }
            let state = Self.deliveryState(result.state)
            try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                     replyID: target.ticket.replyID, state: state, route: result.route,
                                     fallback: result.fallback, liveVerified: result.liveVerified,
                                     header: target.header, hop: target.ticket.hop)
            return LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: state,
                                 route: result.route, fallback: result.fallback, liveVerified: result.liveVerified,
                                 header: target.header, detail: result.detail)
        }
    }

    private func queuedDelivery(_ target: PreparedTarget, detail: String = "queued behind the session writer") -> LightDelivery {
        LightDelivery(to: target.member.name, replyID: target.ticket.replyID, state: .queued, route: nil,
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
                                     detail: delivery.detail)
            }
        }
    }

    private func planSendLocked(from name: String, recipients: [String], text: String,
                                ttl: TimeInterval?, once: Bool, hopLimit: Int?) throws -> SendPlan {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LightRelayError.emptyText }
        let sender = try Self.validateName(name)
        guard members[sender] != nil else { throw LightRelayError.unknownMember(sender) }
        let limit = hopLimit ?? limits.hopLimit
        guard limit >= 1 else { throw LightRelayError.invalidLimit }
        var targets: [String] = []
        for raw in recipients {
            let id = try Self.validateName(raw)
            if id == sender { continue }
            guard members[id] != nil else { throw LightRelayError.unknownMember(id) }
            if !targets.contains(id) { targets.append(id) }
        }
        guard !targets.isEmpty else { throw LightRelayError.noRecipients }
        let thread = LightThread(id: try tokenLocked("t"), originator: sender, hopLimit: limit,
                                 stopped: false, createdAt: now())
        threads[thread.id] = thread
        logs[thread.id] = []
        let mentions = LightMentions.tokens(in: trimmed)
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: sender, text: trimmed,
            mentions: mentions, hop: 1, at: now()
        ))
        var prepared: [PreparedTarget] = []
        for target in targets {
            guard let member = members[target] else { throw LightRelayError.unknownMember(target) }
            prepared.append(try prepareTargetLocked(member: member, from: sender, thread: thread, hop: 1,
                                                   ttl: ttl, once: once, text: trimmed, terminal: false))
        }
        try persistLocked()
        return SendPlan(threadID: thread.id, from: sender, hop: 1, hopLimit: thread.hopLimit, stopped: false,
                        unresolved: [], notice: nil, targets: prepared)
    }

    private func prepareTargetLocked(member: LightMember, from: String, thread: LightThread, hop: Int,
                                     ttl: TimeInterval?, once: Bool, text: String, terminal: Bool) throws -> PreparedTarget {
        let replyTTL = ttl ?? limits.replyTTL
        let issued = now()
        let replyID = try tokenLocked("r")
        let ticket = Ticket(replyID: replyID, threadID: thread.id, from: from, to: member.name, hop: hop,
                            expiresAt: issued.addingTimeInterval(replyTTL), once: once, consumed: false,
                            terminal: terminal, issuedAt: issued)
        ledger[replyID] = ticket
        let header = headerLocked(from: from, thread: thread.id, replyID: replyID, hop: hop, limit: thread.hopLimit)
        let body = text + "\n\n" + header
        let queued = outbox.contains(where: { $0.to == member.name }) || inflight.contains(member.name)
        if queued {
            let target = PreparedTarget(member: member, ticket: ticket, body: body, header: header, queued: true)
            try enqueueLocked(target, routeNote: nil)
            return target
        }
        return PreparedTarget(member: member, ticket: ticket, body: body, header: header, queued: false)
    }

    private func enqueueLocked(_ target: PreparedTarget, routeNote: String?) throws {
        if outbox.contains(where: { $0.replyID == target.ticket.replyID }) {
            return
        }
        let item = OutboxItem(id: try tokenLocked("q"), threadID: target.ticket.threadID, to: target.member.name,
                              replyID: target.ticket.replyID, body: target.body, header: target.header,
                              hop: target.ticket.hop, fallbackRoute: routeNote, enqueuedAt: now(),
                              expiresAt: now().addingTimeInterval(limits.queueTTL))
        outbox.append(item)
        try appendDeliveryLocked(threadID: target.ticket.threadID, to: target.member.name,
                                 replyID: target.ticket.replyID, state: .queued, route: routeNote,
                                 fallback: false, liveVerified: false, header: target.header, hop: target.ticket.hop)
    }

    private func decideReplyLocked(_ replyID: String, text: String, ttl: TimeInterval?, once: Bool) throws -> ReplyDecision {
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
        if ticket.terminal {
            ticket.consumed = true
            ledger[replyID] = ticket
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
                replyTo: replyID, hop: ticket.hop, at: now()
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
        let nextHop = ticket.hop + 1
        if nextHop > thread.hopLimit {
            ticket.consumed = true
            ledger[replyID] = ticket
            thread.stopped = true
            threads[thread.id] = thread
            let notice = "Hop limit \(thread.hopLimit) reached. Thread stopped. Last reply from \(ticket.to): \(text)"
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
                replyTo: replyID, hop: ticket.hop, at: now()
            ))
            try appendLocked(LightLogEntry(
                id: try tokenLocked("m"), kind: .notice, threadID: thread.id, from: thread.originator, text: notice,
                to: thread.originator, at: now()
            ))
            var targets: [PreparedTarget] = []
            if thread.originator != ticket.to, let owner = members[thread.originator] {
                targets.append(try prepareTargetLocked(member: owner, from: ticket.to, thread: thread, hop: ticket.hop,
                                                       ttl: ttl, once: true, text: notice, terminal: true))
            }
            try persistLocked()
            return .fanout(SendPlan(threadID: thread.id, from: ticket.to, hop: ticket.hop, hopLimit: thread.hopLimit,
                                    stopped: true, unresolved: [], notice: notice, targets: targets))
        }
        if ticket.once {
            ticket.consumed = true
        } else {
            ticket.hop = nextHop
        }
        ledger[replyID] = ticket
        threads[thread.id] = thread
        // Always answer the previous sender, then copy each registered @mention.
        // Mentions add deliveries; they do not replace the sender. Unknown tokens
        // stay unresolved. There is no roster, so `@all` is just an unknown name.
        let mentions = LightMentions.tokens(in: text)
        var names: [String] = []
        var unresolved: [String] = []
        if ticket.from != ticket.to, members[ticket.from] != nil {
            names.append(ticket.from)
        }
        for token in mentions where token != ticket.to {
            if members[token] != nil {
                if !names.contains(token) { names.append(token) }
            } else {
                unresolved.append(token)
            }
        }
        try appendLocked(LightLogEntry(
            id: try tokenLocked("m"), kind: .message, threadID: thread.id, from: ticket.to, text: text,
            mentions: mentions, replyTo: replyID, hop: nextHop, at: now()
        ))
        var targets: [PreparedTarget] = []
        for name in names {
            guard let member = members[name] else {
                unresolved.append(name)
                continue
            }
            targets.append(try prepareTargetLocked(member: member, from: ticket.to, thread: thread, hop: nextHop,
                                                   ttl: ttl, once: once, text: text, terminal: false))
        }
        try persistLocked()
        return .fanout(SendPlan(threadID: thread.id, from: ticket.to, hop: nextHop, hopLimit: thread.hopLimit,
                                stopped: false, unresolved: unresolved, notice: nil, targets: targets))
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
        guard let member = members[ticket.to] else { return .pending }
        return .readable(member, ticket.issuedAt)
    }

    private func loggedReply(_ replyID: String) throws -> String? {
        sync {
            guard let ticket = ledger[replyID] else { return nil }
            return logs[ticket.threadID]?.last { $0.kind == .message && $0.replyTo == replyID }?.text
        }
    }

    private func claimNextLocked(skipping blocked: Set<String>) -> Claim? {
        parkOfflineOutboxLocked()
        for (index, item) in outbox.enumerated() {
            if blocked.contains(item.to) || inflight.contains(item.to) { continue }
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
    }

    private func expireLocked() -> ExpireReport {
        let moment = now()
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
        if expiredQueued > 0 || expiredReplies > 0 || expiredInbox > 0 || !staleApplied.isEmpty {
            try? persistLocked()
        }
        return ExpireReport(expiredReplies: expiredReplies, expiredQueued: expiredQueued, notices: notices,
                            expiredInbox: expiredInbox)
    }

    private func headerLocked(from: String, thread: String, replyID: String, hop: Int, limit: Int) -> String {
        var lines = [
            "[pharos from=\(from) thread=\(thread) reply-id=\(replyID) hop=\(hop)/\(limit)]",
            "Reply with `pharos reply \(replyID) \"...\"` (you may @mention another member). Pharos reads this session if you cannot run that command.",
        ]
        if let webhook {
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

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func deliveryState(_ state: LightDriveResult.State) -> LightDeliveryState {
        switch state {
        case .delivered: .delivered
        case .busy: .queued
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

    private static func validateName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw LightRelayError.invalidName(value)
        }
        return value
    }

    private static func validateLabel(_ raw: String, failure: (String) -> LightRelayError) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil else {
            throw failure(value)
        }
        return value
    }

    private static func validateProject(_ raw: String) throws -> String {
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
            if let member = members[item.to] {
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
                                applied: appliedJobs.map { AppliedJob(id: $0.key, at: $0.value) }.sorted { $0.id < $1.id })
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
