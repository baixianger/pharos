import Foundation

/// Opportunistic tmux nudge: when the human @mentions an agent that the hooks
/// report as stopped/idle AND whose `join` captured a tmux pane, type a short
/// "check your mesh mailbox" prompt into that pane so the idle session wakes
/// NOW instead of at its next human prompt. The mailbox stays the delivery of
/// record — a lost nudge costs nothing (Stop hook fallback), a duplicate one is
/// idempotent (`recv` drains once).
///
/// Safety model (why this can't type into the wrong thing):
///  1. Only states `stopped`/`idle` are poked — `blocked` (a permission or
///     elicitation dialog is up; keys would answer IT) and `busy` never are.
///     States come from CC's own lifecycle hooks (see MeshHooks), not guesses.
///  2. The pane's foreground command must still look like a Claude session
///     (`claude`/`node`/`bun`); a dead agent leaving a bare shell is skipped.
///  3. The nudge text contains no backticks/quotes/metacharacters, so even the
///     worst case — a shell executing it — is a harmless "command not found".
///
/// The three-step send (literal keys, pause, separate Enter) mirrors the
/// spawn-claude-tmux `say` recipe: typing text and Enter in one call trips
/// Claude Code's paste detection and the prompt doesn't submit.
enum MeshPoke {

    /// Where a poke would go for this member, from the GUI's point of view.
    enum Route {
        case local(pane: String)                 // same Mac: drive tmux directly
        case remote(pane: String, host: String)  // peer Mac: drive tmux over SSH
        case unpokeable(String)                  // no pane / unknown host — tell the human why
    }

    /// Decide how (whether) the member can be poked from THIS Mac. `peerHost`
    /// is the paired SSH alias from Settings → Machines ("" = none).
    static func route(for m: MeshMemberInfo, peerHost: String) -> Route {
        guard let pane = m.tmuxPane, !pane.isEmpty else { return .unpokeable("not in tmux") }
        guard let host = m.host, !host.isEmpty else {
            // Pre-host-capture join (older CLI): can't tell whose tmux owns the
            // pane, and guessing sends keystrokes to the wrong machine.
            return .unpokeable("unknown host (agent joined via an old CLI)")
        }
        if host == HostIdentity.current { return .local(pane: pane) }
        guard !peerHost.isEmpty else { return .unpokeable("on \(host), but no peer Mac is paired") }
        return .remote(pane: pane, host: peerHost)
    }

    /// The typed prompt. Free of shell metacharacters by design (safety rule 3).
    static func nudgeText(for nick: String) -> String {
        "You have new mesh messages. Run: pharos mesh recv \(nick)"
    }

    /// Does this captured pane text show an idle Claude composer we may type
    /// into? Rejects a running turn ("esc to interrupt") and any pending
    /// dialog (permission/trust prompts) — used ONLY when the hook-reported
    /// state is unknown (e.g. right after a broker restart) and the state
    /// machine can't vouch for the composer itself.
    static func paneLooksIdle(_ text: String) -> Bool {
        let t = text.lowercased()
        if t.contains("esc to interrupt")          // mid-turn (claude)
            || t.contains("working")                // mid-turn (codex shows a working spinner)
            || t.contains("do you want to proceed") // permission dialog
            || t.contains("enter to confirm")       // trust/select dialog
            || t.contains("esc to cancel") {        // any other modal
            return false
        }
        return t.contains("❯") || t.contains("›")   // composer prompt visible (claude / codex)
    }

    /// Nudge `m`'s session. BLOCKING (tmux and possibly SSH) — call off-main.
    /// Returns nil on success, else a human-readable reason the poke was
    /// skipped (surfaced in the chat view's notice bar).
    ///
    /// States: stopped/idle poke directly (the hooks vouch for the composer).
    /// UNKNOWN state falls back to a visual pane probe (`paneLooksIdle`).
    /// busy/blocked/gone always refuse.
    static func nudge(_ m: MeshMemberInfo, peerHost: String) -> String? {
        let state = MeshSessionState(rawValue: m.state ?? "")
        var mustProbe = false
        if state?.pokeable != true {
            guard state == nil else { return "state is \(m.state ?? "?"), not poking" }
            mustProbe = true   // unknown: let the pane's own pixels decide
        }
        let text = nudgeText(for: m.nick)
        switch route(for: m, peerHost: peerHost) {
        case .unpokeable(let why):
            return why
        case .local(let pane):
            guard let tmux = localTmux() else { return "tmux not found on this Mac" }
            guard paneRunsClaude(Shell.run(tmux, ["display-message", "-p", "-t", pane,
                                                  "#{pane_current_command}"])) else {
                return "tmux pane \(pane) is no longer a Claude session"
            }
            if mustProbe {
                guard paneLooksIdle(Shell.run(tmux, ["capture-pane", "-p", "-t", pane]).out) else {
                    return "state unknown and the pane doesn't look safely idle"
                }
            }
            guard Shell.run(tmux, ["send-keys", "-t", pane, "-l", "--", text]).ok else {
                return "tmux send-keys failed (pane \(pane) gone?)"
            }
            usleep(350_000)
            _ = Shell.run(tmux, ["send-keys", "-t", pane, "Enter"])
            return nil
        case .remote(let pane, let host):
            // One SSH round-trip does check + (probe) + type + pause + Enter.
            let p = sq(pane), t = sq(text)
            let probe = mustProbe ? """
            pv=$(tmux capture-pane -p -t \(p) 2>/dev/null)
            case "$pv" in *'esc to interrupt'*|*'Do you want to proceed'*|*'Enter to confirm'*|*'Esc to cancel'*) exit 4 ;; esac
            case "$pv" in *'❯'*) ;; *) exit 4 ;; esac
            """ : ""
            let script = """
            \(pathShim); c=$(tmux display-message -p -t \(p) '#{pane_current_command}' 2>/dev/null) || exit 3
            case "$c" in claude|node|bun|codex*|[0-9]*.[0-9]*.[0-9]*) ;; *) exit 3 ;; esac
            \(probe)
            tmux send-keys -t \(p) -l -- \(t) && sleep 0.35 && tmux send-keys -t \(p) Enter
            """
            let r = Shell.run("/usr/bin/ssh", sshOpts + [host, script])
            return r.ok ? nil : "couldn't poke via \(host) (pane gone/not idle, or SSH failed)"
        }
    }

    /// Post-`say` follow-up for the human's @-targets (BLOCKING — run off-main):
    /// poke every pokeable one, and return notes for whatever needs the human —
    /// a session outside tmux, a pending permission dialog, a gone agent.
    static func followUp(targets: [MeshMemberInfo], peerHost: String) -> [String] {
        var notes: [String] = []
        for t in targets {
            let proj = t.project.map { " (\(($0 as NSString).abbreviatingWithTildeInPath))" } ?? ""
            switch MeshSessionState(rawValue: t.state ?? "") {
            case .stopped, .idle:
                if let why = nudge(t, peerHost: peerHost) {
                    notes.append("@\(t.nick) is idle but can't be auto-poked — \(why). "
                                 + "Nudge its session yourself\(proj).")
                } else {
                    notes.append("⚡ poked @\(t.nick)")
                }
            case .blocked:
                notes.append("@\(t.nick) is waiting on a permission/form dialog\(proj) — "
                             + "approve it; your message lands at its next turn boundary.")
            case .gone:
                notes.append("@\(t.nick)'s session has ended — the message waits in its "
                             + "mailbox until \(t.nick) rejoins.")
            case .busy:
                break   // working: the PostToolUse/Stop hooks deliver it shortly
            case nil:
                if t.session == nil && t.host == nil && t.tmuxPane == nil && t.project == nil {
                    // Never joined, or its registration predates a broker restart.
                    notes.append("@\(t.nick) isn't registered with the mesh — the message "
                                 + "waits in its mailbox; have it run `pharos mesh join` again.")
                } else if nudge(t, peerHost: peerHost) == nil {
                    // Unknown state, but the pane probe vouched for an idle
                    // composer — poked anyway (self-heals post-restart limbo).
                    notes.append("⚡ poked @\(t.nick) (state was unknown; its pane looked idle)")
                } else {
                    notes.append("@\(t.nick)'s state is unknown and its pane can't be safely "
                                 + "poked — it sees the message at its next turn, or nudge it yourself\(proj).")
                }
            }
        }
        return notes
    }

    // MARK: plumbing

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]
    /// Non-interactive SSH shells miss homebrew/user bins (tmux lives there).
    private static let pathShim = #"PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin""#

    private static func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True if the pane's foreground process looks like a live coding-agent CLI
    /// we may type into. Claude reads as claude/node/bun — or a bare VERSION
    /// NUMBER ("2.1.207": the launcher execs a versioned binary, observed live
    /// 2026-07-11). Codex reads as `codex` / `codex-aarch64-*` (the versioned
    /// codex binary, observed 2026-07-13). Anything else means the agent exited
    /// and a nudge would hit whatever took over the pane.
    static func paneRunsClaude(_ r: Shell.Result) -> Bool {
        guard r.ok else { return false }
        let cmd = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["claude", "node", "bun"].contains(cmd)
            || cmd.hasPrefix("codex")
            || cmd.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
    }

    private static func localTmux() -> String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
