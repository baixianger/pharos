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
        threadReader: (@Sendable (String) throws -> CodexThreadInfo)? = nil
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

        if !adopted {
            let bin = descriptor.resolveBinary(env: env, isExecutable: isExecutable)
            let argv = descriptor.launchArgv(bin: bin, model: model)
            if let err = tmux.newSession(name: sessionName, cwd: resolvedCwd, argv: argv) {
                throw CLIAgentLifecycleError.tmux(err)
            }
        }

        try waitUntilReady(name: sessionName, descriptor: descriptor, cwd: resolvedCwd)

        let sessionID: String
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
                    guard let client = daemon(), let current = try? client.loadedThreads() else {
                        if now().timeIntervalSince(discStart) >= timeout {
                            throw CLIAgentLifecycleError.needsHuman("codex daemon not available (the TUI normally starts it); check `codex app-server daemon version`")
                        }
                        sleep(pollInterval)
                        continue
                    }
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
        let notes = adopted ? ["adopted existing tmux session \(sessionName)"] : []
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
            endedAt: nil
        )
    }

    public func status(member: LightMember) -> CLIAgentStatus {
        guard let binding = member.tmux else {
            return CLIAgentStatus(tmux: "-", live: "-", activity: .unknown, detail: "-")
        }

        let tmuxAlive = tmux.hasSession(binding.session)
        guard tmuxAlive else {
            let live = binding.endedAt != nil ? "ended" : "dead"
            return CLIAgentStatus(tmux: binding.session, live: live, activity: .unknown, detail: live)
        }

        let live = tmux.liveness(binding)
        guard live.agentAlive else {
            return CLIAgentStatus(tmux: binding.session, live: live.label, activity: .unknown, detail: "agent not running")
        }

        if member.app == "agy" {
            let text = tmux.capture(binding.session, lines: 100) ?? ""
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
            let text = tmux.capture(name, lines: 100) ?? ""

            if descriptor.app == "agy" {
                let paneState = AgyPane.classify(text)
                switch paneState {
                case .idle:
                    return
                case .needsHuman:
                    throw CLIAgentLifecycleError.needsHuman("\(descriptor.app) asks to trust \(cwd): attach with `tmux attach -t \(name)`, answer, then run member launch again")
                case .busy, .quota, .unknown:
                    break
                }
            } else if descriptor.app == "codex" {
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
}
