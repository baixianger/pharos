import Foundation
import PharosMeshCore

public struct CLIAgentLaunchRequest: Sendable {
    public var name: String
    public var app: String
    public var cwd: String
    public var model: String?
    public var sessionName: String?
    public var openingMessage: String?
    public var host: String

    public init(
        name: String,
        app: String,
        cwd: String,
        model: String? = nil,
        sessionName: String? = nil,
        openingMessage: String? = nil,
        host: String = "local"
    ) {
        self.name = name
        self.app = app
        self.cwd = cwd
        self.model = model
        self.sessionName = sessionName
        self.openingMessage = openingMessage
        self.host = host
    }
}

public struct CLIAgentLaunchResult: Sendable {
    public var sessionID: String
    public var binding: LightTmuxBinding
    public var notes: [String]

    public init(sessionID: String, binding: LightTmuxBinding, notes: [String] = []) {
        self.sessionID = sessionID
        self.binding = binding
        self.notes = notes
    }
}

public enum CLIAgentLifecycleError: Error, Equatable, LocalizedError {
    case invalid(String)
    case tmux(String)
    case needsHuman(String)
    case timeout(String)
    case alreadyAlive(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let s): return "invalid: \(s)"
        case .tmux(let s): return "tmux: \(s)"
        case .needsHuman(let s): return "needs human: \(s)"
        case .timeout(let s): return "timeout: \(s)"
        case .alreadyAlive(let s): return "already alive: \(s)"
        }
    }
}

public struct CLIAgentStopResult: Equatable, Sendable {
    public var binding: LightTmuxBinding
    public var how: String // "graceful" | "killed" | "already-ended"

    public init(binding: LightTmuxBinding, how: String) {
        self.binding = binding
        self.how = how
    }
}

public struct CLIAgentStatus: Equatable, Sendable {
    public var tmux: String
    public var live: String
    public var activity: CLIAgentActivity
    public var detail: String

    public init(tmux: String, live: String, activity: CLIAgentActivity, detail: String) {
        self.tmux = tmux
        self.live = live
        self.activity = activity
        self.detail = detail
    }
}

public struct CLIAgentLifecycle: Sendable {
    public var tmux: TmuxController
    public var runner: any LightProcessRunning         // for lsof
    public var env: [String: String]
    public var home: String
    public var daemon: (@Sendable () -> CodexDaemonClient?)   // nil when no daemon socket
    public var quota: CLIQuotaBook
    public var timeout: TimeInterval
    public var pollInterval: TimeInterval
    public var sleep: @Sendable (TimeInterval) -> Void
    public var now: @Sendable () -> Date
    public var isExecutable: @Sendable (String) -> Bool
    public var threadFinder: (@Sendable (_ snapshot: Set<String>, _ targetCwd: String) throws -> String?)?
    public var threadReader: (@Sendable (String) throws -> CodexThreadInfo)?
    public var rolloutsRoot: URL?

    public init(
        tmux: TmuxController,
        runner: any LightProcessRunning,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        daemon: (@Sendable () -> CodexDaemonClient?)? = nil,
        quota: CLIQuotaBook = CLIQuotaBook(),
        timeout: TimeInterval = 40,
        pollInterval: TimeInterval = 0.5,
        sleep: @Sendable @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @Sendable @escaping () -> Date = Date.init,
        isExecutable: @Sendable @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        threadFinder: (@Sendable (_ snapshot: Set<String>, _ targetCwd: String) throws -> String?)? = nil,
        threadReader: (@Sendable (String) throws -> CodexThreadInfo)? = nil,
        rolloutsRoot: URL? = nil
    ) {
        self.tmux = tmux
        self.runner = runner
        self.env = env
        let defaultHome = home ?? env["HOME"] ?? NSHomeDirectory()
        self.home = defaultHome
        self.daemon = daemon ?? {
            let p = CodexDaemonClient.socketPath(env: env)
            return FileManager.default.fileExists(atPath: p) ? CodexDaemonClient(socketPath: p) : nil
        }
        self.quota = quota
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
        self.isExecutable = isExecutable
        self.threadFinder = threadFinder
        self.threadReader = threadReader
        self.rolloutsRoot = rolloutsRoot
    }

    public func launch(_ request: CLIAgentLaunchRequest) throws -> CLIAgentLaunchResult {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            throw CLIAgentLifecycleError.invalid("cwd does not exist or is not a directory: \(request.cwd)")
        }
        let resolvedCwd = URL(fileURLWithPath: request.cwd).resolvingSymlinksInPath().path

        let sessionName = request.sessionName ?? TmuxNames.sessionName(forMember: request.name)
        guard TmuxNames.isValid(sessionName) else {
            throw CLIAgentLifecycleError.invalid("invalid tmux session name '\(sessionName)'")
        }

        guard let descriptor = CLIAgentDescriptor.named(request.app, env: env) else {
            throw CLIAgentLifecycleError.invalid("unsupported app: \(request.app)")
        }

        var adopted = false
        if tmux.hasSession(sessionName) {
            let p = tmux.pane(sessionName)
            let paneDead = p?.dead ?? false
            let pid = p?.pid
            let isRunning = (pid != nil) && (tmux.processStart(pid: pid!) != nil)
            let agentAlive = !paneDead && isRunning
            if agentAlive {
                adopted = true
            } else {
                throw CLIAgentLifecycleError.invalid("tmux session \(sessionName) exists; use member revive or kill it")
            }
        }

        var snapshot: Set<String> = []
        if !adopted && descriptor.app == "codex" {
            if let client = daemon() {
                snapshot = Set((try? client.loadedThreads()) ?? [])
            }
        }

        let model: String?
        if descriptor.app == "agy" {
            if let reqModel = request.model {
                model = reqModel
            } else if !descriptor.modelChain.isEmpty {
                guard let picked = quota.pick(app: "agy", chain: descriptor.modelChain) else {
                    let nextReset = quota.earliestReset(app: "agy", chain: descriptor.modelChain)
                    let dateStr = nextReset != nil ? ISO8601DateFormatter().string(from: nextReset!) : "unknown"
                    throw CLIAgentLifecycleError.needsHuman("all agy models are over quota until \(dateStr)")
                }
                model = picked
            } else {
                model = nil
            }
        } else {
            model = request.model
        }

        let launchStart = now()
        if !adopted {
            let bin = descriptor.resolveBinary(env: env, isExecutable: isExecutable)
            let argv = descriptor.launchArgv(bin: bin, model: model)
            if let err = tmux.newSession(name: sessionName, cwd: resolvedCwd, argv: argv) {
                throw CLIAgentLifecycleError.tmux(err)
            }
        }

        try waitUntilReady(name: sessionName, descriptor: descriptor, cwd: resolvedCwd)

        let sessionID: String
        var rolloutNote: String? = nil
        if descriptor.app == "codex" {
            let discStart = now()
            var foundID: String?
            while true {
                if let finder = threadFinder {
                    if let id = try finder(snapshot, resolvedCwd) {
                        foundID = id
                        break
                    }
                } else {
                    // The TUI starts the shared daemon itself; its socket can appear a moment after the prompt.
                    if let client = daemon(), let current = try? client.loadedThreads() {
                        let candidates = (adopted && snapshot.isEmpty) ? current : current.filter { !snapshot.contains($0) }
                        var matching: [String] = []
                        for id in candidates {
                            if let info = try? client.readThread(id),
                               let threadCwd = info.cwd {
                                let resThreadCwd = URL(fileURLWithPath: threadCwd).resolvingSymlinksInPath().path
                                if resThreadCwd == resolvedCwd && (info.originator?.contains("codex") == true) {
                                    matching.append(id)
                                }
                            }
                        }
                        if matching.count == 1 {
                            foundID = matching[0]
                            break
                        } else if matching.count > 1 {
                            throw CLIAgentLifecycleError.invalid("ambiguous")
                        }
                    }

                    // Fallback to rollout scanning
                    let rolloutsDir = rolloutsRoot ?? CodexRolloutReader().root
                    let scanSince = adopted ? Date.distantPast : launchStart.addingTimeInterval(-2)
                    if let rolloutID = scanRolloutSessionID(root: rolloutsDir, since: scanSince, cwd: resolvedCwd) {
                        foundID = rolloutID
                        rolloutNote = "session id from rollout (this codex TUI is not on the shared daemon)"
                        break
                    }

                    if now().timeIntervalSince(discStart) >= timeout {
                        throw CLIAgentLifecycleError.needsHuman("codex daemon not available (the TUI normally starts it); check `codex app-server daemon version`")
                    }
                    sleep(pollInterval)
                    continue
                }

                if now().timeIntervalSince(discStart) >= timeout {
                    throw CLIAgentLifecycleError.timeout("timed out discovering codex session id")
                }
                sleep(pollInterval)
            }
            guard let id = foundID else {
                throw CLIAgentLifecycleError.timeout("timed out discovering codex session id")
            }
            sessionID = id
        } else if descriptor.app == "agy" {
            let openingMsg = request.openingMessage ?? "Pharos registered this session as member \(request.name). Reply with exactly: ready"
            guard tmux.sendText(sessionName, openingMsg) else {
                throw CLIAgentLifecycleError.tmux("failed to send opening message to tmux session \(sessionName)")
            }

            guard let panePID = tmux.pane(sessionName)?.pid else {
                throw CLIAgentLifecycleError.tmux("could not determine pane PID for tmux session \(sessionName)")
            }

            let discStart = now()
            var foundUUID: String?
            while true {
                let inv = LightInvocation(
                    argv: ["lsof", "-a", "-p", "\(panePID)", "-Fn"],
                    stdin: "",
                    executable: true,
                    fallback: false,
                    summary: "lsof agy presence lock \(panePID)",
                    loopback: true
                )
                let out = runner.run(inv, stdin: "")
                if out.status == 0 {
                    for line in out.stdout.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("n") {
                            let path = String(trimmed.dropFirst())
                            if let range = path.range(of: "/presence/"), path.hasSuffix(".lock") {
                                let after = path[range.upperBound...]
                                let uuid = String(after.dropLast(".lock".count))
                                if !uuid.isEmpty && !uuid.contains("/") {
                                    foundUUID = uuid
                                    break
                                }
                            }
                        }
                    }
                }
                if foundUUID != nil {
                    break
                }
                if now().timeIntervalSince(discStart) >= timeout {
                    throw CLIAgentLifecycleError.timeout("timed out waiting for agy presence lock in lsof")
                }
                sleep(pollInterval)
            }
            guard let uuid = foundUUID else {
                throw CLIAgentLifecycleError.timeout("timed out waiting for agy presence lock in lsof")
            }
            sessionID = uuid
        } else {
            sessionID = UUID().uuidString
        }

        let panePID = tmux.pane(sessionName)?.pid
        let agentStarted = panePID != nil ? tmux.processStart(pid: panePID!) : nil
        let binding = LightTmuxBinding(
            session: sessionName,
            cwd: resolvedCwd,
            model: model,
            agentPID: panePID,
            agentStarted: agentStarted,
            launchedAt: now(),
            endedAt: nil
        )
        var notes = adopted ? ["adopted existing tmux session \(sessionName)"] : []
        if let rolloutNote { notes.append(rolloutNote) }
        return CLIAgentLaunchResult(sessionID: sessionID, binding: binding, notes: notes)
    }

    public func revive(member: LightMember) throws -> LightTmuxBinding {
        guard let binding = member.tmux else {
            throw CLIAgentLifecycleError.invalid("member has no tmux binding")
        }
        guard let descriptor = CLIAgentDescriptor.named(member.app, env: env) else {
            throw CLIAgentLifecycleError.invalid("unsupported app: \(member.app)")
        }
        let live = tmux.liveness(binding)
        if live.agentAlive {
            throw CLIAgentLifecycleError.alreadyAlive("agent is already alive in tmux session \(binding.session)")
        }

        let model: String?
        if descriptor.app == "agy" {
            if let current = binding.model, quota.exhausted(app: "agy", model: current) == nil {
                model = current
            } else {
                guard let picked = quota.pick(app: "agy", chain: descriptor.modelChain) else {
                    let nextReset = quota.earliestReset(app: "agy", chain: descriptor.modelChain)
                    let dateStr = nextReset != nil ? ISO8601DateFormatter().string(from: nextReset!) : "unknown"
                    throw CLIAgentLifecycleError.needsHuman("all agy models are over quota until \(dateStr)")
                }
                model = picked
            }
        } else {
            model = binding.model
        }

        let bin = descriptor.resolveBinary(env: env, isExecutable: isExecutable)
        let argv = descriptor.resumeArgv(bin: bin, sessionID: member.sessionID, model: model)
        let resolvedCwd = URL(fileURLWithPath: binding.cwd).resolvingSymlinksInPath().path

        if live.tmuxAlive {
            if let err = tmux.respawn(name: binding.session, cwd: resolvedCwd, argv: argv) {
                throw CLIAgentLifecycleError.tmux(err)
            }
        } else {
            if let err = tmux.newSession(name: binding.session, cwd: resolvedCwd, argv: argv) {
                throw CLIAgentLifecycleError.tmux(err)
            }
        }

        try waitUntilReady(name: binding.session, descriptor: descriptor, cwd: resolvedCwd)

        let newPane = tmux.pane(binding.session)
        let newPid = newPane?.pid
        let newStart = newPid != nil ? tmux.processStart(pid: newPid!) : nil

        return LightTmuxBinding(
            session: binding.session,
            cwd: resolvedCwd,
            model: model,
            agentPID: newPid,
            agentStarted: newStart,
            launchedAt: now(),
            endedAt: nil,
            autoRevive: binding.autoRevive,
            endedReason: nil
        )
    }

    public func stop(member: LightMember, force: Bool, timeout: TimeInterval = 20) throws -> CLIAgentStopResult {
        guard let binding = member.tmux else {
            throw CLIAgentLifecycleError.invalid("member has no tmux binding")
        }

        guard tmux.hasSession(binding.session) else {
            var updated = binding
            updated.endedAt = binding.endedAt ?? now()
            updated.endedReason = "stopped"
            return CLIAgentStopResult(binding: updated, how: "already-ended")
        }

        guard let descriptor = CLIAgentDescriptor.named(member.app, env: env) else {
            throw CLIAgentLifecycleError.invalid("unsupported app: \(member.app)")
        }

        var isBusy = false
        var isNeedsHuman = false

        if member.app == "agy" {
            let capture = tmux.capture(binding.session) ?? ""
            let paneState = AgyPane.classify(capture)
            if paneState == .busy { isBusy = true }
            if case .needsHuman = paneState { isNeedsHuman = true }
        } else if member.app == "codex" {
            var daemonChecked = false
            if let client = daemon(), let info = try? client.readThread(member.sessionID) {
                daemonChecked = true
                if info.status.needsHuman {
                    isNeedsHuman = true
                } else if info.status.busy {
                    isBusy = true
                }
            }
            if !daemonChecked {
                let capture = tmux.capture(binding.session) ?? ""
                let paneState = CodexPane.classify(capture)
                if paneState == .busy { isBusy = true }
                if case .needsHuman = paneState { isNeedsHuman = true }
            }
        }

        if isNeedsHuman && !force {
            throw CLIAgentLifecycleError.invalid("member is waiting on a prompt; answer it or use --force")
        }
        if isBusy && !force {
            throw CLIAgentLifecycleError.invalid("member is busy; use --force to interrupt and stop")
        }

        if (isNeedsHuman || isBusy) && force {
            _ = tmux.sendKey(binding.session, "Escape")
            sleep(1)
        }

        _ = tmux.sendLiteral(binding.session, descriptor.exitCommand)
        sleep(0.7)
        _ = tmux.sendKey(binding.session, "Enter")

        let start = now()
        var how = "killed"
        var retriedEnter = false
        while now().timeIntervalSince(start) < timeout {
            let sessionExists = tmux.hasSession(binding.session)
            if !sessionExists {
                how = "graceful"
                break
            }
            let p = tmux.pane(binding.session)
            let paneDead = p?.dead ?? false
            let pidAlive = (p?.pid != nil) && (tmux.processStart(pid: p!.pid) != nil)
            if paneDead || !pidAlive {
                if tmux.hasSession(binding.session) {
                    _ = tmux.kill(binding.session)
                }
                how = "graceful"
                break
            }
            if !retriedEnter && now().timeIntervalSince(start) >= 4.0 {
                _ = tmux.sendKey(binding.session, "Enter")
                retriedEnter = true
            }
            sleep(pollInterval)
        }

        if how == "killed" {
            if tmux.hasSession(binding.session) {
                _ = tmux.kill(binding.session)
            }
        }

        var updated = binding
        updated.endedAt = now()
        updated.endedReason = "stopped"
        return CLIAgentStopResult(binding: updated, how: how)
    }

    public func status(member: LightMember) -> CLIAgentStatus {
        guard let binding = member.tmux else {
            return CLIAgentStatus(tmux: "-", live: "-", activity: .unknown, detail: "-")
        }

        let tmuxAlive = tmux.hasSession(binding.session)
        guard tmuxAlive else {
            let live: String
            if binding.endedReason == "stopped" {
                live = "stopped"
            } else if binding.endedAt != nil {
                live = "ended"
            } else {
                live = "dead"
            }
            return CLIAgentStatus(tmux: binding.session, live: live, activity: .unknown, detail: live)
        }

        let live = tmux.liveness(binding)
        guard live.agentAlive else {
            return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "agent not running")
        }

        if member.app == "agy" {
            let text = tmux.capture(binding.session) ?? ""
            let paneState = AgyPane.classify(text)
            switch paneState {
            case .idle:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .idle, detail: "idle")
            case .busy:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .thinking, detail: "busy")
            case .needsHuman(let what):
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .needsHuman, detail: what)
            case .quota:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .idle, detail: "quota")
            case .unknown:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "unknown")
            }
        } else if member.app == "codex" {
            let info: CodexThreadInfo?
            if let reader = threadReader {
                info = try? reader(member.sessionID)
            } else if let client = daemon() {
                info = try? client.readThread(member.sessionID)
            } else {
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "daemon missing")
            }
            guard let info else {
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "read thread failed")
            }
            switch info.status {
            case .idle:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .idle, detail: "idle")
            case .active(let flags):
                if info.status.needsHuman {
                    return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .needsHuman, detail: flags.joined(separator: ", "))
                } else if flags.isEmpty {
                    return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .thinking, detail: "thinking")
                } else {
                    return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .thinking, detail: flags.joined(separator: ", "))
                }
            case .notLoaded:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "notLoaded")
            case .systemError:
                return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "systemError")
            }
        } else {
            return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "-")
        }
    }

    private func waitUntilReady(name: String, descriptor: CLIAgentDescriptor, cwd: String) throws {
        let start = now()
        while true {
            let text = tmux.capture(name) ?? ""

            if descriptor.app == "agy" {
                let paneState = AgyPane.classify(text)
                switch paneState {
                case .idle:
                    return
                case .needsHuman(let what):
                    if what.contains("update prompt") {
                        throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) update prompt: attach with `tmux attach -t \(name)`, choose Skip, then run member launch again")
                    }
                    throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) asks to trust \(cwd): attach with `tmux attach -t \(name)`, answer, then run member launch again")
                case .busy, .quota, .unknown:
                    break
                }
            } else if descriptor.app == "codex" {
                let paneState = CodexPane.classify(text)
                switch paneState {
                case .needsHuman(let what):
                    if what.contains("update prompt") {
                        throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) update prompt: attach with `tmux attach -t \(name)`, choose Skip, then run member launch again")
                    }
                    throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) asks to trust \(cwd): attach with `tmux attach -t \(name)`, answer, then run member launch again")
                default:
                    break
                }
                if text.contains("Trust this folder?") {
                    throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) asks to trust \(cwd): attach with `tmux attach -t \(name)`, answer, then run member launch again")
                }
                if text.contains("›") || text.contains("Ask Codex") {
                    return
                }
            } else {
                return
            }

            if tmux.hasSession(name) {
                let p = tmux.pane(name)
                if p?.dead == true {
                    throw CLIAgentLifecycleError.tmux("agent process exited in session \(name)")
                }
            } else {
                throw CLIAgentLifecycleError.tmux("tmux session \(name) terminated unexpectedly")
            }

            if now().timeIntervalSince(start) >= timeout {
                throw CLIAgentLifecycleError.timeout("timed out waiting for \(descriptor.app) to become ready in \(name)")
            }

            sleep(pollInterval)
        }
    }

    private func scanRolloutSessionID(root: URL, since: Date, cwd: String) -> String? {
        let scanDir: URL
        let sub = root.appendingPathComponent("sessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: sub.path) {
            scanDir = sub
        } else {
            scanDir = root
        }
        guard let walker = FileManager.default.enumerator(
            at: scanDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        struct Candidate {
            let id: String
            let mtime: Date
        }
        var candidates: [Candidate] = []
        let resolvedCwd = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path

        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard !url.pathComponents.contains("archived") && !url.pathComponents.contains("archived_sessions") else { continue }
            guard name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") else { continue }
            guard let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = resourceValues.contentModificationDate,
                  mtime >= since else { continue }

            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let chunk = handle.readData(ofLength: 4096)
            guard let firstLine = String(data: chunk, encoding: .utf8)?.components(separatedBy: "\n").first,
                  let lineData = firstLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any],
                  let payloadCwd = payload["cwd"] as? String,
                  let id = payload["id"] as? String else { continue }

            let resPayloadCwd = URL(fileURLWithPath: payloadCwd).resolvingSymlinksInPath().path
            if resPayloadCwd == resolvedCwd {
                candidates.append(Candidate(id: id, mtime: mtime))
            }
        }

        return candidates.max(by: { $0.mtime < $1.mtime })?.id
    }
}
