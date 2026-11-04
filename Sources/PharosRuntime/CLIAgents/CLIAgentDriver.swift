import Foundation
import PharosMeshCore

/// Per-member cursor written at send time: agy = transcript step index before the send; codex = clientUserMessageId.
public struct CLIReplyCursor: Codable, Equatable, Sendable {
    public var kind: String /* "agy-step" | "codex-client" */
    public var value: String
    public var at: Date

    public init(kind: String, value: String, at: Date) {
        self.kind = kind
        self.value = value
        self.at = at
    }
}

/// Keeps the last few send cursors per member. `match(member:since:)` picks the earliest one written at or
/// after a ticket's send time, so a later send to the same member never answers an earlier ticket.
public final class CLIReplyCursorBook: @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: [CLIReplyCursor]] = [:]
    private let store: URL?
    static let keep = 20

    public init(store: URL? = nil) {
        self.store = store
        if store != nil {
            self.cursors = loadLocked()
        }
    }

    /// The latest cursor written for `member`.
    public func get(member: String) -> CLIReplyCursor? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { cursors = loadLocked() }
        return cursors[member]?.last
    }

    /// The cursor of the first send at or after `since` (5 s skew), if any.
    public func match(member: String, since: Date) -> CLIReplyCursor? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { cursors = loadLocked() }
        let cutoff = since.addingTimeInterval(-5)
        return (cursors[member] ?? []).filter { $0.at >= cutoff }.min { $0.at < $1.at }
    }

    public func set(member: String, _ cursor: CLIReplyCursor) {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { cursors = loadLocked() }
        var list = cursors[member] ?? []
        list.append(cursor)
        if list.count > Self.keep { list.removeFirst(list.count - Self.keep) }
        cursors[member] = list
        saveLocked()
    }

    private func loadLocked() -> [String: [CLIReplyCursor]] {
        guard let store, let data = try? Data(contentsOf: store) else { return [:] }
        if let decoded = try? JSONDecoder().decode([String: [CLIReplyCursor]].self, from: data) { return decoded }
        return [:]
    }

    private func saveLocked() {
        guard let store else { return }
        do {
            let dir = store.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(cursors)
            try data.write(to: store, options: .atomic)
        } catch {}
    }
}

public enum CodexPaneState: Equatable, Sendable {
    case idle
    case busy
    case needsHuman(what: String)
    case unknown
}

public enum CodexPane {
    public static func classify(_ pane: String) -> CodexPaneState {
        if pane.contains("Update available") && (pane.contains("Update now") || pane.contains("Skip until next version")) {
            return .needsHuman(what: "codex update prompt: choose Skip in tmux session")
        }
        if pane.contains("Would you like to run") ||
           pane.contains("Trust this folder?") ||
           pane.contains("Allow command?") ||
           pane.contains("Would you like to make the following edits") {
            return .needsHuman(what: "approval required")
        }
        if pane.contains("esc to interrupt") {
            return .busy
        }
        if pane.contains("›") {
            return .idle
        }
        return .unknown
    }
}

public struct CLIAgentDriver: Sendable {
    public var tmux: TmuxController
    public var daemon: @Sendable () -> CodexDaemonClient?
    public var quota: CLIQuotaBook
    public var cursors: CLIReplyCursorBook
    public var env: [String: String]
    public var home: String
    public var rollouts: CodexRolloutReader
    public var quotaWindow: TimeInterval
    public var pollInterval: TimeInterval
    public var sleep: @Sendable (TimeInterval) -> Void
    public var now: @Sendable () -> Date

    public init(
        tmux: TmuxController,
        daemon: @escaping @Sendable () -> CodexDaemonClient? = { nil },
        quota: CLIQuotaBook = CLIQuotaBook(),
        cursors: CLIReplyCursorBook = CLIReplyCursorBook(),
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        rollouts: CodexRolloutReader = CodexRolloutReader(),
        quotaWindow: TimeInterval = 8,
        pollInterval: TimeInterval = 0.5,
        sleep: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tmux = tmux
        self.daemon = daemon
        self.quota = quota
        self.cursors = cursors
        self.env = env
        let defaultHome = home ?? env["HOME"] ?? NSHomeDirectory()
        self.home = defaultHome
        self.rollouts = rollouts
        self.quotaWindow = quotaWindow
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    public static func handles(_ member: LightMember) -> Bool {
        guard member.tmux != nil else { return false }
        let app = member.app.lowercased()
        return app == "codex" || app == "agy"
    }

    public func deliver(member: LightMember, text: String, replyID: String?) -> LightDriveResult {
        guard let binding = member.tmux else {
            return LightDriveResult(
                state: .failed,
                route: nil,
                fallback: false,
                liveVerified: false,
                detail: "\(member.name) has no tmux binding"
            )
        }

        let descriptor = CLIAgentDescriptor.named(member.app, env: env)
        let live = tmux.liveness(binding)
        guard live.agentAlive else {
            return LightDriveResult(
                state: .failed,
                route: nil,
                fallback: false,
                liveVerified: false,
                detail: "\(member.name)'s tmux session \(binding.session) is \(live.label); run: pharos member revive \(member.name)"
            )
        }

        if member.app.lowercased() == "codex" {
            return deliverCodex(member: member, binding: binding, text: text, replyID: replyID)
        } else if member.app.lowercased() == "agy" {
            return deliverAgy(member: member, binding: binding, text: text, descriptor: descriptor)
        } else {
            return LightDriveResult(
                state: .failed,
                route: nil,
                fallback: false,
                liveVerified: false,
                detail: "unsupported app \(member.app)"
            )
        }
    }

    private func deliverCodex(member: LightMember, binding: LightTmuxBinding, text: String, replyID: String?) -> LightDriveResult {
        if let client = daemon() {
            do {
                let info = try client.readThread(member.sessionID)
                if info.status == .notLoaded || info.status == .systemError {
                    return deliverCodexTUI(member: member, binding: binding, text: text, replyID: replyID, fallbackReason: "status is \(info.status)")
                }
                let clientID = replyID ?? "pharos-\(UUID().uuidString)"
                let submissionID = try client.queueAdd(thread: member.sessionID, text: text, clientID: clientID)
                cursors.set(member: member.name, CLIReplyCursor(kind: "codex-client", value: clientID, at: now()))
                var detail = "queued \(submissionID)"
                if info.status.needsHuman {
                    detail += " (thread waiting on a human)"
                } else if info.status.busy {
                    detail += " (thread busy)"
                }
                return LightDriveResult(
                    state: .delivered,
                    route: "daemon",
                    fallback: false,
                    liveVerified: false,
                    detail: detail
                )
            } catch {
                return deliverCodexTUI(member: member, binding: binding, text: text, replyID: replyID, fallbackReason: error.localizedDescription)
            }
        } else {
            return deliverCodexTUI(member: member, binding: binding, text: text, replyID: replyID, fallbackReason: "daemon unavailable")
        }
    }

    private func deliverCodexTUI(member: LightMember, binding: LightTmuxBinding, text: String, replyID: String?, fallbackReason: String) -> LightDriveResult {
        // Visible screen only: an approval that was answered earlier may still sit in the scrollback.
        let capture = tmux.capture(binding.session) ?? ""
        let paneState = CodexPane.classify(capture)
        switch paneState {
        case .busy:
            return LightDriveResult(
                state: .busy,
                route: "tui",
                fallback: true,
                liveVerified: false,
                detail: "codex is busy"
            )
        case .needsHuman(let what):
            return LightDriveResult(
                state: .busy,
                route: "tui",
                fallback: true,
                liveVerified: false,
                detail: "needs_human: \(what)"
            )
        case .idle, .unknown:
            guard tmux.sendText(binding.session, text) else {
                return LightDriveResult(
                    state: .failed,
                    route: "tui",
                    fallback: true,
                    liveVerified: false,
                    detail: "failed to send text to tmux session \(binding.session)"
                )
            }
            // No daemon turn id on this path: the envelope's reply-id ties the answer to this send.
            cursors.set(member: member.name, CLIReplyCursor(kind: "codex-marker", value: replyID.map { "reply-id=\($0)" } ?? "", at: now()))
            return LightDriveResult(
                state: .delivered,
                route: "tui",
                fallback: true,
                liveVerified: false,
                detail: "sent keys via tmux (\(fallbackReason))"
            )
        }
    }

    private func deliverAgy(member: LightMember, binding: LightTmuxBinding, text: String, descriptor: CLIAgentDescriptor?) -> LightDriveResult {
        let capture = tmux.capture(binding.session, lines: 100) ?? ""
        let paneState = AgyPane.classify(capture)
        switch paneState {
        case .busy:
            return LightDriveResult(
                state: .busy,
                route: "tui",
                fallback: false,
                liveVerified: false,
                detail: "agy is working"
            )
        case .needsHuman(let what):
            return LightDriveResult(
                state: .busy,
                route: "tui",
                fallback: false,
                liveVerified: false,
                detail: "needs_human: \(what)"
            )
        case .quota(let resetsIn):
            let model = binding.model ?? descriptor?.modelChain.first ?? "default"
            let until = now().addingTimeInterval(resetsIn ?? 3600)
            quota.mark(app: "agy", model: model, until: until)
            let isoDate = ISO8601DateFormatter().string(from: until)
            let nextPick = quota.pick(app: "agy", chain: descriptor?.modelChain ?? []) ?? "none"
            return LightDriveResult(
                state: .deferred,
                route: "tui",
                fallback: false,
                liveVerified: false,
                detail: "agy quota reached on \(model) until \(isoDate); next model: \(nextPick) (pharos member revive \(member.name) switches)"
            )
        case .idle, .unknown:
            break
        }

        let transcriptPath = descriptor?.transcriptPath(sessionID: member.sessionID, home: home)
        let steps: [AgyStep]
        if let transcriptPath {
            steps = AgyTranscript.load(URL(fileURLWithPath: transcriptPath))
        } else {
            steps = []
        }
        // agy restarts step_index at 0 when a TUI resumes a conversation, so the cursor is the
        // record count ("agy-line"), not the highest step index.
        let cursorCount = steps.count
        cursors.set(member: member.name, CLIReplyCursor(kind: "agy-line", value: "\(cursorCount)", at: now()))

        guard tmux.sendText(binding.session, text) else {
            return LightDriveResult(
                state: .failed,
                route: "tui",
                fallback: false,
                liveVerified: false,
                detail: "failed to send text to tmux session \(binding.session)"
            )
        }

        let watchStart = now()
        while now().timeIntervalSince(watchStart) < quotaWindow {
            sleep(pollInterval)
            let polledText = tmux.capture(binding.session, lines: 100) ?? ""
            let polledState = AgyPane.classify(polledText)

            if case .quota(let resetsIn) = polledState {
                let model = binding.model ?? descriptor?.modelChain.first ?? "default"
                let until = now().addingTimeInterval(resetsIn ?? 3600)
                quota.mark(app: "agy", model: model, until: until)
                let isoDate = ISO8601DateFormatter().string(from: until)
                let nextPick = quota.pick(app: "agy", chain: descriptor?.modelChain ?? []) ?? "none"
                return LightDriveResult(
                    state: .deferred,
                    route: "tui",
                    fallback: false,
                    liveVerified: false,
                    detail: "agy quota reached on \(model) until \(isoDate); next model: \(nextPick) (pharos member revive \(member.name) switches)"
                )
            }

            if polledState == .busy {
                return LightDriveResult(
                    state: .delivered,
                    route: "tui",
                    fallback: false,
                    liveVerified: false,
                    detail: "sent keys via tmux"
                )
            }

            if let transcriptPath {
                let latestSteps = AgyTranscript.load(URL(fileURLWithPath: transcriptPath))
                if latestSteps.count > cursorCount {
                    return LightDriveResult(
                        state: .delivered,
                        route: "tui",
                        fallback: false,
                        liveVerified: false,
                        detail: "sent keys via tmux"
                    )
                }
            }
        }

        return LightDriveResult(
            state: .delivered,
            route: "tui",
            fallback: false,
            liveVerified: false,
            detail: "sent keys via tmux"
        )
    }

    public func readReply(member: LightMember, since: Date) -> String? {
        if member.app.lowercased() == "codex" {
            var clientID: String? = nil
            let cursor = cursors.match(member: member.name, since: since)
            if let cursor, cursor.kind == "codex-client", !cursor.value.isEmpty {
                clientID = cursor.value
            }
            // Sent by typing into the TUI: read the answer to the turn that carried our reply-id,
            // so queued sends flushed back to back do not all take the first answer after `since`.
            if let cursor, cursor.kind == "codex-marker", !cursor.value.isEmpty {
                let hit = rollouts.reply(sessionID: member.sessionID, afterMarker: cursor.value)
                if hit.found { return hit.text }
            }

            if let client = daemon() {
                do {
                    let turns = try client.turns(thread: member.sessionID, limit: 10)
                    return CodexDaemonClient.reply(in: turns, clientID: clientID, since: since)
                } catch {
                    return rollouts.firstCompletedReply(sessionID: member.sessionID, since: since)
                }
            } else {
                return rollouts.firstCompletedReply(sessionID: member.sessionID, since: since)
            }
        } else if member.app.lowercased() == "agy" {
            let descriptor = CLIAgentDescriptor.named("agy", env: env)
            guard let path = descriptor?.transcriptPath(sessionID: member.sessionID, home: home) else {
                return nil
            }
            let steps = AgyTranscript.load(URL(fileURLWithPath: path))
            guard !steps.isEmpty else { return nil }

            if let cursor = cursors.match(member: member.name, since: since),
               cursor.kind == "agy-line", let count = Int(cursor.value), count <= steps.count {
                let newer = Array(steps.dropFirst(count))
                return AgyTranscript.reply(after: Int.min, in: newer)?.text
            } else if let cursor = cursors.match(member: member.name, since: since),
               cursor.kind == "agy-step", let stepIndex = Int(cursor.value) {
                let reply = AgyTranscript.reply(after: stepIndex, in: steps)
                return reply?.text
            } else {
                let reply = AgyTranscript.reply(since: since, in: steps)
                return reply?.text
            }
        } else {
            return nil
        }
    }
}

public struct CLIAgentAttentionSource: HumanAttentionSource {
    public var driver: CLIAgentDriver
    public var isLocal: @Sendable (LightMember) -> Bool
    public var hostLabel: String

    public init(driver: CLIAgentDriver, isLocal: @escaping @Sendable (LightMember) -> Bool, hostLabel: String = "local") {
        self.driver = driver
        self.isLocal = isLocal
        self.hostLabel = hostLabel
    }

    public func poll(members: [LightMember]) -> [LightAttentionReport] {
        var reports: [LightAttentionReport] = []
        for member in members where isLocal(member) && member.tmux != nil && CLIAgentDriver.handles(member) {
            guard let binding = member.tmux else { continue }
            let live = driver.tmux.liveness(binding)
            guard live.agentAlive else { continue }

            if member.app.lowercased() == "codex" {
                if let client = driver.daemon() {
                    if let info = try? client.readThread(member.sessionID) {
                        if info.status.needsHuman {
                            var what = "waiting on approval"
                            if case .active(let flags) = info.status {
                                if flags.contains("waitingOnUserInput") {
                                    what = "waiting on user input"
                                }
                            }
                            reports.append(
                                LightAttentionReport(
                                    state: .needsHuman,
                                    what: what,
                                    sessionID: member.sessionID,
                                    app: member.app,
                                    host: hostLabel,
                                    source: "daemon"
                                )
                            )
                        } else {
                            reports.append(
                                LightAttentionReport(
                                    state: .clear,
                                    what: "",
                                    sessionID: member.sessionID,
                                    app: member.app,
                                    host: hostLabel,
                                    source: "daemon"
                                )
                            )
                        }
                    }
                }
            } else if member.app.lowercased() == "agy" {
                let text = driver.tmux.capture(binding.session, lines: 40) ?? ""
                let state = AgyPane.classify(text)
                switch state {
                case .needsHuman(let what):
                    reports.append(
                        LightAttentionReport(
                            state: .needsHuman,
                            what: what,
                            sessionID: member.sessionID,
                            app: member.app,
                            host: hostLabel,
                            source: "tui"
                        )
                    )
                case .idle, .busy, .quota:
                    reports.append(
                        LightAttentionReport(
                            state: .clear,
                            what: "",
                            sessionID: member.sessionID,
                            app: member.app,
                            host: hostLabel,
                            source: "tui"
                        )
                    )
                case .unknown:
                    break
                }
            }
        }
        return reports
    }
}
