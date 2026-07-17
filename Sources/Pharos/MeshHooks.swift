import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `pharos mesh unread` / `mark` / `install-hooks` — the hook-facing surface of
/// the mesh: guaranteed @-mention delivery, plus live session-state reporting.
///
/// Everything here is FAIL-OPEN and ZERO-DAEMON by design: a hook must never
/// error, block, or SPAWN the broker. Local reads use the files the broker
/// mirrors (`mesh-state/…`); state reports use `MeshClient.sendIfUp` (talks
/// only to a broker that's already up); hook modes exit 0 on every path.
///
/// Design history: the 2026-07-04 decision made the room tmux-AGNOSTIC — hooks
/// (turn-boundary delivery) are the guaranteed contract for ANY session.
/// 2026-07-11 layers OPPORTUNISTIC poke on top: join captures $TMUX_PANE, these
/// hooks report the session lifecycle (probed ground truth, cc-hook-probe
/// FINDINGS re-verified on CC v2.1.207), and the GUI send-keys-nudges a target
/// that is verifiably stopped/idle in a known tmux pane. Every uncertainty
/// degrades to the old behavior, never to a wrong keystroke.
enum MeshHooks {

    /// Substring identifying our hook entry in a settings.json, whatever the
    /// wrapper shell form around it.
    private static let marker = "mesh unread --hook-stop"
    /// Substring identifying our SessionStart hook entry.
    private static let startMarker = "mesh session-start"
    /// Substring identifying the state-reporting hook entry (UserPromptSubmit /
    /// Notification / SessionEnd share one command; it keys off the event name).
    private static let markMarker = "mesh mark --hook"
    /// Substring identifying the PostToolUse (poke-mode mid-turn delivery) entry.
    private static let postToolMarker = "mesh unread --hook-post-tool"

    /// The user-scope settings file the `--user` install writes.
    static var userSettingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// True if the global (~/.claude) mesh Stop hook is present — the GUI's
    /// installed/not-installed state.
    static func userHookInstalled() -> Bool {
        guard let d = try? Data(contentsOf: userSettingsFile),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stops = hooks["Stop"] as? [[String: Any]] else { return false }
        return stops.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
    }

    /// The Codex user-scope hooks file the `--codex` install writes.
    static var codexHooksFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    /// True if the Codex mesh Stop hook is present in ~/.codex/hooks.json.
    static func codexHookInstalled() -> Bool {
        guard let d = try? Data(contentsOf: codexHooksFile),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let stops = hooks["Stop"] as? [[String: Any]] else { return false }
        return stops.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
    }

    // MARK: `pharos mesh unread`

    /// Modes: plain peek (`unread [<nick>] [--json]`, never consumes),
    /// `--hook-stop` (Claude Code Stop hook: reads the hook JSON on stdin,
    /// emits a `decision: block` JSON when unread @you messages are pending)
    /// and `--hook-post-tool` (PostToolUse: poke-mode mid-turn delivery).
    static func unread(_ args: [String]) -> Int32 {
        let hookStop = args.contains("--hook-stop")
        let json = args.contains("--json")
        let explicitNick = args.first { !$0.hasPrefix("-") }

        if hookStop { return stopHook(explicitNick: explicitNick) }
        if args.contains("--hook-post-tool") { return postToolHook(explicitNick: explicitNick) }

        guard let member = resolveMember(cwd: FileManager.default.currentDirectoryPath,
                                         preferredNick: explicitNick) else {
            print("no nick given and none joined from this directory — usage: pharos mesh unread <nick>")
            return 2
        }
        guard let u = loadUnread(member.id) else {
            print(json ? #"{"nick":"\#(member.nick)","count":0}"# : "(no unread for \(member.nick))")
            return 0
        }
        if json, let d = try? Data(contentsOf: MeshPaths.unreadFile(member.id)) {
            print(String(decoding: d, as: UTF8.self))
            return 0
        }
        print("\(u.count) unread for \(member.nick):")
        for m in u.messages { print(messageSummary(m)) }
        print("(peek only — consume with: pharos mesh recv \(member.nick) --member \(member.id))")
        return 0
    }

    /// Fire-and-forget a state report for this session (broker resolves the
    /// nick by session/cwd when none is given). Never spawns a broker.
    private static func report(_ state: MeshSessionState, nick: String? = nil,
                               cwd: String, session: String?) {
        MeshClient.sendIfUp(MeshRequest(cmd: "mark", nick: nick, project: cwd,
                                        session: session, state: state.rawValue))
    }

    /// Stop-hook body. Every failure path returns 0 with no output: a broken or
    /// absent mesh must never disturb the session. Doubles as the `stopped`
    /// state reporter — unless our own block continues the turn, in which case
    /// the session is working again (`busy`).
    private static func stopHook(explicitNick: String?) -> Int32 {
        var cwd = FileManager.default.currentDirectoryPath
        var session: String?
        var reentry = false
        if let input = readStdinIfPiped(),
           let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            // Continuing from a Stop-hook block — never loop; the unread signal
            // survives for the next turn boundary if the agent ignored it.
            reentry = obj["stop_hook_active"] as? Bool == true
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            session = obj["session_id"] as? String   // exact per-session addressing
        }
        // Cross-host: a dial-out session has no local presence/unread files, so
        // ask the remote broker (fail-open — unreachable broker never blocks).
        if MeshPaths.dialEndpoint != nil {
            return stopHookRemote(cwd: cwd, session: session, explicitNick: explicitNick, reentry: reentry)
        }
        if reentry { report(.stopped, nick: explicitNick, cwd: cwd, session: session); return 0 }
        guard let member = resolveMember(cwd: cwd, session: session, preferredNick: explicitNick),
              let u = loadUnread(member.id), u.count > 0 else {
            report(.stopped, nick: explicitNick, cwd: cwd, session: session)
            return 0
        }
        emitBlock(nick: member.nick, memberID: member.id, messages: u.messages)
        report(.busy, nick: member.nick, cwd: cwd, session: session)   // the block continues the turn
        return 0
    }

    /// Cross-host Stop hook: one `peek` resolves the nick, returns its unread
    /// AND piggybacks the `stopped` report. Fail-open — an unreachable broker,
    /// no nick, or no unread all exit 0 without blocking.
    private static func stopHookRemote(cwd: String, session: String?, explicitNick: String?,
                                       reentry: Bool) -> Int32 {
        if reentry { report(.stopped, nick: explicitNick, cwd: cwd, session: session); return 0 }
        let resp = MeshClient.send(MeshRequest(cmd: "peek", nick: explicitNick,
                                               project: cwd, session: session,
                                               state: MeshSessionState.stopped.rawValue))
        guard resp.ok, let msgs = resp.messages, !msgs.isEmpty, let nick = resp.note else { return 0 }
        emitBlock(nick: nick, memberID: resp.memberID, messages: msgs)
        report(.busy, nick: nick, cwd: cwd, session: session)   // ditto: turn continues
        return 0
    }

    // MARK: `pharos mesh mark` — session-state reporting

    /// `--hook` mode: shared body for the UserPromptSubmit / Notification /
    /// SessionEnd hooks — maps the event (probed ground truth, cc-hook-probe
    /// FINDINGS) to a state and reports it. Plain mode (`mark <nick> <state>`)
    /// is for manual testing. Always exits 0 in hook mode.
    static func mark(_ args: [String]) -> Int32 {
        if args.contains("--hook") { return markHook() }
        guard args.count >= 2, let s = MeshSessionState(rawValue: args[1]) else {
            print("usage: pharos mesh mark <nick> <busy|blocked|stopped|idle|gone>   (hooks use --hook)")
            return 2
        }
        let r = MeshClient.send(MeshRequest(cmd: "mark", nick: args[0], state: s.rawValue))
        print(r.ok ? "ok" : "error: \(r.error ?? "?")")
        return r.ok ? 0 : 1
    }

    /// Hook event → session state (probed mapping — see MeshSessionState docs).
    /// nil = an event we deliberately ignore.
    static func stateFor(event: String, notificationType: String?) -> MeshSessionState? {
        switch event {
        case "UserPromptSubmit": .busy       // a turn begins (incl. our own nudge → self-debouncing)
        case "SessionEnd":       .gone       // never poke again
        case "Notification":
            switch notificationType {
            case "permission_prompt", "elicitation_dialog":
                .blocked                     // mid-turn, waiting on the HUMAN — poking would type into the dialog
            case "idle_prompt":
                .idle                        // fires 60s after Stop: confirmed sitting at the composer
            default:
                nil
            }
        default: nil
        }
    }

    private static func markHook() -> Int32 {
        guard let input = readStdinIfPiped(),
              let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = obj["hook_event_name"] as? String,
              let state = stateFor(event: event, notificationType: obj["notification_type"] as? String)
        else { return 0 }
        let cwd = (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        report(state, cwd: cwd, session: obj["session_id"] as? String)
        return 0
    }

    // MARK: PostToolUse — poke mode's mid-turn delivery

    /// PostToolUse hook: refreshes `busy` (which also self-heals a stale
    /// `blocked` once the human approves), and surfaces unread @mentions RIGHT
    /// NOW via `additionalContext` (neutral framing, no error label) instead
    /// of waiting for the turn to end. A marker file de-dups so the same
    /// messages aren't re-announced on every tool call.
    private static func postToolHook(explicitNick: String?) -> Int32 {
        var cwd = FileManager.default.currentDirectoryPath
        var session: String?
        if let input = readStdinIfPiped(),
           let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            session = obj["session_id"] as? String
        }
        var nick: String?
        var memberID: String?
        var msgs: [MeshMsg] = []
        if MeshPaths.dialEndpoint != nil {
            // One round-trip: peek returns unread and piggybacks the busy mark.
            let resp = MeshClient.send(MeshRequest(cmd: "peek", nick: explicitNick,
                                                   project: cwd, session: session,
                                                   state: MeshSessionState.busy.rawValue))
            nick = resp.note ?? explicitNick
            memberID = resp.memberID
            msgs = resp.messages ?? []
        } else {
            report(.busy, nick: explicitNick, cwd: cwd, session: session)
            if let member = resolveMember(cwd: cwd, session: session, preferredNick: explicitNick) {
                nick = member.nick
                memberID = member.id
                if let u = loadUnread(member.id) { msgs = u.messages }
            }
        }
        guard let n = nick else { return 0 }
        // The mailbox is already addressed by immutable member id. A non-empty
        // `to` means directed @mention; aliases may differ between this
        // session's rooms, so never re-filter by one display nick here.
        msgs = msgs.filter { !$0.to.isEmpty }
        guard !msgs.isEmpty else { return 0 }
        // De-dup: only announce messages newer than the last mid-turn notice.
        let newest = msgs.map(\.ts).max() ?? 0
        let markerURL = MeshPaths.notifiedFile(memberID ?? n)
        let last = (try? String(contentsOf: markerURL, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard newest > last else { return 0 }
        try? FileManager.default.createDirectory(at: MeshPaths.stateDir, withIntermediateDirectories: true)
        try? String(newest).write(to: markerURL, atomically: true, encoding: .utf8)

        var lines = ["New mesh message(s) for @\(n) — \(msgs.count) pending:"]
        for m in msgs.suffix(10) { lines.append("  " + messageSummary(m)) }
        let memberArg = memberID.map { " --member \($0)" } ?? ""
        lines.append("When you reach a natural pause, pick them up with `pharos mesh recv \(n)\(memberArg)` "
                     + "and reply in the room if a response is expected.")
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PostToolUse",
                "additionalContext": lines.joined(separator: "\n"),
            ]
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
        return 0
    }

    /// Emit the `decision:block` turn-end notice for `nick`'s pending messages.
    ///
    /// Note: Claude Code renders any decision:block Stop hook under its own
    /// "Stop hook error" label — there is no non-error-labeled block form
    /// (verified against the probed hooks reference, 2026-07-04). Only the
    /// reason text below is ours, so keep it friendly.
    private static func emitBlock(nick: String, memberID: String?, messages: [MeshMsg]) {
        var perRoom: [String: Int] = [:]
        for m in messages { perRoom[m.room, default: 0] += 1 }
        var lines = ["New mesh message(s) for @\(nick) — \(messages.count) pending in "
                     + "\(perRoom.keys.sorted().joined(separator: ", ")) (not an error):"]
        for m in messages.suffix(10) { lines.append("  " + messageSummary(m)) }
        let memberArg = memberID.map { " --member \($0)" } ?? ""
        lines.append("Pick them up with `pharos mesh recv \(nick)\(memberArg)`, then reply in the room "
                     + "(`pharos mesh say <room> \(nick) \"…\" @<sender>` or `ask` to wait for an answer). "
                     + "Run recv even if no reply is needed, so this notice clears.")
        let payload: [String: Any] = ["decision": "block", "reason": lines.joined(separator: "\n")]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
    }

    private static func messageSummary(_ message: MeshMsg) -> String {
        let quote = message.replyTo.map { " ↳ \($0.from): \($0.preview)" } ?? ""
        let files = (message.attachments ?? []).map { "[attachment \($0.name), id \($0.id)]" }
        let body = ([message.text] + files).filter { !$0.isEmpty }.joined(separator: " ")
        return "[\(message.room)] \(message.from): \(body)\(quote)"
    }

    // MARK: local reads

    /// cwd → nick via presence.json (broker-mirrored). Longest matching project
    /// path wins; ties go to the most recently seen nick.
    ///
    /// IDENTITY RULE (2026-07-11): an entry that DECLARED a session id belongs
    /// to that session alone — a different session's hooks must never claim it
    /// via the cwd fallback. Without this, any unregistered Claude whose cwd
    /// sat under a registered project dir hijacked that nick: it received the
    /// nick's unread notices (could even drain its mailbox) and stomped its
    /// state (observed live: 娃 joined from $HOME, so EVERY unregistered
    /// session on the hub cwd-matched it and pinned it "busy" — deadlocking
    /// the sweeper). The cwd fallback now only serves session-LESS joins.
    struct ResolvedMember { let id: String; let nick: String }

    static func resolveMember(cwd: String, session: String? = nil,
                              preferredNick: String? = nil) -> ResolvedMember? {
        guard let d = try? Data(contentsOf: MeshPaths.presenceFile),
              let p = try? JSONDecoder().decode(MeshPresence.self, from: d) else { return nil }
        if let s = session, !s.isEmpty {
            if let e = p.members[s] {
                let nick = preferredNick.flatMap { wanted in
                    e.aliases.values.first(where: { $0 == wanted })
                } ?? e.aliases.values.sorted().first ?? "agent"
                return ResolvedMember(id: s, nick: nick)
            }
            return nil
        }
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var best: (member: ResolvedMember, plen: Int, seen: Double)?
        for (id, e) in p.members {
            if let preferredNick, !e.aliases.values.contains(preferredNick) { continue }
            guard let proj = e.project, !proj.isEmpty else { continue }
            let pr = URL(fileURLWithPath: proj).standardizedFileURL.path
            guard path == pr || path.hasPrefix(pr + "/") else { continue }
            if best == nil || pr.count > best!.plen
                || (pr.count == best!.plen && e.lastSeen > best!.seen) {
                let nick = preferredNick ?? e.aliases.values.sorted().first ?? "agent"
                best = (ResolvedMember(id: id, nick: nick), pr.count, e.lastSeen)
            }
        }
        return best?.member
    }

    static func resolveNick(cwd: String, session: String? = nil) -> String? {
        resolveMember(cwd: cwd, session: session)?.nick
    }

    /// Extract `@nick` mentions from free message text. The broker is
    /// mention-only, so a message that only says "@bob" in its body (no trailing
    /// `@arg`) would otherwise reach nobody's mailbox. Trailing punctuation is
    /// trimmed; order-preserving + de-duplicated. Shared by the CLI `say`/`ask`
    /// and the GUI chat input so both surfaces deliver text mentions identically.
    static func parseTextMentions(_ text: String) -> [String] {
        // A nick is [A-Za-z0-9._-] (matches the broker's `safe()` charset). Scan
        // each `@` and take the maximal run of nick chars, stopping at the first
        // non-nick character. Splitting on whitespace alone was wrong for CJK,
        // where "@nick你好" has no space: it swallowed "你好" into the nick (so a
        // real mention never matched), and bare "@我"/"@，" became bogus targets.
        func isNickChar(_ c: Character) -> Bool {
            c.isASCII && (c.isLetter || c.isNumber || "._-".contains(c))
        }
        var out: [String] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, isNickChar(chars[j]) { j += 1 }
            var name = String(chars[(i + 1)..<j])
            while name.hasSuffix(".") { name.removeLast() }   // trailing sentence period
            if !name.isEmpty && !out.contains(name) { out.append(name) }
            i = j
        }
        return out
    }

    private static func loadUnread(_ memberID: String) -> MeshUnread? {
        guard let d = try? Data(contentsOf: MeshPaths.unreadFile(memberID)) else { return nil }
        return try? JSONDecoder().decode(MeshUnread.self, from: d)
    }

    // MARK: session identity (SessionStart hook → pane-local identity)

    /// Both agents record the immutable session id against the exact tmux
    /// socket/pane. Codex uses `--silent` because SessionStart additionalContext
    /// persists as developer context and is surfaced again after tool calls.
    /// Claude retains the explicit instruction for non-Pharos/manual sessions.
    static func sessionStart(_ args: [String]) -> Int32 {
        guard let input = readStdinIfPiped(),
              let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return 0 }
        let cwd = obj["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        recordSessionContext(sessionID: sid, cwd: cwd)
        if args.contains("--silent") { return 0 }
        let ctx = "Pharos mesh: your session id is \(sid). When you join a mesh chat "
                + "room, pass it so delivery targets this exact session — "
                + "`pharos mesh join <room> <nick> --session \(sid)`."
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "SessionStart",
                "additionalContext": ctx,
            ]
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
        return 0
    }

    private struct SessionContext: Codable {
        var sessionID: String
        var cwd: String
        var tmuxPane: String
        var tmuxSocket: String?
        var updatedAt: Double
    }

    private static var sessionContextDirectory: URL {
        MeshPaths.stateDir.appendingPathComponent("session-contexts", isDirectory: true)
    }

    @discardableResult
    static func recordSessionContext(sessionID: String, cwd: String,
                                     environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard !sessionID.isEmpty, let pane = environment["TMUX_PANE"], !pane.isEmpty,
              environment["TMUX"] != nil else { return false }
        let socket = RemoteLaunch.tmuxSocket(fromEnvironmentValue: environment["TMUX"])
        let context = SessionContext(sessionID: sessionID, cwd: cwd, tmuxPane: pane,
                                     tmuxSocket: socket, updatedAt: Date().timeIntervalSince1970)
        let file = sessionContextFile(pane: pane, socket: socket)
        do {
            try FileManager.default.createDirectory(at: sessionContextDirectory,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(context).write(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func currentSessionID(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let pane = environment["TMUX_PANE"], !pane.isEmpty,
              environment["TMUX"] != nil else { return nil }
        let socket = RemoteLaunch.tmuxSocket(fromEnvironmentValue: environment["TMUX"])
        let file = sessionContextFile(pane: pane, socket: socket)
        guard let data = try? Data(contentsOf: file),
              let context = try? JSONDecoder().decode(SessionContext.self, from: data),
              context.tmuxPane == pane, context.tmuxSocket == socket else { return nil }
        return context.sessionID
    }

    private static func sessionContextFile(pane: String, socket: String?) -> URL {
        let identity = "\(socket ?? "default")|\(pane)"
        let name = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return sessionContextDirectory.appendingPathComponent(name + ".json")
    }

    /// Read stdin to EOF, but only when it's piped — a manual terminal run must
    /// not hang waiting for input.
    private static func readStdinIfPiped() -> Data? {
        guard isatty(0) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    }

    // MARK: `pharos mesh install-hooks`

    /// Idempotently wire the Stop hook into `.claude/settings.json` (the given
    /// project's by default, `--user` for ~/.claude). Never clobbers a file it
    /// can't parse.
    static func installHooks(_ args: [String]) -> Int32 {
        if args.contains("--codex") { return installCodexHooks() }
        let fm = FileManager.default
        var dir = fm.currentDirectoryPath
        if let i = args.firstIndex(of: "--project"), i + 1 < args.count { dir = args[i + 1] }
        let base = args.contains("--user")
            ? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
            : URL(fileURLWithPath: dir).appendingPathComponent(".claude", isDirectory: true)
        let file = base.appendingPathComponent("settings.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                print("error: \(file.path) exists but is not valid JSON — fix it first, nothing written")
                return 1
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Six hooks power delivery + session addressing + live state:
        //  • Stop             — surface unread @mentions at turn-end; reports `stopped`.
        //  • SessionStart     — record cwd/session id so `join` can resolve a nick
        //                       precisely (two sessions in one dir stay distinct).
        //  • UserPromptSubmit / Notification / SessionEnd
        //                     — report busy / blocked·idle / gone (poke safety).
        //  • PostToolUse      — refresh busy; poke mode: mid-turn delivery.
        let markCmd = hookCommand("mark --hook")
        let results: [(String, UpsertResult)] = [
            ("Stop", upsertHook(&hooks, event: "Stop",
                                command: hookCommand("unread --hook-stop"), marker: marker)),
            ("SessionStart", upsertHook(&hooks, event: "SessionStart",
                                        command: hookCommand("session-start"), marker: startMarker)),
            ("UserPromptSubmit", upsertHook(&hooks, event: "UserPromptSubmit",
                                            command: markCmd, marker: markMarker)),
            ("Notification", upsertHook(&hooks, event: "Notification",
                                        command: markCmd, marker: markMarker)),
            ("SessionEnd", upsertHook(&hooks, event: "SessionEnd",
                                      command: markCmd, marker: markMarker)),
            ("PostToolUse", upsertHook(&hooks, event: "PostToolUse",
                                       command: hookCommand("unread --hook-post-tool"),
                                       marker: postToolMarker, matcher: "*")),
        ]
        root["hooks"] = hooks

        if results.allSatisfy({ $0.1 == .unchanged }) {
            print("mesh hooks already installed → \(file.path)")
            return 0
        }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: file, options: .atomic)
        } catch {
            print("error: could not write \(file.path): \(error.localizedDescription)")
            return 1
        }
        print(results.map { "\($0.0): \($0.1.verb)" }.joined(separator: "; ") + " → \(file.path)")
        print("(applies to newly started Claude sessions in that scope)")
        return 0
    }

    /// `install-hooks --codex` — wire Pharos into Codex's native lifecycle hook
    /// engine. SessionStart records identity silently; it must not inject
    /// persistent developer context. Two events Codex lacks — Notification and SessionEnd —
    /// are simply not wired: a Codex agent reports busy/stopped but not
    /// blocked/idle/gone (the mesh degrades gracefully). NOTE: Codex prompts to
    /// TRUST new/changed hooks on first run; spawn Codex with
    /// `--dangerously-bypass-hook-trust` (or approve once) so this takes effect.
    private static func installCodexHooks() -> Int32 {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let file = base.appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                print("error: \(file.path) exists but is not valid JSON — fix it first, nothing written")
                return 1
            }
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let results: [(String, UpsertResult)] = [
            ("Stop", upsertHook(&hooks, event: "Stop",
                                command: hookCommand("unread --hook-stop"), marker: marker)),
            ("SessionStart", upsertHook(&hooks, event: "SessionStart",
                                        command: hookCommand("session-start --silent"), marker: startMarker)),
            ("UserPromptSubmit", upsertHook(&hooks, event: "UserPromptSubmit",
                                            command: hookCommand("mark --hook"), marker: markMarker)),
            ("PostToolUse", upsertHook(&hooks, event: "PostToolUse",
                                       command: hookCommand("unread --hook-post-tool"),
                                       marker: postToolMarker, matcher: "*")),
        ]
        root["hooks"] = hooks
        if root["description"] == nil { root["description"] = "Pharos mesh — agent chat delivery + live state" }

        if results.allSatisfy({ $0.1 == .unchanged }) {
            print("Codex mesh hooks already installed → \(file.path)")
            return 0
        }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: file, options: .atomic)
        } catch {
            print("error: could not write \(file.path): \(error.localizedDescription)")
            return 1
        }
        print(results.map { "\($0.0): \($0.1.verb)" }.joined(separator: "; ") + " → \(file.path)")
        print("(Codex has no Notification/SessionEnd hooks — blocked/idle/gone won't report.)")
        print("(first run: Codex prompts to trust hooks — spawn with --dangerously-bypass-hook-trust)")
        return 0
    }

    private enum UpsertResult { case installed, updated, unchanged
        var verb: String { self == .installed ? "installed" : self == .updated ? "updated" : "unchanged" }
    }

    /// Idempotently place `command` under `hooks[event]`. Exact match = leave it;
    /// marker match with a different command = upgrade in place (older install);
    /// no match = append (with `matcher` when the event needs one, e.g. the
    /// tool-name matcher on PostToolUse). Never touches unrelated hook entries.
    private static func upsertHook(_ hooks: inout [String: Any], event: String,
                                   command: String, marker: String,
                                   matcher: String? = nil) -> UpsertResult {
        var arr = hooks[event] as? [[String: Any]] ?? []
        for (i, entry) in arr.enumerated() {
            guard var inner = entry["hooks"] as? [[String: Any]] else { continue }
            for (j, h) in inner.enumerated() where (h["command"] as? String)?.contains(marker) == true {
                if h["command"] as? String == command { return .unchanged }
                inner[j]["command"] = command
                arr[i]["hooks"] = inner
                hooks[event] = arr
                return .updated
            }
        }
        var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 10]]]
        if let m = matcher { entry["matcher"] = m }
        arr.append(entry)
        hooks[event] = arr
        return .installed
    }

    /// The command written into settings.json for a given `pharos mesh <sub>`.
    /// The absolute binary path is ALWAYS primary — a hook runs under the
    /// session's runtime PATH, which need not contain `pharos` even when the
    /// install-time PATH did. Bare `pharos` is only the fallback for a
    /// moved/reinstalled app, and the closing `true` keeps the hook fail-open.
    private static func hookCommand(_ sub: String) -> String {
        let exe = (Bundle.main.executableURL
                   ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        return "if [ -x \"\(exe)\" ]; then \"\(exe)\" mesh \(sub); "
             + "elif command -v pharos >/dev/null 2>&1; then pharos mesh \(sub); else true; fi"
    }
}
