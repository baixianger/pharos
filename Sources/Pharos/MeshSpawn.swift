import Foundation

/// Spawn a coding agent (Claude or Codex) into a tmux session and drive it to
/// JOIN a mesh chat room, then confirm it actually joined — the passive-join
/// flow from the CLI skill, exposed to the GUI's "add member" action.
///
/// The target may be this Mac or the paired Mac over SSH. Remote spawning
/// delegates to `RemoteLaunch`, including its per-tmux-server keychain unlock.
///
/// All steps block (tmux + polling) — always call `spawn` off the main
/// thread and hop progress back to the main actor in the caller.
enum MeshSpawn {
    enum Phase: String { case booting, joining, joined, failed }
    struct Progress { let phase: Phase; let detail: String }

    /// tmux session name for a spawned mesh member.
    static func sessionName(room: String, nick: String) -> String {
        "pharos-mesh-\(safe(room))-\(safe(nick))"
    }

    /// A scratch working dir per spawned member (keeps cwd stable + off the
    /// user's real projects). The nick + --session + --kind make it addressable
    /// regardless of cwd, so a neutral dir is fine.
    private static func agentDir(room: String, nick: String) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos/mesh-agents/\(safe(room))/\(safe(nick))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
    }

    /// The shell command tmux runs as the session's foreground process.
    static func launchCommand(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude --dangerously-skip-permissions"
        // Codex needs the hook-trust bypass so the mesh hooks (~/.codex/hooks.json)
        // actually run without a first-run trust prompt.
        case .codex:  return "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        }
    }

    /// Brief typed into either agent after its composer is ready. Keeping this
    /// shared guarantees local and remote spawn register the same identity.
    static func joinBrief(room: String, nick: String, kind: AgentKind) -> String {
        "Join the mesh chat room \(room) as nick \(nick): run  "
            + "pharos mesh join \(room) \(nick) --session <the session id the Pharos mesh "
            + "SessionStart hook gave you in your context> --kind \(kind.rawValue). "
            + "Then run  pharos mesh say \(room) \(nick) \"\(nick) joined\". "
            + "Return to the idle composer after announcing; do not run a listener or polling command. "
            + "Pharos hooks and nudges will wake you for new messages. Do nothing else."
    }

    /// One entry point for GUI and CLI. `host == nil` means this Mac; otherwise
    /// it is an SSH alias/IP for the paired Mac.
    static func spawn(room: String, nick: String, kind: AgentKind, host: String? = nil,
                      onProgress: @escaping (Progress) -> Void) {
        if let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RemoteLaunch.spawnMeshAgent(room: room, nick: nick, kind: kind,
                                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                        onProgress: onProgress)
        } else {
            spawnLocal(room: room, nick: nick, kind: kind, onProgress: onProgress)
        }
    }

    /// Spawn `kind` locally in tmux and brief it to join `room` as `nick`.
    /// Reports progress; returns once joined or failed.
    static func spawnLocal(room: String, nick: String, kind: AgentKind,
                           onProgress: @escaping (Progress) -> Void) {
        // Spawn is expected to work from one click even if Settings was never
        // opened. The installers are idempotent; Codex's trust prompt is
        // bypassed by launchCommand below.
        let hookStatus = MeshHooks.installHooks(kind == .codex ? ["--codex"] : ["--user"])
        guard hookStatus == 0 else {
            onProgress(Progress(phase: .failed, detail: "couldn't install \(kind.rawValue) mesh hooks"))
            return
        }
        guard let tmux = LaunchService.tmuxPath else {
            onProgress(Progress(phase: .failed, detail: "tmux not found on this Mac")); return
        }
        let name = sessionName(room: room, nick: nick)
        _ = Shell.run(tmux, ["kill-session", "-t", name])   // clear a stale one
        guard Shell.run(tmux, ["new-session", "-d", "-s", name, "-c", agentDir(room: room, nick: nick),
                               "-x", "200", "-y", "50", launchCommand(kind)]).ok else {
            onProgress(Progress(phase: .failed, detail: "couldn't start the tmux session")); return
        }
        onProgress(Progress(phase: .booting, detail: "starting \(kind.rawValue)…"))

        guard waitForBoot(tmux, name) else {
            onProgress(Progress(phase: .failed,
                                detail: "\(kind.rawValue) didn't reach its prompt — peek: tmux attach -t \(name)"))
            return
        }
        passFirstRun(tmux, name)   // trust/theme/first-run screens

        onProgress(Progress(phase: .joining, detail: "asking it to join \(room)…"))
        sendLine(tmux, name, joinBrief(room: room, nick: nick, kind: kind))

        // Confirm it actually joined (~40s).
        for _ in 0..<20 {
            usleep(2_000_000)
            if didJoin(room: room, nick: nick) {
                onProgress(Progress(phase: .joined, detail: "joined \(room)")); return
            }
        }
        onProgress(Progress(phase: .failed,
                            detail: "spawned but hasn't joined yet — check: tmux attach -t \(name)"))
    }

    /// True once `nick` is a member of `room` per the broker.
    static func didJoin(room: String, nick: String) -> Bool {
        let rooms = MeshClient.send(MeshRequest(cmd: "list")).rooms ?? []
        return rooms.first { $0.name == room }?.members.contains(nick) ?? false
    }

    // MARK: tmux drive

    /// Poll the pane until the agent's ready prompt (or a first-run screen)
    /// appears. ~40s ceiling.
    private static func waitForBoot(_ tmux: String, _ name: String) -> Bool {
        for _ in 0..<20 {
            let pane = Shell.run(tmux, ["capture-pane", "-p", "-t", name]).out.lowercased()
            if pane.contains("bypass") || pane.contains("for shortcuts") || pane.contains("effort")
                || pane.contains("trust this folder") || pane.contains("full access")
                || pane.contains("›") {
                return true
            }
            usleep(2_000_000)
        }
        return false
    }

    /// Dismiss trust / first-run prompts by pressing Enter a couple of times
    /// (defaults are safe: trust folder, keep theme). Harmless if none are up.
    private static func passFirstRun(_ tmux: String, _ name: String) {
        for _ in 0..<2 {
            let pane = Shell.run(tmux, ["capture-pane", "-p", "-t", name]).out.lowercased()
            if pane.contains("trust this folder") || pane.contains("do you") || pane.contains("theme") {
                _ = Shell.run(tmux, ["send-keys", "-t", name, "Enter"])
                usleep(1_500_000)
            }
        }
    }

    /// Type a line and submit it — the three-step send (literal text, pause,
    /// separate Enter) that dodges Claude/Codex paste-detection.
    private static func sendLine(_ tmux: String, _ name: String, _ text: String) {
        _ = Shell.run(tmux, ["send-keys", "-t", name, "-l", "--", text])
        usleep(400_000)
        _ = Shell.run(tmux, ["send-keys", "-t", name, "Enter"])
    }
}
