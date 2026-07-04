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
        if let input = readStdinIfPiped(),
           let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
            // Already continuing from a Stop-hook block — never loop; the unread
            // signal survives for the next turn boundary if the agent ignored it.
            if obj["stop_hook_active"] as? Bool == true { return 0 }
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
        }
        guard let nick = explicitNick ?? resolveNick(cwd: cwd),
              let u = loadUnread(nick), u.count > 0 else { return 0 }

        // Note: Claude Code renders any decision:block Stop hook under its own
        // "Stop hook error" label — there is no non-error-labeled block form
        // (verified against the probed hooks reference, 2026-07-04). Only the
        // reason text below is ours, so keep it friendly.
        var lines = ["New mesh message(s) for @\(nick) — \(u.count) pending in \(u.rooms.keys.sorted().joined(separator: ", ")) (not an error):"]
        for m in u.messages.suffix(10) { lines.append("  [\(m.room)] \(m.from): \(m.text)") }
        lines.append("Pick them up with `pharos mesh recv \(nick)`, then reply in the room "
                     + "(`pharos mesh say <room> \(nick) \"…\" @<sender>` or `ask` to wait for an answer). "
                     + "Run recv even if no reply is needed, so this notice clears.")
        let payload: [String: Any] = ["decision": "block", "reason": lines.joined(separator: "\n")]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            print(String(decoding: d, as: UTF8.self))
        }
        return 0
    }

    // MARK: local reads

    /// cwd → nick via presence.json (broker-mirrored). Longest matching project
    /// path wins; ties go to the most recently seen nick.
    static func resolveNick(cwd: String) -> String? {
        guard let d = try? Data(contentsOf: MeshPaths.presenceFile),
              let p = try? JSONDecoder().decode(MeshPresence.self, from: d) else { return nil }
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
        var stops = hooks["Stop"] as? [[String: Any]] ?? []
        let desired = hookCommand()
        // Present already? Exact match = done; marker match with a different
        // command = an older install (e.g. bare-pharos form) — upgrade in place.
        var upgraded = false
        for (i, entry) in stops.enumerated() {
            guard var inner = entry["hooks"] as? [[String: Any]] else { continue }
            for (j, h) in inner.enumerated() where (h["command"] as? String)?.contains(marker) == true {
                if h["command"] as? String == desired {
                    print("mesh Stop hook already installed → \(file.path)")
                    return 0
                }
                inner[j]["command"] = desired
                upgraded = true
            }
            if upgraded { stops[i]["hooks"] = inner; break }
        }
        if !upgraded {
            stops.append(["hooks": [["type": "command", "command": desired, "timeout": 10]]])
        }
        hooks["Stop"] = stops
        root["hooks"] = hooks

        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: file, options: .atomic)
        } catch {
            print("error: could not write \(file.path): \(error.localizedDescription)")
            return 1
        }
        print("\(upgraded ? "Updated" : "Installed") mesh Stop hook → \(file.path)")
        print("(applies to newly started Claude sessions in that scope)")
        return 0
    }

    /// The command written into settings.json. The absolute binary path is
    /// ALWAYS primary — a hook runs under the session's runtime PATH, which
    /// need not contain `pharos` even when the install-time PATH did. Bare
    /// `pharos` is only the fallback for a moved/reinstalled app, and the
    /// closing `true` keeps the hook fail-open forever.
    private static func hookCommand() -> String {
        let exe = (Bundle.main.executableURL
                   ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
        return "if [ -x \"\(exe)\" ]; then \"\(exe)\" mesh unread --hook-stop; "
             + "elif command -v pharos >/dev/null 2>&1; then pharos mesh unread --hook-stop; else true; fi"
    }
}
