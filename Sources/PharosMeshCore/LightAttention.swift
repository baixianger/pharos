import Foundation

// MARK: - needs_human
//
// An agent is waiting on a human (an approval prompt the agent itself raised).
// Pharos only records and reports it: nobody approves or denies through Pharos.
// While the state is active, messages to that member are queued and Pharos does
// not read its session for an answer. The state clears when the agent proceeds
// (a hook or poll says so, or the member runs `pharos reply`) or when its TTL ends.
// The relay is brand-blind: sources (per-app hooks, achat pending polls) normalize
// to `LightAttentionReport` before they reach it.

public enum LightAttentionState: String, Codable, Sendable {
    case needsHuman = "needs_human"
    case clear

    public static func parse(_ raw: String?) -> LightAttentionState? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "needs_human", "needs-human", "needshuman", "blocked": return .needsHuman
        case "clear", "cleared", "proceed", "proceeded", "none": return .clear
        default: return nil
        }
    }
}

/// One normalized observation: `{state, what, sessionId, app, host, ts}`.
public struct LightAttentionReport: Codable, Equatable, Sendable {
    public var state: LightAttentionState
    /// What the agent is waiting on, e.g. `Bash: rm -rf build`. Shown, never acted on.
    public var what: String
    public var sessionID: String
    /// App label as the member was registered (`codex`, `dsh`, …). Empty matches any app.
    public var app: String
    /// Machine the agent runs on, as the source reports it.
    public var host: String
    /// When the source saw it. Nil means now.
    public var at: Date?
    /// How long the state holds without a refresh. Nil uses `LightAttention.defaultTTL`.
    public var ttl: TimeInterval?
    /// `hook` (pushed by the app) or `poll` (read by Pharos). A poll's clear does not
    /// clear a hook's state; a hook's clear clears either.
    public var source: String

    public init(state: LightAttentionState, what: String = "", sessionID: String, app: String = "", host: String = "",
                at: Date? = nil, ttl: TimeInterval? = nil, source: String = "hook") {
        self.state = state
        self.what = what
        self.sessionID = sessionID
        self.app = app
        self.host = host
        self.at = at
        self.ttl = ttl
        self.source = source
    }
}

/// The recorded state for one member.
public struct LightAttention: Codable, Equatable, Sendable {
    public var member: String
    public var state: LightAttentionState
    public var what: String
    public var host: String
    public var sessionID: String
    public var app: String
    public var source: String
    /// First report of this wait.
    public var since: Date
    /// Latest report (a refresh moves `expiresAt`, not `since`).
    public var seen: Date
    public var expiresAt: Date

    public init(member: String, state: LightAttentionState = .needsHuman, what: String, host: String, sessionID: String,
                app: String, source: String, since: Date, seen: Date, expiresAt: Date) {
        self.member = member
        self.state = state
        self.what = what
        self.host = host
        self.sessionID = sessionID
        self.app = app
        self.source = source
        self.since = since
        self.seen = seen
        self.expiresAt = expiresAt
    }

    /// A hook report holds 20 minutes unless refreshed or cleared.
    public static let defaultTTL: TimeInterval = 20 * 60
    /// A poll is refreshed every tick; it lapses quickly when polling stops.
    public static let pollTTL: TimeInterval = 120
    /// `what` is a label, not a transcript.
    public static let whatLimit = 160

    /// `Bash: rm -rf build (host mini, session 01a1…, 2m ago)`
    public func describe(at moment: Date) -> String {
        let label = what.isEmpty ? "approval prompt" : what
        var parts: [String] = []
        if !host.isEmpty { parts.append("host \(host)") }
        parts.append("session \(sessionID)")
        parts.append("\(Self.age(moment.timeIntervalSince(since))) ago")
        return "\(label) (\(parts.joined(separator: ", ")))"
    }

    /// `45s`, `3m`, `2h`, `1d`.
    public static func age(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        if value < 60 { return "\(value)s" }
        if value < 3600 { return "\(value / 60)m" }
        if value < 86_400 { return "\(value / 3600)h" }
        return "\(value / 86_400)d"
    }

    /// One line, newlines folded, at most `whatLimit` characters.
    public static func clip(_ raw: String) -> String {
        let folded = raw.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard folded.count > whatLimit else { return folded }
        return String(folded.prefix(whatLimit - 1)) + "…"
    }
}

public struct LightAttentionOutcome: Codable, Equatable, Sendable {
    public var state: LightAttentionState
    /// Members now recorded as needs_human.
    public var recorded: [String]
    /// Members whose needs_human state this report cleared.
    public var cleared: [String]
    /// No registered member has that session.
    public var unmatched: Bool

    public init(state: LightAttentionState, recorded: [String] = [], cleared: [String] = [], unmatched: Bool = false) {
        self.state = state
        self.recorded = recorded
        self.cleared = cleared
        self.unmatched = unmatched
    }
}
