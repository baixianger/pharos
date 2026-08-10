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

    /// Where a spawned agent's tmux session should start. Resolved on whichever
    /// machine actually runs the session, so `.project` always maps to that
    /// host's own registered checkout path.
    enum WorkDir: Sendable, Equatable {
        case scratch              // neutral per-member dir (the default, off real projects)
        case path(String)         // an explicit absolute directory
        case project(String)      // a registered project name → its per-host path

        var isDefault: Bool { self == .scratch }
    }

    /// Outcome of resolving a `WorkDir` to a concrete directory.
    enum ResolvedDir { case ok(String), fail(String) }

    /// Resolve a `WorkDir` against THIS Mac's filesystem + project registry.
    static func resolveLocal(_ workDir: WorkDir, room: String, nick: String) -> ResolvedDir {
        switch workDir {
        case .scratch:
            return .ok(agentDir(room: room, nick: nick))
        case .path(let raw):
            let p = (raw as NSString).expandingTildeInPath
            guard isDirectory(p) else { return .fail("directory not found: \(p)") }
            return .ok(p)
        case .project(let name):
            guard let project = PharosCore.findProject(name) else { return .fail("project not found: \(name)") }
            guard let path = project.resolvedLocalPath(forHost: HostIdentity.current), !path.isEmpty else {
                return .fail("project '\(name)' has no path registered on this Mac")
            }
            guard isDirectory(path) else { return .fail("project path missing: \(path)") }
            return .ok(path)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// tmux session name for a spawned mesh member.
    static func sessionName(room: String, nick: String) -> String {
        "pharos-mesh-\(safe(room))-\(safe(nick))"
    }

    /// A scratch working dir per spawned member (keeps cwd stable + off the
    /// user's real projects). The pane-recorded session id + nick make it addressable
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
    static func launchCommand(_ kind: AgentKind, executable: String? = nil,
                              environment: [String: String] = [:]) -> String {
        switch kind {
        case .claude:
            return kind.command(yolo: true, executable: executable, environment: environment)
        // Codex needs the hook-trust bypass so the mesh hooks (~/.codex/hooks.json)
        // actually run without a first-run trust prompt.
        case .codex:
            return kind.command(yolo: true, executable: executable, environment: environment)
                + " --dangerously-bypass-hook-trust"
        }
    }

    static func launchCommand(_ kind: AgentKind,
                              resolution: LaunchService.AgentResolution) -> String {
        launchCommand(kind, executable: resolution.executable,
                      environment: resolution.environment)
    }

    /// Brief typed into either agent after its composer is ready. Keeping this
    /// shared guarantees local and remote spawn register the same identity.
    static func joinBrief(room: String, nick: String, kind: AgentKind,
                          session: String) -> String {
        "Join the mesh chat room \(room) as nick \(nick): run  "
            // Do not pass the tmux session name here. The agent's structured
            // SessionStart hook records the real Codex/Claude session id, and
            // `mesh join` resolves that id from the current tmux seat. Using
            // the tmux name made later Stop/@mention hooks address a different
            // identity and left the real session stuck busy.
            + "pharos mesh join \(room) \(nick) --session \(session) --kind \(kind.rawValue). "
            + "Then run  pharos mesh send \"\(nick) joined\". "
            + "Return to the idle composer after announcing; do not run a listener or polling command. "
            + "Pharos hooks and nudges will wake you for new messages. Do nothing else."
    }

    /// One entry point for GUI and CLI. `host == nil` means this Mac; otherwise
    /// it is an SSH alias/IP for the paired Mac.
    static func spawn(room: String, nick: String, kind: AgentKind, host: String? = nil,
                      workDir: WorkDir = .scratch,
                      onProgress: @escaping (Progress) -> Void) async {
        let projectID: String?
        switch workDir {
        case .scratch:
            projectID = "__scratch__"
        case .project(let name):
            projectID = PharosCore.findProject(name)?.id.uuidString
        case .path:
            projectID = nil // explicit paths remain an SSH/local rescue path
        }
        if let projectID, let node = MeshNodeControl.activeNode(for: host) {
            let name = sessionName(room: room, nick: nick)
            let memberID = UUID().uuidString.lowercased()
            onProgress(Progress(phase: .booting, detail: "asking Node \(node.host) to start \(kind.rawValue)…"))
            let command = await MeshNodeControl.spawn(
                node: node,
                payload: MeshNodeSpawnPayload(projectID: projectID, sessionName: name,
                                              memberID: memberID,
                                              agent: kind.rawValue, yolo: true,
                                              room: room, nick: nick)
            )
            guard command.state == .succeeded else {
                onProgress(Progress(phase: .failed, detail: command.result ?? "Node spawn failed"))
                return
            }
            onProgress(Progress(phase: .joining, detail: "waiting for \(nick) to join \(room)…"))
            for _ in 0..<40 {
                try? await Task.sleep(for: .seconds(1))
                if didJoin(room: room, nick: nick, memberID: memberID) {
                    onProgress(Progress(phase: .joined, detail: "joined \(room) via Node"))
                    return
                }
            }
            onProgress(Progress(phase: .failed, detail: "Node started the agent but it did not join the room"))
            return
        }
        if let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RemoteLaunch.spawnMeshAgent(room: room, nick: nick, kind: kind,
                                        host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                                        workDir: workDir, onProgress: onProgress)
        } else {
            await spawnLocal(room: room, nick: nick, kind: kind,
                             workDir: workDir, onProgress: onProgress)
        }
    }

    /// Spawn `kind` locally in tmux and brief it to join `room` as `nick`.
    /// Reports progress; returns once joined or failed.
    static func spawnLocal(room: String, nick: String, kind: AgentKind,
                           workDir: WorkDir = .scratch,
                           onProgress: @escaping (Progress) -> Void) async {
        let dir: String
        switch resolveLocal(workDir, room: room, nick: nick) {
        case .ok(let d): dir = d
        case .fail(let why): onProgress(Progress(phase: .failed, detail: why)); return
        }
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
        guard let resolution = await LaunchService.agentResolution(kind) else {
            onProgress(Progress(phase: .failed,
                                detail: "\(kind.label) not found in common locations or login shell PATH"))
            return
        }
        let name = sessionName(room: room, nick: nick)
        let memberID = UUID().uuidString.lowercased()
        let socket = localTmuxSocket(memberID: memberID)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socket).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = runTmux(tmux, socket: socket, ["kill-server"])
        try? FileManager.default.removeItem(atPath: socket)
        let command = "/usr/bin/env PHAROS_MESH_SESSION='\(memberID)' "
            + launchCommand(kind, resolution: resolution)
        guard runTmux(tmux, socket: socket, ["new-session", "-d", "-s", name, "-c", dir,
                                             "-x", "200", "-y", "50", command]).ok else {
            onProgress(Progress(phase: .failed, detail: "couldn't start the tmux session")); return
        }
        // Size the window to whichever client is currently driving it, instead of
        // the smallest attached one — so a phone/desktop attaching later doesn't
        // make the agent's TUI redraw-fight (the "flushing" screen). Best-effort.
        _ = runTmux(tmux, socket: socket, ["set-option", "-t", name, "window-size", "latest"])
        _ = runTmux(tmux, socket: socket, ["set-window-option", "-t", name, "aggressive-resize", "on"])
        let where_ = workDir.isDefault ? "" : " in \((dir as NSString).abbreviatingWithTildeInPath)"
        onProgress(Progress(phase: .booting, detail: "starting \(kind.rawValue)\(where_)…"))

        guard waitForBoot(tmux, socket: socket, name) else {
            onProgress(Progress(phase: .failed,
                                detail: "\(kind.rawValue) didn't reach its prompt — peek: tmux -S \(socket) attach -t \(name)"))
            return
        }
        onProgress(Progress(phase: .joining, detail: "asking it to join \(room)…"))
        sendLine(tmux, socket: socket, name,
                 joinBrief(room: room, nick: nick, kind: kind, session: memberID))

        // Confirm it actually joined (~40s).
        for _ in 0..<20 {
            usleep(2_000_000)
            if didJoin(room: room, nick: nick, memberID: memberID) {
                onProgress(Progress(phase: .joined, detail: "joined \(room)")); return
            }
        }
        onProgress(Progress(phase: .failed,
                            detail: "spawned but hasn't joined yet — check: tmux -S \(socket) attach -t \(name)"))
    }

    /// True once `nick` is a member of `room` per the broker.
    static func didJoin(room: String, nick: String, memberID: String? = nil) -> Bool {
        let roster = MeshClient.send(MeshRequest(cmd: "who"))
        return roster.members?.contains { member in
            member.nick == nick && member.rooms.contains(room)
                && (memberID == nil || member.id == memberID)
        } ?? false
    }

    // MARK: tmux drive

    enum BootScreenState: Equatable {
        case waiting
        case skipUpdate
        case submitInterstitial
        case ready
    }

    /// Codex uses `›` both for its composer and for trust-screen selection.
    /// Require the actual composer before sending the room join brief.
    static func bootScreenState(_ pane: String) -> BootScreenState {
        let lower = pane.lowercased()
        if lower.contains("update available") &&
            lower.contains("update now") && lower.contains("skip") {
            return .skipUpdate
        }
        if lower.contains("do you trust") || lower.contains("trust the contents") ||
            lower.contains("trust this folder") ||
            (lower.contains("choose") && lower.contains("theme")) ||
            lower.contains("press enter to continue") {
            return .submitInterstitial
        }
        if lower.contains("bypass permissions on") || lower.contains("for shortcuts") ||
            lower.contains("effort:") ||
            (lower.contains("full access") && lower.contains("context")) {
            return .ready
        }
        return .waiting
    }

    /// Poll the pane until the agent's real composer appears. ~40s ceiling.
    private static func waitForBoot(_ tmux: String, socket: String, _ name: String) -> Bool {
        for _ in 0..<20 {
            let pane = runTmux(tmux, socket: socket, ["capture-pane", "-p", "-t", name]).out
            switch bootScreenState(pane) {
            case .ready:
                return true
            case .skipUpdate:
                _ = runTmux(tmux, socket: socket, ["send-keys", "-t", name, "Down", "Enter"])
                usleep(1_500_000)
            case .submitInterstitial:
                _ = runTmux(tmux, socket: socket, ["send-keys", "-t", name, "Enter"])
                usleep(1_500_000)
            case .waiting:
                usleep(2_000_000)
            }
        }
        return false
    }

    /// Type a line and submit it — the three-step send (literal text, pause,
    /// separate Enter) that dodges Claude/Codex paste-detection.
    private static func sendLine(_ tmux: String, _ name: String, _ text: String) {
        _ = Shell.run(tmux, ["send-keys", "-t", name, "-l", "--", text])
        usleep(400_000)
        _ = Shell.run(tmux, ["send-keys", "-t", name, "Enter"])
    }

    private static func sendLine(_ tmux: String, socket: String, _ name: String, _ text: String) {
        _ = runTmux(tmux, socket: socket, ["send-keys", "-t", name, "-l", "--", text])
        usleep(400_000)
        _ = runTmux(tmux, socket: socket, ["send-keys", "-t", name, "Enter"])
    }

    private static func runTmux(_ tmux: String, socket: String, _ args: [String]) -> Shell.Result {
        Shell.run(tmux, ["-S", socket] + args)
    }

    static func localTmuxSocket(memberID: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos/tmux", isDirectory: true)
            .appendingPathComponent("mesh-\(safe(memberID)).sock")
            .path
    }
}
