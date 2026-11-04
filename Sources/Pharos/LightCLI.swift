import Foundation
import PharosMeshCore
import PharosRuntime

// Lightweight-tier wiring for the `pharos` CLI: node-to-node routing, hub
// forwarding, the sandbox-safe reply hand-off, `host list|alias|unalias`, and
// the node-side commands (`node-deliver`, `node-harvest`, `light-tick`).
extension CLI {
    static var lightEnvironment: [String: String] { ProcessInfo.processInfo.environment }

    /// Set by the node (and the SSH backup) on a request it runs itself: never hand it on again.
    static var lightDirect: Bool { lightEnvironment["PHAROS_LIGHT_DIRECT"] == "1" }

    /// A CLI on a machine whose Broker is elsewhere. The Broker machine's node owns the ledger.
    static var lightIsHub: Bool {
        let tcp = lightEnvironment["PHAROS_MESH_TCP"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tcp.isEmpty && MeshClient.remoteEndpoint == nil
    }

    private static let routerBox = LightRouterBox()

    static func lightRouter() -> LightMeshRouter {
        routerBox.get {
            let env = lightEnvironment
            let bins = LightAppBins.fromEnvironment(env)
            let hosts = LightHostsFile.standard(env).load()
            var overrides: [String: String] = [:]
            let link: any LightBrokerLink = MeshBrokerLink.fromEnvironment(env)
            if let hubSSH = env["PHAROS_LIGHT_SSH_HOST"], !hubSSH.isEmpty,
               let hub = LightHostDirectory(nodes: link.roster() ?? [], config: hosts).hub {
                overrides[hub.name] = hubSSH
            }
            return LightMeshRouter(link: link, hosts: hosts,
                                   ssh: LightSSHRoute(runner: FoundationLightProcessRunner(),
                                                      remotePharos: bins.remotePharosShell),
                                   sshOverrides: overrides)
        }
    }

    // MARK: Dispatch

    /// member/thread/send/reply/wait/read/session/project.
    static func lightDispatch(command: String, arguments: [String]) -> LightCLIResult {
        let local = arguments.contains("--here")
        if !lightDirect, !local, !lightIsHub {
            return forwardToHub(command: command, arguments: arguments)
        }
        if command == "reply", !lightDirect, lightEnvironment["PHAROS_LIGHT_NO_SPOOL"] != "1",
           !LightRelay.storeIsWritable(LightRelay.defaultStoreURL()) {
            return spoolReply(arguments: arguments)
        }
        switch command {
        case "session": return sessionExecute(arguments: arguments)
        case "project": return projectExecute(arguments: arguments)
        default: return lightExecute(command: command, arguments: arguments)
        }
    }

    /// Hand a messaging command to the Broker machine's Pharos node (mesh, SSH backup).
    private static func forwardToHub(command: String, arguments: [String]) -> LightCLIResult {
        let router = lightRouter()
        guard let hub = router.hubName() ?? lightEnvironment["PHAROS_LIGHT_HUB"] else {
            if command == "reply", let spooled = trySpoolForNode(arguments: arguments) { return spooled }
            return LightCLIResult(exitCode: 1, text: "error: Pharos node offline (the Broker's node); nothing was sent")
        }
        // Aliases are this user's own: resolve them here, the hub may not know them.
        var args = arguments
        for (index, token) in args.enumerated() where token == "--host" && index + 1 < args.count {
            args[index + 1] = router.canonical(args[index + 1])
        }
        let timeout = forwardTimeout(command: command, arguments: args)
        guard let run = router.run(hub, argv: [command] + args, timeout: timeout) else {
            if command == "reply", let spooled = trySpoolForNode(arguments: arguments) { return spooled }
            return LightCLIResult(exitCode: 1, text: "error: Pharos node offline (\(hub)); nothing was sent")
        }
        let text = run.stdout.trimmingCharacters(in: .newlines)
        var notes = run.stderr.split(separator: "\n").map(String.init)
        if run.path == .ssh { notes.append("note: reached the Broker's node via ssh (mesh unavailable)") }
        return LightCLIResult(exitCode: run.status, text: text, notes: notes)
    }

    private static func forwardTimeout(command: String, arguments: [String]) -> TimeInterval {
        if command == "wait" {
            var rawSeconds: TimeInterval?
            for (index, arg) in arguments.enumerated() {
                if arg == "--timeout", index + 1 < arguments.count {
                    rawSeconds = try? LightCommands.duration(arguments[index + 1])
                    break
                } else if arg.hasPrefix("--timeout=") {
                    let value = String(arg.dropFirst("--timeout=".count))
                    rawSeconds = try? LightCommands.duration(value)
                    break
                }
            }
            let (seconds, _) = LightCommands.clampWaitTimeout(rawSeconds)
            return seconds + 30
        }
        return command == "session" || command == "project" ? 360 : 240
    }

    /// Reply from a sandbox: the store is not writable. A local node drains the spool.
    private static func spoolReply(arguments: [String]) -> LightCLIResult {
        trySpoolForNode(arguments: arguments)
            ?? LightCLIResult(exitCode: 1, text: "error: this sandbox blocks the Pharos store, the mesh, and the spool; answer in your own chat and Pharos will read it back")
    }

    private static func trySpoolForNode(arguments: [String]) -> LightCLIResult? {
        guard LightReplySpool.standard(lightEnvironment).write(argv: ["reply"] + arguments) != nil else { return nil }
        return LightCLIResult(exitCode: 0, text: "handed to the local Pharos node (spool)")
    }

    // MARK: host list | alias | unalias

    static func hostExecute(_ rest: [String], json: Bool) -> Int32? {
        guard let sub = rest.first, ["list", "ls", "alias", "unalias"].contains(sub) else { return nil }
        let env = lightEnvironment
        var config = LightHostsFile.standard(env).load()
        let roster = MeshBrokerLink.fromEnvironment(env).roster()
        let directory = LightHostDirectory(nodes: roster ?? [], config: config)
        var words: [String] = []
        var skip = false
        for token in rest.dropFirst() {
            if skip { skip = false; continue }
            if token == "--ssh" { skip = true; continue }
            if !token.hasPrefix("--") { words.append(token) }
        }
        switch sub {
        case "list", "ls":
            let moment = Date()
            let rows = directory.roster.map { node -> [String: Any] in
                [
                    "name": node.name, "online": node.online(at: moment),
                    "lastSeen": ISO8601DateFormatter().string(from: node.lastSeen),
                    "aliases": directory.aliases(of: node.name), "hub": node.brokerLocal,
                    "id": node.id, "host": node.host,
                ]
            }
            let dangling = config.aliases.filter { alias in !directory.roster.contains { $0.name == alias.value } }
            if json {
                print(prettyJSON(["nodes": rows, "broker": roster != nil,
                                  "unmatchedAliases": dangling.map { ["alias": $0.key, "node": $0.value] }]))
                return 0
            }
            if roster == nil { print("Broker not reachable from here; no node list (aliases below are saved)") }
            if rows.isEmpty, roster != nil { print("no Pharos nodes have checked in") }
            for node in directory.roster {
                let state = node.online(at: moment) ? "online" : "offline"
                let ago = LightRelay.lastSeenAgo(node.lastSeen, now: moment)
                let aliases = directory.aliases(of: node.name)
                print("\(node.name)\t\(state)\t\(ago)\t\(aliases.isEmpty ? "-" : aliases.joined(separator: ","))\(node.brokerLocal ? "\tbroker" : "")")
            }
            for (alias, node) in dangling.sorted(by: { $0.key < $1.key }) {
                print("\(node)\tnot a Pharos node\t-\t\(alias)")
            }
            return 0
        case "alias":
            guard words.count == 2 else {
                print("usage: pharos host alias <node> <short> [--ssh DEST]"); return 2
            }
            var ssh: String?
            if let index = rest.firstIndex(of: "--ssh"), index + 1 < rest.count { ssh = rest[index + 1] }
            do {
                guard roster != nil else {
                    return fail("Broker not reachable; an alias must name a Pharos node (see pharos host list)")
                }
                config = try directory.alias(node: words[0], as: words[1], ssh: ssh)
                try LightHostsFile.standard(env).save(config)
                print("alias \(words[1].lowercased()) -> \(config.aliases[words[1].lowercased()] ?? words[0])")
                return 0
            } catch {
                return fail(error.localizedDescription)
            }
        default:
            guard words.count == 1 else { print("usage: pharos host unalias <short>"); return 2 }
            do {
                config = try directory.unalias(words[0])
                try LightHostsFile.standard(env).save(config)
                print("removed alias \(words[0].lowercased())")
                return 0
            } catch {
                return fail(error.localizedDescription)
            }
        }
    }

    // MARK: Node-side commands

    /// Driver for this machine only: every member is local here.
    private static func localDriver() -> ExternalLightDriver {
        let env = lightEnvironment
        let bins = LightAppBins.fromEnvironment(env)
        let live = env["PHAROS_LIGHT_LIVE"] == "1"
        let cliEnv = CLIAgentEnvironment.make(env: env)
        return ExternalLightDriver(
            allowLive: live,
            runner: live ? FoundationLightProcessRunner() : nil,
            binaries: .fromEnvironment(env),
            codexSessions: CodexRolloutReader(),
            achat: bins.achat,
            replyFloorStore: LightRelay.defaultStoreURL().appendingPathComponent("achat-reply-floors.json"),
            selfHost: nil,
            cliAgents: cliEnv?.driver
        )
    }

    static func nodeExecute(command: String, arguments: [String]) -> LightCLIResult {
        LightNodeExec.execute(command: command, arguments: arguments, driver: localDriver())
    }

    /// Hub JSON encodes dates as seconds since 1970.
    static var secondsDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func nodeAgentExecute(_ arguments: [String]) -> LightCLIResult {
        let env = lightEnvironment
        guard let cliEnv = CLIAgentEnvironment.make(env: env) else {
            let resp = LightNodeAgentResponse(ok: false, error: "node has no live CLI access (PHAROS_LIGHT_LIVE=1)")
            return LightNodeExec.encodeLine(resp)
        }
        let localAgents = CLIMemberAgents(lifecycle: cliEnv.lifecycle, selfHost: .all)
        return LightNodeExec.executeAgent(arguments: arguments, agents: localAgents)
    }

    /// One bounded background pass, run by the node every ~20s: drain the reply
    /// spool, and on the Broker machine retry parked jobs and read back answers.
    static func lightTick(json: Bool) -> LightCLIResult {
        var body: [String: Any] = ["hub": lightIsHub]
        let spooled = LightReplySpool.standard(lightEnvironment).drain { argv in
            let result = lightDispatchNoSpool(argv)
            return result.exitCode == 0
        }
        body["spooled"] = spooled

        let env = lightEnvironment
        if let cliEnv = CLIAgentEnvironment.make(env: env) {
            let nodeName = LightHostDirectory.nodeName(ProcessInfo.processInfo.hostName)
            let supervisorStore = LightRelay.defaultStoreURL().deletingLastPathComponent().appendingPathComponent("cli-supervisor.json")
            let supervisor = CLISupervisor(lifecycle: cliEnv.lifecycle, node: nodeName, stateStore: supervisorStore)

            if lightIsHub {
                if let relay = try? makeLightRelay() {
                    let selfHost = LightSelfHost.fromEnvironment(env)
                    let hubMembers = relay.listMembers().filter { m in
                        guard m.tmux != nil else { return false }
                        return m.host == "local" || selfHost.matches(m.host)
                    }
                    let reports = supervisor.pass(members: hubMembers)
                    _ = try? relay.recordRuntime(reports, nodeMatches: { _ in true })
                    let revived = reports.filter { $0.detail == "auto-revived" }.map(\.member)
                    body["supervised"] = hubMembers.count
                    body["revived"] = revived
                }
            } else {
                let router = lightRouter()
                if let hub = router.hubName() {
                    let runResult = router.run(hub, argv: ["member", "node-members", "--node", nodeName, "--json"], timeout: 30)
                    if let out = runResult, out.status == 0,
                       let data = out.stdout.data(using: .utf8),
                       let members = try? Self.secondsDecoder.decode([LightMember].self, from: data) {
                        if !members.isEmpty {
                            let reports = supervisor.pass(members: members)
                            let revived = reports.filter { $0.detail == "auto-revived" }.map(\.member)
                            body["supervised"] = members.count
                            body["revived"] = revived
                            if let b64 = LightCodec.encode(reports) {
                                _ = router.run(hub, argv: ["member", "node-report", "--node", nodeName, "--payload", b64], timeout: 30)
                            }
                        } else {
                            body["supervised"] = 0
                            body["revived"] = [String]()
                        }
                    }
                }
            }
        }

        if lightIsHub, FileManager.default.fileExists(atPath: LightRelay.defaultStoreURL().path) {
            do {
                let relay = try makeLightRelay()
                let env = lightEnvironment
                let sessions = LightSessionService(
                    relay: relay, runner: FoundationLightProcessRunner(), prober: LoopbackDebugProber(),
                    ports: .fromEnvironment(env), apps: .fromEnvironment(env), selfHost: .fromEnvironment(env),
                    nodes: lightRouter()
                )
                let report = LightTick(relay: relay, sessions: sessions, router: lightRouter(),
                                       attention: attentionPoller(env)).run()
                body["attention"] = report.attention
                body["inboxRetried"] = report.inboxRetried
                body["flushed"] = report.flushed
                body["harvested"] = report.harvested
                body["checked"] = report.checked
            } catch {
                body["error"] = error.localizedDescription
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return LightCLIResult(exitCode: 1, text: "{}") }
        _ = json
        return LightCLIResult(exitCode: body["error"] == nil ? 0 : 1, text: text)
    }

    /// needs_human polls (achat `pending` and CLI agents) run only with live app access, for members on this machine.
    private static func attentionPoller(_ env: [String: String]) -> (any HumanAttentionSource)? {
        guard env["PHAROS_LIGHT_LIVE"] == "1", env["PHAROS_LIGHT_ATTENTION_POLL"] != "0" else { return nil }
        let selfHost = LightSelfHost.fromEnvironment(env)
        let label = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "local"
        let achat = AchatPendingAttentionSource(runner: FoundationLightProcessRunner(),
                                           achat: LightAppBins.fromEnvironment(env).achat,
                                           isLocal: { selfHost.matches($0.host) }, hostLabel: label.lowercased())
        if let cliEnv = CLIAgentEnvironment.make(env: env) {
            return CombinedAttentionSource(sources: [achat, cliEnv.attentionSource])
        }
        return achat
    }

    private static func lightDispatchNoSpool(_ argv: [String]) -> LightCLIResult {
        guard argv.first == "reply" else { return LightCLIResult(exitCode: 2, text: "error: spool holds replies only") }
        let arguments = Array(argv.dropFirst())
        if !lightIsHub { return forwardToHubNoSpool(arguments) }
        return lightExecute(command: "reply", arguments: arguments)
    }

    private static func forwardToHubNoSpool(_ arguments: [String]) -> LightCLIResult {
        let router = lightRouter()
        guard let hub = router.hubName(), let run = router.run(hub, argv: ["reply"] + arguments, timeout: 120) else {
            return LightCLIResult(exitCode: 1, text: "error: Pharos node offline (the Broker's node)")
        }
        return LightCLIResult(exitCode: run.status, text: run.stdout)
    }
}

/// One router per process (its roster cache is the point).
final class LightRouterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var router: LightMeshRouter?

    func get(_ make: () -> LightMeshRouter) -> LightMeshRouter {
        lock.lock()
        defer { lock.unlock() }
        if let router { return router }
        let made = make()
        router = made
        return made
    }
}
