import Foundation

/// The `pharos` command-line front door — Pharos's interface for agents and
/// scripts. A thin shim: it parses argv, calls `PharosCore`, and prints the
/// result. Reads print a human table by default and JSON under `--json`;
/// mutations print a one-line confirmation. Exit codes: 0 ok, 1 operation
/// error, 2 usage error.
///
/// An agent (or a script) can shell out to it directly, e.g.
///   pharos list --json
///   pharos launch myrepo claude --tmux
///   pharos remove myrepo            # reversible — see `pharos trash`
enum CLI {

    /// True if `token` should route to the CLI rather than the GUI. Any bare
    /// word (not starting with `-`) is treated as a CLI subcommand — known or a
    /// typo — so typos surface a usage error instead of silently opening the GUI.
    /// GUI launch arguments from LaunchServices all start with `-` (`-psn_…`,
    /// `-NSDocumentRevisionsDebugMode`, …) and fall through to the app, except
    /// the explicit help/version flags handled here.
    static func isCommand(_ token: String) -> Bool {
        if ["--help", "-h", "--version", "-v"].contains(token) { return true }
        return !token.hasPrefix("-")
    }

    // MARK: Entry

    /// Run the CLI. `args` excludes the program name. Returns the process exit code.
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else { printUsage(); return 0 }
        let rest = Array(args.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage(); return 0
        case "version", "--version", "-v":
            print("pharos \(version)"); return 0
        case "identity" where rest.first == "bootstrap":
            do {
                let replica = try MeshLocalReplica.openDefault(headless: false)
                print("identity ready\t\(replica.identity.deviceID.rawValue.uuidString)")
                return 0
            } catch {
                FileHandle.standardError.write(
                    Data("error: identity bootstrap failed: \(error)\n".utf8)
                )
                return 1
            }
        default:
            break
        }

        let p = parse(rest)

        if PharosMeshRuntimeMode.usesDistributedMesh,
           ProcessInfo.processInfo.environment["PHAROS_REGISTRY"] == nil {
            if DistributedRegistryCLI.handles(command, parsed: p) {
                return await DistributedRegistryCLI.run(command, parsed: p)
            }
            if ["launch", "resume", "playbook", "open", "editor", "reveal", "path", "git", "worktrees", "sessions"].contains(command)
                || (command == "issue" && p.arg(0) == "start") {
                await DistributedRegistryCLI.refreshLocalCache()
            }
        }

        do {
            switch command {
            // Reads
            case "list", "projects":
                return emit(PharosCore.listProjects(), json: p.has("json"))
            case "groups":
                return emit(PharosCore.listGroups(), json: p.has("json"))
            case "trash":
                return try runTrash(p)
            case "git":
                return emit(try PharosCore.gitStatus(project: p.arg(0) ?? ""), json: p.has("json"))
            case "worktrees":
                return emit(try PharosCore.listWorktrees(project: p.arg(0) ?? ""), json: p.has("json"))
            case "sessions":
                return emit(try PharosCore.listSessions(project: p.arg(0) ?? "", agent: p.arg(1) ?? ""), json: p.has("json"))

            // Actions
            case "launch":
                let yolo: Bool? = p.has("no-yolo") ? false : (p.has("yolo") ? true : nil)
                let tmux: Bool? = p.has("tmux") ? true : nil
                return ok(try await PharosCore.launchAgent(project: p.arg(0), agent: p.arg(1), yolo: yolo, tmux: tmux, host: p.opt("host"), source: .cli))
            case "agents":
                return ok(RemoteLaunch.listAgents(host: p.opt("host"), filter: p.arg(0)))
            case "agent":
                return try runAgent(p)
            case "resume":
                return ok(try await PharosCore.resumeSession(project: p.arg(0), agent: p.arg(1), sessionID: p.arg(2)))
            case "playbook":
                return ok(try PharosCore.runPlaybook(project: p.arg(0), playbook: p.arg(1)))
            case "open":
                return ok(try PharosCore.openTerminal(project: p.arg(0)))
            case "editor":
                return ok(try PharosCore.openEditor(project: p.arg(0)))
            case "reveal":
                return ok(try PharosCore.revealInFinder(project: p.arg(0)))

            // Writes
            case "add":
                return ok(try PharosCore.addProject(name: p.arg(0), localPath: p.opt("path"),
                                                    githubRemote: p.opt("remote"),
                                                    tags: p.all("tag"), notes: p.opt("notes")))
            case "remove":
                let message = try PharosCore.removeProject(name: p.arg(0))
                AuditLog.record(actor: .cli, action: "remove_project", detail: p.arg(0) ?? "")
                return ok(message)
            case "rename":
                return ok(try PharosCore.renameProject(name: p.arg(0), newName: p.arg(1)))
            case "describe":
                // Everything after the project name is the description text.
                let text = p.positional.dropFirst().joined(separator: " ")
                return ok(try PharosCore.setDescription(name: p.arg(0), description: text))
            case "group":
                return try runGroup(p)
            case "issue":
                return try await runIssue(p)
            case "milestone":
                return try runMilestone(p)
            case "update":
                return try runUpdate(p)
            case "attach":
                return try runAttach(p)
            case "path":
                if p.arg(1) == nil, !p.has("clear") {
                    return emit(try PharosCore.localPath(project: p.arg(0)), json: p.has("json"))
                }
                return ok(try PharosCore.setLocalPath(project: p.arg(0), path: p.arg(1), clear: p.has("clear")))
            case "host":
                return emit(PharosCore.hostInfo(), json: p.has("json"))
            case "search":
                return emit(try PharosCore.search(p.positional.joined(separator: " ")), json: p.has("json"))
            case "overview", "dashboard":
                return emit(PharosCore.overview(), json: p.has("json"))
            case "yolo":
                return ok(try PharosCore.setFlag(name: p.arg(0), flag: "yolo", value: try boolArg(p.arg(1), label: "on|off")))
            case "tmux":
                return ok(try PharosCore.setFlag(name: p.arg(0), flag: "tmux", value: try boolArg(p.arg(1), label: "on|off")))
            case "mesh":
                return await runMesh(rest)
            case "skill", "skills":
                return runSkill(rest)

            default:
                return usageError("Unknown command: \(command)")
            }
        } catch let e as CoreError {
            return fail(e.message)
        } catch let e as UsageError {
            return usageError(e.message)
        } catch {
            return fail("\(error)")
        }
    }

    // MARK: Sub-dispatchers

    /// `pharos agent peek|say|kill <session> [--host <alias>]` — drive a live
    /// agent tmux session, local or on another machine (see `pharos agents`).
    private static func runAgent(_ p: Parsed) throws -> Int32 {
        let host = p.opt("host")
        guard let sub = p.arg(0) else {
            return usageError("usage: pharos agent peek|say|kill <session> [--host <alias>]")
        }
        guard let session = p.arg(1) else {
            return usageError("agent \(sub) needs a session name (list them: pharos agents)")
        }
        do {
            switch sub {
            case "peek":
                let lines = Int(p.opt("lines") ?? "") ?? 40
                return ok(try RemoteLaunch.peek(session: session, host: host, lines: lines))
            case "say":
                let text = p.positional.dropFirst(2).joined(separator: " ")
                guard !text.isEmpty else { return usageError("agent say needs a message") }
                return ok(try RemoteLaunch.say(session: session, host: host, text: text))
            case "kill":
                return ok(try RemoteLaunch.kill(session: session, host: host))
            default:
                return usageError("Unknown agent subcommand: \(sub) (use peek|say|kill)")
            }
        } catch let e as RemoteLaunch.RemoteError {
            throw CoreError(message: e.message)
        }
    }

    private static func runTrash(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case nil, "list":
            return emit(PharosCore.listTrash(), json: p.has("json"))
        case "restore":
            return ok(try PharosCore.restoreTrash(id: p.arg(1)))
        case "empty":
            return ok(PharosCore.emptyTrash())
        case let other?:
            return usageError("Unknown trash subcommand: \(other) (use list | restore <id> | empty)")
        }
    }

    /// `pharos mesh …` — the agent chat room. Uses raw tokens (positional
    /// room/nick/text), not the flag parser. Non-blocking: `say` delivers into the
    /// target's mailbox, the Stop hook surfaces it; `recv` drains without blocking.
    private static func runMesh(_ args: [String]) async -> Int32 {
        let legacyBrokerEnabled = ProcessInfo.processInfo.environment["PHAROS_LEGACY_BROKER"] == "1"
        guard let sub = args.first else {
            print(legacyBrokerEnabled ? legacyMeshUsage : distributedMeshUsage)
            return 0
        }
        if !legacyBrokerEnabled, ["help", "--help", "-h"].contains(sub) {
            print(distributedMeshUsage)
            return 0
        }
        if sub == "pair", !legacyBrokerEnabled {
            return await DistributedPairCLI.run(Array(args.dropFirst()))
        }
        if DistributedAgentCLI.commands.contains(sub), !legacyBrokerEnabled {
            var distributedArgs = args
            if ["join", "send"].contains(sub),
               !args.contains("--session"), !args.contains("--member"),
               let sessionID = DistributedHookCLI.currentSessionID()
                    ?? MeshHooks.currentSessionID() {
                distributedArgs += ["--member", sessionID]
                if sub == "join" {
                    distributedArgs.removeLast(2)
                    distributedArgs += ["--session", sessionID]
                }
            }
            return await DistributedAgentCLI.run(distributedArgs)
        }
        if !legacyBrokerEnabled, sub == "unread", args.contains("--hook-stop") {
            return await DistributedHookCLI.run("stop", args: args)
        }
        if !legacyBrokerEnabled, sub == "unread", args.contains("--hook-post-tool") {
            return await DistributedHookCLI.run("post-tool", args: args)
        }
        if !legacyBrokerEnabled, sub == "mark", args.contains("--hook") {
            return await DistributedHookCLI.run("mark", args: args)
        }
        if !legacyBrokerEnabled, sub == "session-start" {
            return await DistributedHookCLI.run("session-start", args: args)
        }
        if !legacyBrokerEnabled, sub == "install-hooks" {
            return MeshHooks.installHooks(Array(args.dropFirst()))
        }
        if !legacyBrokerEnabled, sub == "spawn" {
            return await runMeshSpawn(Array(args.dropFirst()))
        }
        if !legacyBrokerEnabled {
            print("error: '\(sub)' belongs to the retired Broker/Node CLI and is unavailable in distributed mode")
            print(distributedMeshUsage)
            return 1
        }
        let a = Array(args.dropFirst())
        func report(_ r: MeshResponse) -> Int32 {
            print(r.ok ? (r.note ?? "ok") : "error: \(r.error ?? "?")")
            return r.ok ? 0 : 1
        }
        func printMessages(_ messages: [MeshMsg], empty: String) {
            if messages.isEmpty { print(empty) }
            for message in messages {
                print("id: \(message.stableID)")
                if let reply = message.replyTo { print("  ↳ \(reply.from): \(reply.preview)") }
                print("[\(message.room)] \(message.from): \(message.text)")
                for attachment in message.attachments ?? [] {
                    print("  attachment: \(attachment.name) (\(attachment.byteSize) bytes, id \(attachment.id))")
                    print("  download: pharos mesh attachment get \(attachment.id) --out \(attachment.name)")
                }
            }
        }

        switch sub {
        case "daemon":
            MeshBroker.runDaemon()                          // never returns
        case "create":
            guard let room = a.first else { print("usage: pharos mesh create <room>"); return 2 }
            return report(MeshClient.send(MeshRequest(cmd: "create", room: room)))
        case "list":
            let r = MeshClient.send(MeshRequest(cmd: "list"))
            guard r.ok else { return report(r) }
            let rooms = r.rooms ?? []
            if rooms.isEmpty { print("(no rooms)") }
            for ri in rooms { print("\(ri.name)  [\(ri.members.joined(separator: ", "))]") }
            return 0
        case "join":
            guard a.count >= 2 else { print("usage: pharos mesh join <room> <nick> [--session <id>] [--kind claude|codex]"); return 2 }
            // cwd is recorded as the nick's project so hooks can resolve cwd → nick;
            // --session (the id the SessionStart hook injected) makes it exact.
            let env = ProcessInfo.processInfo.environment
            var session: String?
            if let i = a.firstIndex(of: "--session"), i + 1 < a.count { session = a[i + 1] }
            session = session ?? MeshHooks.currentSessionID(environment: env)
            guard session?.isEmpty == false else {
                print("error: no session identity for this pane; restart the agent or pass --session <id>")
                return 2
            }
            // The CLI runs inside the agent's own shell, so a tmux-wrapped
            // session exposes its pane right here — captured into presence, it's
            // what lets this Host's headless node locate the pane safely.
            let pane = env["TMUX"] != nil ? env["TMUX_PANE"] : nil
            let socket = RemoteLaunch.tmuxSocket(fromEnvironmentValue: env["TMUX"])
            // Agent kind → which avatar set the GUI shows. Explicit --kind wins;
            // else auto-detect from the runtime the CLI is running inside.
            var kind: String?
            if let i = a.firstIndex(of: "--kind"), i + 1 < a.count { kind = a[i + 1] }
            kind = kind ?? detectAgentKind(env)
            var request = MeshRequest(cmd: "join", room: a[0], nick: a[1],
                                      project: FileManager.default.currentDirectoryPath,
                                      session: session,
                                      host: HostIdentity.current,
                                      tmuxPane: pane,
                                      tmuxSocket: socket,
                                      kind: kind,
                                      tailscaleIP: detectTailscaleIP())
            request.nodeID = MeshNodeIdentity.current
            let r = MeshClient.send(request)
            guard r.ok else { return report(r) }
            print("joined \(a[0]) as \(a[1])")
            let history = r.messages ?? []
            if !history.isEmpty {
                print("recent:")
                printMessages(history, empty: "")
            }
            return 0
        case "history":
            guard let room = a.first else { print("usage: pharos mesh history <room> [--limit N]"); return 2 }
            var limit = 30
            if let i = a.firstIndex(of: "--limit"), i + 1 < a.count, let n = Int(a[i + 1]) { limit = n }
            let r = MeshClient.send(MeshRequest(cmd: "history", room: room, limit: limit))
            guard r.ok else { return report(r) }
            printMessages(r.messages ?? [], empty: "(no history)")
            return 0
        case "leave":
            guard a.count >= 2 else { print("usage: pharos mesh leave <room> <nick>"); return 2 }
            return report(MeshClient.send(MeshRequest(cmd: "leave", room: a[0], nick: a[1])))
        case "rename-member":
            guard a.count >= 3 else { print("usage: pharos mesh rename-member <room> <nick> <new-nick>"); return 2 }
            return report(MeshClient.send(MeshRequest(cmd: "rename-member", room: a[0], nick: a[1], text: a[2])))
        case "delete", "rm":
            guard let room = a.first else { print("usage: pharos mesh delete <room>"); return 2 }
            return report(MeshClient.send(MeshRequest(cmd: "delete", room: room)))
        case "rename":
            guard a.count >= 2 else { print("usage: pharos mesh rename <room> <new-name>"); return 2 }
            return report(MeshClient.send(MeshRequest(cmd: "rename", room: a[0], text: a[1])))
        case "say":
            guard a.count >= 3 else { print("usage: pharos mesh say <room> <nick> <text> [@target …] [--reply ID] [--attach FILE]"); return 2 }
            var to = a.dropFirst(3).compactMap { $0.hasPrefix("@") ? String($0.dropFirst()) : nil }
            // Also honor @mentions written in the message text — the broker is
            // mention-only, so "@bob" in the body with no trailing @arg would
            // otherwise wake nobody (matches the GUI input's behavior).
            for m in MeshHooks.parseTextMentions(a[2]) where !to.contains(m) { to.append(m) }
            let replyID = a.firstIndex(of: "--reply").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            let attachmentPath = a.firstIndex(of: "--attach").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            if replyID != nil || attachmentPath != nil {
                let capabilities = MeshClient.send(MeshRequest(cmd: "capabilities"))
                guard capabilities.capabilities?.contains("mesh-v2") == true else {
                    print("error: update the Mesh broker before sending replies or attachments")
                    return 1
                }
            }
            let memberID = a.firstIndex(of: "--member").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
                ?? MeshHooks.currentSessionID()
            var request = MeshRequest(cmd: "say", room: a[0], nick: a[1], memberID: memberID,
                                      text: a[2], to: to)
            request.replyToID = replyID
            if let attachmentPath {
                do { request.attachments = [try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: attachmentPath))] }
                catch { print("error: \(error.localizedDescription)"); return 1 }
            }
            let r = MeshClient.send(request)
            return report(r)
        case "send":
            guard let text = a.first, !text.hasPrefix("--") else {
                print("usage: pharos mesh send <text> [@target …] [--room ROOM] [--reply ID] [--attach FILE]")
                return 2
            }
            let room = a.firstIndex(of: "--room").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            let memberID = a.firstIndex(of: "--member").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
                ?? MeshHooks.currentSessionID()
            guard let memberID, !memberID.isEmpty else {
                print("error: no session identity for this pane; restart the agent or pass --member <session-id>")
                return 2
            }
            var to = a.dropFirst().compactMap { $0.hasPrefix("@") ? String($0.dropFirst()) : nil }
            for mention in MeshHooks.parseTextMentions(text) where !to.contains(mention) { to.append(mention) }
            let replyID = a.firstIndex(of: "--reply").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            let attachmentPath = a.firstIndex(of: "--attach").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            var request = MeshRequest(cmd: "say", room: room, memberID: memberID, text: text, to: to,
                                      replyToID: replyID)
            if let attachmentPath {
                do { request.attachments = [try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: attachmentPath))] }
                catch { print("error: \(error.localizedDescription)"); return 1 }
            }
            return report(MeshClient.send(request))
        case "attachment":
            guard let action = a.first else { print("usage: pharos mesh attachment put|get …"); return 2 }
            switch action {
            case "put":
                guard a.count >= 2 else { print("usage: pharos mesh attachment put <file>"); return 2 }
                do { print(try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: a[1])).id); return 0 }
                catch { print("error: \(error.localizedDescription)"); return 1 }
            case "get":
                guard a.count >= 2 else { print("usage: pharos mesh attachment get <id> [--out path]"); return 2 }
                let out = a.firstIndex(of: "--out").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } ?? a[1]
                do { print(try MeshClient.downloadAttachment(id: a[1], to: URL(fileURLWithPath: out)).path); return 0 }
                catch { print("error: \(error.localizedDescription)"); return 1 }
            default:
                print("usage: pharos mesh attachment put|get …"); return 2
            }
        case "recv":
            let nick = a.first.flatMap { $0.hasPrefix("--") ? nil : $0 }
            let memberID = a.firstIndex(of: "--member").flatMap { i in i + 1 < a.count ? a[i + 1] : nil }
                ?? MeshHooks.currentSessionID()
            guard nick != nil || memberID != nil else {
                print("usage: pharos mesh recv [<nick>] [--member <session-id>]")
                return 2
            }
            let r = MeshClient.send(MeshRequest(cmd: "recv", nick: nick, memberID: memberID,
                                                project: FileManager.default.currentDirectoryPath))
            guard r.ok else { return report(r) }
            printMessages(r.messages ?? [], empty: "(no unread)")
            return 0
        case "who":
            let r = MeshClient.send(MeshRequest(cmd: "who"))
            guard r.ok else { return report(r) }
            let members = r.members ?? []
            if members.isEmpty { print("(nobody has joined yet)") }
            for m in members {
                var bits = [m.state ?? "state?"]
                if let k = m.kind { bits.append(k) }
                if let h = m.host { bits.append(h) }
                if let ip = m.tailscaleIP { bits.append(ip) }
                bits.append(m.tmuxPane.map { "tmux \($0)" } ?? "no tmux")
                if let p = m.project { bits.append((p as NSString).abbreviatingWithTildeInPath) }
                bits.append("session \(m.id.prefix(8))")
                print("\(m.nick)  [\(bits.joined(separator: " · "))]  rooms: \(m.rooms.joined(separator: ", "))")
            }
            return 0
        case "pair":
            let explicit = a.firstIndex(of: "--endpoint")
                .flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
            let endpoint = explicit ?? MeshPaths.dialEndpoint
                ?? PairingService.selfTailscaleIP().map { "\($0):47800" }
            guard let endpoint, meshSplitHostPort(endpoint) != nil else {
                print("error: no Tailscale Broker endpoint is available")
                return 1
            }
            let response = MeshClient.send(MeshRequest(cmd: "pairing-create",
                                                       timeoutMs: 300_000, host: endpoint),
                                           to: endpoint)
            guard response.ok, let link = response.payload else { return report(response) }
            printTerminalQRCode(link)
            print(link)
            print("expires in 5 minutes · single use")
            return 0
        case "mark":
            return MeshHooks.mark(a)                // Claude Code state hooks (see MeshHooks)
        case "spawn":
            return await runMeshSpawn(a)
        case "poke":
            guard a.count == 2 else { print("usage: pharos mesh poke <room> <nick>"); return 2 }
            let response = MeshClient.send(MeshRequest(cmd: "poke", room: a[0], nick: a[1]))
            guard response.ok else { return report(response) }
            print("poke queued for @\(a[1]) on its Host node")
            return 0
        case "unread":
            return MeshHooks.unread(a)
        case "session-start":
            return MeshHooks.sessionStart(a)        // Claude Code SessionStart hook
        case "install-hooks":
            return MeshHooks.installHooks(a)
        default:
            print(legacyMeshUsage); return 2
        }
    }

    /// Shared local/SSH spawn workflow for both distributed product mode and
    /// the explicit legacy diagnostic. Confirmation follows the active Mesh
    /// runtime, so distributed mode reads replicated membership only.
    private static func runMeshSpawn(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else {
            print("usage: pharos mesh spawn <room> <nick> [claude|codex] [--host <ssh>] [--cwd <dir> | --project <name>]")
            return 2
        }
        var kind = AgentKind.claude
        var host: String?
        var cwd: String?
        var projectName: String?
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--host":
                guard i + 1 < args.count else { print("error: --host needs an SSH alias or IP"); return 2 }
                host = args[i + 1]; i += 2
            case "--cwd", "--dir":
                guard i + 1 < args.count else { print("error: --cwd needs a directory path"); return 2 }
                cwd = args[i + 1]; i += 2
            case "--project":
                guard i + 1 < args.count else { print("error: --project needs a project name"); return 2 }
                projectName = args[i + 1]; i += 2
            default:
                if let parsed = AgentKind(rawValue: args[i]) { kind = parsed; i += 1 }
                else { print("error: expected claude, codex, --host, --cwd, or --project; got '\(args[i])'"); return 2 }
            }
        }
        if cwd != nil, projectName != nil {
            print("error: use either --cwd or --project, not both"); return 2
        }
        let workDir: MeshSpawn.WorkDir = cwd.map { .path($0) }
            ?? projectName.map { .project($0) } ?? .scratch
        var final = MeshSpawn.Phase.failed
        await MeshSpawn.spawn(
            room: args[0], nick: args[1], kind: kind,
            host: host, workDir: workDir
        ) { progress in
            print("[\(progress.phase.rawValue)] \(progress.detail)")
            final = progress.phase
        }
        return final == .joined ? 0 : 1
    }

    /// Which coding agent is this CLI running inside? Claude Code exports
    /// `CLAUDECODE=1`; Codex runs inside its `codex.system` cryptex sandbox and
    /// exports `CODEX_*` (and its bootstrap dir is on PATH). nil = unknown →
    /// the GUI treats it as Claude (the default avatar set).
    private static func detectAgentKind(_ env: [String: String]) -> String? {
        if env["CLAUDECODE"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil { return "claude" }
        if env.keys.contains(where: { $0.hasPrefix("CODEX_") })
            || (env["PATH"]?.contains("codex.system") ?? false) { return "codex" }
        return nil
    }

    /// This machine's own Tailscale IPv4, captured at join so the mobile app can
    /// auto-fill the SSH host for a member without the user typing it. Best-effort
    /// — nil if Tailscale isn't installed/logged in.
    private static func detectTailscaleIP() -> String? {
        let candidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/bin/tailscale"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let out = Shell.run(path, ["ip", "-4"]).out
            if let line = out.split(whereSeparator: \.isNewline).first {
                let ip = line.trimmingCharacters(in: .whitespaces)
                if ip.split(separator: ".").count == 4 { return ip }
            }
        }
        return nil
    }

    /// `pharos skill …` — install the bundled agent skills into Claude's skills dir.
    private static func runSkill(_ args: [String]) -> Int32 {
        switch args.first {
        case "list", nil, "ls":
            let s = SkillInstall.available()
            if s.isEmpty { print("(no bundled skills found)") } else { s.forEach { print($0) } }
            return 0
        case "install":
            let rest = Array(args.dropFirst())
            guard let name = rest.first else {
                print("usage: pharos skill install <name|all> [--project <dir>]"); return 2
            }
            var project: String?
            if let i = rest.firstIndex(of: "--project"), i + 1 < rest.count { project = rest[i + 1] }
            SkillInstall.install(name, projectDir: project).forEach { print($0) }
            return 0
        case let other?:
            return usageError("Unknown skill subcommand: \(other) (use list | install <name|all> [--project <dir>])")
        }
    }

    private static let distributedMeshUsage = """
    pharos mesh — distributed, local-first agent chat
      create <room>                       create a replicated room
      list                                list replicated rooms + members
      join <room> <nick> --session <id>   join with this agent session
      history <room> [--limit N]          show replicated history
      send <text> [@n …] [--room ROOM] [--member ID] [--reply ID] [--attach FILE]
      say <room> <nick> <text> [@n …] [--reply ID] [--attach FILE]
      recv [<nick>] --member <id>          drain this session's replicated unread messages
      who                                 list replicated room membership
      attachment put|get …                store/read content-addressed attachments
      pair invite|accept|redeem|list       manage signed trusted-device pairing
      leave <room> <nick|member-id>       leave replicated room membership
      stop <room> <nick|member-id>        send a signed stop to the owning Host
      rename-member <room> <member> <new> rename replicated membership
      rename <room> <new-name>            rename a replicated room
      delete <room>                       delete a replicated room
      unread --hook-stop                  structured Claude Stop hook
      unread --hook-post-tool             structured Claude PostToolUse hook
      mark --hook                         structured lifecycle hook
      session-start [--silent]            record structured session identity
      install-hooks [--project DIR|--user|--codex]
      spawn <room> <nick> [claude|codex] [--host SSH] [--cwd DIR|--project NAME]

    Pair devices from Pharos Settings. Host control is signed and identity-addressed;
    there is no Broker endpoint or always-on legacy Node.
    """

    private static let legacyMeshUsage = """
    pharos mesh — legacy Broker agent chat (rollback only)
      create <room>                       create a room
      list                                list rooms + members
      join   <room> <nick> [--session <id>]   register this pane under a room-local alias
      history <room> [--limit N]          recent messages in a room (catch up)
      send   <text> [@n …] [--room ROOM] [--reply ID] [--attach FILE]
                                          send as the current joined session; a sole room is inferred
      say    <room> <nick> <text> [@n …] [--reply ID] [--attach FILE]
                                          explicit legacy form; sender still comes from session identity
      attachment put|get …                upload or download a Mesh attachment
      recv   [<nick>] [--member <id>]     drain unread for this session across ALL its rooms
      who                                 roster: every joined agent + live state/host/tmux pane
      pair [--endpoint HOST:PORT]         show an iPhone pairing link (and QR when qrencode is installed)
      spawn  <room> <nick> [claude|codex] [--host <ssh>]  spawn local/remote + confirm join (GUI "add member")
      poke   [<room>] <nick>              manually run the safe auto-poke path
      unread [<nick>] [--json]            peek the local unread signal (no daemon, never consumes)
      unread --hook-stop                  Claude Code Stop-hook mode (fail-open, reads hook JSON on stdin)
      unread --hook-post-tool             Claude Code PostToolUse-hook mode (poke mode: mid-turn delivery)
      mark --hook                         Claude Code state-hook mode (UserPromptSubmit/Notification/SessionEnd)
      session-start [--silent]            record hook session identity for the current tmux pane
      install-hooks [--project <dir> | --user]   wire all mesh hooks into .claude/settings.json
      install-hooks --codex                      wire mesh hooks into ~/.codex/hooks.json (Codex agents)
      leave  <room> <nick>                leave a room
      rename-member <room> <nick> <new>   rename a member without changing its session identity
      rename <room> <new-name>            rename a room
      delete <room>                       delete a room (drops its transcript)
    """

    private static func printTerminalQRCode(_ value: String) {
        let candidates = ["/opt/homebrew/bin/qrencode", "/usr/local/bin/qrencode", "/usr/bin/qrencode"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        let result = Shell.run(executable, ["-t", "ANSIUTF8", value])
        if result.ok, !result.out.isEmpty { print(result.out) }
    }

    private static func runGroup(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case "create":
            return ok(try PharosCore.createGroup(name: p.arg(1)))
        case "delete":
            let message = try PharosCore.deleteGroup(name: p.arg(1))
            AuditLog.record(actor: .cli, action: "delete_group", detail: p.arg(1) ?? "")
            return ok(message)
        case "add":
            return ok(try PharosCore.addToGroup(name: p.arg(1), group: p.arg(2)))
        case "remove":
            return ok(try PharosCore.removeFromGroup(name: p.arg(1), group: p.arg(2)))
        default:
            return usageError("Usage: pharos group <create|delete|add|remove> …")
        }
    }

    private static func runIssue(_ p: Parsed) async throws -> Int32 {
        let number = p.arg(2).flatMap { Int($0) }
        switch p.arg(0) {
        case "list", nil:
            return emit(try PharosCore.issueList(project: p.arg(1), all: p.has("all"),
                                                 label: p.opt("label"), status: p.opt("status"),
                                                 priority: p.opt("priority"), milestone: p.opt("milestone")),
                        json: p.has("json"))
        case "milestone":
            // issue milestone <project> <#> <name|none>
            return ok(try PharosCore.issueSetMilestone(project: p.arg(1), number: p.arg(2).flatMap { Int($0) },
                                                       milestone: p.arg(3)))
        case "parent":
            // issue parent <project> <#> <parent#|none>
            return ok(try PharosCore.issueSetParent(project: p.arg(1), number: p.arg(2).flatMap { Int($0) },
                                                    parent: p.arg(3)))
        case "link", "unlink":
            // issue link|unlink <project> <#> <relates|blocks|blocked-by|duplicate> <#>
            return ok(try PharosCore.issueLink(project: p.arg(1), from: p.arg(2).flatMap { Int($0) },
                                               kind: p.arg(3), to: p.arg(4).flatMap { Int($0) },
                                               add: p.arg(0) == "link"))
        case "add":
            return ok(try PharosCore.issueAdd(project: p.arg(1), title: p.arg(2),
                                              priority: p.opt("priority"), body: p.opt("body"),
                                              attach: p.all("attach"), labels: p.all("label")))
        case "label":
            // issue label add|rm <project> <#> <label>
            let labelNumber = p.arg(3).flatMap { Int($0) }
            switch p.arg(1) {
            case "add":
                return ok(try PharosCore.issueLabel(project: p.arg(2), number: labelNumber, add: true, label: p.arg(4)))
            case "rm", "remove":
                return ok(try PharosCore.issueLabel(project: p.arg(2), number: labelNumber, add: false, label: p.arg(4)))
            default:
                return usageError("Usage: pharos issue label <add|rm> <project> <#> <label>")
            }
        case "status":
            return ok(try PharosCore.issueSetStatus(project: p.arg(1), number: number, status: p.arg(3)))
        case "priority":
            return ok(try PharosCore.issueSetPriority(project: p.arg(1), number: number, priority: p.arg(3)))
        case "start":
            let yolo: Bool? = p.has("no-yolo") ? false : (p.has("yolo") ? true : nil)
            let tmux: Bool? = p.has("tmux") ? true : nil
            return ok(try await PharosCore.issueStart(project: p.arg(1), number: number, agent: p.arg(3),
                                                      yolo: yolo, tmux: tmux, host: p.opt("host"), source: .cli))
        case "rm", "remove":
            let message = try PharosCore.issueRemove(project: p.arg(1), number: number)
            AuditLog.record(actor: .cli, action: "issue_remove", detail: "\(p.arg(1) ?? "")#\(number ?? 0)")
            return ok(message)
        case let other?:
            return usageError("Unknown issue subcommand: \(other) (use list|add|status|priority|start|rm)")
        }
    }

    private static func runAttach(_ p: Parsed) throws -> Int32 {
        let number = p.arg(2).flatMap { Int($0) }
        switch p.arg(0) {
        case "add":
            // Files are the positionals after <project> <#>, plus any --file values.
            let files = Array(p.positional.dropFirst(3)) + p.all("file")
            return ok(try PharosCore.attachAdd(project: p.arg(1), number: number, paths: files))
        case "list", nil:
            return emit(try PharosCore.attachList(project: p.arg(1), number: number), json: p.has("json"))
        case "rm", "remove":
            return ok(try PharosCore.attachRemove(project: p.arg(1), number: number, ref: p.arg(3)))
        case let other?:
            return usageError("Unknown attach subcommand: \(other) (use add|list|rm)")
        }
    }

    private static func runMilestone(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case "add":
            return ok(try PharosCore.milestoneAdd(project: p.arg(1), milestone: p.arg(2), due: p.opt("due")))
        case "list", nil:
            return emit(try PharosCore.milestoneList(project: p.arg(1)), json: p.has("json"))
        case "rm", "remove":
            return ok(try PharosCore.milestoneRemove(project: p.arg(1), milestone: p.arg(2)))
        case let other?:
            return usageError("Unknown milestone subcommand: \(other) (use add|list|rm)")
        }
    }

    private static func runUpdate(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case "list", nil:
            return emit(try PharosCore.updateList(project: p.arg(1)), json: p.has("json"))
        case "add":
            // Everything after the project name is the update text.
            let text = p.positional.dropFirst(2).joined(separator: " ")
            let issue = p.opt("issue").flatMap { Int($0) }
            return ok(try PharosCore.updateAdd(project: p.arg(1), body: text, issueNumber: issue))
        case let other?:
            return usageError("Unknown update subcommand: \(other) (use list|add)")
        }
    }

    // MARK: Output

    private static func ok(_ message: String) -> Int32 {
        if let error = PharosCore.consumeRegistrySaveError() {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
        print(message)
        return 0
    }

    private static func emit(_ outcome: CoreOutcome, json: Bool) -> Int32 {
        if json, let payload = outcome.json {
            print(prettyJSON(payload))
        } else {
            print(outcome.text)
        }
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }

    private static func usageError(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n\nRun `pharos help` for usage.\n".utf8))
        return 2
    }

    // MARK: Argument parsing

    /// Marker error for bad usage (vs. a `CoreError` operation failure).
    struct UsageError: Error { let message: String }

    /// Parsed argv: positionals, single-valued options, repeatable options, and
    /// boolean flags.
    struct Parsed {
        var positional: [String] = []
        var options: [String: String] = [:]
        var multi: [String: [String]] = [:]
        var flags: Set<String> = []

        func arg(_ i: Int) -> String? { i < positional.count ? positional[i] : nil }
        func opt(_ key: String) -> String? { options[key] }
        func all(_ key: String) -> [String] { multi[key] ?? [] }
        func has(_ flag: String) -> Bool { flags.contains(flag) }
    }

    /// Flags that never take a value.
    private static let knownFlags: Set<String> = ["json", "tmux", "yolo", "no-yolo", "all", "clear"]

    static func parse(_ tokens: [String]) -> Parsed {
        var p = Parsed()
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--" {
                p.positional.append(contentsOf: tokens[(i + 1)...])
                break
            }
            if t.hasPrefix("--") {
                let body = String(t.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[..<eq])
                    let val = String(body[body.index(after: eq)...])
                    p.options[key] = val
                    p.multi[key, default: []].append(val)
                } else if knownFlags.contains(body) {
                    p.flags.insert(body)
                } else if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") {
                    let val = tokens[i + 1]
                    p.options[body] = val
                    p.multi[body, default: []].append(val)
                    i += 1
                } else {
                    p.flags.insert(body)
                }
            } else if t == "-j" {
                p.flags.insert("json")
            } else {
                p.positional.append(t)
            }
            i += 1
        }
        return p
    }

    private static func boolArg(_ value: String?, label: String) throws -> Bool {
        switch value?.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: throw UsageError(message: "expected \(label), got \(value ?? "nothing")")
        }
    }

    // MARK: Misc

    private static var version: String { "0.8.0" }

    private static func prettyJSON(_ obj: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func printUsage() {
        print("""
        pharos — Pharos project manager CLI. Agents and scripts drive Pharos here.

        USAGE
          pharos <command> [args] [--json]

        READ
          list                         List projects (alias: projects)
          groups                       List groups and their counts
          git <project>                Git status for a project
          worktrees <project>          List a project's git worktrees
          sessions <project> <agent>   List past sessions (agent: claude|codex)
          search <query>               Search issues across ALL projects (title/body/labels)
          overview                     Aggregate stats across all projects (counts, blocked, milestones)
          issue list <project> [--all] [--status S] [--priority P] [--label L] [--milestone M]   List/filter issues
          milestone list <project>     List milestones (issue counts + due dates)
          update list <project>        Show the project-update feed
          trash [list]                 List soft-deleted items

        ISSUES & PROJECT LOG (single-user — no human assignees)
          issue add <project> "<title>" [--priority none|low|medium|high|urgent] [--body "…"] [--attach <file>]… [--label L]…
          issue label add|rm <project> <#> <label>
          issue milestone <project> <#> <name|none>                Assign/clear an issue's milestone
          issue parent <project> <#> <parent#|none>                Make an issue a sub-task (or clear)
          issue link|unlink <project> <#> <relates|blocks|blocked-by|duplicate> <#>   Relate issues
          milestone add <project> "<name>" [--due yyyy-MM-dd]      Create a milestone
          milestone rm <project> <name>
          issue status <project> <#> <backlog|todo|in_progress|done|canceled>
          issue priority <project> <#> <none|low|medium|high|urgent>
          issue start <project> <#> <agent> [--no-yolo] [--tmux] [--host <alias>]   Launch an agent ON an issue (--host: on another machine)
          issue rm <project> <#>                                   (→ Trash, 30-day restore)
          attach add <project> <#> <file>…                         Attach files to an issue
          attach list <project> <#>                                List an issue's attachments
          attach rm <project> <#> <index|name>                     Remove an attachment
          update add <project> "<text>" [--issue <#>]              Log a progress note

        AGENTS / LAUNCH
          launch <project> <agent> [--no-yolo] [--tmux] [--host <alias>]   Launch an agent (--host: detached on another machine, RC URL printed)
          agents [<filter>] [--host <alias>]              List live agent tmux sessions (pharos-*)
          agent peek <session> [--lines N] [--host <alias>]   Tail an agent's pane
          agent say  <session> <text…> [--host <alias>]       Type one line into an agent
          agent kill <session> [--host <alias>]               Kill an agent session
          resume <project> <agent> <session_id>           Resume a past session
          playbook <project> <name>                       Run a saved playbook
          open <project>                                  Open the terminal there
          editor <project>                                Open the editor there
          reveal <project>                                Reveal in Finder

        REGISTRY (mutations are reversible via the Trash where noted)
          add <name> [--path P] [--remote URL] [--tag T]... [--notes N]
          remove <project>             Forget a project (→ Trash, 30-day restore)
          rename <project> <new-name>
          describe <project> <text…>   Set a project's notes
          group create <name>
          group delete <name>          (→ Trash, 30-day restore)
          group add <project> <group>
          group remove <project> <group>
          yolo <project> <on|off>
          tmux <project> <on|off>
          trash restore <id>           Restore a soft-deleted item
          trash empty                  Permanently purge the Trash

        MULTI-MACHINE (distributed project data; paths stay on each device)
          host                         Show this machine's host key
          path <project>               Show THIS Host's local folder
          path <project> <path>        Set THIS machine's local folder for a project
          path <project> --clear       Forget this machine's local folder

        OTHER
          identity bootstrap           Initialize the signed Keychain identity mirror
          help, version

        Add --json to any READ command for machine-readable output.
        Set PHAROS_REGISTRY=/path/to/projects.json to target an alternate store.
        """)
    }
}
