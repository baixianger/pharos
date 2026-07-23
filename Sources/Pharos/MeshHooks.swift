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
/// 2026-07-17 layers durable Node poke on top. Hooks are the ONLY source of
/// busy/blocked/stopped/idle state. Their reports are leases: fresh busy and
/// blocked suppress poke; expired or unknown state permits eventual delivery.
/// tmux output and ANSI/TUI text never infer state. The Node observes only an
/// exact pane/process identity so it can mark a session `gone` after exit.
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

    /// True only when the complete current Claude hook manifest is present.
    /// Checking one legacy Stop entry made partially upgraded installs look
    /// healthy even when newer lifecycle events were absent.
    static func userHookInstalled() -> Bool {
        guard let d = try? Data(contentsOf: userSettingsFile),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return claudeManifest.allSatisfy { hookEntryPresent(hooks, event: $0.event, marker: $0.marker) }
    }

    /// The Codex user-scope hooks file the `--codex` install writes.
    static var codexHooksFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    /// True only when the complete current Codex hook manifest is present.
    static func codexHookInstalled() -> Bool {
        guard let d = try? Data(contentsOf: codexHooksFile),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return codexManifest.allSatisfy { hookEntryPresent(hooks, event: $0.event, marker: $0.marker) }
    }

    private static let claudeManifest: [(event: String, marker: String)] = [
        ("Stop", marker), ("SessionStart", startMarker),
        ("UserPromptSubmit", markMarker), ("PermissionRequest", markMarker),
        ("Notification", markMarker), ("ElicitationResult", markMarker),
        ("PostToolUseFailure", markMarker), ("StopFailure", markMarker),
        ("SessionEnd", markMarker), ("PostToolUse", postToolMarker),
        ("PreToolUse", markMarker),
    ]

    private static let codexManifest: [(event: String, marker: String)] = [
        ("Stop", marker), ("SessionStart", startMarker),
        ("UserPromptSubmit", markMarker), ("PermissionRequest", markMarker),
        ("PostToolUse", postToolMarker),
    ]

    private static func hookEntryPresent(_ hooks: [String: Any], event: String,
                                         marker: String) -> Bool {
        guard let entries = hooks[event] as? [[String: Any]] else { return false }
        return entries.contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
                ($0["command"] as? String)?.contains(marker) == true
            }
        }
    }

    // MARK: `pharos mesh unread`

    /// Modes: plain peek (`unread [<nick>] [--json]`, never consumes),
    /// `--hook-stop` (Stop hook: reads hook JSON on stdin and continues the
    /// agent with unread @you messages using the platform's supported output)
    /// and `--hook-post-tool` (PostToolUse: poke-mode mid-turn delivery).
    static func unread(_ args: [String]) -> Int32 {
        let hookStop = args.contains("--hook-stop")
        let json = args.contains("--json")
        let explicitNick = args.first { !$0.hasPrefix("-") }

        if hookStop { return stopHook(explicitNick: explicitNick, codex: args.contains("--codex")) }
        if args.contains("--hook-post-tool") {
            return postToolHook(explicitNick: explicitNick, codex: args.contains("--codex"))
        }

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
    ///
    /// Carries the physical tmux seat (host, pane, socket) — free to read from
    /// the hook's own environment — so the broker can reclaim a session that a
    /// `/clear` re-minted onto the same seat even if the SessionStart rebind
    /// never landed (see `rebindLocked` in the broker). For a session the broker
    /// already knows, these fields are inert.
    private static func report(_ state: MeshSessionState, nick: String? = nil,
                               cwd: String, session: String?, reason: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let pane = env["TMUX"] != nil ? env["TMUX_PANE"] : nil
        let socket = RemoteLaunch.tmuxSocket(fromEnvironmentValue: env["TMUX"])
        var request = MeshRequest(cmd: "mark", nick: nick, project: cwd,
                                  session: session,
                                  host: HostIdentity.current,
                                  tmuxPane: pane, tmuxSocket: socket,
                                  state: state.rawValue,
                                  stateReason: reason)
        request.nodeID = MeshNodeIdentity.current
        MeshClient.sendIfUp(request)
    }

    /// Stop-hook body. Every failure path returns 0 with no output: a broken or
    /// absent mesh must never disturb the session. Doubles as the `stopped`
    /// state reporter — unless our own block continues the turn, in which case
    /// the session is working again (`busy`).
    private static func stopHook(explicitNick: String?, codex: Bool) -> Int32 {
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
            return stopHookRemote(cwd: cwd, session: session, explicitNick: explicitNick,
                                  reentry: reentry, codex: codex)
        }
        if reentry { report(.stopped, nick: explicitNick, cwd: cwd, session: session); return 0 }
        guard let member = resolveMember(cwd: cwd, session: session, preferredNick: explicitNick),
              let u = loadUnread(member.id), u.count > 0 else {
            report(.stopped, nick: explicitNick, cwd: cwd, session: session)
            return 0
        }
        emitContinuation(nick: member.nick, memberID: member.id, messages: u.messages, codex: codex)
        report(.busy, nick: member.nick, cwd: cwd, session: session)   // the block continues the turn
        return 0
    }

    /// Cross-host Stop hook: one `peek` resolves the nick, returns its unread
    /// AND piggybacks the `stopped` report. Fail-open — an unreachable broker,
    /// no nick, or no unread all exit 0 without blocking.
    private static func stopHookRemote(cwd: String, session: String?, explicitNick: String?,
                                       reentry: Bool, codex: Bool) -> Int32 {
        if reentry { report(.stopped, nick: explicitNick, cwd: cwd, session: session); return 0 }
        let resp = MeshClient.send(MeshRequest(cmd: "peek", nick: explicitNick,
                                               project: cwd, session: session,
                                               state: MeshSessionState.stopped.rawValue))
        guard resp.ok, let msgs = resp.messages, !msgs.isEmpty, let nick = resp.note else { return 0 }
        emitContinuation(nick: nick, memberID: resp.memberID, messages: msgs, codex: codex)
        report(.busy, nick: nick, cwd: cwd, session: session)   // ditto: turn continues
        return 0
    }

    // MARK: `pharos mesh mark` — session-state reporting

    /// `--hook` mode: shared body for lifecycle hooks — maps the event
    /// (official schema plus probed ground truth, cc-hook-probe
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
    static func stateFor(event: String, notificationType: String?,
                         reason: String? = nil) -> MeshSessionState? {
        switch event {
        case "UserPromptSubmit": .busy       // a turn begins (incl. our own nudge → self-debouncing)
        case "PermissionRequest": .blocked   // an approval dialog is about to be shown
        case "ElicitationResult", "PostToolUseFailure":
            .busy                            // human/form response returned to the active turn
        case "StopFailure":      .stopped    // API error ended the turn; composer is poke-safe
        case "SessionEnd":
            // `/clear` and `resume` end this session id but immediately start a
            // NEW one on the SAME tmux pane (~0.2s later) — the agent is not
            // gone, it is being replaced. Mark it `stopped` (pane alive,
            // delivery continues) and let the successor's rebind carry the
            // membership over; marking it `gone` here is what stranded a
            // working agent off the roster after a plain `/clear`. Only a real
            // teardown is `gone`. Unknown reasons stay `gone` (conservative):
            // the Node's pane probe re-confirms a truly dead seat within ~40s.
            switch reason {
            case "clear", "resume": .stopped
            default:                .gone
            }
        case "Notification":
            switch notificationType {
            case "permission_prompt", "elicitation_dialog":
                .blocked                     // mid-turn, waiting on the HUMAN — poking would type into the dialog
            case "idle_prompt":
                .idle                        // fires 60s after Stop: confirmed sitting at the composer
            case "elicitation_complete", "elicitation_response":
                .busy                        // clear the blocked lease as the form closes
            default:
                nil
            }
        default: nil
        }
    }

    private static func markHook() -> Int32 {
        guard let input = readStdinIfPiped(),
              let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let event = obj["hook_event_name"] as? String else { return 0 }
        let cwd = (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath
        let session = obj["session_id"] as? String
        // PreToolUse{AskUserQuestion}: the dialog is about to block the session
        // on a HUMAN. Report blocked(form) and forward the full form into the
        // member's room so the human can answer from chat (verified: the
        // dialog itself renders normally as long as we emit no decision).
        if event == "PreToolUse" {
            guard obj["tool_name"] as? String == "AskUserQuestion" else { return 0 }
            report(.blocked, cwd: cwd, session: session, reason: "form:AskUserQuestion")
            forwardForm(toolInput: obj["tool_input"] as? [String: Any] ?? [:], session: session)
            return 0
        }
        guard let state = stateFor(event: event, notificationType: obj["notification_type"] as? String,
                                   reason: obj["reason"] as? String)
        else { return 0 }
        report(state, cwd: cwd, session: session,
               reason: stateReason(event: event, notificationType: obj["notification_type"] as? String,
                                   payload: obj))
        return 0
    }

    /// Render an AskUserQuestion tool_input as a chat-readable form. Static and
    /// pure for testability.
    static func formMessage(toolInput: [String: Any]) -> String? {
        guard let questions = toolInput["questions"] as? [[String: Any]],
              !questions.isEmpty else { return nil }
        var lines = ["📋 表单待填（AskUserQuestion）— 我停在这张表上等人选择。直接在群里 @我 回复选项即可，Pharos 会代我收表并送达你的答复。"]
        for (index, question) in questions.enumerated() {
            let header = (question["header"] as? String).map { "［\($0)］" } ?? ""
            let multi = question["multiSelect"] as? Bool == true ? "（可多选）" : ""
            lines.append("\(index + 1). \(question["question"] as? String ?? "?")\(header)\(multi)")
            for option in question["options"] as? [[String: Any]] ?? [] {
                let label = option["label"] as? String ?? "?"
                let detail = (option["description"] as? String).map { " — \($0)" } ?? ""
                lines.append("   ◦ \(label)\(detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Fail-open forward of the form into the member's room(s). The member id
    /// IS the session id for session-joined agents, so this works identically
    /// for local-broker and dial-out sessions. A say without a room resolves
    /// the single-room case; multi-room members fall back to one say per room.
    private static func forwardForm(toolInput: [String: Any], session: String?) {
        guard let session, !session.isEmpty,
              let text = formMessage(toolInput: toolInput) else { return }
        var say = MeshRequest(cmd: "say", text: text)
        say.memberID = session
        guard let response = MeshClient.sendIfUp(say), !response.ok else { return }
        let roster = MeshClient.sendIfUp(MeshRequest(cmd: "who"))
        let rooms = Set((roster?.members ?? []).filter { $0.id == session }.flatMap(\.rooms))
        for room in rooms {
            var perRoom = MeshRequest(cmd: "say", room: room, text: text)
            perRoom.memberID = session
            _ = MeshClient.sendIfUp(perRoom)
        }
    }

    /// Human-attention and failure detail stays orthogonal to readiness state.
    /// It is replaced on every mark, so a later busy/stopped event clears a
    /// stale permission or error reason automatically.
    private static func stateReason(event: String, notificationType: String?,
                                    payload: [String: Any]) -> String? {
        switch event {
        case "PermissionRequest":
            return (payload["tool_name"] as? String).map { "permission:\($0)" } ?? "permission"
        case "Notification" where notificationType == "permission_prompt":
            return "permission"
        case "Notification" where notificationType == "elicitation_dialog":
            return "elicitation"
        case "StopFailure":
            let error = payload["error"] as? String ?? "unknown"
            let details = (payload["error_details"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let details, !details.isEmpty { return "api_error:\(error):\(details)" }
            return "api_error:\(error)"
        default:
            return nil
        }
    }

    // MARK: PostToolUse — poke mode's mid-turn delivery

    /// PostToolUse hook: refreshes `busy` (which also self-heals a stale
    /// `blocked` once the human approves), and surfaces unread @mentions RIGHT
    /// NOW via `additionalContext` (neutral framing, no error label) instead
    /// of waiting for the turn to end. A marker file de-dups so the same
    /// messages aren't re-announced on every tool call.
    private static func postToolHook(explicitNick: String?, codex: Bool) -> Int32 {
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
        guard let n = nick else { return finishPostTool(codex: codex) }
        // The mailbox is already addressed by immutable member id. A non-empty
        // `to` means directed @mention; aliases may differ between this
        // session's rooms, so never re-filter by one display nick here.
        msgs = msgs.filter { !$0.to.isEmpty }
        guard !msgs.isEmpty else { return finishPostTool(codex: codex) }
        // De-dup: only announce messages newer than the last mid-turn notice.
        let newest = msgs.map(\.ts).max() ?? 0
        let markerURL = MeshPaths.notifiedFile(memberID ?? n)
        let last = (try? String(contentsOf: markerURL, encoding: .utf8))
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        guard newest > last else { return finishPostTool(codex: codex) }
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

    /// Empty PostToolUse output is accepted by both Claude and Codex. Recent
    /// Codex builds reject the formerly supported `suppressOutput` key.
    private static func finishPostTool(codex: Bool) -> Int32 {
        _ = codex
        return 0
    }

    /// Continue the agent with unread room context. Claude now has a first-class
    /// non-error Stop feedback form. Codex's Stop schema intentionally remains
    /// top-level `decision:block`.
    private static func emitContinuation(nick: String, memberID: String?, messages: [MeshMsg],
                                         codex: Bool) {
        var perRoom: [String: Int] = [:]
        for m in messages { perRoom[m.room, default: 0] += 1 }
        var lines = ["New mesh message(s) for @\(nick) — \(messages.count) pending in "
                     + "\(perRoom.keys.sorted().joined(separator: ", ")) (not an error):"]
        for m in messages.suffix(10) { lines.append("  " + messageSummary(m)) }
        let memberArg = memberID.map { " --member \($0)" } ?? ""
        lines.append("Pick them up with `pharos mesh recv \(nick)\(memberArg)`, then reply in the room "
                     + "(`pharos mesh send \"…\" @<sender> --room <room>` or `ask` to wait for an answer). "
                     + "Run recv even if no reply is needed, so this notice clears.")
        let text = lines.joined(separator: "\n")
        let payload = continuationPayload(text: text, codex: codex)
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
    }

    /// Kept testable because Claude and Codex deliberately expose different
    /// Stop output schemas despite sharing the same event name.
    static func continuationPayload(text: String, codex: Bool) -> [String: Any] {
        codex
            ? ["decision": "block", "reason": text]
            : ["hookSpecificOutput": ["hookEventName": "Stop", "additionalContext": text]]
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
        // `/clear` and `resume` end the prior session id and start THIS one on
        // the same tmux pane; `source` names exactly that transition. Only then
        // do we reclaim the seat: a plain `startup` is a genuinely new agent and
        // must NOT inherit a stale predecessor, and `compact` reuses the same
        // session id (nothing to rebind). On clear/resume, ask the broker to
        // move the same-seat predecessor's rooms, mailbox and presence onto us
        // so the roster follows the live session instead of pinning to the dead
        // one. Fail-open: if the broker is unreachable now, this session's first
        // `mark` lazily does the same reclaim (see the broker's mark/rebind).
        if let source = obj["source"] as? String, source == "clear" || source == "resume" {
            rebindPriorSeat(sessionID: sid, cwd: cwd)
        }
        if args.contains("--silent") { return 0 }
        var ctx = "Pharos mesh: your session id is \(sid). When you join a mesh chat "
                + "room, pass it so delivery targets this exact session — "
                + "`pharos mesh join <room> <nick> --session \(sid)`."
        // SessionStart also fires on compaction/resume (source=compact/resume).
        // A compaction summary is lossy and can corrupt a remembered room name,
        // leading the agent to re-`join` the wrong name — which silently makes a
        // new room. Re-state the broker's authoritative membership so the agent
        // never re-derives it from memory. (Membership survives compaction.)
        let memberships = currentMemberships(sessionID: sid)
        if !memberships.isEmpty {
            let list = memberships.map { "\($0.room) (as \($0.nick))" }.joined(separator: ", ")
            ctx += " You are ALREADY joined to: \(list) — this membership persists across "
                 + "context compaction, so do NOT run `join` again for these rooms. "
                 + "To catch up use `pharos mesh recv <nick>`; to reply use "
                 + "`pharos mesh say <room> <nick> …`. Only `join` a brand-new room the human names."
        }
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

    /// Broker-authoritative rooms this session is currently joined to, as
    /// (room, nick) pairs. Fail-open: an unreachable broker or a not-yet-joined
    /// session returns empty, so a fresh startup adds no membership guidance.
    /// Each `who` row is scoped to one room (rooms == [that room]).
    static func currentMemberships(sessionID: String) -> [(room: String, nick: String)] {
        guard let resp = MeshClient.sendIfUp(MeshRequest(cmd: "who")), resp.ok,
              let members = resp.members else { return [] }
        var pairs: [(room: String, nick: String)] = []
        var seen = Set<String>()
        for m in members where m.id == sessionID {
            guard let room = m.rooms.first else { continue }
            if seen.insert(room).inserted { pairs.append((room, m.nick)) }
        }
        return pairs.sorted { $0.room < $1.room }
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

    /// Fire-and-forget rebind for the current tmux seat: hand the broker this
    /// session's physical identity (host, pane, socket) + cwd so it can move a
    /// same-seat predecessor's mesh membership onto us. The broker owns all the
    /// safety (seat match, cwd secondary-confirm, recency window); here we only
    /// have to prove the seat. No seat (not under tmux) → nothing to reclaim.
    static func rebindPriorSeat(sessionID: String, cwd: String,
                                environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !sessionID.isEmpty, let pane = environment["TMUX_PANE"], !pane.isEmpty,
              environment["TMUX"] != nil else { return }
        let socket = RemoteLaunch.tmuxSocket(fromEnvironmentValue: environment["TMUX"])
        var request = MeshRequest(cmd: "rebind", project: cwd, session: sessionID,
                                  host: HostIdentity.current,
                                  tmuxPane: pane, tmuxSocket: socket)
        request.nodeID = MeshNodeIdentity.current
        MeshClient.sendIfUp(request)
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
        // Lifecycle hooks power delivery + session addressing + live state:
        //  • Stop             — surface unread @mentions at turn-end; reports `stopped`.
        //  • SessionStart     — record cwd/session id so `join` can resolve a nick
        //                       precisely (two sessions in one dir stay distinct).
        //  • UserPromptSubmit / PermissionRequest / Notification
        //                     — report busy / blocked·idle (poke safety).
        //  • ElicitationResult / PostToolUseFailure
        //                     — clear blocked back to busy.
        //  • StopFailure / SessionEnd — report stopped(error) / gone.
        //  • PostToolUse      — refresh busy; poke mode: mid-turn delivery.
        let markCmd = hookCommand("mark --hook")
        let results: [(String, UpsertResult)] = [
            ("Stop", upsertHook(&hooks, event: "Stop",
                                command: hookCommand("unread --hook-stop"), marker: marker)),
            ("SessionStart", upsertHook(&hooks, event: "SessionStart",
                                        command: hookCommand("session-start"), marker: startMarker)),
            ("UserPromptSubmit", upsertHook(&hooks, event: "UserPromptSubmit",
                                            command: markCmd, marker: markMarker)),
            ("PermissionRequest", upsertHook(&hooks, event: "PermissionRequest",
                                              command: markCmd, marker: markMarker, matcher: "*")),
            ("Notification", upsertHook(&hooks, event: "Notification",
                                        command: markCmd, marker: markMarker)),
            ("ElicitationResult", upsertHook(&hooks, event: "ElicitationResult",
                                              command: markCmd, marker: markMarker, matcher: "*")),
            ("PostToolUseFailure", upsertHook(&hooks, event: "PostToolUseFailure",
                                               command: markCmd, marker: markMarker, matcher: "*")),
            ("StopFailure", upsertHook(&hooks, event: "StopFailure",
                                        command: markCmd, marker: markMarker, matcher: "*")),
            ("SessionEnd", upsertHook(&hooks, event: "SessionEnd",
                                      command: markCmd, marker: markMarker)),
            ("PostToolUse", upsertHook(&hooks, event: "PostToolUse",
                                       command: hookCommand("unread --hook-post-tool"),
                                       marker: postToolMarker, matcher: "*")),
            // AskUserQuestion only: report blocked(form) and forward the form
            // content into the member's room before the dialog blocks the turn.
            ("PreToolUse", upsertHook(&hooks, event: "PreToolUse",
                                      command: markCmd, marker: markMarker,
                                      matcher: "AskUserQuestion")),
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
    /// persistent developer context. Codex's PermissionRequest provides a
    /// structured blocked signal even though it lacks Notification. SessionEnd
    /// remains unavailable, so Node liveness owns `gone`. NOTE: Codex prompts to
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
                                command: hookCommand("unread --hook-stop --codex"), marker: marker)),
            ("SessionStart", upsertHook(&hooks, event: "SessionStart",
                                        command: hookCommand("session-start --silent"), marker: startMarker)),
            ("UserPromptSubmit", upsertHook(&hooks, event: "UserPromptSubmit",
                                            command: hookCommand("mark --hook"), marker: markMarker)),
            ("PermissionRequest", upsertHook(&hooks, event: "PermissionRequest",
                                              command: hookCommand("mark --hook"),
                                              marker: markMarker, matcher: "*")),
            ("PostToolUse", upsertHook(&hooks, event: "PostToolUse",
                                       command: hookCommand("unread --hook-post-tool --codex"),
                                       marker: postToolMarker, matcher: "*")),
        ]
        root["hooks"] = hooks
        let removedUnsupportedMetadata = sanitizeCodexRoot(&root)

        if results.allSatisfy({ $0.1 == .unchanged }), !removedUnsupportedMetadata {
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
        print("(Codex PermissionRequest reports blocked; Notification/SessionEnd remain unavailable.)")
        print("(first run: Codex prompts to trust hooks — spawn with --dangerously-bypass-hook-trust)")
        return 0
    }

    /// Codex parses the root as a strict schema. Earlier Pharos releases added
    /// this descriptive metadata; remove only our known field and preserve any
    /// unrelated user-owned keys for forward compatibility.
    @discardableResult
    static func sanitizeCodexRoot(_ root: inout [String: Any]) -> Bool {
        root.removeValue(forKey: "description") != nil
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
                if h["type"] as? String == "command",
                   h["command"] as? String == command,
                   h["timeout"] as? Int == 10,
                   (entry["matcher"] as? String) == matcher {
                    return .unchanged
                }
                var desiredHandler = h
                desiredHandler["type"] = "command"
                desiredHandler["command"] = command
                desiredHandler["timeout"] = 10
                inner[j] = desiredHandler
                var desiredEntry = entry
                desiredEntry["hooks"] = inner
                if let matcher { desiredEntry["matcher"] = matcher }
                else { desiredEntry.removeValue(forKey: "matcher") }
                arr[i] = desiredEntry
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
