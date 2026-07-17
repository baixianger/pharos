import Foundation
import PharosMeshCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Per-Host, least-privilege Mesh worker. It keeps an outbound event loop to
/// the Broker and may only type a fixed mailbox prompt into a locally-owned,
/// registered tmux pane that still contains the expected coding-agent process
/// and visibly shows an idle composer.
enum MeshNode {
    static func run(endpoint: String?, buildID: String? = nil) -> Int32 {
        if let endpoint { MeshClient.remoteEndpoint = endpoint }
        var state = LoopState()
        FileHandle.standardError.write(Data("pharos node: starting as \(hostName)\(tailscaleIP.map { " (\($0))" } ?? "")\n".utf8))

        // Each iteration runs inside its own autorelease pool: Process/Pipe/
        // FileHandle are ObjC-backed on Darwin, and a CLI main loop never
        // drains the implicit pool — without this, every subprocess probe
        // leaks its pipe fds until the process hits the fd ceiling and
        // silently loses every authenticated Broker call (heartbeat, command
        // drain, mark). Linux Foundation has no autorelease semantics; the
        // explicit pipe closes in run(_:_:) are sufficient there.
        while true {
            #if canImport(Darwin)
            autoreleasepool { iterate(&state, buildID: buildID) }
            #else
            iterate(&state, buildID: buildID)
            #endif
        }
    }

    private struct LoopState {
        var cursor: UInt64?
        var backoff: UInt32 = 1
        var missingProbeCounts: [String: Int] = [:]
        var nextReconcile = Date.distantPast
        var heartbeatHealthy = true
    }

    private static func iterate(_ state: inout LoopState, buildID: String?) {
        heartbeat(buildID: buildID, healthy: &state.heartbeatHealthy)
        drainNodeCommands(missingProbeCounts: &state.missingProbeCounts)
        if Date() >= state.nextReconcile {
            reconcileMembers(missingProbeCounts: &state.missingProbeCounts)
            state.nextReconcile = Date().addingTimeInterval(20)
        }
        // The held event request is still push-style delivery; a five
        // second ceiling also bounds durable-command retry latency when a
        // trust/composer transition itself produced no new Broker event.
        let response = MeshClient.events(after: state.cursor, timeoutMs: 5_000)
        guard response.ok, let next = response.cursor else {
            FileHandle.standardError.write(Data("pharos node: broker unavailable; retrying\n".utf8))
            sleep(state.backoff)
            state.backoff = min(state.backoff * 2, 15)
            return
        }
        state.backoff = 1
        state.cursor = next
    }

    private static func drainNodeCommands(missingProbeCounts: inout [String: Int]) {
        for _ in 0..<20 {
            let response = MeshClient.send(MeshRequest(cmd: "node-command-next", nodeID: nodeID))
            guard response.ok, let command = response.command else { return }
            switch command.action {
            case .poke:
                executePokeCommand(command)
            case .reconcile:
                reconcileMembers(missingProbeCounts: &missingProbeCounts)
                update(command, state: .running, result: "reconciling")
                update(command, state: .succeeded, result: managedSessionInventory())
            case .spawnAgent:
                executeSpawnCommand(command)
            case .stopSession:
                executeStopCommand(command)
            }
        }
    }

    private static func executePokeCommand(_ command: MeshNodeCommand) {
        guard let payload = command.payload?.data(using: .utf8),
              let request = try? JSONDecoder().decode(MeshNodePokePayload.self, from: payload) else {
            update(command, state: .failed, result: "invalid poke payload")
            return
        }
        let roster = MeshClient.send(MeshRequest(cmd: "who"))
        guard roster.ok, let member = roster.members?.first(where: { $0.id == request.memberID }) else {
            update(command, state: .failed, result: "member no longer exists")
            return
        }
        guard owns(member) else {
            update(command, state: .failed, result: "member is not owned by this node")
            return
        }
        if request.requireUnread, (member.unread ?? 0) == 0 {
            update(command, state: .running, result: "mailbox already consumed")
            update(command, state: .succeeded, result: "mailbox already consumed")
            return
        }
        if let reason = poke(member) {
            if reason == "agent session is gone" {
                update(command, state: .failed, result: reason)
            } else if reason.hasPrefix("hook owns delivery") {
                update(command, state: .accepted, result: reason,
                       retryAt: Date().timeIntervalSince1970 + 5)
            } else {
                update(command, state: .failed, result: reason)
            }
            return
        }
        update(command, state: .running, result: "wake-up injected")
        update(command, state: .succeeded, result: "wake-up injected")
    }

    private static func executeSpawnCommand(_ command: MeshNodeCommand) {
        guard let data = command.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MeshNodeSpawnPayload.self, from: data),
              validSessionName(payload.sessionName),
              ["claude", "codex"].contains(payload.agent),
              let tmux = tmuxExecutable,
              let executable = agentExecutable(payload.agent) else {
            update(command, state: .failed, result: "invalid spawn payload, project path, or agent executable")
            return
        }
        guard validRoomField(payload.room), validRoomField(payload.nick) else {
            update(command, state: .failed, result: "room or nick contains unsafe control characters")
            return
        }
        let projectPath: String
        if payload.projectID == "__scratch__", let room = payload.room, let nick = payload.nick {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pharos/mesh-agents/\(safePathPart(room))/\(safePathPart(nick))",
                                      isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            projectPath = directory.path
        } else if let registered = MeshNodeProjectPaths.path(for: payload.projectID) {
            projectPath = registered
        } else {
            update(command, state: .failed, result: "project path is not registered on this node")
            return
        }
        prepareNodeTmuxDirectory()
        let prefix = ["-S", nodeTmuxSocket]
        if run(tmux, prefix + ["has-session", "-t", payload.sessionName]).ok {
            continueSpawnBootstrap(command, payload: payload, tmux: tmux, prefix: prefix)
            return
        }
        var arguments = prefix + ["new-session", "-d", "-s", payload.sessionName,
                                  "-c", projectPath, "-x", "200", "-y", "50", executable]
        if payload.yolo {
            arguments += payload.agent == "claude"
                ? ["--dangerously-skip-permissions"]
                : ["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust"]
        }
        let result = run(tmux, arguments)
        if result.ok {
            _ = run(tmux, prefix + ["set-option", "-t", payload.sessionName, "window-size", "latest"])
            if payload.room?.isEmpty == false, payload.nick?.isEmpty == false {
                update(command, state: .accepted, result: "agent started; waiting for bootstrap",
                       retryAt: Date().timeIntervalSince1970 + 2)
            } else {
                update(command, state: .running, result: "managed tmux session started")
                update(command, state: .succeeded,
                       result: "started \(payload.sessionName) on \(nodeTmuxSocket)")
            }
        } else {
            update(command, state: .failed, result: result.output.isEmpty ? "tmux spawn failed" : result.output)
        }
    }

    /// Starting an interactive coding agent is a durable state machine, not a
    /// fire-and-forget shell command. Both Claude and Codex can stop at a
    /// first-use workspace trust screen before they expose their composer. We
    /// only acknowledge the exact built-in prompts, then wait for a verified
    /// idle composer before injecting the fixed room bootstrap instruction.
    private static func continueSpawnBootstrap(_ command: MeshNodeCommand,
                                               payload: MeshNodeSpawnPayload,
                                               tmux: String, prefix: [String]) {
        guard let room = payload.room, let nick = payload.nick,
              !room.isEmpty, !nick.isEmpty else {
            update(command, state: .running, result: "session already exists")
            update(command, state: .succeeded, result: "session already exists")
            return
        }

        let roster = MeshClient.send(MeshRequest(cmd: "who"))
        if roster.ok, roster.members?.contains(where: {
            $0.nick == nick && $0.rooms.contains(room) && owns($0)
                && $0.tmuxSocket == nodeTmuxSocket
        }) == true {
            update(command, state: .running, result: "agent joined room")
            update(command, state: .succeeded,
                   result: "started \(payload.sessionName); @\(nick) joined \(room)")
            return
        }

        if command.result?.hasPrefix("room bootstrap submitted") == true {
            update(command, state: .accepted, result: "room bootstrap submitted; waiting for room join",
                   retryAt: Date().timeIntervalSince1970 + 5)
            return
        }

        let capture = run(tmux, prefix + ["capture-pane", "-p", "-t", payload.sessionName])
        guard capture.ok else {
            update(command, state: .accepted, result: "waiting for agent pane",
                   retryAt: Date().timeIntervalSince1970 + 2)
            return
        }
        if MeshPaneSafety.isKnownWorkspaceTrustPrompt(capture.output) {
            let confirmed = run(tmux, prefix + ["send-keys", "-t", payload.sessionName, "Enter"])
            update(command, state: confirmed.ok ? .accepted : .failed,
                   result: confirmed.ok ? "confirmed coding-agent workspace trust" : "failed to confirm workspace trust",
                   retryAt: confirmed.ok ? Date().timeIntervalSince1970 + 2 : nil)
            return
        }
        if MeshPaneSafety.paneLooksIdle(capture.output) {
            let prompt = "Join the Pharos mesh room \(room) as \(nick), announce that you joined, then return to the idle composer. Use the session id supplied by your SessionStart context when joining."
            let typed = run(tmux, prefix + ["send-keys", "-t", payload.sessionName, "-l", "--", prompt])
            if typed.ok { usleep(350_000) }
            let submitted = typed.ok
                ? run(tmux, prefix + ["send-keys", "-t", payload.sessionName, "Enter"])
                : CommandResult(ok: false, output: "literal send-keys failed")
            update(command, state: submitted.ok ? .accepted : .failed,
                   result: submitted.ok ? "room bootstrap submitted" : submitted.output,
                   retryAt: submitted.ok ? Date().timeIntervalSince1970 + 4 : nil)
            return
        }
        update(command, state: .accepted, result: "waiting for coding-agent composer or room join",
               retryAt: Date().timeIntervalSince1970 + 2)
    }

    private static func executeStopCommand(_ command: MeshNodeCommand) {
        guard let data = command.payload?.data(using: .utf8),
              let payload = try? JSONDecoder().decode(MeshNodeStopPayload.self, from: data),
              !payload.memberID.isEmpty, let tmux = tmuxExecutable else {
            update(command, state: .failed, result: "invalid stop payload or tmux unavailable")
            return
        }
        let roster = MeshClient.send(MeshRequest(cmd: "who"))
        guard roster.ok, let member = roster.members?.first(where: { $0.id == payload.memberID }) else {
            update(command, state: .succeeded, result: "member already absent")
            return
        }
        guard owns(member), let target = stopTarget(member) else {
            update(command, state: .failed, result: "member is not owned by this node or has no safe tmux target")
            return
        }
        let prefix = target.socket.map { ["-S", $0] } ?? []
        update(command, state: .running, result: "stopping managed tmux session")
        let lookup = run(tmux, prefix + ["display-message", "-p", "-t", target.pane, "#{session_name}"])
        guard lookup.ok else {
            update(command, state: .succeeded, result: "session already absent")
            return
        }
        let sessionName = lookup.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validSessionName(sessionName) else {
            update(command, state: .failed, result: "tmux returned an unsafe session name")
            return
        }
        let result = run(tmux, prefix + ["kill-session", "-t", sessionName])
        update(command, state: result.ok ? .succeeded : .failed,
               result: result.ok ? "stopped \(sessionName)" : result.output)
    }

    /// Resolve stop authority from Broker-owned member identity, never from a
    /// caller-supplied session name. nil socket deliberately means tmux's
    /// default server; an explicit socket is accepted only after path checks.
    static func stopTarget(_ member: MeshMemberInfo) -> (socket: String?, pane: String)? {
        guard let pane = member.tmuxPane, validPane(pane) else { return nil }
        if let socket = member.tmuxSocket, !validSocket(socket) { return nil }
        return (member.tmuxSocket, pane)
    }

    private static func managedSessionInventory() -> String {
        guard let tmux = tmuxExecutable else { return "[]" }
        prepareNodeTmuxDirectory()
        let result = run(tmux, ["-S", nodeTmuxSocket, "list-sessions", "-F", "#{session_name}"])
        let sessions = result.ok ? result.output.split(whereSeparator: \.isNewline).map(String.init) : []
        guard let data = try? JSONEncoder().encode(sessions) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static var nodeTmuxSocket: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pharos/tmux/node.sock").path
    }

    private static func prepareNodeTmuxDirectory() {
        let directory = URL(fileURLWithPath: nodeTmuxSocket).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static func validSessionName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 120
            && value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }

    private static func validRoomField(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.count <= 120 && !value.contains(where: { $0.isNewline || $0.asciiValue == 0 })
    }

    private static func safePathPart(_ value: String) -> String {
        let safe = String(value.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
        return String(safe.prefix(120))
    }

    private static func agentExecutable(_ agent: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [String]
        if agent == "claude" {
            candidates = ["\(home)/.local/bin/claude", "\(home)/.npm-global/bin/claude",
                          "\(home)/.bun/bin/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"]
        } else {
            candidates = ["\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex",
                          "\(home)/.bun/bin/codex", "/opt/homebrew/bin/codex",
                          "/usr/local/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        }
        if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return direct
        }
        let shell = FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/bash"
        let resolved = run(shell, ["-lic", "command -v \(agent)"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: resolved) ? resolved : nil
    }

    private static func update(_ command: MeshNodeCommand, state: MeshNodeCommandState,
                               result: String, retryAt: Double? = nil) {
        var request = MeshRequest(cmd: "node-command-update", state: state.rawValue,
                                  payload: result, nodeID: nodeID, commandID: command.id)
        request.retryAt = retryAt
        let response = MeshClient.send(request)
        if !response.ok { log("command \(command.id) ACK failed: \(response.error ?? "unknown")") }
    }

    private static func heartbeat(buildID: String?, healthy: inout Bool) {
        let response = MeshClient.send(MeshRequest(cmd: "node-heartbeat", memberID: nodeID,
                                                   host: hostName, tailscaleIP: tailscaleIP,
                                                   payload: buildID))
        // A rejected heartbeat unregisters this Node from every control path
        // (stop/spawn/poke). That must never be silent — log the transition.
        if response.ok != healthy {
            healthy = response.ok
            log(healthy ? "heartbeat restored"
                        : "heartbeat rejected: \(response.error ?? "no response")")
        }
    }

    /// Periodically verify only durable machine facts: the exact pane and its
    /// coding-agent process still exist. UI text is intentionally not parsed;
    /// hook leases alone govern busy/blocked expiry.
    private static func reconcileMembers(missingProbeCounts: inout [String: Int]) {
        let response = MeshClient.send(MeshRequest(cmd: "who"))
        guard response.ok else { return }
        var seen = Set<String>()
        for member in response.members ?? [] where owns(member) && seen.insert(member.id).inserted {
            guard member.state != MeshSessionState.gone.rawValue,
                  let pane = member.tmuxPane, validPane(pane),
                  let tmux = tmuxExecutable else { continue }
            if let socket = member.tmuxSocket, !validSocket(socket) { continue }
            let prefix = member.tmuxSocket.map { ["-S", $0] } ?? []
            let root = run(tmux, prefix + ["display-message", "-p", "-t", pane, "#{pane_pid}"])
            guard root.ok, let rootPID = Int(root.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                recordMissing(member, counts: &missingProbeCounts)
                continue
            }
            let processList = run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
            guard processList.ok,
                  MeshPaneSafety.processTreeContainsAgent(processList.output, rootPID: rootPID,
                                                          kind: member.kind) else {
                recordMissing(member, counts: &missingProbeCounts)
                continue
            }
            missingProbeCounts.removeValue(forKey: member.id)
        }
    }

    private static func recordMissing(_ member: MeshMemberInfo, counts: inout [String: Int]) {
        let count = (counts[member.id] ?? 0) + 1
        counts[member.id] = count
        guard count >= 2 else { return }
        markObserved(member, state: .gone)
        counts.removeValue(forKey: member.id)
    }

    private static func markObserved(_ member: MeshMemberInfo, state: MeshSessionState) {
        var request = MeshRequest(cmd: "mark", memberID: member.id, state: state.rawValue)
        request.expectedState = member.state
        request.expectedStateTs = member.stateTs
        let response = MeshClient.send(request)
        if response.ok { log("reconciled @\(member.nick) to \(state.rawValue)") }
    }

    static func owns(_ member: MeshMemberInfo) -> Bool {
        if let remoteIP = member.tailscaleIP, !remoteIP.isEmpty,
           let localIP = tailscaleIP, !localIP.isEmpty {
            return remoteIP == localIP
        }
        return normalized(member.host) == normalized(hostName)
    }

    static func poke(_ member: MeshMemberInfo) -> String? {
        if member.state == MeshSessionState.gone.rawValue { return "agent session is gone" }
        guard MeshPaneSafety.allowsPoke(state: member.state, stateTs: member.stateTs) else {
            return "hook owns delivery while state is \(member.state ?? "unknown")"
        }
        guard let pane = member.tmuxPane, validPane(pane) else { return "missing or unsafe tmux pane" }
        guard let tmux = tmuxExecutable else { return "tmux not found" }
        if let socket = member.tmuxSocket, !validSocket(socket) { return "unsafe tmux socket" }
        let prefix = member.tmuxSocket.map { ["-S", $0] } ?? []

        let root = run(tmux, prefix + ["display-message", "-p", "-t", pane, "#{pane_pid}"])
        guard root.ok, let rootPID = Int(root.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return "tmux pane is unavailable"
        }
        let processList = run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        guard processList.ok,
              MeshPaneSafety.processTreeContainsAgent(processList.output, rootPID: rootPID, kind: member.kind) else {
            return "pane no longer runs the registered agent"
        }
        let message = "You have new mesh messages. Run: pharos mesh recv \(member.nick) --member \(member.id)"
        guard run(tmux, prefix + ["send-keys", "-t", pane, "-l", "--", message]).ok else {
            return "tmux send-keys failed"
        }
        usleep(350_000)
        guard run(tmux, prefix + ["send-keys", "-t", pane, "Enter"]).ok else {
            return "tmux Enter failed"
        }
        return nil
    }

    private static var hostName: String {
        let value = ProcessInfo.processInfo.hostName
        return value.isEmpty ? "this-host" : value
    }

    private static let nodeID: String = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pharos", isDirectory: true)
        let file = directory.appendingPathComponent("mesh-node-id")
        if let value = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data((value + "\n").utf8).write(to: file, options: .atomic)
        return value
    }()

    /// Cached: the getter is consulted on every heartbeat and every ownership
    /// check, and the underlying probe shells out to the tailscale CLI. The
    /// single-threaded node loop is the only reader/writer.
    nonisolated(unsafe) private static var tailscaleIPCache: (value: String?, expires: Date) = (nil, .distantPast)

    private static var tailscaleIP: String? {
        if Date() < tailscaleIPCache.expires { return tailscaleIPCache.value }
        let value = probeTailscaleIP()
        tailscaleIPCache = (value, Date().addingTimeInterval(60))
        return value
    }

    private static func probeTailscaleIP() -> String? {
        if let value = ProcessInfo.processInfo.environment["PHAROS_TAILSCALE_IP"], !value.isEmpty { return value }
        for executable in ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                           "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
            where FileManager.default.isExecutableFile(atPath: executable) {
            let value = run(executable, ["ip", "-4"]).output
                .split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, value.split(separator: ".").count == 4 { return value }
        }
        return nil
    }

    private static var tmuxExecutable: String? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    private static func validPane(_ value: String) -> Bool {
        MeshPaneSafety.validTmuxPane(value)
    }

    private static func validSocket(_ value: String) -> Bool {
        MeshPaneSafety.validTmuxSocket(value)
    }

    private struct CommandResult { let ok: Bool; let output: String }

    private static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        // Close both ends deterministically: FileHandle deallocation is not
        // prompt in this daemon (see the loop's autorelease note), and leaked
        // pipe fds eventually exhaust the process fd table.
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return CommandResult(ok: false, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(ok: process.terminationStatus == 0,
                             output: String(decoding: data, as: UTF8.self))
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("pharos node: \(message)\n".utf8))
    }
}
