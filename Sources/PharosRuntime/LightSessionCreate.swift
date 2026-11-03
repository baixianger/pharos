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
        if !here.ok {
            return LightCLIResult(exitCode: 1, text: "error: \(here.message ?? "session failed")")
        }
        if job.kind == "session-new", !here.dryRun {
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
                               name: name, launch: argv.flag("launch"), dryRun: argv.flag("dry-run"))
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
        let command = remoteCommand(verb: verb, spec: spec)
        let invocation = LightInvocation(
            argv: ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", "--", spec.host, command],
            stdin: "", executable: true, fallback: false,
            summary: "forward pharos session to the target node", loopback: false
        )
        let output = runner.run(invocation, stdin: "")
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
            if json { return Self.jsonText(["ok": false, "status": "error", "message": message], ok: false) }
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

    func payload() -> String {
        var body: [String: Any] = [
            "app": app, "host": host, "workspace": workspace, "name": name, "launch": launch, "dryRun": dryRun,
        ]
        if let title { body["title"] = title }
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
                           name: name, launch: (object["launch"] as? Bool) == true, dryRun: (object["dryRun"] as? Bool) == true)
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
    static let knownOptions: Set<String> = ["host", "app", "workspace", "title", "name", "node", "result"]

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
