import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `pharos mesh unread` / `pharos mesh install-hooks` — the hook-facing surface
/// of the mesh, giving @-mentions guaranteed delivery to a live joined session.
///
/// Everything here is FAIL-OPEN and ZERO-DAEMON by design: a hook must never
/// error, block, or wake the broker. It reads the two local files the broker
/// mirrors (`mesh-state/unread/<nick>.json`, `mesh-state/presence.json`) and, in
/// hook mode, exits 0 on every path.
///
/// Recorded design decision (2026-07-04): the chat room is tmux-AGNOSTIC — we
/// don't know whether a session is wrapped in tmux, so a Pharos-side tmux
/// keystroke push is not a universal delivery option. The hook model works for
/// ANY session; its ceiling — delivery at the next turn boundary (Stop) or next
/// human prompt, never mid-idle — is the accepted contract.
enum MeshHooks {

    /// Substring identifying our hook entry in a settings.json, whatever the
    /// wrapper shell form around it.
    private static let marker = "mesh unread --hook-stop"
    /// Substring identifying our SessionStart hook entry.
    private static let startMarker = "mesh session-start"

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

    // MARK: `pharos mesh unread`

    /// Modes: plain peek (`unread [<nick>] [--json]`, never consumes) and
    /// `--hook-stop` (Claude Code Stop hook: reads the hook JSON on stdin,
    /// emits a `decision: block` JSON when unread @you messages are pending).
    static func unread(_ args: [String]) -> Int32 {
        let hookStop = args.contains("--hook-stop")
        let json = args.contains("--json")
        let explicitNick = args.first { !$0.hasPrefix("-") }

        if hookStop { return stopHook(explicitNick: explicitNick) }

        guard let nick = explicitNick ?? resolveNick(cwd: FileManager.default.currentDirectoryPath) else {
            print("no nick given and none joined from this directory — usage: pharos mesh unread <nick>")
            return 2
        }
        guard let u = loadUnread(nick) else {
            print(json ? #"{"nick":"\#(nick)","count":0}"# : "(no unread for \(nick))")
            return 0
        }
        if json, let d = try? Data(contentsOf: MeshPaths.unreadFile(nick)) {
            print(String(decoding: d, as: UTF8.self))
            return 0
        }
        print("\(u.count) unread for \(nick):")
        for m in u.messages { print("[\(m.room)] \(m.from): \(m.text)") }
        print("(peek only — consume with: pharos mesh recv \(nick))")
        return 0
    }

    /// Stop-hook body. Every failure path returns 0 with no output: a broken or
    /// absent mesh must never disturb the session.
    private static func stopHook(explicitNick: String?) -> Int32 {
        var cwd = FileManager.default.currentDirectoryPath
        var session: String?
        if let input = readStdinIfPiped(),
           let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            // Already continuing from a Stop-hook block — never loop; the unread
            // signal survives for the next turn boundary if the agent ignored it.
            if obj["stop_hook_active"] as? Bool == true { return 0 }
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            session = obj["session_id"] as? String   // exact per-session addressing
        }
        // Cross-host: a dial-out session has no local presence/unread files, so
        // ask the remote broker (fail-open — unreachable broker never blocks).
        if MeshPaths.tcpEndpoint != nil {
            return stopHookRemote(cwd: cwd, session: session, explicitNick: explicitNick)
        }
        guard let nick = explicitNick ?? resolveNick(cwd: cwd, session: session),
              let u = loadUnread(nick), u.count > 0 else { return 0 }
        emitBlock(nick: nick, messages: u.messages)
        return 0
    }

    /// Cross-host Stop hook: the broker (reached over TCP) resolves the nick and
    /// returns its unread. Fail-open — an unreachable broker, no nick, or no
    /// unread all exit 0 without blocking.
    private static func stopHookRemote(cwd: String, session: String?, explicitNick: String?) -> Int32 {
        let resp = MeshClient.send(MeshRequest(cmd: "peek", nick: explicitNick,
                                               project: cwd, session: session))
        guard resp.ok, let msgs = resp.messages, !msgs.isEmpty, let nick = resp.note else { return 0 }
        emitBlock(nick: nick, messages: msgs)
        return 0
    }

    /// Emit the `decision:block` turn-end notice for `nick`'s pending messages.
    ///
    /// Note: Claude Code renders any decision:block Stop hook under its own
    /// "Stop hook error" label — there is no non-error-labeled block form
    /// (verified against the probed hooks reference, 2026-07-04). Only the
    /// reason text below is ours, so keep it friendly.
    private static func emitBlock(nick: String, messages: [MeshMsg]) {
        var perRoom: [String: Int] = [:]
        for m in messages { perRoom[m.room, default: 0] += 1 }
        var lines = ["New mesh message(s) for @\(nick) — \(messages.count) pending in "
                     + "\(perRoom.keys.sorted().joined(separator: ", ")) (not an error):"]
        for m in messages.suffix(10) { lines.append("  [\(m.room)] \(m.from): \(m.text)") }
        lines.append("Pick them up with `pharos mesh recv \(nick)`, then reply in the room "
                     + "(`pharos mesh say <room> \(nick) \"…\" @<sender>` or `ask` to wait for an answer). "
                     + "Run recv even if no reply is needed, so this notice clears.")
        let payload: [String: Any] = ["decision": "block", "reason": lines.joined(separator: "\n")]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
    }

    // MARK: local reads

    /// cwd → nick via presence.json (broker-mirrored). Longest matching project
    /// path wins; ties go to the most recently seen nick.
    static func resolveNick(cwd: String, session: String? = nil) -> String? {
        guard let d = try? Data(contentsOf: MeshPaths.presenceFile),
              let p = try? JSONDecoder().decode(MeshPresence.self, from: d) else { return nil }
        // 1. Exact session match wins — precise even when several nicks joined
        //    from the same directory. Ties (a nick re-joined) → most recent.
        if let s = session, !s.isEmpty {
            let hit = p.nicks.filter { $0.value.session == s }
                             .max { $0.value.lastSeen < $1.value.lastSeen }
            if let hit { return hit.key }
        }
        // 2. Fall back to cwd: longest project prefix; ties → most recently seen.
        let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
        var best: (nick: String, plen: Int, seen: Double)?
        for (nick, e) in p.nicks {
            guard let proj = e.project, !proj.isEmpty else { continue }
            let pr = URL(fileURLWithPath: proj).standardizedFileURL.path
            guard path == pr || path.hasPrefix(pr + "/") else { continue }
            if best == nil || pr.count > best!.plen
                || (pr.count == best!.plen && e.lastSeen > best!.seen) {
                best = (nick, pr.count, e.lastSeen)
            }
        }
        return best?.nick
    }

    /// Extract `@nick` mentions from free message text. The broker is
    /// mention-only, so a message that only says "@bob" in its body (no trailing
    /// `@arg`) would otherwise reach nobody's mailbox. Trailing punctuation is
    /// trimmed; order-preserving + de-duplicated. Shared by the CLI `say`/`ask`
    /// and the GUI chat input so both surfaces deliver text mentions identically.
    static func parseTextMentions(_ text: String) -> [String] {
        var out: [String] = []
        for tok in text.split(whereSeparator: { $0.isWhitespace }) where tok.hasPrefix("@") {
            let name = tok.dropFirst()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?()[]{}<>'\""))
            if !name.isEmpty && !out.contains(name) { out.append(name) }
        }
        return out
    }

    private static func loadUnread(_ nick: String) -> MeshUnread? {
        guard let d = try? Data(contentsOf: MeshPaths.unreadFile(nick)) else { return nil }
        return try? JSONDecoder().decode(MeshUnread.self, from: d)
    }

    // MARK: session identity (SessionStart hook → context injection)

    /// `pharos mesh session-start` — Claude Code SessionStart hook. Reads the
    /// hook JSON on stdin (`{session_id, …}`) and injects the session id back
    /// into the agent's context, instructing it to pass `--session <id>` when it
    /// joins a room. That gives `join` a per-SESSION identity, so two sessions
    /// in one directory stay distinct — which cwd alone can't disambiguate.
    /// Fail-open: on any gap it emits nothing and exits 0 (no context added, and
    /// `join` simply falls back to cwd-based addressing).
    static func sessionStart(_ args: [String]) -> Int32 {
        guard let input = readStdinIfPiped(),
              let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              let sid = obj["session_id"] as? String, !sid.isEmpty else { return 0 }
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
        // Two hooks power guaranteed delivery + session addressing:
        //  • Stop         — surface unread @mentions at turn-end.
        //  • SessionStart — record cwd/session id so `join` can resolve a nick
        //                   precisely (two sessions in one dir stay distinct).
        let s1 = upsertHook(&hooks, event: "Stop",
                            command: hookCommand("unread --hook-stop"), marker: marker)
        let s2 = upsertHook(&hooks, event: "SessionStart",
                            command: hookCommand("session-start"), marker: startMarker)
        root["hooks"] = hooks

        if s1 == .unchanged && s2 == .unchanged {
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
        print("Stop hook: \(s1.verb); SessionStart hook: \(s2.verb) → \(file.path)")
        print("(applies to newly started Claude sessions in that scope)")
        return 0
    }

    private enum UpsertResult { case installed, updated, unchanged
        var verb: String { self == .installed ? "installed" : self == .updated ? "updated" : "unchanged" }
    }

    /// Idempotently place `command` under `hooks[event]`. Exact match = leave it;
    /// marker match with a different command = upgrade in place (older install);
    /// no match = append. Never touches unrelated hook entries.
    private static func upsertHook(_ hooks: inout [String: Any], event: String,
                                   command: String, marker: String) -> UpsertResult {
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
        arr.append(["hooks": [["type": "command", "command": command, "timeout": 10]]])
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
