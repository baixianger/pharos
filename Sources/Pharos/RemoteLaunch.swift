import Foundation

/// Launch a coding agent on ANOTHER machine over SSH, inside a detached tmux
/// session on that host (survives disconnect). Ports the flow the
/// spawn-claude-tmux skill validated end-to-end on 2026-07-10, including its
/// hard-won rules:
///
///  - macOS keychain lock state is *per security session* (= per tmux server),
///    and an unlock dies with the server → create the agent's session FIRST so
///    the server stays alive, unlock into it, THEN boot the agent.
///  - Remote args are single-quote wrapped: zsh remotes equals-expand a bare
///    leading `=` (`-t =name` → "command not found").
///  - `tmux run-shell` output is captured then searched — piping it straight
///    into a matcher can silently drop it.
///  - The peer login password comes from the LOCAL keychain item
///    `host-<alias>`, delivered stdin → tmux buffer, never argv/ps.
enum RemoteLaunch {
    struct RemoteError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
    /// Non-interactive SSH shells miss homebrew/user bins (tmux, claude live there).
    private static let pathShim = #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin""#

    /// Single-quote wrap for the remote shell (safe under zsh/bash, any content).
    private static func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func ssh(_ host: String, _ script: String) -> Shell.Result {
        Shell.run("/usr/bin/ssh", sshOpts + [host, "\(pathShim); \(script)"])
    }

    private static func tmux(_ host: String, _ args: [String]) -> Shell.Result {
        ssh(host, "tmux " + args.map(sq).joined(separator: " "))
    }

    /// ssh with data written to the remote command's stdin (for secrets — the
    /// secret never appears in argv on either machine).
    private static func sshStdin(_ host: String, _ script: String, stdin: String) -> Shell.Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = sshOpts + [host, "\(pathShim); \(script)"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
        do { try p.run() } catch { return Shell.Result(out: "", err: "\(error)", code: -1) }
        if let d = stdin.data(using: .utf8) { inPipe.fileHandleForWriting.write(d) }
        inPipe.fileHandleForWriting.closeFile()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return Shell.Result(out: out, err: err, code: p.terminationStatus)
    }

    private static func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Main entry

    /// Launch `kind` for `project` on `host` (an ~/.ssh/config alias). Blocking:
    /// waits for the agent to reach its ready prompt (claude) before returning.
    /// `brief`, when set, is typed into the agent once it is ready.
    static func launch(project: Project, kind: AgentKind, host: String,
                       yolo: Bool, issue: Int? = nil, brief: String? = nil,
                       source: AuditLog.Source) throws -> String {
        // 1. Alias wired? (fail instead of prompting)
        guard Shell.run("/usr/bin/ssh", sshOpts + [host, "true"]).ok else {
            throw RemoteError(message: "Cannot SSH to '\(host)' (BatchMode). Check ~/.ssh/config + key auth; new machine → spawn-claude-tmux references/ssh-host-setup.md")
        }

        // 2. Remote identity → per-host project path (from the synced registry).
        let idProbe = ssh(host, #"echo "$(id -u)|$(uname)|$(scutil --get ComputerName 2>/dev/null || hostname)""#)
        let parts = idProbe.out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", maxSplits: 2).map(String.init)
        guard idProbe.ok, parts.count == 3 else {
            throw RemoteError(message: "Cannot identify remote host '\(host)': \(idProbe.err)")
        }
        let (uid, os, hostKey) = (parts[0], parts[1], parts[2])
        guard let path = project.resolvedLocalPath(forHost: hostKey) else {
            throw RemoteError(message: "Project '\(project.name)' has no path registered for host '\(hostKey)'. On that machine run: pharos path \(project.name) <dir>")
        }
        guard ssh(host, "test -d \(sq(path))").ok else {
            throw RemoteError(message: "Registered path missing on \(hostKey): \(path)")
        }

        // 3. Session name (same scheme as local; remote tmux is its own namespace).
        let name = issue.map { LaunchService.tmuxSessionName(project, kind, issue: $0) }
            ?? LaunchService.tmuxSessionName(project, kind)
        if tmux(host, ["has-session", "-t", "=\(name)"]).ok {
            throw RemoteError(message: "Session '\(name)' already runs on \(host). Peek: ssh -t \(host) tmux attach -t \(name)")
        }

        // 4. Create the session FIRST — the server must be alive before any unlock.
        guard tmux(host, ["new-session", "-d", "-s", name, "-c", path]).ok else {
            throw RemoteError(message: "Failed to create tmux session on \(host) (is tmux installed there?)")
        }

        // 5. Mac target: keychain readiness inside this server's security session.
        var notes: [String] = []
        if os == "Darwin" {
            notes.append(keychainReady(host: host))
            // SSH keys: point the session at the GUI launchd agent socket if any.
            sendLine(host, name, #"export SSH_AUTH_SOCK="$(find /var/run /private/tmp -maxdepth 2 -name Listeners -user "$(whoami)" 2>/dev/null | head -1)""#)
            pause(0.8)
        }

        // 6. Boot the agent. Claude gets --remote-control (the takeover safety
        //    valve for a detached yolo session); codex has no equivalent.
        var cmd: String
        if kind == .claude {
            cmd = "claude --remote-control \(name)" + (yolo ? " --dangerously-skip-permissions" : "")
        } else {
            cmd = kind.command(yolo: yolo)
        }
        if uid == "0" { cmd = "IS_SANDBOX=1 " + cmd }   // root refuses yolo without it
        sendLine(host, name, cmd)

        if yolo {
            AuditLog.record(actor: source, action: "launch_agent_yolo_remote",
                            detail: "\(kind.rawValue) @ \(host):\(path)")
        }

        // 7. Claude: wait for the ready prompt, walking first-run interstitials;
        //    grab the Remote Control URL. Codex: fire-and-report.
        var lines = ["Launched \(kind.label) on \(host) (\(hostKey)) at \(path)",
                     "session: \(name)   attach: ssh -t \(host) tmux attach -t \(name)"]
        lines.append(contentsOf: notes.filter { !$0.isEmpty })
        if kind == .claude {
            let (state, url) = waitBoot(host: host, name: name, timeout: 120)
            switch state {
            case "ready":
                if let brief, !brief.isEmpty { pause(1); sendLine(host, name, brief) }
                lines.append("state: READY" + (brief != nil ? " (brief sent)" : ""))
            case "login":
                lines.append("state: LOGGED OUT — recover: cc-tmux.sh login -n \(name) -H \(host) (OAuth relay)")
            default:
                lines.append("state: boot not detected in 120s — peek the session")
            }
            lines.append("rc url : \(url ?? "not visible — /rc inside the session shows it")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Mesh member spawn

    /// Remote counterpart of `MeshSpawn.spawnLocal`: create a neutral scratch
    /// session on the paired Mac, unlock that tmux server's keychain security
    /// session, boot Claude/Codex, brief it to join, and confirm at the broker.
    /// Blocking; callers run it off-main.
    static func spawnMeshAgent(room: String, nick: String, kind: AgentKind, host: String,
                               onProgress: @escaping (MeshSpawn.Progress) -> Void) {
        func fail(_ detail: String) {
            onProgress(.init(phase: .failed, detail: detail))
        }

        guard Shell.run("/usr/bin/ssh", sshOpts + [host, "true"]).ok else {
            fail("can't SSH to \(host) (check Settings → Machines)")
            return
        }

        let hookArgs = kind == .codex ? "--codex" : "--user"
        guard ssh(host, "pharos mesh install-hooks \(hookArgs) >/dev/null").ok else {
            fail("couldn't install \(kind.rawValue) mesh hooks on \(host)")
            return
        }

        let homeProbe = ssh(host, #"printf %s "$HOME""#)
        let home = homeProbe.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard homeProbe.ok, home.hasPrefix("/") else {
            fail("couldn't resolve the home folder on \(host)")
            return
        }
        let dir = home + "/.pharos/mesh-agents/" + MeshSpawn.safe(room) + "/" + MeshSpawn.safe(nick)
        guard ssh(host, "mkdir -p \(sq(dir))").ok else {
            fail("couldn't create the agent folder on \(host)")
            return
        }

        let name = MeshSpawn.sessionName(room: room, nick: nick)
        _ = tmux(host, ["kill-session", "-t", "=\(name)"]) // clear a stale spawn
        guard tmux(host, ["new-session", "-d", "-s", name, "-c", dir,
                          "-x", "200", "-y", "50"]).ok else {
            fail("couldn't start tmux on \(host)")
            return
        }

        // Keep the server alive before probing/unlocking: the login keychain's
        // security session is scoped to this tmux server on macOS.
        let os = ssh(host, "uname").out.trimmingCharacters(in: .whitespacesAndNewlines)
        var keychainNote = ""
        if os == "Darwin" {
            keychainNote = keychainReady(host: host)
            sendLine(host, name,
                     #"export SSH_AUTH_SOCK="$(find /var/run /private/tmp -maxdepth 2 -name Listeners -user "$(whoami)" 2>/dev/null | head -1)""#)
            pause(0.8)
        }

        onProgress(.init(phase: .booting,
                         detail: "starting \(kind.rawValue) on \(host)…"
                             + (keychainNote.isEmpty ? "" : "  \(keychainNote)")))
        sendLine(host, name, MeshSpawn.launchCommand(kind))

        let ready: Bool
        if kind == .claude {
            ready = waitBoot(host: host, name: name, timeout: 90).0 == "ready"
        } else {
            ready = waitCodexBoot(host: host, name: name, timeout: 60)
        }
        guard ready else {
            fail("\(kind.rawValue) didn't reach its prompt — peek: ssh -t \(host) tmux attach -t \(name)")
            return
        }

        onProgress(.init(phase: .joining, detail: "asking it on \(host) to join \(room)…"))
        sendLine(host, name, MeshSpawn.joinBrief(room: room, nick: nick, kind: kind))

        for _ in 0..<25 {
            pause(2)
            if MeshSpawn.didJoin(room: room, nick: nick) {
                onProgress(.init(phase: .joined, detail: "joined \(room) from \(host)"))
                return
            }
        }
        fail("spawned on \(host) but hasn't joined — peek: ssh -t \(host) tmux attach -t \(name)")
    }

    /// Codex-ready detection for remote mesh spawning. Trust/interstitial
    /// screens are submitted separately; the hook-trust prompt itself is
    /// bypassed by MeshSpawn's launch command.
    private static func waitCodexBoot(host: String, name: String, timeout: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var lastScreen = ""
        while Date() < deadline {
            let pane = tmux(host, ["capture-pane", "-p", "-t", name]).out
            let lower = pane.lowercased()
            var screen = ""
            if lower.contains("trust this folder") || lower.contains("do you trust") { screen = "trust" }
            else if lower.contains("choose") && lower.contains("theme") { screen = "theme" }
            else if lower.contains("press enter to continue") { screen = "continue" }
            if !screen.isEmpty && screen != lastScreen {
                _ = tmux(host, ["send-keys", "-t", name, "Enter"])
                lastScreen = screen
                pause(2)
                continue
            }
            // Check readiness only after interstitials: Codex uses `›` both as
            // its composer and as the selection cursor on the trust screen.
            if screen.isEmpty && (pane.contains("›") || lower.contains("full access")
                                  || lower.contains("for shortcuts")) {
                return true
            }
            pause(2)
        }
        return false
    }

    // MARK: - Keychain readiness (macOS 26: per-security-session, per tmux server)

    /// Probe the remote tmux server's session; unlock from the local
    /// `host-<alias>` item when locked. Best-effort — returns a status line.
    private static func keychainReady(host: String) -> String {
        let probe = tmux(host, ["run-shell", "security show-keychain-info ~/Library/Keychains/login.keychain-db 2>&1"])
        let combined = probe.out + "\n" + probe.err          // capture, THEN search
        guard combined.contains("not allowed") else { return "keychain: already unlocked" }

        let item = Shell.run("/usr/bin/security", ["find-generic-password", "-s", "host-\(host)", "-w"])
        guard item.ok else {
            return "keychain: LOCKED, no local item 'host-\(host)' — claude may need login (seed via spawn-claude-tmux references/mac-keychain.md)"
        }
        let secret = item.out.trimmingCharacters(in: .whitespacesAndNewlines)

        let tmp = "px-unlock-\(ProcessInfo.processInfo.processIdentifier)"
        _ = tmux(host, ["kill-session", "-t", tmp])          // stale leftovers
        guard tmux(host, ["new-session", "-d", "-s", tmp]).ok else { return "keychain: LOCKED (no unlock pane)" }
        defer { _ = tmux(host, ["kill-session", "-t", tmp]) }

        _ = tmux(host, ["send-keys", "-t", tmp, "-l", "--", "security unlock-keychain ~/Library/Keychains/login.keychain-db"])
        pause(0.5)
        _ = tmux(host, ["send-keys", "-t", tmp, "Enter"])
        // Poll for the prompt BEFORE pasting — a blind paste lands on the shell
        // prompt and Enter would execute the password (history leak).
        var prompted = false
        for _ in 0..<15 {
            if tmux(host, ["capture-pane", "-t", tmp, "-p"]).out.lowercased().contains("password to unlock") {
                prompted = true; break
            }
            pause(1)
        }
        guard prompted else { return "keychain: LOCKED (unlock prompt never appeared)" }
        _ = sshStdin(host, "tmux load-buffer -b pxpw - && tmux paste-buffer -d -b pxpw -t \(sq(tmp))", stdin: secret)
        pause(0.5)
        _ = tmux(host, ["send-keys", "-t", tmp, "Enter"])
        pause(2)
        let pane = tmux(host, ["capture-pane", "-t", tmp, "-p"]).out
        if matches(pane, "not correct|unable to unlock|failed") {
            return "keychain: unlock FAILED (wrong password in 'host-\(host)'? re-seed with -U)"
        }
        return "keychain: unlocked for this tmux server"
    }

    // MARK: - Boot wait (claude)

    /// Wait for claude to reach its ready prompt, auto-answering first-run
    /// interstitials (theme/trust/continue → Enter; bypass warning → Down+Enter,
    /// its default is "No, exit"). Returns (state, rcURL?).
    private static func waitBoot(host: String, name: String, timeout: Int) -> (String, String?) {
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var lastScreen = ""
        while Date() < deadline {
            let pane = tmux(host, ["capture-pane", "-t", name, "-p"]).out
            if matches(pane, "bypass permissions on|for shortcuts|effort:") {
                return ("ready", grabURL(host: host, name: name))
            }
            if matches(pane, "login method|subscription|console account") {
                return ("login", grabURL(host: host, name: name))
            }
            var screen = ""
            if matches(pane, "choose the text style|dark mode") { screen = "theme" }
            else if matches(pane, "do you trust|trust this folder|accessing workspace") { screen = "trust" }
            else if matches(pane, "yes, i accept") { screen = "bypass" }
            else if matches(pane, "press enter to continue") { screen = "continue" }
            if !screen.isEmpty && screen != lastScreen {
                if screen == "bypass" {
                    _ = tmux(host, ["send-keys", "-t", name, "Down"])
                    pause(0.3)
                }
                _ = tmux(host, ["send-keys", "-t", name, "Enter"])
                lastScreen = screen
            }
            pause(3)
        }
        return ("timeout", nil)
    }

    private static func grabURL(host: String, name: String) -> String? {
        let pane = tmux(host, ["capture-pane", "-t", name, "-p", "-J", "-S", "-200"]).out
        guard let r = pane.range(of: #"https://claude\.ai/code/session[A-Za-z0-9_-]*"#,
                                 options: .regularExpression) else { return nil }
        return String(pane[r])
    }

    /// send-keys literal text, brief pause, then Enter as a separate keystroke
    /// (paste-detection safety — same rule as the skill's type_line).
    private static func sendLine(_ host: String, _ name: String, _ text: String) {
        _ = tmux(host, ["send-keys", "-t", name, "-l", "--", text])
        pause(0.5)
        _ = tmux(host, ["send-keys", "-t", name, "Enter"])
    }

    // MARK: - Driving surface (pharos agents / agent peek|say|kill)

    /// tmux, local or remote — one driving surface for either side.
    /// Live Pharos tmux sessions on `host` — the remote counterpart of
    /// `LaunchService.runningSessions()`, for the reconcile sweep. nil =
    /// "couldn't tell" (ssh unreachable, tmux missing): callers MUST fail open
    /// and leave that host's links alone. A tmux with no server is a real empty
    /// set (every session there ended). Short 5s connect timeout — this runs
    /// from the GUI's poll loop.
    static func runningSessions(host: String) -> Set<String>? {
        let r = Shell.run("/usr/bin/ssh",
                          ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host,
                           "\(pathShim); tmux list-sessions -F '#{session_name}'"])
        if r.code == 0 {
            return Set(r.out.split(separator: "\n").map(String.init).filter { $0.hasPrefix("pharos-") })
        }
        if (r.err + r.out).contains("no server running") { return [] }
        return nil
    }

    private static func tmuxAny(_ host: String?, _ args: [String]) -> Shell.Result {
        if let host, !host.isEmpty { return tmux(host, args) }
        guard let bin = LaunchService.tmuxPath else {
            return Shell.Result(out: "", err: "tmux not installed", code: 127)
        }
        return Shell.run(bin, args)
    }

    private static func at(_ host: String?) -> String { host.map { " on \($0)" } ?? "" }

    /// Live `pharos-*` agent sessions, optionally substring-filtered.
    static func listAgents(host: String?, filter: String?) -> String {
        let r = tmuxAny(host, ["list-sessions", "-F", "#{session_name}\t#{session_attached}"])
        guard r.ok else { return "(no tmux server\(at(host)))" }
        let rows = r.out.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("pharos-") }
            .filter { row in filter.map { row.localizedCaseInsensitiveContains($0) } ?? true }
        if rows.isEmpty { return "(no pharos agent sessions\(at(host)))" }
        return rows.map { row in
            let f = row.split(separator: "\t").map(String.init)
            return (f.first ?? row) + ((f.count > 1 && f[1] != "0") ? "  (attached)" : "")
        }.joined(separator: "\n")
    }

    /// Tail of an agent's pane (trailing blank pane rows trimmed).
    static func peek(session: String, host: String?, lines: Int) throws -> String {
        let r = tmuxAny(host, ["capture-pane", "-t", session, "-p"])
        guard r.ok else {
            throw RemoteError(message: "cannot peek '\(session)'\(at(host)): \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var all = r.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while all.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { all.removeLast() }
        return all.suffix(max(1, lines)).joined(separator: "\n")
    }

    /// Type one line into an agent (literal send-keys, then Enter — type_line rule).
    static func say(session: String, host: String?, text: String) throws -> String {
        guard !text.contains("\n") else {
            throw RemoteError(message: "multiline message — write it to a file on the target and say 'Read <path>' instead")
        }
        guard tmuxAny(host, ["has-session", "-t", "=\(session)"]).ok else {
            throw RemoteError(message: "no session '\(session)'\(at(host)) (see: pharos agents)")
        }
        _ = tmuxAny(host, ["send-keys", "-t", session, "-l", "--", text])
        pause(0.5)
        _ = tmuxAny(host, ["send-keys", "-t", session, "Enter"])
        return "sent to '\(session)'\(at(host))"
    }

    static func kill(session: String, host: String?) throws -> String {
        guard tmuxAny(host, ["kill-session", "-t", "=\(session)"]).ok else {
            throw RemoteError(message: "no session '\(session)'\(at(host)) (see: pharos agents)")
        }
        return "killed '\(session)'\(at(host))"
    }
}
