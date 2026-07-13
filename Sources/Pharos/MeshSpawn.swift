import Foundation

/// Spawn a coding agent (Claude or Codex) into a tmux session and drive it to
/// JOIN a mesh chat room, then confirm it actually joined — the passive-join
/// flow from the CLI skill, exposed to the GUI's "add member" action.
///
/// First cut is LOCAL only (this Mac). Remote-host spawn (over SSH, with
/// keychain unlock) reuses RemoteLaunch and is a follow-up.
///
/// All steps block (tmux + polling) — always call `spawnLocal` off the main
/// thread and hop progress back to the main actor in the caller.
enum MeshSpawn {
    enum Phase: String { case booting, joining, joined, failed }
    struct Progress { let phase: Phase; let detail: String }

    /// tmux session name for a spawned mesh member.
    static func sessionName(_ nick: String) -> String { "pharos-mesh-\(safe(nick))" }

    /// A scratch working dir per spawned member (keeps cwd stable + off the
    /// user's real projects). The nick + --session + --kind make it addressable
    /// regardless of cwd, so a neutral dir is fine.
    private static func agentDir(_ nick: String) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos/mesh-agents/\(safe(nick))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func safe(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
    }

    /// The shell command tmux runs as the session's foreground process.
    private static func launchCommand(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude --dangerously-skip-permissions"
        // Codex needs the hook-trust bypass so the mesh hooks (~/.codex/hooks.json)
        // actually run without a first-run trust prompt.
        case .codex:  return "codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        }
    }

    /// Spawn `kind` locally in tmux and brief it to join `room` as `nick`.
    /// Reports progress; returns once joined or failed.
    static func spawnLocal(room: String, nick: String, kind: AgentKind,
                           onProgress: @escaping (Progress) -> Void) {
        guard let tmux = LaunchService.tmuxPath else {
            onProgress(Progress(phase: .failed, detail: "tmux not found on this Mac")); return
        }
        let name = sessionName(nick)
        _ = Shell.run(tmux, ["kill-session", "-t", name])   // clear a stale one
        guard Shell.run(tmux, ["new-session", "-d", "-s", name, "-c", agentDir(nick),
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
        let brief = "Join the mesh chat room \(room) as nick \(nick): run  "
            + "pharos mesh join \(room) \(nick) --session <the session id the Pharos mesh "
            + "SessionStart hook gave you in your context> --kind \(kind.rawValue). "
            + "Then run  pharos mesh say \(room) \(nick) \"\(nick) joined\"  and wait for messages. "
            + "Do nothing else."
        sendLine(tmux, name, brief)

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
