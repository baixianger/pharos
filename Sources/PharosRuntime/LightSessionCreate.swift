import Foundation
import PharosMeshCore

// Session creation stays outside the messaging rules. The Broker decides whether
// the target Pharos node is online, forwards the request over the existing SSH
// route, or leaves it in that node's inbox. The target process is the only one
// that probes, launches, or calls achat. A miss never runs achat on the caller.

public enum LightAppProbe: Equatable, Sendable {
    case ready
    case runningWithoutDebug
    case portHeldByOther
    case absent
}

public enum LightLaunchDecision: Equatable, Sendable {
    case reuse
    case launch
    case refuse(String)

    public static func decide(probe: LightAppProbe, launchRequested: Bool) -> LightLaunchDecision {
        switch probe {
        case .ready:
            return .reuse
        case .runningWithoutDebug:
            return .refuse("app is running without its debug endpoint; quit it and relaunch (relaunching the same app reuses the existing instance and ignores the debug port)")
        case .portHeldByOther:
            return .refuse("debug port is held by something else; nothing was started")
        case .absent:
            if launchRequested { return .launch }
            return .refuse("app not running")
        }
    }
}

public protocol LightAppProbing: Sendable {
    func probe(app: String, port: Int) -> LightAppProbe
}

/// How an app can accept a new project. `restart` means the live app would
/// discard an out-of-band write, so Pharos does not write anything.
public enum LightProjectAddable: String, Equatable, Sendable {
    case api
    case ui
    case restart
}

public struct LightProjectPlan: Equatable, Sendable {
    public var addable: LightProjectAddable
    public var callAchat: Bool
    public var message: String?

    public init(addable: LightProjectAddable, callAchat: Bool, message: String?) {
        self.addable = addable
        self.callAchat = callAchat
        self.message = message
    }
}

/// Per-app decision for `project add`. Codex is the app-server API. DSH is the
/// web API only while its desktop is not the file writer, and the desktop UI
/// when the debug endpoint belongs to DSH. Antigravity is the desktop UI only.
public enum LightProjectAdd {
    public static func addable(app: String) -> LightProjectAddable {
        switch app {
        case "codex", "dsh": return .api
        case "ag": return .ui
        default: return .restart
        }
    }

    public static func plan(app: String, probe: LightAppProbe) -> LightProjectPlan {
        switch app {
        case "codex":
            return LightProjectPlan(addable: .api, callAchat: true, message: nil)
        case "dsh":
            switch probe {
            case .ready:
                return LightProjectPlan(addable: .ui, callAchat: true, message: nil)
            case .absent:
                return LightProjectPlan(addable: .api, callAchat: true, message: nil)
            case .runningWithoutDebug:
                return LightProjectPlan(
                    addable: .restart, callAchat: false,
                    message: "dsh desktop is running without a debug port and would overwrite a web-side add. Use Add workspace in the app, or quit dsh and run this again. Nothing was written."
                )
            case .portHeldByOther:
                return LightProjectPlan(addable: .ui, callAchat: false,
                                        message: "debug port is held by something else; nothing was started")
            }
        case "ag":
            if probe == .ready {
                return LightProjectPlan(addable: .ui, callAchat: true, message: nil)
            }
            return LightProjectPlan(
                addable: .ui, callAchat: false,
                message: "Antigravity adds a project only from the desktop (Create New Project, then pick the folder). Nothing was written."
            )
        default:
            return LightProjectPlan(addable: .restart, callAchat: false, message: "project add is not available for this app")
        }
    }
}

public struct LightDebugPorts: Equatable, Sendable {
    public var dsh: Int?
    public var ag: Int?
    public var codex: Int?

    public init(dsh: Int? = nil, ag: Int? = nil, codex: Int? = nil) {
        self.dsh = dsh
        self.ag = ag
        self.codex = codex
    }

    public func port(for app: String) -> Int? {
        switch app {
        case "dsh": return dsh
        case "ag": return ag
        case "codex": return codex
        default: return nil
        }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LightDebugPorts {
        func port(_ key: String) -> Int? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Int(raw), (1...65535).contains(value) else { return nil }
            return value
        }
        return LightDebugPorts(dsh: port("PHAROS_DSH_CDP_PORT"), ag: port("PHAROS_AG_CDP_PORT"),
                               codex: port("PHAROS_CODEX_CDP_PORT"))
    }
}

public struct LightAppBins: Equatable, Sendable {
    public var achat: String
    public var dsh: String?
    public var ag: String?
    public var codex: String?

    public init(achat: String = "achat", dsh: String? = nil, ag: String? = nil, codex: String? = nil) {
        self.achat = achat
        self.dsh = dsh
        self.ag = ag
        self.codex = codex
    }

    public func executable(for app: String) -> String? {
        switch app {
        case "dsh": return dsh
        case "ag": return ag
        case "codex": return codex
        default: return nil
        }
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LightAppBins {
        func pick(_ key: String) -> String? {
            let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if value.isEmpty || value.contains("\n") || value.contains("\0") { return nil }
            return value
        }
        let achat = pick("PHAROS_ACHAT_BIN") ?? "achat"
        return LightAppBins(achat: achat, dsh: pick("PHAROS_DSH_APP"), ag: pick("PHAROS_AG_APP"),
                            codex: pick("PHAROS_CODEX_APP"))
    }
}

public struct LightSessionService {
    public var relay: LightRelay
    public var runner: any LightProcessRunning
    public var prober: any LightAppProbing
    public var ports: LightDebugPorts
    public var apps: LightAppBins
    public var pause: @Sendable (TimeInterval) -> Void
    public var launchPolls: Int

    public init(relay: LightRelay, runner: any LightProcessRunning, prober: any LightAppProbing,
                ports: LightDebugPorts, apps: LightAppBins,
                pause: @escaping @Sendable (TimeInterval) -> Void = { _ in },
                launchPolls: Int = 20) {
        self.relay = relay
        self.runner = runner
        self.prober = prober
        self.ports = ports
        self.apps = apps
        self.pause = pause
        self.launchPolls = launchPolls
    }

    public func execute(arguments: [String]) -> LightCLIResult {
        let argv = SessionArgv.parse(arguments)
        switch argv.positional.first {
        case "new":
            return perform(.new, argv)
        case "workspaces":
            return perform(.workspaces, argv)
        case "pull", "heartbeat":
            return pull(argv)
        case "ack":
            return ack(argv)
        default:
            return Self.usage("pharos session new|workspaces|pull|ack")
        }
    }

    public func executeProject(arguments: [String]) -> LightCLIResult {
        let argv = SessionArgv.parse(arguments)
        guard let op = argv.positional.first, op == "list" || op == "add" else {
            return Self.usage("pharos project list|add --host H --app dsh|ag|codex [--path DIR] [--name N] [--dry-run] [--no-queue]")
        }
        guard let app = argv.option("app"), ["dsh", "ag", "codex"].contains(app) else {
            return Self.usage("pharos project \(op) --host H --app dsh|ag|codex")
        }
        let path = argv.option("path") ?? ""
        if op == "add", path.isEmpty || path.contains("\n") || path.contains("\0") {
            return Self.usage("pharos project add --host H --app A --path DIR [--name N] [--dry-run] [--no-queue]")
        }
        let name = argv.option("name") ?? ""
        if name.contains("\n") || name.contains("\0") {
            return Self.usage("pharos project add --host H --app A --path DIR [--name N]")
        }
        var spec = ProjectSpec(op: op, app: app, host: argv.option("host") ?? "local", path: path, name: name,
                               dryRun: argv.flag("dry-run"))
        if argv.flag("here") {
            let outcome = op == "list" ? listHere(spec) : addHere(spec)
            return renderProject(outcome, host: spec.host, json: true)
        }
        guard let host = argv.option("host"), !host.isEmpty else {
            return Self.usage("pharos project \(op) --host H --app \(app)")
        }
        spec.host = host
        return forwardProject(spec, noQueue: argv.flag("no-queue"), json: argv.flag("json"))
    }

    /// Apply a pulled job's result. A second completion of the same id is ignored.
    public func complete(id: String, result: String) -> LightCLIResult {
        if relay.nodeJobWasApplied(id) {
            return LightCLIResult(exitCode: 0, text: "duplicate ignored")
        }
        guard let job = relay.nodeJob(id) else {
            return LightCLIResult(exitCode: 1, text: "error: unknown request \(id)")
        }
        guard let object = Self.extractJSON(result), let here = Self.hereResult(object) else {
            return LightCLIResult(exitCode: 1, text: "error: unreadable session result")
        }
        if !here.ok && here.status != "needs_user_action" {
            return LightCLIResult(exitCode: 1, text: "error: \(here.message ?? "session failed")")
        }
        if job.kind == "session-new", !here.dryRun, here.ok {
            guard let spec = SessionSpec.from(payload: job.payload) else {
                return LightCLIResult(exitCode: 1, text: "error: unreadable session request")
            }
            guard let sessionID = here.sessionId else {
                return LightCLIResult(exitCode: 1, text: "error: achat did not return a session id")
            }
            do {
                _ = try register(spec, sessionID: sessionID)
            } catch let error as LightRelayError {
                if case .duplicateMember = error { _ = relay.ack(job: id) }
                return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
            } catch {
                return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
            }
        }
        guard relay.ack(job: id) else {
            return LightCLIResult(exitCode: 0, text: "duplicate ignored")
        }
        return LightCLIResult(exitCode: 0, text: "acked \(id)")
    }

    public static func launchArgv(executable: String, port: Int) -> [String] {
        let flags = ["--remote-debugging-port=\(port)", "--remote-debugging-address=127.0.0.1"]
        if executable.hasSuffix(".app") {
            return ["open", "-a", executable, "--args"] + flags
        }
        return [executable] + flags
    }

    public static func achatArgv(bin: String, app: String, command: String, workspace: String?,
                                 title: String?, dryRun: Bool) -> [String] {
        var argv = [bin, app, command, "--host", "local", "--json"]
        if let workspace, !workspace.isEmpty {
            argv += ["--project", workspace]
        }
        if dryRun { argv.append("--dry-run") }
        if command == "new", let title, !title.isEmpty { argv.append(title) }
        return argv
    }

    public static func achatWorkspaceArgv(bin: String, app: String, command: String, path: String?,
                                          name: String?, dryRun: Bool) -> [String] {
        var argv = [bin, app, "workspace", command]
        if command == "add", let path, !path.isEmpty { argv.append(path) }
        argv += ["--host", "local", "--json"]
        if let name, !name.isEmpty { argv += ["--name", name] }
        if dryRun { argv.append("--dry-run") }
        return argv
    }

    // MARK: Commands

    private enum Verb {
        case new
        case workspaces
    }

    private func perform(_ verb: Verb, _ argv: SessionArgv) -> LightCLIResult {
        guard let app = argv.option("app"), ["dsh", "ag", "codex"].contains(app) else {
            return Self.usage("pharos session \(verb == .new ? "new" : "workspaces") --host H --app dsh|ag|codex")
        }
        let workspace = argv.option("workspace")
        if verb == .new, workspace == nil || workspace?.isEmpty == true {
            return Self.usage("pharos session new --host H --app A --workspace PROJECT [--title T] [--name N] [--launch] [--dry-run] [--no-queue]")
        }
        let explicitName = argv.option("name")
        let hostForName = argv.option("host") ?? "local"
        let name = explicitName ?? Self.defaultMemberName(app: app, host: hostForName, workspace: workspace ?? "workspace")
        let spec = SessionSpec(app: app, host: hostForName, workspace: workspace ?? "", title: argv.option("title"),
                               name: name, launch: argv.flag("launch"), dryRun: argv.flag("dry-run"),
                               addProject: argv.option("add-project"))
        if argv.flag("here") {
            return performHere(spec, verb: verb, json: true)
        }
        guard let host = argv.option("host"), !host.isEmpty else {
            return Self.usage("pharos session \(verb == .new ? "new" : "workspaces") --host H --app \(app)")
        }
        var forwarded = spec
        forwarded.host = host
        if explicitName == nil {
            forwarded.name = Self.defaultMemberName(app: app, host: host, workspace: workspace ?? "workspace")
        }
        return forwardOrQueue(verb: verb, spec: forwarded, noQueue: argv.flag("no-queue"), json: argv.flag("json"))
    }

    private func forwardOrQueue(verb: Verb, spec: SessionSpec, noQueue: Bool, json: Bool) -> LightCLIResult {
        let status = relay.nodeStatus(spec.host)
        if !status.online {
            return hold(status: status, spec: spec, verb: verb, noQueue: noQueue, json: json)
        }
        let output = ssh(spec.host, command: remoteCommand(verb: verb, spec: spec),
                         summary: "forward pharos session to the target node")
        if let object = Self.extractJSON(output.stdout), let here = Self.hereResult(object) {
            return finishRemote(here, spec: spec, json: json)
        }
        return hold(status: relay.nodeStatus(spec.host), spec: spec, verb: verb, noQueue: noQueue, json: json)
    }

    private func hold(status: LightNodeStatus, spec: SessionSpec, verb: Verb, noQueue: Bool, json: Bool) -> LightCLIResult {
        let message = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen)
        if spec.dryRun || noQueue {
            return offlineResult(message: message, requestID: nil, status: status, json: json, queued: false)
        }
        let kind = verb == .new ? "session-new" : "session-workspaces"
        do {
            let queued = try relay.enqueueNodeJob(node: spec.host, kind: kind, payload: spec.payload())
            return offlineResult(message: message, requestID: queued.job.id, status: status, json: json, queued: true)
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }

    private func finishRemote(_ here: HereBody, spec: SessionSpec, json: Bool) -> LightCLIResult {
        if !here.ok {
            let message = here.message ?? "session failed"
            let status = here.status == "needs_user_action" ? "needs_user_action" : "error"
            if json { return Self.jsonText(["ok": false, "status": status, "message": message], ok: false) }
            return LightCLIResult(exitCode: 1, text: "error: \(message)")
        }
        if !spec.dryRun, !here.dryRun, spec.workspace.isEmpty == false, here.sessionId != nil, here.status != "listed" {
            guard let sessionID = here.sessionId else {
                return LightCLIResult(exitCode: 1, text: "error: achat did not return a session id")
            }
            do {
                let member = try register(spec, sessionID: sessionID)
                if json {
                    return Self.jsonText([
                        "ok": true, "status": "created", "name": member.name, "sessionId": sessionID,
                        "route": here.route ?? "", "node": spec.host,
                    ], ok: true)
                }
                return LightCLIResult(exitCode: 0, text: "registered \(member.name)\nsession \(sessionID)\nroute \(here.route ?? "-")")
            } catch {
                return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
            }
        }
        if here.status == "listed" || !here.projects.isEmpty && here.sessionId == nil && !here.dryRun && spec.workspace.isEmpty {
            return formatProjects(here.projects, json: json)
        }
        if spec.dryRun || here.dryRun {
            if json {
                return Self.jsonText([
                    "ok": true, "status": "dry-run", "route": here.route ?? "", "node": spec.host,
                    "projects": here.projects,
                ], ok: true)
            }
            var lines = ["dry-run", "route \(here.route ?? "-")"]
            if !here.projects.isEmpty { lines.append(here.projects.joined(separator: "\n")) }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        }
        return formatProjects(here.projects, json: json)
    }

    private func performHere(_ spec: SessionSpec, verb: Verb, json: Bool) -> LightCLIResult {
        var ensured = false
        if verb == .new, let path = spec.addProject, !path.isEmpty {
            let outcome = addHere(ProjectSpec(op: "add", app: spec.app, host: spec.host, path: path,
                                              name: spec.workspace, dryRun: spec.dryRun))
            let accepted = outcome.status == "added" || outcome.status == "already" || (spec.dryRun && outcome.ok)
            if !accepted { return renderProject(outcome, host: spec.host, json: json) }
            ensured = true
        }
        guard let port = ports.port(for: spec.app) else {
            return hereFailure("debug port is not configured", spec: spec, json: json)
        }
        let first = prober.probe(app: spec.app, port: port)
        let decision = LightLaunchDecision.decide(probe: first, launchRequested: spec.launch && !spec.dryRun)
        var launched = false
        switch decision {
        case .refuse(let message):
            return hereFailure(message, spec: spec, json: json)
        case .reuse:
            break
        case .launch:
            guard let executable = apps.executable(for: spec.app) else {
                return hereFailure("app executable is not configured", spec: spec, json: json)
            }
            let argv = Self.launchArgv(executable: executable, port: port)
            let started = runner.run(LightInvocation(
                argv: argv, stdin: "", executable: true, fallback: false,
                summary: "launch \(spec.app) with a loopback debug port", loopback: true
            ), stdin: "")
            if started.status != 0 {
                let detail = started.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return hereFailure(detail.isEmpty ? "launch failed" : detail, spec: spec, json: json)
            }
            var ready = false
            for _ in 0..<max(launchPolls, 1) {
                pause(0.05)
                if prober.probe(app: spec.app, port: port) == .ready {
                    ready = true
                    break
                }
            }
            if !ready {
                return hereFailure("app did not become ready", spec: spec, json: json)
            }
            launched = true
        }
        if verb == .new, !ensured {
            if let message = registrationError(spec) {
                return hereFailure(message, spec: spec, json: json)
            }
        }
        let command = verb == .new ? "new" : "list"
        let achat = runner.run(LightInvocation(
            argv: Self.achatArgv(bin: apps.achat, app: spec.app, command: command, workspace: spec.workspace.isEmpty ? nil : spec.workspace,
                                 title: spec.title, dryRun: spec.dryRun),
            stdin: "", executable: true, fallback: false,
            summary: "achat \(spec.app) \(command)", loopback: true
        ), stdin: "")
        guard let object = Self.extractJSON(achat.stdout) else {
            let detail = achat.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty ? "achat failed" : detail
            return hereFailure(message, spec: spec, json: json)
        }
        let parsed = Self.interpretAchat(object)
        if achat.status != 0 || !parsed.ok {
            return hereFailure(parsed.message ?? "achat failed", spec: spec, json: json)
        }
        if verb == .new, !spec.dryRun, !parsed.dryRun, parsed.sessionID == nil {
            return hereFailure("achat did not return a session id", spec: spec, json: json)
        }
        let status = spec.dryRun || parsed.dryRun ? "dry-run" : (verb == .new ? "created" : "listed")
        let body = HereBody(ok: true, status: status, message: parsed.message, sessionId: parsed.sessionID,
                            route: parsed.route, projects: parsed.projects, dryRun: spec.dryRun || parsed.dryRun, launched: launched)
        let text = Self.jsonText(body.object, ok: true)
        return json ? text : text
    }

    private func pull(_ argv: SessionArgv) -> LightCLIResult {
        guard let node = argv.option("node") ?? argv.option("host") else {
            return Self.usage("pharos session pull --node HOST")
        }
        do {
            let jobs = try relay.pull(node: node)
            if argv.flag("json") {
                let rows = jobs.map { job -> [String: Any] in
                    ["id": job.id, "node": job.node, "kind": job.kind, "payload": job.payload, "deliveries": job.deliveries]
                }
                return Self.jsonText(["ok": true, "node": node, "jobs": rows], ok: true)
            }
            if jobs.isEmpty { return LightCLIResult(exitCode: 0, text: "no jobs") }
            return LightCLIResult(exitCode: 0, text: jobs.map { "\($0.id)\t\($0.kind)\t\($0.deliveries)" }.joined(separator: "\n"))
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }

    private func ack(_ argv: SessionArgv) -> LightCLIResult {
        guard let id = argv.positional.dropFirst().first else {
            return Self.usage("pharos session ack <request-id> [--result JSON]")
        }
        if let result = argv.option("result") {
            return complete(id: id, result: result)
        }
        if relay.nodeJobWasApplied(id) {
            return LightCLIResult(exitCode: 0, text: "duplicate ignored")
        }
        guard relay.ack(job: id) else {
            return LightCLIResult(exitCode: 1, text: "error: unknown request \(id)")
        }
        return LightCLIResult(exitCode: 0, text: "acked \(id)")
    }

    private func ssh(_ host: String, command: String, summary: String) -> LightProcessOutput {
        runner.run(LightInvocation(
            argv: ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--", host, command],
            stdin: "", executable: true, fallback: false, summary: summary, loopback: false
        ), stdin: "")
    }

    private func runAchat(_ argv: [String], summary: String) -> LightProcessOutput {
        runner.run(LightInvocation(
            argv: argv, stdin: "", executable: true, fallback: false, summary: summary, loopback: true
        ), stdin: "")
    }

    private func planAdd(app: String) -> LightProjectPlan {
        if app == "codex" { return LightProjectAdd.plan(app: app, probe: .absent) }
        guard let port = ports.port(for: app) else {
            let mode: LightProjectAddable = app == "ag" ? .ui : .restart
            return LightProjectPlan(addable: mode, callAchat: false, message: "debug port is not configured")
        }
        return LightProjectAdd.plan(app: app, probe: prober.probe(app: app, port: port))
    }

    private func forwardProject(_ spec: ProjectSpec, noQueue: Bool, json: Bool) -> LightCLIResult {
        let status = relay.nodeStatus(spec.host)
        if !status.online {
            return holdProject(status: status, spec: spec, noQueue: noQueue, json: json)
        }
        let output = ssh(spec.host, command: projectCommand(spec), summary: "forward pharos project to the target node")
        if let object = Self.extractJSON(output.stdout), object["status"] is String || object["ok"] is Bool {
            return presentProject(object, spec: spec, json: json)
        }
        return holdProject(status: relay.nodeStatus(spec.host), spec: spec, noQueue: noQueue, json: json)
    }

    private func holdProject(status: LightNodeStatus, spec: ProjectSpec, noQueue: Bool, json: Bool) -> LightCLIResult {
        let message = LightRelay.nodeOfflineMessage(lastSeen: status.lastSeen)
        if spec.dryRun || noQueue {
            return offlineResult(message: message, requestID: nil, status: status, json: json, queued: false)
        }
        let kind = spec.op == "add" ? "project-add" : "project-list"
        do {
            let queued = try relay.enqueueNodeJob(node: spec.host, kind: kind, payload: spec.payload())
            return offlineResult(message: message, requestID: queued.job.id, status: status, json: json, queued: true)
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }

    private func projectCommand(_ spec: ProjectSpec) -> String {
        var args = ["pharos", "project", spec.op, "--here", "--app", spec.app]
        if spec.op == "add" { args += ["--path", spec.path] }
        if !spec.name.isEmpty { args += ["--name", spec.name] }
        if spec.dryRun { args.append("--dry-run") }
        args.append("--json")
        return args.map(Self.shellQuote).joined(separator: " ")
    }

    private func listHere(_ spec: ProjectSpec) -> ProjectOutcome {
        switch workspaceRows(app: spec.app, dryRun: spec.dryRun) {
        case .failure(let failure):
            return ProjectOutcome(ok: false, status: "error", message: failure.message, app: spec.app, path: spec.path,
                                 name: spec.name, addable: LightProjectAdd.addable(app: spec.app).rawValue, dryRun: spec.dryRun, rows: [])
        case .success(let rows):
            return ProjectOutcome(ok: true, status: spec.dryRun ? "dry-run" : "listed", message: nil, app: spec.app,
                                 path: spec.path, name: spec.name, addable: LightProjectAdd.addable(app: spec.app).rawValue,
                                 dryRun: spec.dryRun, rows: rows)
        }
    }

    private func addHere(_ spec: ProjectSpec) -> ProjectOutcome {
        let plan = planAdd(app: spec.app)
        if !plan.callAchat {
            return ProjectOutcome(ok: false, status: "needs_user_action", message: plan.message, app: spec.app,
                                 path: spec.path, name: spec.name, addable: plan.addable.rawValue, dryRun: spec.dryRun, rows: [])
        }
        let rows: [LightProjectRow]
        switch workspaceRows(app: spec.app, dryRun: false) {
        case .failure(let failure):
            return ProjectOutcome(ok: false, status: "error", message: failure.message, app: spec.app, path: spec.path,
                                 name: spec.name, addable: plan.addable.rawValue, dryRun: spec.dryRun, rows: [])
        case .success(let listed):
            rows = listed
        }
        if let found = rows.first(where: { Self.samePath($0.path, spec.path) }) {
            return ProjectOutcome(ok: true, status: "already", message: nil, app: spec.app, path: spec.path,
                                 name: found.name.isEmpty ? spec.name : found.name, addable: plan.addable.rawValue,
                                 dryRun: spec.dryRun, rows: rows)
        }
        let output = runAchat(
            Self.achatWorkspaceArgv(bin: apps.achat, app: spec.app, command: "add", path: spec.path,
                                   name: spec.name.isEmpty ? nil : spec.name, dryRun: spec.dryRun),
            summary: "achat \(spec.app) workspace add"
        )
        guard let object = Self.extractJSON(output.stdout) else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectOutcome(ok: false, status: "error", message: detail.isEmpty ? "achat failed" : detail,
                                 app: spec.app, path: spec.path, name: spec.name, addable: plan.addable.rawValue,
                                 dryRun: spec.dryRun, rows: [])
        }
        let parsed = Self.interpretProject(object)
        if output.status != 0 || !parsed.ok {
            let status = parsed.status == "needs_user_action" ? "needs_user_action" : "error"
            return ProjectOutcome(ok: false, status: status, message: parsed.message ?? "achat failed", app: spec.app,
                                 path: parsed.path ?? spec.path, name: parsed.name ?? spec.name,
                                 addable: parsed.addable ?? plan.addable.rawValue, dryRun: spec.dryRun || parsed.dryRun, rows: parsed.rows)
        }
        if spec.dryRun || parsed.dryRun {
            return ProjectOutcome(ok: true, status: "dry-run", message: parsed.message, app: spec.app,
                                 path: parsed.path ?? spec.path, name: parsed.name ?? spec.name,
                                 addable: parsed.addable ?? plan.addable.rawValue, dryRun: true, rows: parsed.rows)
        }
        let status = parsed.status == "already" ? "already" : "added"
        return ProjectOutcome(ok: true, status: status, message: parsed.message, app: spec.app,
                             path: parsed.path ?? spec.path, name: parsed.name ?? spec.name,
                             addable: parsed.addable ?? plan.addable.rawValue, dryRun: false, rows: parsed.rows)
    }

    private func registrationError(_ spec: SessionSpec) -> String? {
        switch workspaceRows(app: spec.app, dryRun: false) {
        case .failure(let failure):
            return failure.message
        case .success(let rows):
            let wanted = spec.workspace.lowercased()
            if rows.contains(where: { $0.name.lowercased() == wanted }) { return nil }
            if let path = spec.addProject, rows.contains(where: { Self.samePath($0.path, path) }) { return nil }
            return "project is not registered"
        }
    }

    private struct RowFailure: Error { var message: String }

    private func workspaceRows(app: String, dryRun: Bool) -> Result<[LightProjectRow], RowFailure> {
        let output = runAchat(
            Self.achatWorkspaceArgv(bin: apps.achat, app: app, command: "list", path: nil, name: nil, dryRun: dryRun),
            summary: "achat \(app) workspace list"
        )
        guard let object = Self.extractJSON(output.stdout) else {
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(RowFailure(message: detail.isEmpty ? "achat failed" : detail))
        }
        let parsed = Self.interpretProject(object)
        if output.status != 0 || !parsed.ok { return .failure(RowFailure(message: parsed.message ?? "achat failed")) }
        return .success(parsed.rows)
    }

    private func renderProject(_ outcome: ProjectOutcome, host: String, json: Bool) -> LightCLIResult {
        if json {
            var body: [String: Any] = [
                "ok": outcome.ok, "status": outcome.status, "app": outcome.app, "addable": outcome.addable, "dryRun": outcome.dryRun,
            ]
            if !host.isEmpty { body["node"] = host }
            if !outcome.path.isEmpty { body["path"] = outcome.path }
            if !outcome.name.isEmpty { body["name"] = outcome.name }
            if let message = outcome.message, !message.isEmpty { body["message"] = message }
            if outcome.status == "listed" || outcome.status == "dry-run" || !outcome.rows.isEmpty {
                body["projects"] = outcome.rows.map { row -> [String: Any] in
                    var item: [String: Any] = ["name": row.name]
                    if let path = row.path { item["path"] = path }
                    return item
                }
            }
            return Self.jsonText(body, ok: outcome.ok)
        }
        switch outcome.status {
        case "added", "already":
            var lines = ["\(outcome.status) \(outcome.name)".trimmingCharacters(in: .whitespaces)]
            if !outcome.path.isEmpty { lines.append("path \(outcome.path)") }
            lines.append("addable \(outcome.addable)")
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        case "listed":
            if outcome.rows.isEmpty { return LightCLIResult(exitCode: 0, text: "no projects") }
            let lines = outcome.rows.map { row in
                if let path = row.path, !path.isEmpty { return "\(row.name)\t\(path)" }
                return row.name
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        case "dry-run":
            var lines = ["dry-run", "addable \(outcome.addable)"]
            if !outcome.path.isEmpty { lines.append("path \(outcome.path)") }
            if !outcome.rows.isEmpty {
                lines.append(contentsOf: outcome.rows.map { row in
                    if let path = row.path, !path.isEmpty { return "\(row.name)\t\(path)" }
                    return row.name
                })
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        case "needs_user_action":
            var lines = ["needs_user_action", "addable \(outcome.addable)"]
            if let message = outcome.message, !message.isEmpty { lines.append(message) }
            return LightCLIResult(exitCode: 1, text: lines.joined(separator: "\n"))
        default:
            return LightCLIResult(exitCode: 1, text: "error: \(outcome.message ?? "project failed")")
        }
    }

    private func presentProject(_ object: [String: Any], spec: ProjectSpec, json: Bool) -> LightCLIResult {
        let parsed = Self.interpretProject(object)
        let status = object["status"] as? String ?? parsed.status
        let outcome = ProjectOutcome(
            ok: (object["ok"] as? Bool) != false && parsed.ok && status != "needs_user_action" && status != "error",
            status: status, message: object["message"] as? String ?? parsed.message, app: spec.app,
            path: object["path"] as? String ?? parsed.path ?? spec.path,
            name: object["name"] as? String ?? parsed.name ?? spec.name,
            addable: object["addable"] as? String ?? parsed.addable ?? LightProjectAdd.addable(app: spec.app).rawValue,
            dryRun: (object["dryRun"] as? Bool) == true || parsed.dryRun,
            rows: parsed.rows.isEmpty ? Self.projectRows(object) : parsed.rows
        )
        var shown = outcome
        if status == "needs_user_action" || status == "error" || status == "node offline" { shown.ok = false }
        if status == "added" || status == "already" || status == "listed" || status == "dry-run" || status == "queued" { shown.ok = true }
        return renderProject(shown, host: spec.host, json: json)
    }

    private func register(_ spec: SessionSpec, sessionID: String) throws -> LightMember {
        let project = Self.projectSlug(spec.workspace)
        return try relay.register(LightMember(
            name: spec.name, host: spec.host, app: spec.app, project: project, sessionID: sessionID,
            routes: LightRouteCatalog.defaults(for: spec.app)
        ))
    }

    private func remoteCommand(verb: Verb, spec: SessionSpec) -> String {
        var args = ["pharos", "session", verb == .new ? "new" : "workspaces", "--here", "--app", spec.app]
        if verb == .new { args += ["--workspace", spec.workspace] }
        if let title = spec.title, !title.isEmpty { args += ["--title", title] }
        if !spec.name.isEmpty { args += ["--name", spec.name] }
        if let path = spec.addProject, !path.isEmpty { args += ["--add-project", path] }
        if spec.dryRun { args.append("--dry-run") }
        if spec.launch { args.append("--launch") }
        args.append("--json")
        return args.map(Self.shellQuote).joined(separator: " ")
    }

    private func hereFailure(_ message: String, spec: SessionSpec, json: Bool) -> LightCLIResult {
        _ = spec
        if json {
            return Self.jsonText(["ok": false, "status": "error", "message": message], ok: false)
        }
        return LightCLIResult(exitCode: 1, text: "error: \(message)")
    }

    private func offlineResult(message: String, requestID: String?, status: LightNodeStatus, json: Bool, queued: Bool) -> LightCLIResult {
        if json {
            var body: [String: Any] = [
                "ok": queued, "status": queued ? "queued" : "node offline", "node": status.host, "message": message,
            ]
            if let requestID { body["requestId"] = requestID }
            if let seen = status.lastSeen {
                body["lastSeen"] = Int(seen.timeIntervalSince1970)
            } else {
                body["lastSeen"] = NSNull()
            }
            return Self.jsonText(body, ok: queued)
        }
        if let requestID {
            return LightCLIResult(exitCode: 0, text: "queued \(requestID)\n\(message)")
        }
        return LightCLIResult(exitCode: 1, text: "error: \(message)")
    }

    private func formatProjects(_ names: [String], json: Bool) -> LightCLIResult {
        if json { return Self.jsonText(["ok": true, "status": "listed", "projects": names], ok: true) }
        return LightCLIResult(exitCode: 0, text: names.isEmpty ? "no workspaces" : names.joined(separator: "\n"))
    }

    private static func jsonText(_ body: [String: Any], ok: Bool) -> LightCLIResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return LightCLIResult(exitCode: 1, text: "error: could not encode the result")
        }
        return LightCLIResult(exitCode: ok ? 0 : 1, text: text)
    }

    static func defaultMemberName(app: String, host: String, workspace: String) -> String {
        var raw = "\(app)-\(host)-\(workspace)".lowercased()
        var slug = ""
        for character in raw {
            if character.isLetter || character.isNumber || character == "-" {
                slug.append(character)
            } else {
                slug.append("-")
            }
        }
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if slug.first?.isLetter != true { slug = "m-\(slug)" }
        if slug.count > 63 { slug = String(slug.prefix(63)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        raw = slug
        return raw
    }

    static func projectSlug(_ workspace: String) -> String {
        var slug = ""
        for character in workspace.lowercased() {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                slug.append(character)
            } else {
                slug.append("-")
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        if slug.isEmpty { slug = "project" }
        if slug.count > 63 { slug = String(slug.prefix(63)) }
        return slug
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func extractJSON(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    static func samePath(_ left: String?, _ right: String) -> Bool {
        guard let left else { return false }
        func norm(_ value: String) -> String {
            var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            while text.count > 1 && text.hasSuffix("/") { text.removeLast() }
            return text
        }
        let lhs = norm(left)
        let rhs = norm(right)
        if lhs.isEmpty || rhs.isEmpty { return false }
        return lhs == rhs
    }

    static func projectRows(_ object: [String: Any]) -> [LightProjectRow] {
        let raw = (object["projects"] as? [Any]) ?? []
        return raw.compactMap { item in
            if let name = item as? String { return LightProjectRow(name: name, path: nil) }
            guard let row = item as? [String: Any] else { return nil }
            let name = (row["name"] as? String) ?? ""
            let path = row["path"] as? String
                ?? ((row["roots"] as? [[String: Any]])?.first?["path"] as? String)
            if name.isEmpty && (path ?? "").isEmpty { return nil }
            return LightProjectRow(name: name, path: path)
        }
    }

    static func interpretProject(_ object: [String: Any]) -> ProjectRead {
        let dryRun = (object["dryRun"] as? Bool) == true
        let rows = projectRows(object)
        var message: String?
        var code: String?
        if let error = object["error"] as? [String: Any] {
            code = error["code"] as? String
            let text = error["message"] as? String
            let joined = [code, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !joined.isEmpty { message = joined }
        }
        if let text = object["message"] as? String, !text.isEmpty { message = text }
        let explicit = object["status"] as? String
        let okFlag = (object["ok"] as? Bool) != false && code == nil
        let status: String
        if explicit == "needs_user_action" || code == "needs_user_action" {
            status = "needs_user_action"
        } else if let explicit, !explicit.isEmpty {
            status = explicit
        } else if !okFlag {
            status = "error"
        } else if dryRun {
            status = "dry-run"
        } else if object["created"] as? Bool == true || object["added"] as? Bool == true {
            status = "added"
        } else if !rows.isEmpty {
            status = "listed"
        } else {
            status = "added"
        }
        let ok = okFlag && status != "needs_user_action" && status != "error" && status != "node offline"
        return ProjectRead(ok: ok, status: status, message: message, name: object["name"] as? String,
                           path: object["path"] as? String, addable: object["addable"] as? String,
                           rows: rows, dryRun: dryRun)
    }

    static func interpretAchat(_ object: [String: Any]) -> (ok: Bool, message: String?, sessionID: String?, route: String?, projects: [String], dryRun: Bool) {
        let ok = (object["ok"] as? Bool) != false
        let dryRun = (object["dryRun"] as? Bool) == true
        let route = object["route"] as? String
        let projects = (object["projects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        var message: String?
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String
            let text = error["message"] as? String
            let joined = [code, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
            if !joined.isEmpty { message = joined }
        }
        return (ok, message, findSessionID(object), route, projects, dryRun)
    }

    static func hereResult(_ object: [String: Any]) -> HereBody? {
        guard object["status"] is String || object["ok"] is Bool else { return nil }
        if object["error"] is [String: Any], object["status"] == nil, object["created"] == nil, object["projects"] == nil {
            let parsed = interpretAchat(object)
            return HereBody(ok: parsed.ok, status: "error", message: parsed.message, sessionId: parsed.sessionID,
                            route: parsed.route, projects: parsed.projects, dryRun: parsed.dryRun, launched: false)
        }
        let parsed = interpretAchat(object)
        let status = object["status"] as? String ?? (parsed.dryRun ? "dry-run" : (parsed.sessionID == nil ? "listed" : "created"))
        return HereBody(ok: (object["ok"] as? Bool) != false && parsed.ok, status: status, message: object["message"] as? String ?? parsed.message,
                        sessionId: object["sessionId"] as? String ?? parsed.sessionID, route: object["route"] as? String ?? parsed.route,
                        projects: object["projects"] as? [String] ?? parsed.projects,
                        dryRun: (object["dryRun"] as? Bool) == true || parsed.dryRun,
                        launched: (object["launched"] as? Bool) == true)
    }

    private static func findSessionID(_ object: [String: Any], depth: Int = 0) -> String? {
        if depth > 5 { return nil }
        for key in ["sessionId", "threadId", "conversation"] {
            if let value = object[key] as? String, acceptableSession(value) { return value }
        }
        if let session = object["session"] as? String, acceptableSession(session) { return session }
        if let session = object["session"] as? [String: Any] {
            if let id = (session["id"] as? String) ?? (session["sessionId"] as? String), acceptableSession(id) { return id }
        }
        if let thread = object["thread"] as? [String: Any], let id = thread["id"] as? String, acceptableSession(id) { return id }
        if let state = object["state"] as? [String: Any], let found = findSessionID(state, depth: depth + 1) { return found }
        return nil
    }

    private static func acceptableSession(_ value: String) -> Bool {
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$"#, options: .regularExpression) != nil else { return false }
        return !value.contains("/") && !value.contains("~") && !value.contains("@")
    }

    private static func usage(_ text: String) -> LightCLIResult {
        LightCLIResult(exitCode: 2, text: "error: \(text)")
    }
}

struct SessionSpec: Equatable {
    var app: String
    var host: String
    var workspace: String
    var title: String?
    var name: String
    var launch: Bool
    var dryRun: Bool
    var addProject: String? = nil

    func payload() -> String {
        var body: [String: Any] = [
            "app": app, "host": host, "workspace": workspace, "name": name, "launch": launch, "dryRun": dryRun,
        ]
        if let title { body["title"] = title }
        if let addProject, !addProject.isEmpty { body["addProject"] = addProject }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func from(payload: String) -> SessionSpec? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = object["app"] as? String, let host = object["host"] as? String,
              let workspace = object["workspace"] as? String, let name = object["name"] as? String else { return nil }
        return SessionSpec(app: app, host: host, workspace: workspace, title: object["title"] as? String,
                           name: name, launch: (object["launch"] as? Bool) == true, dryRun: (object["dryRun"] as? Bool) == true,
                           addProject: object["addProject"] as? String)
    }
}

struct LightProjectRow: Equatable {
    var name: String
    var path: String?
}

struct ProjectRead {
    var ok: Bool
    var status: String
    var message: String?
    var name: String?
    var path: String?
    var addable: String?
    var rows: [LightProjectRow]
    var dryRun: Bool
}

struct ProjectOutcome {
    var ok: Bool
    var status: String
    var message: String?
    var app: String
    var path: String
    var name: String
    var addable: String
    var dryRun: Bool
    var rows: [LightProjectRow]
}

struct ProjectSpec: Equatable {
    var op: String
    var app: String
    var host: String
    var path: String
    var name: String
    var dryRun: Bool

    func payload() -> String {
        let body: [String: Any] = [
            "op": op, "app": app, "host": host, "path": path, "name": name, "dryRun": dryRun,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

struct HereBody {
    var ok: Bool
    var status: String
    var message: String?
    var sessionId: String?
    var route: String?
    var projects: [String]
    var dryRun: Bool
    var launched: Bool

    var object: [String: Any] {
        var body: [String: Any] = [
            "ok": ok, "status": status, "projects": projects, "dryRun": dryRun, "launched": launched,
        ]
        if let message { body["message"] = message }
        if let sessionId { body["sessionId"] = sessionId }
        if let route { body["route"] = route }
        return body
    }
}

private struct SessionArgv {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let knownFlags: Set<String> = ["json", "dry-run", "launch", "no-queue", "here"]
    static let knownOptions: Set<String> = ["host", "app", "workspace", "title", "name", "node", "result", "path", "add-project"]

    static func parse(_ tokens: [String]) -> SessionArgv {
        var argv = SessionArgv()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                argv.positional.append(contentsOf: tokens[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let key: String
                let inline: String?
                if let eq = body.firstIndex(of: "=") {
                    key = String(body[..<eq])
                    inline = String(body[body.index(after: eq)...])
                } else {
                    key = body
                    inline = nil
                }
                if let inline {
                    argv.options[key] = inline
                } else if knownFlags.contains(key) {
                    argv.flags.insert(key)
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    argv.options[key] = tokens[index + 1]
                    index += 1
                } else {
                    argv.flags.insert(key)
                }
            } else {
                argv.positional.append(token)
            }
            index += 1
        }
        return argv
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func option(_ name: String) -> String? { options[name] }
}

/// Loopback-only debug check used by a target node. Tests inject their own prober.
/// `curl` is used because this Foundation build does not ship a usable URLSession.
public struct LoopbackDebugProber: LightAppProbing {
    public var runner: any LightProcessRunning

    public init(runner: any LightProcessRunning = FoundationLightProcessRunner()) {
        self.runner = runner
    }

    public func probe(app: String, port: Int) -> LightAppProbe {
        let output = runner.run(LightInvocation(
            argv: ["curl", "-fsS", "--max-time", "1", "http://127.0.0.1:\(port)/json/version"],
            stdin: "", executable: true, fallback: false,
            summary: "probe the loopback debug endpoint", loopback: true
        ), stdin: "")
        if output.status == 0, !output.stdout.isEmpty {
            return Self.belongs(output.stdout, app: app) ? .ready : .portHeldByOther
        }
        return Self.processRunning(app) ? .runningWithoutDebug : .absent
    }

    private static func belongs(_ body: String, app: String) -> Bool {
        let folded = body.lowercased()
        switch app {
        case "dsh": return folded.contains("dsh") || folded.contains("deepseek")
        case "codex": return folded.contains("codex") || folded.contains("chatgpt")
        case "ag": return folded.contains("antigravity")
        default: return false
        }
    }

    private static func processRunning(_ app: String) -> Bool {
        let names: [String]
        switch app {
        case "dsh": names = ["dsh"]
        case "codex": names = ["Codex", "ChatGPT"]
        case "ag": names = ["Antigravity"]
        default: names = []
        }
        for name in names {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", name]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return true }
            } catch {
                return false
            }
        }
        return false
    }
}
