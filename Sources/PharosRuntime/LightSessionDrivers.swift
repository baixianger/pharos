import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import PharosMeshCore

// External session adapter for the lightweight tier.
//
// Policy is ported from the achat drivers (route order, loopback-only debug
// ports, writer-lock awareness, no approval auto-answer). The relay stays
// brand-blind. Live app turns are not certified from this tree: `liveVerified`
// stays false, and desktop IPC, CDP, and the DSH web lifecycle are planned
// rather than executed. Headless `codex exec resume` and `claude -p --resume`
// can be spawned only when `allowLive` is set; that switch is off unless a
// human turns it on outside CI.

public enum LightRouteOperation: Sendable {
    case send
    case read
}

public struct LightBinaries: Equatable, Sendable {
    public var codex: String
    public var claude: String
    public var dsh: String
    public var tmux: String

    public init(codex: String = "codex", claude: String = "claude", dsh: String = "dsh", tmux: String = "tmux") {
        self.codex = codex
        self.claude = claude
        self.dsh = dsh
        self.tmux = tmux
    }

    public static let names = LightBinaries()

    /// The Codex desktop app ships its CLI here; the Mac usually has no `codex` on PATH.
    public static let bundledCodex = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment,
                                       isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> LightBinaries {
        func pick(_ key: String, _ fallback: String) -> String {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty || value.contains("\n") || value.contains("\0") { return fallback }
            return value
        }
        return LightBinaries(
            codex: pick("PHAROS_CODEX_BIN", isExecutable(bundledCodex) ? bundledCodex : "codex"),
            claude: pick("PHAROS_CLAUDE_BIN", "claude"),
            dsh: pick("PHAROS_DSH_BIN", "dsh"),
            tmux: pick("PHAROS_TMUX_BIN", "tmux")
        )
    }
}

public struct LightInvocation: Equatable, Sendable {
    public var argv: [String]
    public var stdin: String
    public var executable: Bool
    public var fallback: Bool
    public var summary: String
    public var loopback: Bool
    /// Working directory for the spawned process; nil runs in the temporary directory.
    public var cwd: String?

    public init(argv: [String], stdin: String, executable: Bool, fallback: Bool, summary: String, loopback: Bool,
                cwd: String? = nil) {
        self.argv = argv
        self.stdin = stdin
        self.executable = executable
        self.fallback = fallback
        self.summary = summary
        self.loopback = loopback
        self.cwd = cwd
    }
}

public struct LightProcessOutput: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol LightProcessRunning: Sendable {
    func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput
}

public enum LightRouteCatalog {
    public static func defaults(for app: String) -> [LightRoute] {
        switch app {
        case "codex": return codex
        case "dsh": return dsh
        case "claude": return claude
        case "ag": return ag
        case "cursor": return cursor
        default:
            return [LightRoute(id: "native", access: .write, fallback: false, summary: "app-declared native route")]
        }
    }

    public static let codex: [LightRoute] = [
        LightRoute(id: "app-server", access: .write, fallback: false,
                   summary: "headless codex exec resume. Yields if a writer lock is held. Does not answer approval prompts."),
        LightRoute(id: "ipc", access: .write, fallback: false,
                   summary: "desktop IPC, delegated to achat."),
        LightRoute(id: "desktop", access: .write, fallback: false,
                   summary: "desktop CDP on 127.0.0.1, delegated to achat."),
        LightRoute(id: "tmux", access: .write, fallback: true,
                   summary: "last resort: tmux send-keys and capture-pane."),
    ]

    public static let dsh: [LightRoute] = [
        LightRoute(id: "web", access: .write, fallback: false,
                   summary: "dsh web API, delegated to achat. Start on demand with --host 127.0.0.1 --port 0 --no-open, stop after the turn to release the writer lock."),
        LightRoute(id: "desktop", access: .write, fallback: false,
                   summary: "desktop CDP on 127.0.0.1, delegated to achat."),
        LightRoute(id: "files", access: .read, fallback: false,
                   summary: "read-only session files."),
        LightRoute(id: "tmux", access: .write, fallback: true,
                   summary: "last resort: tmux send-keys and capture-pane."),
    ]

    public static let claude: [LightRoute] = [
        LightRoute(id: "headless", access: .write, fallback: false,
                   summary: "claude -p --resume. Does not answer approval prompts."),
        LightRoute(id: "tmux", access: .write, fallback: true,
                   summary: "last resort: tmux send-keys and capture-pane."),
    ]

    public static let ag: [LightRoute] = [
        LightRoute(id: "desktop", access: .write, fallback: false,
                   summary: "desktop CDP on 127.0.0.1, delegated to achat."),
    ]

    /// Design routes for Cursor. Pharos does not spawn `cursor-agent`; achat owns both.
    public static let cursor: [LightRoute] = [
        LightRoute(id: "cursor-agent", access: .write, fallback: false,
                   summary: "headless cursor-agent --resume <id> -p, delegated to achat. Workspace is the folder."),
        LightRoute(id: "desktop", access: .write, fallback: false,
                   summary: "desktop CDP on 127.0.0.1, delegated to achat."),
    ]
}

public enum LightRoutePlanner {
    public static func routes(for member: LightMember) -> [LightRoute] {
        member.routes.isEmpty ? LightRouteCatalog.defaults(for: member.app) : member.routes
    }

    public static func select(member: LightMember, operation: LightRouteOperation) -> LightRoute? {
        let routes = routes(for: member)
        switch operation {
        case .send:
            return routes.first { $0.access == .write }
        case .read:
            let preferred = ["app-server", "files", "headless", "tmux"]
            for id in preferred {
                if let route = routes.first(where: { $0.id == id }) { return route }
            }
            return routes.first
        }
    }

    public static func invocation(member: LightMember, route: LightRoute, body: String, binaries: LightBinaries) -> LightInvocation {
        switch (member.app, route.id) {
        case ("codex", "app-server"):
            return LightInvocation(
                argv: [binaries.codex, "exec", "resume", member.sessionID, "-", "--json", "--skip-git-repo-check"],
                stdin: body,
                executable: true,
                fallback: false,
                summary: route.summary,
                loopback: false
            )
        case ("claude", "headless"):
            return LightInvocation(
                argv: [binaries.claude, "-p", "--resume", member.sessionID],
                stdin: body,
                executable: true,
                fallback: false,
                summary: route.summary,
                loopback: false
            )
        case ("dsh", "web"):
            return LightInvocation(
                argv: [binaries.dsh, "--profile", "web", "--no-open", "--port", "0", "--host", "127.0.0.1"],
                stdin: "",
                executable: false,
                fallback: false,
                summary: route.summary,
                loopback: true
            )
        case (_, "desktop"), ("ag", "desktop"), ("codex", "desktop"), ("dsh", "desktop"):
            return LightInvocation(
                argv: [],
                stdin: "",
                executable: false,
                fallback: false,
                summary: route.summary,
                loopback: true
            )
        case (_, "ipc"):
            return LightInvocation(argv: [], stdin: "", executable: false, fallback: false, summary: route.summary, loopback: true)
        case (_, "tmux"):
            return LightInvocation(
                argv: [binaries.tmux, "send-keys", "-t", member.sessionID, "-l", body, "Enter"],
                stdin: "",
                executable: true,
                fallback: true,
                summary: route.summary,
                loopback: false
            )
        case (_, "files"):
            return LightInvocation(argv: [], stdin: "", executable: false, fallback: false, summary: route.summary, loopback: false)
        default:
            return LightInvocation(argv: [], stdin: "", executable: false, fallback: route.fallback, summary: route.summary, loopback: false)
        }
    }

    /// Read-shaped argv. Not used to ingest replies: a pane dump cannot prove the text is new.
    public static func readInvocation(member: LightMember, route: LightRoute, binaries: LightBinaries) -> LightInvocation {
        if route.id == "tmux" {
            return LightInvocation(
                argv: [binaries.tmux, "capture-pane", "-t", member.sessionID, "-p"],
                stdin: "",
                executable: true,
                fallback: true,
                summary: route.summary,
                loopback: false
            )
        }
        return LightInvocation(argv: [], stdin: "", executable: false, fallback: route.fallback,
                               summary: route.summary, loopback: route.id == "desktop" || route.id == "web")
    }
}

public struct ExternalLightDriver: LightSessionDriver {
    public var allowLive: Bool
    public var runner: (any LightProcessRunning)?
    public var binaries: LightBinaries
    /// Local Codex session store. When set, a headless resume runs in the session's
    /// recorded cwd, and `readReply` returns the turn's final message from the rollout.
    public var codexSessions: CodexRolloutReader?
    /// `achat` executable. Desktop, IPC, and web routes delegate send/read here.
    public var achat: String
    let replyFloor: AchatReplyFloor

    public init(allowLive: Bool = false, runner: (any LightProcessRunning)? = nil, binaries: LightBinaries = .names,
                codexSessions: CodexRolloutReader? = nil, achat: String = "achat", replyFloorStore: URL? = nil) {
        self.allowLive = allowLive
        self.runner = runner
        self.binaries = binaries
        self.codexSessions = codexSessions
        self.achat = achat
        self.replyFloor = AchatReplyFloor(store: replyFloorStore)
    }

    /// Desktop, IPC, and web (and Cursor's headless CLI) are achat's routes.
    /// Pharos does not speak CDP, IPC, or the DSH web lifecycle.
    public static func delegatesToAchat(app: String, routeID: String) -> Bool {
        if ["tmux", "files", "app-server", "headless"].contains(routeID) { return false }
        if ["desktop", "ipc", "web"].contains(routeID) { return true }
        return app == "cursor" && routeID == "cursor-agent"
    }

    public static func achatSendArgv(bin: String, app: String, session: String, text: String) -> [String] {
        [bin, app, "send", "--host", "local", "--json", "--session", session, "--no-webhook", text]
    }

    public static func achatReadArgv(bin: String, app: String, session: String) -> [String] {
        [bin, app, "read", "--host", "local", "--json", "--session", session, "--open"]
    }

    public func deliver(member: LightMember, body: String) -> LightDriveResult {
        let writable = LightRoutePlanner.routes(for: member).filter { $0.access == .write }
        guard !writable.isEmpty else {
            return LightDriveResult(state: .failed, route: nil, fallback: false, liveVerified: false,
                                    detail: "no writable route for \(member.app)")
        }
        if !allowLive || runner == nil {
            let route = writable[0]
            let planned = LightRoutePlanner.invocation(member: member, route: route, body: body, binaries: binaries)
            return LightDriveResult(state: .deferred, route: route.id, fallback: route.fallback || planned.fallback,
                                    liveVerified: false, detail: "unverified live; \(planned.summary)")
        }
        var notes: [String] = []
        var delegated = false
        for route in writable {
            if Self.delegatesToAchat(app: member.app, routeID: route.id) {
                if delegated { continue }
                delegated = true
                let sent = achatSend(member: member, body: body)
                if sent.ok {
                    return LightDriveResult(state: .delivered, route: route.id, fallback: false,
                                            liveVerified: false, detail: sent.detail)
                }
                notes.append("\(route.id) \(sent.detail)")
                continue
            }
            var planned = LightRoutePlanner.invocation(member: member, route: route, body: body, binaries: binaries)
            if member.app == "codex", route.id == "app-server", planned.cwd == nil {
                // `codex exec resume` takes the turn's cwd from the process; keep the session's own folder.
                planned.cwd = codexSessions?.cwd(sessionID: member.sessionID)
            }
            if !planned.executable {
                let prefix = notes.isEmpty ? "" : "previous: \(notes.joined(separator: "; ")); "
                return LightDriveResult(state: .deferred, route: route.id, fallback: route.fallback,
                                        liveVerified: false, detail: "unverified live; \(prefix)\(planned.summary)")
            }
            let output = runner?.run(planned, stdin: planned.stdin)
                ?? LightProcessOutput(status: 127, stdout: "", stderr: "no runner")
            if output.status == 0 {
                return LightDriveResult(state: .delivered, route: route.id, fallback: planned.fallback,
                                        liveVerified: false, detail: "runner exit 0; live effect unverified")
            }
            notes.append("\(route.id) exit \(output.status)")
        }
        return LightDriveResult(state: .failed, route: nil, fallback: false, liveVerified: false,
                                detail: notes.joined(separator: "; "))
    }

    public func readReply(member: LightMember, since: Date) -> String? {
        if let route = LightRoutePlanner.select(member: member, operation: .send),
           Self.delegatesToAchat(app: member.app, routeID: route.id) {
            return harvest(member)
        }
        // Stale pane text must not become a reply. Only a reader that can date a
        // completed turn answers: the Codex rollout's first `task_complete` after `since`.
        if member.app == "codex", let codexSessions {
            return codexSessions.firstCompletedReply(sessionID: member.sessionID, since: since)
        }
        _ = since
        return nil
    }

    private func achatSend(member: LightMember, body: String) -> (ok: Bool, detail: String) {
        guard let runner else { return (false, "no runner") }
        let key = Self.floorKey(member)
        // Always re-read: a floor persisted by an earlier process may be below replies
        // that arrived since, and a send without `repliesBefore` would then harvest stale text.
        let prior = runner.run(Self.readInvocation(bin: achat, member: member), stdin: "")
        if prior.status == 0, let count = Self.interpretAchatTurn(prior.stdout).replies {
            replyFloor.set(key, count)
        }
        let invocation = LightInvocation(
            argv: Self.achatSendArgv(bin: achat, app: member.app, session: member.sessionID, text: body),
            stdin: "", executable: true, fallback: false,
            summary: "achat \(member.app) send", loopback: true
        )
        let output = runner.run(invocation, stdin: "")
        let parsed = Self.interpretAchatTurn(output.stdout)
        if output.status != 0 || !parsed.ok {
            let detail = parsed.message ?? output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, detail.isEmpty ? "achat exit \(output.status)" : detail)
        }
        if let before = parsed.repliesBefore { replyFloor.set(key, before) }
        return (true, "achat \(member.app) send")
    }

    /// `achat read` has no timestamps. A reply is new when its count is above the
    /// count captured before send (`repliesBefore`). `achat wait` blocks; `pharos wait` polls this instead.
    private func harvest(_ member: LightMember) -> String? {
        guard let runner else { return nil }
        let output = runner.run(Self.readInvocation(bin: achat, member: member), stdin: "")
        guard output.status == 0 else { return nil }
        let parsed = Self.interpretAchatTurn(output.stdout)
        guard parsed.ok, let count = parsed.replies else { return nil }
        // A turn still streaming has a partial last reply. Harvest it once the session is idle.
        if parsed.busy { return nil }
        let key = Self.floorKey(member)
        if let floor = replyFloor.get(key), count > floor {
            let text = Self.stripReplyEcho(parsed.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            if text.isEmpty { return nil }
            replyFloor.set(key, count)
            return text
        }
        if replyFloor.get(key) == nil { replyFloor.set(key, count) }
        return nil
    }

    private static func readInvocation(bin: String, member: LightMember) -> LightInvocation {
        LightInvocation(
            argv: achatReadArgv(bin: bin, app: member.app, session: member.sessionID),
            stdin: "", executable: true, fallback: false,
            summary: "achat \(member.app) read", loopback: true
        )
    }

    private static func floorKey(_ member: LightMember) -> String { "\(member.app):\(member.sessionID)" }

    /// A read-only agent (Cursor ask mode) cannot run `pharos reply` and may end its answer with the
    /// command it would have run. Pharos already carries the reply, so trailing echo lines are dropped.
    /// Text that is only the command is kept as is.
    static func stripReplyEcho(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var dropped = false
        while let last = lines.last {
            let line = last.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "```" || line.range(of: #"^`{0,3}pharos reply r_[A-Za-z0-9]+(\s.*)?$"#, options: .regularExpression) != nil {
                if !line.isEmpty, line != "```" { dropped = true }
                lines.removeLast()
            } else { break }
        }
        let kept = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return dropped && !kept.isEmpty ? kept : text
    }

    static func interpretAchatTurn(_ stdout: String) -> (ok: Bool, replies: Int?, repliesBefore: Int?, reply: String?, message: String?, busy: Bool) {
        guard let object = LightSessionService.extractJSON(stdout) else {
            return (false, nil, nil, nil, nil, false)
        }
        var message: String?
        if let error = object["error"] as? [String: Any] {
            message = error["message"] as? String
        }
        if message == nil, let text = object["message"] as? String, !text.isEmpty { message = text }
        let ok = object["error"] == nil && (object["ok"] as? Bool) != false
        let reply = (object["reply"] as? String) ?? ((object["wait"] as? [String: Any])?["reply"] as? String)
        return (ok, intValue(object["replies"]), intValue(object["repliesBefore"]), reply, message, (object["busy"] as? Bool) == true)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Double, let whole = Int(exactly: number) { return whole }
        if let number = value as? NSNumber {
            let whole = number.intValue
            if number.doubleValue == Double(whole) { return whole }
        }
        return nil
    }
}

/// Reply counts observed through achat. `read` has no timestamps, so a higher
/// count than the pre-send floor is the new reply. Shared by reference so a
/// later `readReply` sees what `deliver` recorded. With a store file the floor
/// also survives the process: `pharos send` records it, a later `pharos wait`
/// (a new process) harvests against it.
final class AchatReplyFloor: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private let store: URL?

    init(store: URL? = nil) {
        self.store = store
    }

    func get(_ key: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { counts = load() }
        return counts[key]
    }

    func set(_ key: String, _ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        if store != nil { counts = load() }
        counts[key] = value
        save()
    }

    private func load() -> [String: Int] {
        guard let store, let data = try? Data(contentsOf: store),
              let object = try? JSONDecoder().decode([String: Int].self, from: data) else { return counts }
        return object
    }

    private func save() {
        guard let store, let data = try? JSONEncoder().encode(counts) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }
}

/// Reads `~/.codex/sessions/**/rollout-*-<session>.jsonl` (read-only).
public struct CodexRolloutReader: Sendable {
    public var root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)) {
        self.root = root
    }

    public func rollout(sessionID: String) -> URL? {
        guard !sessionID.isEmpty, !sessionID.contains("/"),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        let suffix = "-\(sessionID).jsonl"
        for case let url as URL in walker where url.lastPathComponent.hasPrefix("rollout-") && url.lastPathComponent.hasSuffix(suffix) {
            return url
        }
        return nil
    }

    public func cwd(sessionID: String) -> String? {
        for object in records(sessionID: sessionID) where object["type"] as? String == "session_meta" {
            guard let cwd = (object["payload"] as? [String: Any])?["cwd"] as? String, !cwd.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue { return cwd }
            return nil
        }
        return nil
    }

    /// The final agent message of the first turn that completed after `since`.
    public func firstCompletedReply(sessionID: String, since: Date) -> String? {
        for object in records(sessionID: sessionID) {
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "task_complete",
                  let stamp = object["timestamp"] as? String, let at = Self.date(stamp), at > since,
                  let text = payload["last_agent_message"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func records(sessionID: String) -> [[String: Any]] {
        guard let url = rollout(sessionID: sessionID),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }

    static func date(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public struct SSHLightReplyForwarder: LightReplyForwarding {
    public var destination: String
    public var remoteCommand: String
    public var runner: any LightProcessRunning

    public init(destination: String, remoteCommand: String = "pharos", runner: any LightProcessRunning) {
        self.destination = destination
        self.remoteCommand = remoteCommand
        self.runner = runner
    }

    public func forward(replyID: String, text: String) -> LightForwardResult? {
        // `--` keeps text that starts with `-` from being read as an option on the Broker.
        let command = "\(remoteCommand) reply \(shellQuote(replyID)) -- \(shellQuote(text))"
        let output = ssh(command, summary: "forward pharos reply over the existing SSH route")
        if output.status == 0 {
            // Show the Broker's own result (thread, deliveries, new reply-ids) to the sender.
            let remote = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return LightForwardResult(ok: true, message: remote.isEmpty ? "forwarded" : "forwarded via \(destination)\n\(remote)", exitCode: 0)
        }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return LightForwardResult(ok: false, message: detail.isEmpty ? "ssh exit \(output.status)" : detail, exitCode: output.status)
    }

    public func forwardCommand(_ arguments: [String]) -> LightForwardResult? {
        let command = ([remoteCommand] + arguments.map(Self.shellQuote)).joined(separator: " ")
        let output = ssh(command, summary: "forward pharos \(arguments.first ?? "command") over the existing SSH route")
        let remote = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.status == 0 {
            return LightForwardResult(ok: true, message: remote, exitCode: 0)
        }
        let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = remote.isEmpty ? (detail.isEmpty ? "ssh exit \(output.status)" : detail) : remote
        return LightForwardResult(ok: false, message: text, exitCode: output.status)
    }

    private func ssh(_ command: String, summary: String) -> LightProcessOutput {
        let invocation = LightInvocation(
            argv: ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--", destination, command],
            stdin: "",
            executable: true,
            fallback: false,
            summary: summary,
            loopback: false
        )
        return runner.run(invocation, stdin: "")
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shellQuote(_ value: String) -> String { Self.shellQuote(value) }
}

public struct FoundationLightProcessRunner: LightProcessRunning {
    public init() {}

    public func run(_ invocation: LightInvocation, stdin: String) -> LightProcessOutput {
        guard let launch = invocation.argv.first, !launch.isEmpty else {
            return LightProcessOutput(status: 127, stdout: "", stderr: "empty command")
        }
        let process = Process()
        if launch.contains("/") {
            process.executableURL = URL(fileURLWithPath: launch)
            process.arguments = Array(invocation.argv.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = invocation.argv
        }
        var isDirectory: ObjCBool = false
        if let cwd = invocation.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        } else {
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
        }
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let collectedOut = LockedData()
        let collectedErr = LockedData()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collectedOut.append(chunk)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                collectedErr.append(chunk)
            }
        }
        do {
            try process.run()
            if let data = stdin.data(using: .utf8), !data.isEmpty {
                input.fileHandleForWriting.write(data)
            }
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            collectedOut.append(output.fileHandleForReading.readDataToEndOfFile())
            collectedErr.append(error.fileHandleForReading.readDataToEndOfFile())
            return LightProcessOutput(
                status: process.terminationStatus,
                stdout: String(data: collectedOut.data, encoding: .utf8) ?? "",
                stderr: String(data: collectedErr.data, encoding: .utf8) ?? ""
            )
        } catch {
            return LightProcessOutput(status: 127, stdout: "", stderr: error.localizedDescription)
        }
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        storage.append(data)
        lock.unlock()
    }
    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
