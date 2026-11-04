import Foundation

public struct LightMemberRuntimeStatus: Codable, Equatable, Sendable {
    public var tmux: String
    public var live: String
    public var activity: String
    public var detail: String

    public init(tmux: String, live: String, activity: String, detail: String) {
        self.tmux = tmux
        self.live = live
        self.activity = activity
        self.detail = detail
    }
}

public struct LightMemberAgentsError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public protocol LightMemberAgents: Sendable {
    func launch(name: String, app: String, cwd: String, host: String, model: String?, tmuxSession: String?,
                openingMessage: String?, project: String) throws -> LightMember   // returns member with tmux binding + routes
    func adopt(name: String, app: String, cwd: String, sessionID: String, host: String, model: String?, tmuxSession: String?,
               project: String, autoRevive: Bool) throws -> LightMember
    func revive(_ member: LightMember) throws -> LightTmuxBinding
    func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding
    func status(_ member: LightMember) -> LightMemberRuntimeStatus?   // nil = not a tmux CLI member
    var notes: [String] { get }
}

extension LightMemberAgents {
    public var notes: [String] { [] }
    public func adopt(name: String, app: String, cwd: String, sessionID: String, host: String, model: String?, tmuxSession: String?,
                      project: String, autoRevive: Bool) throws -> LightMember {
        throw LightMemberAgentsError("member adopt needs live CLI access")
    }
    public func stop(_ member: LightMember, force: Bool) throws -> LightTmuxBinding {
        throw LightMemberAgentsError("member stop needs live CLI access")
    }
}

public struct LightMemberListEntry: Codable, Sendable {
    public var name: String
    public var host: String
    public var app: String
    public var project: String
    public var sessionID: String
    public var routes: [LightRoute]
    public var tmux: LightTmuxBinding?
    public var runtime: LightMemberRuntimeStatus?
    public var reportedAt: Date?
    public var reportedBy: String?

    public init(member: LightMember, runtime: LightMemberRuntimeStatus?, reportedAt: Date? = nil, reportedBy: String? = nil) {
        self.name = member.name
        self.host = member.host
        self.app = member.app
        self.project = member.project
        self.sessionID = member.sessionID
        self.routes = member.routes
        self.tmux = member.tmux
        self.runtime = runtime
        self.reportedAt = reportedAt
        self.reportedBy = reportedBy
    }

    enum CodingKeys: String, CodingKey {
        case name, host, app, project, sessionID, routes, tmux, runtime, reportedAt, reportedBy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(host, forKey: .host)
        try container.encode(app, forKey: .app)
        try container.encode(project, forKey: .project)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(routes, forKey: .routes)
        try container.encodeIfPresent(tmux, forKey: .tmux)
        try container.encodeIfPresent(runtime, forKey: .runtime)
        try container.encodeIfPresent(reportedAt, forKey: .reportedAt)
        try container.encodeIfPresent(reportedBy, forKey: .reportedBy)
    }
}

public struct LightCLIResult: Equatable, Sendable {
    public var exitCode: Int32
    public var text: String
    /// Advisory lines for stderr (e.g. `hint: body mentions @x; use --cc x to copy them`).
    public var notes: [String]

    public init(exitCode: Int32, text: String, notes: [String] = []) {
        self.exitCode = exitCode
        self.text = text
        self.notes = notes
    }
}

/// Thin command surface over `LightRelay`. Parsing and formatting live here so
/// the macOS CLI and the tests cross the same seam.
public enum LightCommands {
    public static func execute(command: String, arguments: [String], relay: LightRelay,
                               routesForApp: (String) -> [LightRoute],
                               routeByID: (String) -> LightRoute = LightRoute.named,
                               agents: (any LightMemberAgents)? = nil,
                               hostOwner: (@Sendable (String) -> String)? = nil,
                               refreshInventory: (@Sendable (_ host: String) -> Void)? = nil) -> LightCLIResult {
        let argv = LightArgv.parse(arguments)
        do {
            if ["thread", "wait", "read", "attention"].contains(command),
               let forwarded = relay.forwardCommand(command: command, arguments: arguments) {
                return forwarded
            }
            // `reply` with addressing or intent options needs the whole argv on the Broker.
            if command == "reply", !argv.multi("cc").isEmpty || argv.option("intent") != nil || argv.flag("deliver"),
               let forwarded = relay.forwardCommand(command: command, arguments: arguments) {
                return forwarded
            }
            switch command {
            case "member":
                return try member(argv, relay: relay, routesForApp: routesForApp, routeByID: routeByID, agents: agents, hostOwner: hostOwner, refreshInventory: refreshInventory)
            case "thread":
                return try thread(argv, relay: relay)
            case "send":
                return try send(argv, relay: relay)
            case "reply":
                return try reply(argv, relay: relay)
            case "wait":
                return try wait(argv, relay: relay)
            case "read":
                return try read(argv, relay: relay)
            case "attention":
                return try attention(argv, relay: relay)
            default:
                return usage("unknown light command \(command)")
            }
        } catch let error as LightRelayError {
            let code: Int32 = {
                if case .emptyText = error { return 2 }
                return 1
            }()
            return LightCLIResult(exitCode: code, text: "error: \(error.localizedDescription)")
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }

    private static func member(_ argv: LightArgv, relay: LightRelay,
                               routesForApp: (String) -> [LightRoute],
                               routeByID: (String) -> LightRoute,
                               agents: (any LightMemberAgents)? = nil,
                               hostOwner: (@Sendable (String) -> String)? = nil,
                               refreshInventory: (@Sendable (_ host: String) -> Void)? = nil) throws -> LightCLIResult {
        switch argv.positional.first {
        case "list", nil:
            let members = relay.listMembers()
            let moment = Date()

            struct MemberRow {
                let member: LightMember
                let tmux: String
                let live: String
                let state: String
                let runtime: LightMemberRuntimeStatus?
                let reportedAt: Date?
                let reportedBy: String?
            }

            let rows: [MemberRow] = members.map { member in
                var binding = member.tmux
                let tmuxStr = binding?.session ?? "-"
                let liveStr: String
                let stateStr: String
                let runtime: LightMemberRuntimeStatus?
                var reportedAt: Date? = nil
                var reportedBy: String? = nil

                if binding == nil {
                    liveStr = "-"
                    let existingAttention = relay.attention(for: member.name)
                        .map { "needs_human \(LightAttention.age(moment.timeIntervalSince($0.since)))" }
                    stateStr = existingAttention ?? "-"
                    runtime = nil
                } else if var st = agents?.status(member) {
                    if st.live == "dead" && binding?.endedAt == nil {
                        binding?.endedAt = moment
                        binding?.endedReason = "exited"
                        try? relay.updateTmux(member: member.name, binding)
                        st.live = "ended"
                        st.detail = "ended"
                    }
                    if binding?.endedReason == "stopped" && (st.live == "ended" || st.live == "dead") {
                        st.live = "stopped"
                    }
                    liveStr = st.live
                    let existingAttention = relay.attention(for: member.name)
                        .map { "needs_human \(LightAttention.age(moment.timeIntervalSince($0.since)))" }
                    if let existingAttention {
                        stateStr = existingAttention
                    } else if ["idle", "thinking", "needs_human"].contains(st.activity) {
                        stateStr = st.activity
                    } else if !st.activity.isEmpty && st.activity != "unknown" && st.activity != "-" {
                        stateStr = st.activity
                    } else {
                        stateStr = "-"
                    }
                    runtime = st
                } else if let report = relay.runtime(for: member.name),
                          // A stop/exit recorded after the node's last report wins over that report.
                          !(binding?.endedAt.map { $0 > report.at } ?? false) {
                    reportedAt = report.at
                    reportedBy = report.node
                    let age = moment.timeIntervalSince(report.at)
                    if age > 90 {
                        liveStr = "stale"
                        stateStr = "-"
                        let ageStr = LightAttention.age(age)
                        let suffix = " (last report \(ageStr) ago)"
                        let jsonDetail = report.detail.isEmpty ? suffix.trimmingCharacters(in: .whitespaces) : "\(report.detail)\(suffix)"
                        runtime = LightMemberRuntimeStatus(
                            tmux: report.tmux,
                            live: "stale",
                            activity: "-",
                            detail: jsonDetail
                        )
                    } else {
                        liveStr = report.live
                        let existingAttention = relay.attention(for: member.name)
                            .map { "needs_human \(LightAttention.age(moment.timeIntervalSince($0.since)))" }
                        if let existingAttention {
                            stateStr = existingAttention
                        } else if report.activity != "unknown" && !report.activity.isEmpty && report.activity != "-" {
                            stateStr = report.activity
                        } else {
                            stateStr = "-"
                        }
                        runtime = LightMemberRuntimeStatus(
                            tmux: report.tmux,
                            live: report.live,
                            activity: report.activity,
                            detail: report.detail
                        )
                    }
                } else {
                    if binding?.endedAt != nil {
                        liveStr = (binding?.endedReason == "stopped") ? "stopped" : "ended"
                    } else {
                        liveStr = "?"
                    }
                    let existingAttention = relay.attention(for: member.name)
                        .map { "needs_human \(LightAttention.age(moment.timeIntervalSince($0.since)))" }
                    stateStr = existingAttention ?? "-"
                    runtime = nil
                }

                return MemberRow(
                    member: member, tmux: tmuxStr, live: liveStr, state: stateStr,
                    runtime: runtime, reportedAt: reportedAt, reportedBy: reportedBy
                )
            }

            if argv.flag("json") {
                let entries = rows.map { row in
                    LightMemberListEntry(
                        member: row.member, runtime: row.runtime,
                        reportedAt: row.reportedAt, reportedBy: row.reportedBy
                    )
                }
                return json(entries)
            }

            if members.isEmpty { return ok("no members") }
            let lines = rows.map { row in
                let routes = row.member.routes.map(\.id).joined(separator: ",")
                return "\(row.member.name)\t\(row.member.app)\t\(row.member.host)\t\(row.member.project)\t\(row.member.sessionID)\t\(routes)\t\(row.tmux)\t\(row.live)\t\(row.state)"
            }
            var out = ["NAME\tAPP\tHOST\tPROJECT\tSESSION\tROUTES\tTMUX\tLIVE\tSTATE"] + lines
            let tableNames = Set(members.map(\.name))
            out.append(contentsOf: groupedAttentionLines(relay.activeAttention(), at: moment, filterMembers: tableNames))
            return ok(out.joined(separator: "\n"))
        case "node-members":
            guard let node = argv.option("node") else {
                return usage("pharos member node-members --node N --json")
            }
            let owner = hostOwner ?? { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let matched = relay.listMembers().filter { m in
                guard m.tmux != nil else { return false }
                let oMember = owner(m.host)
                let oNode = owner(node)
                if oMember == oNode { return true }
                return (m.host.lowercased() == "local" || oMember == "local") && (node.lowercased() == "local" || oNode == "local")
            }
            return json(matched)
        case "node-report":
            guard let node = argv.option("node"), let payload = argv.option("payload") else {
                return usage("pharos member node-report --node N --payload B64")
            }
            guard let reports = LightCodec.decode([LightMemberRuntimeReport].self, payload) else {
                return LightCLIResult(exitCode: 2, text: "error: unreadable report payload")
            }
            let owner = hostOwner ?? { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let accepted = try relay.recordRuntime(reports) { member in
                let oMember = owner(member.host)
                let oNode = owner(node)
                if oMember == oNode { return true }
                return (member.host.lowercased() == "local" || oMember == "local") && (node.lowercased() == "local" || oNode == "local")
            }
            return json(["accepted": accepted])
        case "launch":
            let host = argv.option("host") ?? "local"
            var dir = argv.option("dir")
            if dir == nil || dir!.isEmpty {
                if let projectOpt = argv.option("project"), !projectOpt.isEmpty {
                    let wsStore = LightWorkspaceStore(rootDir: relay.storeURL)
                    let canonical = hostOwner?(host) ?? host
                    var workspaces = wsStore.workspaces(for: host)
                    if workspaces.isEmpty && canonical != host {
                        workspaces = wsStore.workspaces(for: canonical)
                    }
                    if let ws = workspaces.first(where: { $0.name.lowercased() == projectOpt.lowercased() }) {
                        dir = ws.path
                    }
                }
            }
            guard let app = argv.option("app"),
                  let name = argv.option("name"),
                  let finalDir = dir, !finalDir.isEmpty else {
                return usage("pharos member launch --app codex|agy --name N (--dir D | --project P) [--host H] [--model M] [--tmux SESSION] [--message TEXT] [--auto-revive] [--json]")
            }
            guard let agents else {
                return LightCLIResult(exitCode: 1, text: "error: member launch needs live CLI access (PHAROS_LIGHT_LIVE=1)")
            }
            let project: String = {
                if let p = argv.option("project"), !p.isEmpty { return p }
                let last = URL(fileURLWithPath: finalDir).lastPathComponent
                return last.isEmpty ? "default" : last
            }()
            let model = argv.option("model")
            let tmuxSession = argv.option("tmux")
            let message = argv.option("message")

            let validatedName = try LightRelay.validateName(name)
            _ = try LightRelay.validateProject(project)

            if let _ = relay.member(named: validatedName) {
                throw LightRelayError.duplicateMember(validatedName)
            }

            var member = try agents.launch(
                name: validatedName,
                app: app,
                cwd: finalDir,
                host: host,
                model: model,
                tmuxSession: tmuxSession,
                openingMessage: message,
                project: project
            )
            if argv.flag("auto-revive") {
                member.tmux?.autoRevive = true
            }

            let registered = try relay.register(member)
            if argv.flag("json") { return json(registered) }
            let tmuxName = registered.tmux?.session ?? tmuxSession ?? validatedName
            return LightCLIResult(
                exitCode: 0,
                text: "launched \(registered.name) (app \(registered.app)) in tmux \(tmuxName), session \(registered.sessionID)",
                notes: agents.notes
            )
        case "adopt":
            guard let name = argv.option("name"), !name.isEmpty else {
                return usage("pharos member adopt <address|host app id> --name X [--dir D] [--model M] [--tmux S] [--auto-revive] [--project P] [--force] [--json]")
            }
            guard let agents else {
                return LightCLIResult(exitCode: 1, text: "error: member adopt needs live CLI access (PHAROS_LIGHT_LIVE=1)")
            }

            let validatedName = try LightRelay.validateName(name)
            if let _ = relay.member(named: validatedName) {
                throw LightRelayError.duplicateMember(validatedName)
            }

            let positional = Array(argv.positional.dropFirst())
            let host: String
            let app: String
            let sessionID: String
            var resolvedEntry: LightSessionEntry? = nil
            let invStore = LightInventoryStore(rootDir: relay.storeURL)

            if positional.count == 1 {
                let address = positional[0]
                let canonical = hostOwner ?? { $0 }
                var resolved: (host: String, app: String, entry: LightSessionEntry)? = nil
                do {
                    resolved = try LightDirectory.resolve(address, inventoryStore: invStore, canonicalHost: canonical)
                } catch {
                    let hostPart = address.split(separator: "/").first.map(String.init) ?? ""
                    let targetHost = canonical(hostPart)
                    refreshInventory?(targetHost)
                    resolved = try? LightDirectory.resolve(address, inventoryStore: invStore, canonicalHost: canonical)
                    if resolved == nil {
                        throw error
                    }
                }
                guard let res = resolved else {
                    return LightCLIResult(exitCode: 1, text: "error: failed to resolve address \(address)")
                }
                host = res.host
                app = res.app
                sessionID = res.entry.id
                resolvedEntry = res.entry
            } else if positional.count >= 3 {
                let rawHost = positional[0]
                host = (hostOwner != nil) ? hostOwner!(rawHost) : rawHost
                app = positional[1].lowercased()
                sessionID = positional[2]

                var inv = invStore.load(node: host)
                if inv == nil || !inv!.sessions.contains(where: { $0.id == sessionID }) {
                    refreshInventory?(host)
                    inv = invStore.load(node: host)
                }
                resolvedEntry = inv?.sessions.first(where: { $0.id == sessionID })
            } else {
                return usage("pharos member adopt <address|host app id> --name X [--dir D] [--model M] [--tmux S] [--auto-revive] [--project P] [--force] [--json]")
            }

            guard app == "codex" || app == "agy" else {
                return LightCLIResult(exitCode: 1, text: "error: adopt supports codex and agy; use pharos member register for \(app)")
            }

            if let existing = relay.listMembers().first(where: { $0.sessionID == sessionID }) {
                return LightCLIResult(exitCode: 1, text: "error: member '\(existing.name)' already has session id '\(sessionID)'")
            }

            var dir = argv.option("dir")
            if dir == nil || dir!.isEmpty {
                dir = resolvedEntry?.cwd
                if (dir == nil || dir!.isEmpty) {
                    refreshInventory?(host)
                    let refreshed = invStore.load(node: host)
                    resolvedEntry = refreshed?.sessions.first(where: { $0.id == sessionID })
                    dir = resolvedEntry?.cwd
                }
            }
            guard let finalCwd = dir, !finalCwd.isEmpty else {
                return LightCLIResult(exitCode: 1, text: "error: no cwd known for \(sessionID); pass --dir")
            }

            let force = argv.flag("force")
            if app == "codex", !force, let state = resolvedEntry?.state, state == "active" || state == "needs_human" {
                return LightCLIResult(exitCode: 1, text: "error: session is busy in another client; --force to attach anyway")
            }

            let project: String
            if let p = argv.option("project"), !p.isEmpty {
                project = p
            } else if let p = resolvedEntry?.project, !p.isEmpty {
                project = p
            } else {
                let last = URL(fileURLWithPath: finalCwd).lastPathComponent
                project = last.isEmpty ? "default" : last
            }

            var member = try agents.adopt(
                name: validatedName,
                app: app,
                cwd: finalCwd,
                sessionID: sessionID,
                host: host,
                model: argv.option("model"),
                tmuxSession: argv.option("tmux"),
                project: project,
                autoRevive: argv.flag("auto-revive")
            )
            if argv.flag("auto-revive") {
                member.tmux?.autoRevive = true
            }

            let registered = try relay.register(member)
            if argv.flag("json") { return json(registered) }
            let tmuxName = registered.tmux?.session ?? argv.option("tmux") ?? validatedName
            return LightCLIResult(
                exitCode: 0,
                text: "adopted \(registered.name) (app \(registered.app)) on \(host) in tmux \(tmuxName), session \(registered.sessionID)",
                notes: agents.notes
            )
        case "stop":
            guard let name = argv.positional.dropFirst().first else {
                return usage("pharos member stop N [--force] [--json]")
            }
            guard let agents else {
                return LightCLIResult(exitCode: 1, text: "error: member stop needs live CLI access (PHAROS_LIGHT_LIVE=1)")
            }
            guard let member = relay.member(named: name) else {
                throw LightRelayError.unknownMember(name)
            }
            guard member.tmux != nil else {
                return LightCLIResult(exitCode: 1, text: "error: member \(name) has no tmux binding")
            }
            let binding = try agents.stop(member, force: argv.flag("force"))
            try relay.updateTmux(member: name, binding)
            _ = try? relay.reportAttention(LightAttentionReport(
                state: .clear,
                sessionID: member.sessionID,
                app: member.app,
                source: "hook"
            ))
            var updated = member
            updated.tmux = binding
            if argv.flag("json") { return json(updated) }
            let how = agents.notes.first { $0.hasPrefix("stop: ") }?.dropFirst("stop: ".count) ?? "graceful"
            return ok("stopped \(name) (\(how)); revive with: pharos member revive \(name)")
        case "set":
            guard let name = argv.positional.dropFirst().first else {
                return usage("pharos member set N --auto-revive on|off")
            }
            guard let member = relay.member(named: name) else {
                throw LightRelayError.unknownMember(name)
            }
            guard var binding = member.tmux else {
                return LightCLIResult(exitCode: 1, text: "error: member \(name) has no tmux binding")
            }
            guard let raw = argv.option("auto-revive") else {
                return usage("pharos member set N --auto-revive on|off")
            }
            let val: Bool
            switch raw.lowercased() {
            case "on", "true", "1", "yes": val = true
            case "off", "false", "0", "no": val = false
            default:
                return usage("pharos member set N --auto-revive on|off")
            }
            binding.autoRevive = val
            try relay.updateTmux(member: name, binding)
            var updated = member
            updated.tmux = binding
            if argv.flag("json") { return json(updated) }
            return ok("set \(name) auto-revive \(val ? "on" : "off")")
        case "revive":
            guard let name = argv.positional.dropFirst().first else {
                return usage("pharos member revive N [--json]")
            }
            guard let agents else {
                return LightCLIResult(exitCode: 1, text: "error: member revive needs live CLI access (PHAROS_LIGHT_LIVE=1)")
            }
            guard let member = relay.member(named: name) else {
                throw LightRelayError.unknownMember(name)
            }
            guard member.tmux != nil else {
                return LightCLIResult(exitCode: 1, text: "error: member \(name) has no tmux binding")
            }
            var newBinding = try agents.revive(member)
            newBinding.autoRevive = member.tmux?.autoRevive
            newBinding.endedReason = nil
            newBinding.endedAt = nil
            try relay.updateTmux(member: name, newBinding)
            var updated = member
            updated.tmux = newBinding
            if argv.flag("json") { return json(updated) }
            return ok("revived \(name) in tmux \(newBinding.session) (resumed \(member.sessionID))")
        case "register" where argv.option("app") == "webhook":
            // A remote assistant reached by HTTPS POST. Its session id is the webhook config name.
            guard let name = argv.option("name") else {
                return usage("pharos member register --name N --app webhook [--webhook CONFIG] [--host H] [--project P]")
            }
            let config = argv.option("webhook") ?? argv.option("session") ?? name
            let member = try relay.register(LightMember(
                name: name, host: argv.option("host") ?? "webhook", app: "webhook",
                project: argv.option("project") ?? "webhook", sessionID: config,
                routes: [LightRoute(id: "webhook", access: .write, fallback: false,
                                    summary: "HTTPS POST of the message envelope to the named webhook config")]
            ))
            if argv.flag("json") { return json(member) }
            return ok("registered \(member.name) (webhook \(member.sessionID))")
        case "register":
            guard let name = argv.option("name"), let host = argv.option("host"),
                  let app = argv.option("app"), let project = argv.option("project"),
                  let session = argv.option("session") else {
                return usage("pharos member register --name N --host H --app A --project P --session S [--route R]...")
            }
            let requested = argv.multi("route")
            let routes = requested.isEmpty ? routesForApp(app) : requested.map(routeByID)
            let member = try relay.register(LightMember(
                name: name, host: host, app: app, project: project, sessionID: session, routes: routes
            ))
            if argv.flag("json") { return json(member) }
            return ok("registered \(member.name)")
        default:
            return usage("pharos member register|list|launch|revive|stop|set")
        }
    }

    private static func thread(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        switch argv.positional.first {
        case "list":
            let threads = relay.listThreads()
            if argv.flag("json") { return json(threads) }
            if threads.isEmpty { return ok("no threads") }
            let lines = threads.map { view in
                let flag = view.thread.stopped ? "stopped" : "open"
                let people = view.participants.joined(separator: ",")
                return "\(view.thread.id)\t\(flag)\t\(view.thread.hopLimit)\t\(view.kind.rawValue)\t\(people)"
            }
            return ok((["THREAD\tSTATE\tHOP-LIMIT\tKIND\tPARTICIPANTS"] + lines).joined(separator: "\n"))
        case "show":
            guard let id = argv.positional.dropFirst().first else {
                return usage("pharos thread show <id>")
            }
            let view = try relay.show(thread: id)
            if argv.flag("json") {
                let messages = try relay.read(thread: id)
                return json(LightThreadShow(thread: view.thread, participants: view.participants, kind: view.kind, messages: messages))
            }
            let flag = view.thread.stopped ? "stopped" : "open"
            let people = view.participants.joined(separator: ",")
            let head = [
                "thread \(view.thread.id)",
                "kind \(view.kind.rawValue)",
                "state \(flag)",
                "originator \(view.thread.originator)",
                "hop-limit \(view.thread.hopLimit)",
                "participants \(people)",
                "intent \((view.thread.intent ?? .ask).rawValue)",
            ] + discussLines(view.thread) + attentionLines(view.participants, relay: relay)
            let entries = try relay.read(thread: id)
            let body = formatLog(entries)
            return ok((head + (body.isEmpty ? [] : [body])).joined(separator: "\n"))
        case "new", "add":
            return usage("threads are not created or joined explicitly. pharos send starts one. pharos thread list|show <id>")
        default:
            return usage("pharos thread list|show <id>")
        }
    }

    static let sendUsage = "pharos send --from NAME --to NAME... [--cc NAME]... [--intent ask|inform|discuss] [--deliver] [--rounds N] [--hop-limit N] -- <text>"
    static let replyUsage = "pharos reply r_xxx [--cc NAME]... [--intent answer|ask|inform] [--deliver] -- <text>"

    private static func send(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let from = argv.option("from") else { return usage(sendUsage) }
        // Recipients come only from parameters: --to, --cc, and leading member names (same as --to).
        var recipients = argv.multi("to")
        var words = argv.positional
        while let first = words.first, first != from, relay.member(named: first) != nil {
            recipients.append(words.removeFirst())
        }
        let text = (words + argv.forcedText).joined(separator: " ")
        guard !text.isEmpty else { return usage(sendUsage) }
        let intent: LightIntent
        if let raw = argv.option("intent") {
            guard let parsed = LightIntent.parse(raw) else { return usage("unknown intent \(raw); use ask|inform|answer|discuss") }
            intent = parsed
        } else {
            intent = .ask
        }
        let rounds = try argv.int("rounds")
        if rounds != nil, intent != .discuss { return usage("--rounds applies only to --intent discuss") }
        let result = try relay.send(from: from, to: recipients, cc: argv.multi("cc"), text: text, intent: intent,
                                    deliverReplies: argv.flag("deliver"), rounds: rounds,
                                    ttl: try argv.duration("ttl"), once: argv.flag("once"),
                                    hopLimit: try argv.int("hop-limit"))
        return render(result, json: argv.flag("json"))
    }

    private static func reply(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let id = argv.positional.first else { return usage(replyUsage) }
        // `--` protects text that starts with `-`, same as `send`.
        let text = (Array(argv.positional.dropFirst()) + argv.forcedText).joined(separator: " ")
        guard !text.isEmpty else { return usage(replyUsage) }
        var intent: LightIntent? = nil
        if let raw = argv.option("intent") {
            guard let parsed = LightIntent.parse(raw) else { return usage("unknown intent \(raw); use ask|inform|answer|discuss") }
            intent = parsed
        }
        let result = try relay.reply(id, text: text, cc: argv.multi("cc"), intent: intent, deliver: argv.flag("deliver"),
                                     ttl: try argv.duration("ttl"), once: argv.flag("once"))
        return render(result, json: argv.flag("json"))
    }

    private struct AttentionGroupKey: Hashable {
        let sessionID: String
        let app: String
    }

    private static func groupedAttentionLines(_ states: [LightAttention], at moment: Date, filterMembers: Set<String>? = nil) -> [String] {
        var groups: [AttentionGroupKey: [LightAttention]] = [:]
        var order: [AttentionGroupKey] = []
        for state in states {
            let key = AttentionGroupKey(sessionID: state.sessionID, app: state.app)
            if groups[key] == nil {
                order.append(key)
                groups[key] = [state]
            } else {
                groups[key]?.append(state)
            }
        }
        var lines: [String] = []
        for key in order {
            guard let group = groups[key], !group.isEmpty else { continue }
            if let filterMembers {
                let anyPresent = group.contains { filterMembers.contains($0.member) }
                if !anyPresent { continue }
            }
            let memberNames = group.map(\.member).sorted().joined(separator: ",")
            let oldest = group.min { $0.since < $1.since } ?? group[0]
            lines.append("needs_human \(memberNames): \(oldest.describe(at: moment))")
        }
        return lines
    }

    /// `needs_human codex-a: Bash: rm -rf build (host mini, session 01a1…, 2m ago)` per waiting participant.
    private static func attentionLines(_ names: [String], relay: LightRelay) -> [String] {
        let moment = Date()
        return names.compactMap { name in
            relay.attention(for: name).map { "needs_human \(name): \($0.describe(at: moment))" }
        }
    }

    static let attentionUsage = "pharos attention report --state needs_human|clear --session S [--app A] [--host H] [--what TEXT] [--ttl 20m] [--at EPOCH] [--source hook|poll] | pharos attention list [--json]"

    /// needs_human is recorded and reported only. There is no approve or deny command.
    private static func attention(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        switch argv.positional.first {
        case "list", nil:
            let states = relay.activeAttention()
            if argv.flag("json") { return json(states) }
            if states.isEmpty { return ok("no member needs a human") }
            let moment = Date()
            return ok(groupedAttentionLines(states, at: moment).joined(separator: "\n"))
        case "report":
            guard let state = LightAttentionState.parse(argv.option("state")), let session = argv.option("session") else {
                return usage(attentionUsage)
            }
            var at: Date? = nil
            if let raw = argv.option("at") {
                guard let seconds = Double(raw) else { return usage("--at takes epoch seconds") }
                // Hooks may report milliseconds.
                at = Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
            }
            let what = argv.option("what") ?? (argv.positional.dropFirst() + argv.forcedText).joined(separator: " ")
            let outcome = try relay.reportAttention(LightAttentionReport(
                state: state, what: what, sessionID: session, app: argv.option("app") ?? "",
                host: argv.option("host") ?? "", at: at, ttl: try argv.duration("ttl"),
                source: argv.option("source") ?? "hook"))
            if argv.flag("json") { return json(outcome) }
            if outcome.unmatched { return ok("no member has session \(session)") }
            switch state {
            case .needsHuman: return ok("needs_human \(outcome.recorded.joined(separator: ","))")
            case .clear: return ok(outcome.cleared.isEmpty ? "nothing to clear" : "cleared \(outcome.cleared.joined(separator: ","))")
            }
        case "approve", "deny", "answer":
            return usage("Pharos does not approve or deny; answer the prompt in the agent's own app")
        default:
            return usage(attentionUsage)
        }
    }

    private static func discussLines(_ thread: LightThread) -> [String] {
        var lines: [String] = []
        if thread.intent == .discuss {
            let cap = thread.rounds ?? LightRelay.defaultDiscussRounds
            lines.append("rounds \(thread.roundsUsed ?? 0)/\(cap)")
            lines.append("discussion \(thread.closed == true ? "closed" : "open")")
        }
        if thread.deliverReplies == true { lines.append("deliver-replies yes") }
        if let conclusion = thread.conclusion { lines.append("conclusion \(conclusion)") }
        return lines
    }

    private static func wait(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        guard let id = argv.positional.first else { return usage("pharos wait r_xxx [--timeout 30s]") }
        let (timeout, capNote) = clampWaitTimeout(try argv.duration("timeout"))
        let result = try relay.wait(replyID: id, timeout: timeout)
        var notes = result.nextReplyID.map { ["next reply-id \($0) (pharos reply \($0) -- \"...\" to continue)"] } ?? []
        if let capNote {
            notes.insert(capNote, at: 0)
        }
        if argv.flag("json") {
            var encoded = json(result, ok: result.status == .replied)
            encoded.notes = notes
            if result.status == .pending { encoded.exitCode = 2 }
            return encoded
        }
        switch result.status {
        case .replied:
            return LightCLIResult(exitCode: 0, text: result.text ?? "", notes: notes)
        case .pending:
            if let state = result.attention {
                return LightCLIResult(exitCode: 2, text: "pending \(id)\nneeds_human \(state.member): \(state.describe(at: Date()))", notes: notes)
            }
            return LightCLIResult(exitCode: 2, text: "pending \(id)", notes: notes)
        case .expired:
            return LightCLIResult(exitCode: 1, text: "error: expired reply-id \(id)", notes: notes)
        case .unknown:
            return LightCLIResult(exitCode: 1, text: "error: unknown reply-id \(id)", notes: notes)
        }
    }

    private static func read(_ argv: LightArgv, relay: LightRelay) throws -> LightCLIResult {
        let entries: [LightLogEntry]
        if let thread = argv.option("thread") {
            entries = try relay.read(thread: thread)
        } else if let token = argv.positional.first, LightTokens.isValid(token, prefix: "r") {
            entries = try relay.read(replyID: token)
        } else {
            return usage("pharos read --thread ID | pharos read r_xxx")
        }
        if argv.flag("json") { return json(entries) }
        let text = formatLog(entries)
        return ok(text.isEmpty ? "empty" : text)
    }

    private static func formatLog(_ entries: [LightLogEntry]) -> String {
        entries.map { entry -> String in
            switch entry.kind {
            case .message:
                var who = entry.from ?? ""
                let to = entry.recipients ?? []
                if !to.isEmpty { who += " -> " + to.joined(separator: ",") }
                if let cc = entry.cc, !cc.isEmpty { who += " cc " + cc.joined(separator: ",") }
                if entry.via == "harvest" { who += " (read from session)" }
                return "message\t\((entry.intent ?? .ask).rawValue)\t\(who)\t\(entry.text)"
            case .notice:
                return "notice\t\(entry.text)"
            case .delivery:
                let route = entry.route ?? "-"
                let verified = (entry.liveVerified ?? false) ? "verified" : "unverified"
                return "delivery\t\(entry.to ?? "")\t\(entry.state?.rawValue ?? "")\t\(entry.replyID ?? "")\t\(route)\t\(verified)"
            }
        }.joined(separator: "\n")
    }

    private static func render(_ result: LightSendResult, json: Bool) -> LightCLIResult {
        if json {
            var encoded = self.json(result)
            encoded.notes = hintLines(result)
            return encoded
        }
        if result.forwarded { return ok(result.notice ?? "forwarded") }
        var lines: [String] = []
        if result.stopped {
            lines.append("stopped \(result.threadID)")
        } else {
            let intent = result.intent.map { " intent \($0.rawValue)" } ?? ""
            lines.append("thread \(result.threadID) hop \(result.hop)/\(result.hopLimit)\(intent)")
        }
        if result.closed == true, result.notice == nil { lines.append("discussion closed") }
        if let notice = result.notice { lines.append(notice) }
        for delivery in result.deliveries {
            let route = delivery.route ?? "-"
            let verified = delivery.liveVerified ? "verified" : "unverified"
            let fallback = delivery.fallback ? " fallback" : ""
            let via = delivery.via.map { "\tvia \($0)" } ?? ""
            lines.append("\(delivery.state.rawValue)\t\(delivery.to)\t\(delivery.replyID)\t\(route)\t\(verified)\(fallback)\(via)")
            if delivery.attention != nil {
                lines.append("  " + delivery.detail)
            } else if delivery.detail.contains("node offline") {
                lines.append(delivery.detail)
            } else if delivery.state == .failed, !delivery.detail.isEmpty {
                lines.append("  " + delivery.detail.split(separator: "\n").prefix(2).joined(separator: " "))
            }
        }
        if !result.unresolved.isEmpty {
            lines.append("unresolved \(result.unresolved.joined(separator: ","))")
        }
        return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"), notes: hintLines(result))
    }

    static func hintLines(_ result: LightSendResult) -> [String] {
        (result.hints ?? []).map { "hint: body mentions @\($0); use --cc \($0) to copy them" }
    }

    private static func ok(_ text: String, notes: [String] = []) -> LightCLIResult {
        LightCLIResult(exitCode: 0, text: text, notes: notes)
    }

    private static func usage(_ text: String) -> LightCLIResult {
        LightCLIResult(exitCode: 2, text: "error: \(text)")
    }

    private static func json<T: Encodable>(_ value: T, ok: Bool = true) -> LightCLIResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return LightCLIResult(exitCode: 1, text: "error: could not encode the result")
        }
        return LightCLIResult(exitCode: ok ? 0 : 1, text: text)
    }
}

private struct LightThreadShow: Codable {
    var thread: LightThread
    var participants: [String]
    var kind: LightThreadKind
    var messages: [LightLogEntry]
}

private struct LightArgv {
    var positional: [String] = []
    /// Tokens after `--`. They are always message text, even when they name a member
    /// or look like a flag (`--json`). A trailing known flag stays part of the text.
    var forcedText: [String] = []
    var options: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var flags: Set<String> = []

    static let knownFlags: Set<String> = ["json", "once", "deliver", "force"]
    static let repeatedKeys: Set<String> = ["route", "to", "cc"]

    static func parse(_ tokens: [String]) -> LightArgv {
        var argv = LightArgv()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                argv.forcedText.append(contentsOf: tokens[(index + 1)...])
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
                    argv.repeated[key, default: []].append(inline)
                } else if knownFlags.contains(key) {
                    argv.flags.insert(key)
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    let value = tokens[index + 1]
                    argv.options[key] = value
                    argv.repeated[key, default: []].append(value)
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
    func multi(_ name: String) -> [String] { repeated[name] ?? [] }

    func int(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw), value >= 1 else { throw LightRelayError.invalidName(raw) }
        return value
    }

    func duration(_ name: String) throws -> TimeInterval? {
        guard let raw = options[name] else { return nil }
        return try Self.parseDuration(raw)
    }

    static func parseDuration(_ raw: String) throws -> TimeInterval {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds >= 0 { return seconds }
        guard let suffix = trimmed.last, let number = Double(trimmed.dropLast()), number >= 0 else {
            throw LightRelayError.invalidName(raw)
        }
        switch suffix {
        case "s": return number
        case "m": return number * 60
        case "h": return number * 60 * 60
        case "d": return number * 24 * 60 * 60
        default: throw LightRelayError.invalidName(raw)
        }
    }
}

extension LightCommands {
    /// `30s`, `5m`, `2h`, `1d`, or plain seconds.
    public static func duration(_ raw: String) throws -> TimeInterval {
        try LightArgv.parseDuration(raw)
    }

    public static let defaultWaitTimeout: TimeInterval = 60
    public static let maxWaitTimeout: TimeInterval = 300

    public static func clampWaitTimeout(_ raw: TimeInterval?) -> (timeout: TimeInterval, note: String?) {
        guard let raw else { return (defaultWaitTimeout, nil) }
        if raw <= 0 { return (0, nil) }
        if raw > maxWaitTimeout { return (maxWaitTimeout, "note: --timeout capped at 300s") }
        return (raw, nil)
    }

    /// `pharos help chat`: how agents message each other through Pharos.
    public static let chatHelp = """
    pharos help chat — messaging between agents (lightweight tier)

    ADDRESSING (parameters only)
      pharos send --from ME --to A [--to B]... [--cc C]... [--intent I] -- "<text>"
      pharos reply r_xxx [--cc C]... [--intent I] [--deliver] -- "<text>"
      Recipients come only from --to / --cc (leading member names count as --to).
      An @name in the text is plain text. If it names a registered member who is not
      addressed, Pharos prints `hint: body mentions @x; use --cc x to copy them` and
      delivers nothing extra. A reply goes back only to the member who sent the message,
      plus any --cc. A reply Pharos reads back from a session is never copied.

    INTENTS (--intent; send defaults to ask, reply to answer)
      ask      Delivered; a reply is expected.
      inform   Delivered as an FYI. The recipient should not reply just to acknowledge.
      answer   A reply to an ask. Recorded in the thread for the asker; not delivered.
      discuss  Back-and-forth, delivered each turn, capped by --rounds N (default 4,
               and still bounded by --hop-limit). Each reply is one round. A reply of
               DONE, or reaching the cap, closes the discussion; the originator is then
               asked for a one-line conclusion, which is recorded in the thread.

    WAKING THE SENDER
      By default an answer to your ask is only recorded: read it with
      `pharos read r_xxx` or `pharos thread show T`.
      --deliver on send (applies to its replies) or on reply wakes the sender's session.
      A reply with --intent ask is always delivered.

    READING
      pharos read r_xxx [--json]                  Answer text and messages for this reply.
      pharos thread show T [--json]               Intent, rounds, conclusion, every message.

    NEEDS HUMAN (an agent waiting on its own approval prompt)
      pharos attention list [--json]     Members waiting on a human: what, host, session, age.
      Per-app hooks (Claude Code / Codex PermissionRequest, dsh approval events) and
      polls (Antigravity / dsh / Cursor pending) report it; it clears when the agent
      proceeds or after its TTL (20m from a hook). Meanwhile a send to that member is
      queued ("queued ... needs_human: ...") and Pharos does not read its session.
      `member list` and `thread show` mark it. Pharos never approves or denies: the
      human answers in the agent's own app.

    CLI AGENT MEMBERS (tmux-backed codex / agy)
      pharos member launch --app codex|agy --name N --dir D [--host H] [--model M] [--tmux SESSION] [--message TEXT] [--project P] [--auto-revive] [--json]
      pharos member revive N [--json]
      pharos member stop N [--force] [--json]
      pharos member set N --auto-revive on|off
      Launches, revives, or stops a tmux-backed CLI agent member. Replies are read from the
      daemon (codex) / transcript (agy). needs_human is report-only.

    WEBHOOK MEMBERS (remote assistants)
      pharos webhook set NAME --url https://… [--header-name H] --secret-stdin|--secret-file F|--secret-env VAR
      pharos member register --name BOT --app webhook [--webhook NAME]
      Delivery is an HTTPS POST of {replyId, threadId, from, to, cc, intent, text, hop,
      hopLimit, expectsReply, replyCommand, prompt} with the secret in header H.
      The bot answers with `pharos reply r_xxx -- "<text>"` (from any Pharos node). Pharos does
      not read replies back from a webhook member.

    ANSWERING (you received a message with a reply-id)
      Answer with `pharos reply r_xxx -- "<text>"`. It hands the answer to this
      machine's Pharos node (directly, over the mesh, or through a spool file when a
      sandbox blocks the rest). If your shell cannot run it at all (read-only or ask
      mode), just answer in your own chat; Pharos reads it back from your session.
      After answering with `pharos reply`, say NOTHING about it in your own chat UI
      (not "replied", not "sent", not a summary) unless someone asks you.

    MACHINES (Pharos nodes)
      pharos host list [--json]          Nodes on the mesh: name, online/offline, last seen, aliases.
      pharos host alias NODE SHORT [--ssh DEST]   Your own short name for a node (any --host).
      pharos host unalias SHORT
      Another machine's sessions are driven only by that machine's Pharos node: over the
      Pharos mesh first, over SSH as a backup, else queued on the Broker for that node.
      Results say which (via mesh|ssh|queued). A node that cannot be reached is reported
      as "Pharos node offline".

    RECOMMENDED PATTERN
      For an ask, send with --intent ask --deliver and carry on — do not block.
      The answer is delivered into your session when it lands (or check pharos thread
      show T later). A subagent is useful for running a multi-round --intent discuss
      and reporting only the conclusion (recorded in the thread).
    """
}
