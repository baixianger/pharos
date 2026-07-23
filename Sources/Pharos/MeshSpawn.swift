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
    static func joinBrief(room: String, nick: String, kind: AgentKind) -> String {
        "Join the mesh chat room \(room) as nick \(nick): run  "
            + "pharos mesh join \(room) \(nick) --kind \(kind.rawValue). "
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
        if !PharosMeshRuntimeMode.usesDistributedMesh,
           let projectID, let node = MeshNodeControl.activeNode(for: host) {
            let name = sessionName(room: room, nick: nick)
            onProgress(Progress(phase: .booting, detail: "asking Node \(node.host) to start \(kind.rawValue)…"))
            let command = await MeshNodeControl.spawn(
                node: node,
                payload: MeshNodeSpawnPayload(projectID: projectID, sessionName: name,
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
                if await didJoin(room: room, nick: nick) {
                    onProgress(Progress(phase: .joined, detail: "joined \(room) via Node"))
                    return
                }
            }
            onProgress(Progress(phase: .failed, detail: "Node started the agent but it did not join the room"))
            return
        }
        if let host, !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await RemoteLaunch.spawnMeshAgent(
                room: room, nick: nick, kind: kind,
                host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                workDir: workDir, onProgress: onProgress
            )
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
        _ = Shell.run(tmux, ["kill-session", "-t", name])   // clear a stale one
        guard Shell.run(tmux, ["new-session", "-d", "-s", name, "-c", dir,
                               "-x", "200", "-y", "50",
                               launchCommand(kind, resolution: resolution)]).ok else {
            onProgress(Progress(phase: .failed, detail: "couldn't start the tmux session")); return
        }
        // Size the window to whichever client is currently driving it, instead of
        // the smallest attached one — so a phone/desktop attaching later doesn't
        // make the agent's TUI redraw-fight (the "flushing" screen). Best-effort.
        _ = Shell.run(tmux, ["set-option", "-t", name, "window-size", "latest"])
        _ = Shell.run(tmux, ["set-window-option", "-t", name, "aggressive-resize", "on"])
        let where_ = workDir.isDefault ? "" : " in \((dir as NSString).abbreviatingWithTildeInPath)"
        onProgress(Progress(phase: .booting, detail: "starting \(kind.rawValue)\(where_)…"))

        guard waitForBoot(tmux, name) else {
            onProgress(Progress(phase: .failed,
                                detail: "\(kind.rawValue) didn't reach its prompt — peek: tmux attach -t \(name)"))
            return
        }
        onProgress(Progress(phase: .joining, detail: "asking it to join \(room)…"))
        sendLine(tmux, name, joinBrief(room: room, nick: nick, kind: kind))

        // Confirm it actually joined (~40s).
        for _ in 0..<20 {
            usleep(2_000_000)
            if let member = await joinedMember(room: room, nick: nick) {
                do {
                    try await registerLocalHostResource(
                        memberID: member.id, tmuxSession: name
                    )
                    onProgress(Progress(phase: .joined, detail: "joined \(room)"))
                } catch {
                    onProgress(Progress(
                        phase: .failed,
                        detail: "joined \(room), but Host control registration failed: \(error.localizedDescription)"
                    ))
                }
                return
            }
        }
        onProgress(Progress(phase: .failed,
                            detail: "spawned but hasn't joined yet — check: tmux attach -t \(name)"))
    }

    /// True once `nick` is materialized in `room`. Product mode reads the
    /// shared local replica, so CLI and GUI confirmation never contacts the
    /// retired Broker. Legacy diagnostic mode keeps its historical probe.
    static func didJoin(room: String, nick: String) async -> Bool {
        await joinedMember(room: room, nick: nick) != nil
    }

    static func joinedMember(
        room: String, nick: String
    ) async -> DistributedChatMember? {
        if PharosMeshRuntimeMode.usesDistributedMesh {
            do {
                let replica = try MeshLocalReplica.openDefault(headless: true)
                let group = try await replica.ensureActiveTrustGroup()
                let chat = DistributedChatRegistry(replica: replica, group: group)
                guard let target = try await chat.rooms().first(where: {
                    $0.name.localizedCaseInsensitiveCompare(room) == .orderedSame
                }) else { return nil }
                return try await chat.members(in: target).first(where: {
                    $0.nick.localizedCaseInsensitiveCompare(nick) == .orderedSame
                })
            } catch {
                return nil
            }
        }
        let rooms = MeshClient.send(MeshRequest(cmd: "list")).rooms ?? []
        guard rooms.first(where: { $0.name == room })?.members.contains(nick) == true else {
            return nil
        }
        return DistributedChatMember(id: nick, nick: nick)
    }

    private static func registerLocalHostResource(
        memberID: String, tmuxSession: String
    ) async throws {
        guard let resourceID = MeshResourceID(rawValue: memberID) else {
            throw MeshSpawnControlError.invalidMemberID
        }
        let replica = try MeshLocalReplica.openDefault(headless: true)
        let group = try await replica.ensureActiveTrustGroup()
        let binding = try DistributedHostResourceBinding(
            resourceID: resourceID, tmuxSession: tmuxSession, tmuxSocket: nil
        )
        try DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        ).save(binding, for: resourceID)
        // The spawn knows the intended tmux name, but only a structured hook
        // running inside that pane can prove the exact socket/pane/runtime
        // fingerprint. Reconcile upgrades control capabilities immediately
        // after that proof appears.
        let actions: Set<MeshHostAction> = [.presence]
        let timestamp = MeshHybridTimestamp(
            wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        if let existing = try await replica.store.hostResource(
            in: group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        ) {
            guard existing.state == .active else {
                throw DistributedMeshStoreError.hostResourceRetired
            }
            if Set(existing.allowedActions) != actions {
                _ = try await replica.store.replaceHostResource(
                    in: group, on: replica.identity, resourceID: resourceID,
                    allowedActions: actions, at: max(timestamp, existing.updatedAt)
                )
            }
        } else {
            _ = try await replica.store.registerHostResource(
                in: group, on: replica.identity, resourceID: resourceID,
                allowedActions: actions, at: timestamp
            )
        }
    }

    // MARK: tmux drive

    enum BootScreenState: Equatable {
        case waiting
        case skipUpdate
        case submitInterstitial
        case ready
    }

    /// Classify interstitials before readiness. Codex uses `›` both for its
    /// normal composer and for the trust-screen selection cursor; the launch
    /// command also contains the word "bypass". Neither is sufficient proof
    /// that the composer is ready.
    static func bootScreenState(_ pane: String) -> BootScreenState {
        let lower = pane.lowercased()
        // Never auto-select "Update now" inside a freshly-created tmux
        // session. Homebrew can take minutes and replacing the running binary
        // can strand its TUI. Skip this launch-time prompt; updates remain a
        // deliberate user/admin operation outside agent creation.
        if lower.contains("update available") &&
            lower.contains("update now") && lower.contains("skip") {
            return .skipUpdate
        }
        if lower.contains("do you trust") ||
            lower.contains("trust the contents") ||
            lower.contains("trust this folder") ||
            (lower.contains("choose") && lower.contains("theme")) ||
            lower.contains("press enter to continue") {
            return .submitInterstitial
        }
        if lower.contains("for shortcuts") || lower.contains("effort:") ||
            lower.contains("full access") && lower.contains("context") {
            return .ready
        }
        return .waiting
    }

    /// Poll the pane until the agent's real composer appears, submitting any
    /// trust/theme/continue interstitial first. ~40s ceiling.
    private static func waitForBoot(_ tmux: String, _ name: String) -> Bool {
        for _ in 0..<20 {
            let pane = Shell.run(tmux, ["capture-pane", "-p", "-t", name]).out
            switch bootScreenState(pane) {
            case .ready:
                return true
            case .skipUpdate:
                _ = Shell.run(tmux, ["send-keys", "-t", name, "Down", "Enter"])
                usleep(1_500_000)
            case .submitInterstitial:
                _ = Shell.run(tmux, ["send-keys", "-t", name, "Enter"])
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
}

private enum MeshSpawnControlError: LocalizedError {
    case invalidMemberID

    var errorDescription: String? { "The agent session ID is not a safe Host resource ID." }
}
