import Foundation
import PharosMeshCore

public enum LightInventoryCommands {

    public struct Argv {
        public var positional: [String]
        public var options: [String: String]
        public var flags: Set<String>

        public static func parse(_ args: [String]) -> Argv {
            var positional: [String] = []
            var options: [String: String] = [:]
            var flags: Set<String> = []
            var i = 0
            while i < args.count {
                let arg = args[i]
                if arg.hasPrefix("--") {
                    let flag = String(arg.dropFirst(2))
                    if let eq = flag.firstIndex(of: "=") {
                        let k = String(flag[..<eq])
                        let v = String(flag[flag.index(after: eq)...])
                        options[k] = v
                    } else if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                        options[flag] = args[i + 1]
                        i += 1
                    } else {
                        flags.insert(flag)
                    }
                } else if arg.hasPrefix("-") && arg.count > 1 {
                    let flag = String(arg.dropFirst(1))
                    if i + 1 < args.count && !args[i + 1].hasPrefix("-") {
                        options[flag] = args[i + 1]
                        i += 1
                    } else {
                        flags.insert(flag)
                    }
                } else {
                    positional.append(arg)
                }
                i += 1
            }
            return Argv(positional: positional, options: options, flags: flags)
        }

        public func option(_ key: String) -> String? { options[key] }
        public func flag(_ key: String) -> Bool { flags.contains(key) }
    }

    public static func relativeAge(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let diff = max(0, Int(now.timeIntervalSince(date)))
        if diff < 60 {
            return "\(diff)s"
        } else if diff < 3600 {
            return "\(diff / 60)m"
        } else if diff < 86400 {
            return "\(diff / 3600)h"
        } else {
            return "\(diff / 86400)d"
        }
    }

    // MARK: - Node Inventory

    public static func executeNodeInventory(env: [String: String] = ProcessInfo.processInfo.environment) -> LightCLIResult {
        guard env["PHAROS_LIGHT_LIVE"] == "1" else {
            return LightCLIResult(exitCode: 1, text: "{\"ok\": false, \"error\": \"node-inventory needs live CLI access (PHAROS_LIGHT_LIVE=1)\"}")
        }
        let nodeName = LightHostDirectory.nodeName(ProcessInfo.processInfo.hostName)
        let collector = SessionInventoryCollector(env: env)
        let inventory = collector.collect(node: nodeName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(inventory),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return LightCLIResult(exitCode: 1, text: "{\"ok\": false, \"error\": \"failed to encode inventory\"}")
        }
        return LightCLIResult(exitCode: 0, text: jsonStr)
    }

    // MARK: - Node Report

    public static func executeNodeReport(
        arguments: [String],
        store: LightInventoryStore = LightInventoryStore(),
        canonicalHost: (String) -> String = { $0 }
    ) -> LightCLIResult {
        let argv = Argv.parse(arguments)
        guard let rawNode = argv.option("node"),
              let payload = argv.option("payload") else {
            return LightCLIResult(exitCode: 2, text: "error: agents node-report --node N --payload B64")
        }
        let node = canonicalHost(rawNode)
        guard let inventory = LightCodec.decode(LightNodeInventory.self, payload) else {
            return LightCLIResult(exitCode: 2, text: "error: unreadable inventory payload")
        }
        do {
            try store.save(node: node, inventory: inventory)
            return LightCLIResult(exitCode: 0, text: "{\"ok\": true}")
        } catch {
            return LightCLIResult(exitCode: 1, text: "{\"ok\": false, \"error\": \"\(error.localizedDescription)\"}")
        }
    }

    // MARK: - Project Workspaces (without --app)

    public static func executeProjectWorkspaces(
        arguments: [String],
        rootDir: URL = LightRelay.defaultStoreURL(),
        canonicalHost: (String) -> String = { $0 }
    ) -> LightCLIResult? {
        let argv = Argv.parse(arguments)
        if argv.option("app") != nil {
            return nil // Handled by achat project service
        }

        guard let op = argv.positional.first, op == "add" || op == "list" else {
            return nil
        }

        guard let rawHost = argv.option("host"), !rawHost.isEmpty else {
            return LightCLIResult(exitCode: 2, text: "usage: pharos project \(op) --host H [options]")
        }
        let host = canonicalHost(rawHost)
        let wsStore = LightWorkspaceStore(rootDir: rootDir)
        let invStore = LightInventoryStore(rootDir: rootDir)

        if op == "add" {
            guard let path = argv.option("path"), !path.isEmpty else {
                return LightCLIResult(exitCode: 2, text: "usage: pharos project add --host H --path DIR [--name N]")
            }
            do {
                let ws = try wsStore.addManual(node: host, path: path, name: argv.option("name"))
                if argv.flag("json") {
                    let data = try? LightInventoryStore.jsonEncoder.encode(ws)
                    return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
                }
                return LightCLIResult(exitCode: 0, text: "added workspace '\(ws.name)' on \(host): \(ws.path)")
            } catch {
                return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
            }
        } else {
            let workspaces = wsStore.workspaces(for: host)
            let inv = invStore.load(node: host)
            if argv.flag("json") {
                let data = try? LightInventoryStore.jsonEncoder.encode(workspaces)
                return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "[]")
            }

            var lines = ["NAME\tPATH\tSOURCE\tAPPS\tSESSIONS"]
            for ws in workspaces {
                let count = inv?.sessions.filter { $0.cwd == ws.path }.count ?? 0
                let appsStr = ws.apps.isEmpty ? "-" : ws.apps.joined(separator: ",")
                lines.append("\(ws.name)\t\(ws.path)\t\(ws.source)\t\(appsStr)\t\(count)")
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        }
    }

    // MARK: - pharos ls

    public static func executeLs(
        arguments: [String],
        rootDir: URL = LightRelay.defaultStoreURL(),
        router: LightMeshRouter? = nil,
        members: [LightMember] = [],
        now: Date = Date()
    ) -> LightCLIResult {
        let argv = Argv.parse(arguments)
        let invStore = LightInventoryStore(rootDir: rootDir)
        let wsStore = LightWorkspaceStore(rootDir: rootDir)

        let target = argv.positional.first(where: { !$0.hasPrefix("-") })
        let isJson = argv.flag("json")
        let isAll = argv.flag("all")
        let isRefresh = argv.flag("refresh")

        if isRefresh, let router {
            refreshInventories(target: target, router: router, store: invStore)
        }

        let parts = target?.split(separator: "/").map(String.init) ?? []

        // Level 0: No target -> one line per host
        if parts.isEmpty {
            var knownNodes: Set<String> = []
            if let router {
                for node in router.directory()?.roster ?? [] {
                    knownNodes.insert(router.canonical(node.name))
                }
            }
            for (node, _) in invStore.loadAll() {
                knownNodes.insert(node)
            }
            let sortedNodes = Array(knownNodes).sorted()

            if isJson {
                var jsonResult: [[String: Any]] = []
                for node in sortedNodes {
                    let inv = invStore.load(node: node)
                    let workspaces = wsStore.workspaces(for: node)
                    let status = router?.status(node)
                    let online = status?.online ?? false
                    var appCounts: [String: Int] = [:]
                    if let inv {
                        for s in inv.sessions {
                            appCounts[s.app, default: 0] += 1
                        }
                    }
                    jsonResult.append([
                        "host": node,
                        "online": online,
                        "workspaces": workspaces.count,
                        "apps": appCounts,
                        "inventoryAge": inv != nil ? relativeAge(inv?.at, now: now) : NSNull()
                    ])
                }
                guard let data = try? JSONSerialization.data(withJSONObject: jsonResult, options: [.sortedKeys, .prettyPrinted]),
                      let str = String(data: data, encoding: .utf8) else {
                    return LightCLIResult(exitCode: 0, text: "[]")
                }
                return LightCLIResult(exitCode: 0, text: str)
            }

            var lines: [String] = []
            for node in sortedNodes {
                let status = router?.status(node)
                let onlineStr = (status?.online == true) ? "online" : "offline"
                let workspaces = wsStore.workspaces(for: node)
                let inv = invStore.load(node: node)

                var appCounts: [String: Int] = [:]
                if let inv {
                    for s in inv.sessions {
                        appCounts[s.app, default: 0] += 1
                    }
                }
                let appsStr: String
                if appCounts.isEmpty {
                    appsStr = "apps -"
                } else {
                    let sortedApps = appCounts.keys.sorted().map { "\($0):\(appCounts[$0]!)" }.joined(separator: " ")
                    appsStr = "apps \(sortedApps)"
                }

                let invAge = inv != nil ? "inventory \(relativeAge(inv?.at, now: now)) old" : "no inventory"
                lines.append("\(node)  \(onlineStr)  \(workspaces.count) workspaces  \(appsStr)  \(invAge)")
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        }

        // Level 1: host -> workspaces with per-app session counts
        let rawHost = parts[0]
        let host = router?.canonical(rawHost) ?? rawHost
        let workspaces = wsStore.workspaces(for: host)
        let inv = invStore.load(node: host)

        if parts.count == 1 {
            if isJson {
                let data = try? LightInventoryStore.jsonEncoder.encode(workspaces)
                return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "[]")
            }
            var lines = ["WORKSPACE\tPATH\tSOURCE\tAPPS"]
            for ws in workspaces {
                let sessionsInWs = inv?.sessions.filter { $0.cwd == ws.path } ?? []
                var counts: [String: Int] = [:]
                for s in sessionsInWs { counts[s.app, default: 0] += 1 }
                let countsStr = counts.keys.sorted().map { "\($0):\(counts[$0]!)" }.joined(separator: " ")
                lines.append("\(ws.name)\t\(ws.path)\t\(ws.source)\t\(countsStr.isEmpty ? "-" : countsStr)")
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        }

        // Level 2: host/app -> workspaces for that app
        let app = parts[1].lowercased()
        if parts.count == 2 {
            let appWorkspaces = workspaces.filter { ws in
                if ws.apps.contains(app) { return true }
                if let sessions = inv?.sessions {
                    for s in sessions {
                        if s.app.lowercased() == app && s.cwd == ws.path {
                            return true
                        }
                    }
                }
                return false
            }
            if isJson {
                let data = try? LightInventoryStore.jsonEncoder.encode(appWorkspaces)
                return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "[]")
            }
            var lines = ["WORKSPACE\tPATH\tSOURCE\tSESSIONS"]
            for ws in appWorkspaces {
                var count = 0
                if let sessions = inv?.sessions {
                    for s in sessions {
                        if s.app.lowercased() == app && s.cwd == ws.path {
                            count += 1
                        }
                    }
                }
                lines.append("\(ws.name)\t\(ws.path)\t\(ws.source)\t\(count)")
            }
            return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
        }

        // Level 3: host/app/project -> sessions
        let project = parts[2]
        let matchingWs = workspaces.first(where: { $0.name.lowercased() == project.lowercased() })

        let allSessions = inv?.sessions ?? []
        let filtered = allSessions.filter { s in
            guard s.app.lowercased() == app else { return false }
            if project == "-" {
                return s.cwd == nil || s.cwd?.isEmpty == true
            }
            if let p = s.project, p.lowercased() == project.lowercased() {
                return true
            }
            if let cwd = s.cwd, let ws = matchingWs, cwd == ws.path {
                return true
            }
            return false
        }

        let sorted = filtered.sorted(by: { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) })
        let displayList = isAll ? sorted : Array(sorted.prefix(15))

        let memberMap = Dictionary(members.filter { $0.host == host || $0.host == "local" }.map { ($0.sessionID, $0.name) }, uniquingKeysWith: { a, _ in a })

        if isJson {
            let data = try? LightInventoryStore.jsonEncoder.encode(displayList)
            return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "[]")
        }

        var lines = ["ADDRESS\tTITLE\tLAST\tSTATE\tMEMBER"]
        for s in displayList {
            let shortId = String(s.id.prefix(8))
            let addr = "\(host)/\(app)/\(project)/\(shortId)"
            let title = s.title ?? "-"
            let last = relativeAge(s.lastActive, now: now)
            let state = s.state ?? "unknown"
            let mem = memberMap[s.id] ?? "-"
            lines.append("\(addr)\t\(title)\t\(last)\t\(state)\t\(mem)")
        }
        return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
    }

    // MARK: - pharos agents

    public static func executeAgents(
        arguments: [String],
        rootDir: URL = LightRelay.defaultStoreURL(),
        router: LightMeshRouter? = nil,
        members: [LightMember] = [],
        now: Date = Date()
    ) -> LightCLIResult {
        let argv = Argv.parse(arguments)
        let invStore = LightInventoryStore(rootDir: rootDir)
        let isJson = argv.flag("json")
        let isAll = argv.flag("all")
        let isRefresh = argv.flag("refresh")

        let filterHostRaw = argv.option("host")
        let filterHost = filterHostRaw.map { router?.canonical($0) ?? $0 }
        let filterApp = argv.option("app")?.lowercased()
        let filterProject = argv.option("project")?.lowercased()

        if isRefresh, let router {
            refreshInventories(target: filterHost, router: router, store: invStore)
        }

        let allInventories = invStore.loadAll()
        var targetHosts: [String] = []

        if let filterHost {
            if allInventories[filterHost] == nil {
                let roster = router?.directory()?.roster ?? []
                let rosterNames = roster.map { router?.canonical($0.name) ?? $0.name }
                let known = Array(Set(allInventories.keys).union(rosterNames)).sorted()
                let knownStr = known.isEmpty ? "none" : known.joined(separator: ", ")
                return LightCLIResult(exitCode: 1, text: "error: unknown host '\(filterHostRaw!)'. Known hosts: \(knownStr)")
            }
            targetHosts = [filterHost]
        } else {
            targetHosts = Array(allInventories.keys).sorted()
        }

        var candidateEntries: [(host: String, entry: LightSessionEntry)] = []
        for h in targetHosts {
            guard let inv = allInventories[h] else { continue }
            for s in inv.sessions {
                if let filterApp, s.app.lowercased() != filterApp { continue }
                if let filterProject {
                    let match = (s.project?.lowercased() == filterProject) ||
                                (s.cwd != nil && URL(fileURLWithPath: s.cwd!).lastPathComponent.lowercased() == filterProject)
                    if !match { continue }
                }
                candidateEntries.append((host: h, entry: s))
            }
        }

        // Group by host+app for limit (default 15 per host+app unless --all)
        var displayEntries: [(host: String, entry: LightSessionEntry)] = []
        if isAll {
            displayEntries = candidateEntries.sorted(by: { ($0.entry.lastActive ?? .distantPast) > ($1.entry.lastActive ?? .distantPast) })
        } else {
            var grouped: [String: [(host: String, entry: LightSessionEntry)]] = [:]
            for item in candidateEntries {
                let key = "\(item.host)/\(item.entry.app)"
                grouped[key, default: []].append(item)
            }
            for (_, list) in grouped {
                let sortedList = list.sorted(by: { ($0.entry.lastActive ?? .distantPast) > ($1.entry.lastActive ?? .distantPast) })
                displayEntries.append(contentsOf: sortedList.prefix(15))
            }
            displayEntries.sort(by: { ($0.entry.lastActive ?? .distantPast) > ($1.entry.lastActive ?? .distantPast) })
        }

        let memberMap = Dictionary(members.map { ($0.sessionID, $0.name) }, uniquingKeysWith: { a, _ in a })

        if isJson {
            var jsonItems: [[String: Any]] = []
            for item in displayEntries {
                let e = item.entry
                jsonItems.append([
                    "host": item.host,
                    "app": e.app,
                    "sessionId": e.id,
                    "cwd": e.cwd ?? NSNull(),
                    "project": e.project ?? NSNull(),
                    "title": e.title ?? NSNull(),
                    "lastActive": e.lastActive != nil ? ISO8601DateFormatter().string(from: e.lastActive!) : NSNull(),
                    "state": e.state ?? "unknown",
                    "member": memberMap[e.id] ?? NSNull()
                ])
            }
            guard let data = try? JSONSerialization.data(withJSONObject: jsonItems, options: [.sortedKeys, .prettyPrinted]),
                  let str = String(data: data, encoding: .utf8) else {
                return LightCLIResult(exitCode: 0, text: "[]")
            }
            return LightCLIResult(exitCode: 0, text: str)
        }

        var lines = ["HOST\tAPP\tSESSION\tPROJECT\tTITLE\tLAST\tSTATE\tMEMBER"]
        for item in displayEntries {
            let e = item.entry
            let sessionShort = String(e.id.prefix(8))
            let project = e.project ?? "-"
            let title = e.title ?? "-"
            let last = relativeAge(e.lastActive, now: now)
            let state = e.state ?? "unknown"
            let mem = memberMap[e.id] ?? "-"
            lines.append("\(item.host)\t\(e.app)\t\(sessionShort)\t\(project)\t\(title)\t\(last)\t\(state)\t\(mem)")
        }

        // Footers
        for h in targetHosts {
            guard let inv = allInventories[h] else { continue }
            let ageSec = max(0, Int(now.timeIntervalSince(inv.at)))
            let ageStr = relativeAge(inv.at, now: now)
            var partsNotes: [String] = []
            if !inv.notes.isEmpty {
                partsNotes.append(inv.notes.joined(separator: "; "))
            }

            let footer: String
            if ageSec > 300 {
                let noteDetail = partsNotes.isEmpty ? "" : " (\(partsNotes.joined(separator: ", ")))"
                footer = "host \(h): inventory \(ageStr) old (stale; pharos agents --refresh --host \(h))\(noteDetail)"
            } else {
                let noteDetail = partsNotes.isEmpty ? "" : " (\(partsNotes.joined(separator: ", ")))"
                footer = "host \(h): inventory \(ageStr) old\(noteDetail)"
            }
            lines.append(footer)
        }

        return LightCLIResult(exitCode: 0, text: lines.joined(separator: "\n"))
    }

    private static func refreshInventories(
        target: String?,
        router: LightMeshRouter,
        store: LightInventoryStore
    ) {
        let hostsToRefresh: [String]
        if let target {
            let hostPart = target.split(separator: "/").first.map(String.init) ?? target
            hostsToRefresh = [router.canonical(hostPart)]
        } else {
            let roster = router.directory()?.roster ?? []
            hostsToRefresh = roster.filter { router.status($0.name).online }.map { router.canonical($0.name) }
        }

        for h in hostsToRefresh {
            if let run = router.run(h, argv: ["node-inventory"], timeout: 45), run.status == 0 {
                if let data = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                   let inv = try? LightInventoryStore.jsonDecoder.decode(LightNodeInventory.self, from: data) {
                    try? store.save(node: h, inventory: inv)
                }
            }
        }
    }

    // MARK: - pharos member adopt

    public static func executeAdopt(
        arguments: [String],
        relay: LightRelay,
        agents: (any LightMemberAgents)?,
        router: LightMeshRouter? = nil
    ) -> LightCLIResult {
        let argv = Argv.parse(arguments)
        guard let name = argv.option("name"), !name.isEmpty else {
            return LightCLIResult(exitCode: 2, text: "error: pharos member adopt <address|host app id> --name X [--dir D] [--model M] [--tmux S] [--auto-revive] [--project P] [--force] [--json]")
        }
        guard let agents else {
            return LightCLIResult(exitCode: 1, text: "error: member adopt needs live CLI access (PHAROS_LIGHT_LIVE=1)")
        }

        let validatedName: String
        do {
            validatedName = try LightRelay.validateName(name)
        } catch {
            return LightCLIResult(exitCode: 2, text: "error: invalid member name '\(name)'")
        }

        if relay.member(named: validatedName) != nil {
            return LightCLIResult(exitCode: 1, text: "error: duplicate member '\(validatedName)'")
        }

        // Parse address vs long form
        // Arguments after 'adopt':
        let positional = Array(argv.positional.dropFirst())
        let host: String
        let app: String
        let sessionID: String
        var resolvedEntry: LightSessionEntry? = nil

        let invStore = LightInventoryStore(rootDir: relay.storeURL)

        if positional.count == 1 {
            let address = positional[0]
            do {
                let resolved = try LightDirectory.resolve(
                    address,
                    inventoryStore: invStore,
                    canonicalHost: { router?.canonical($0) ?? $0 }
                )
                host = resolved.host
                app = resolved.app
                sessionID = resolved.entry.id
                resolvedEntry = resolved.entry
            } catch {
                return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
            }
        } else if positional.count >= 3 {
            let rawHost = positional[0]
            host = router?.canonical(rawHost) ?? rawHost
            app = positional[1].lowercased()
            sessionID = positional[2]

            // Look up entry in host inventory
            var inv = invStore.load(node: host)
            if inv == nil || !inv!.sessions.contains(where: { $0.id == sessionID }) {
                if let router {
                    refreshInventories(target: host, router: router, store: invStore)
                    inv = invStore.load(node: host)
                }
            }
            resolvedEntry = inv?.sessions.first(where: { $0.id == sessionID })
        } else {
            return LightCLIResult(exitCode: 2, text: "error: pharos member adopt <address|host app id> --name X [--dir D] [--model M] [--tmux S] [--auto-revive] [--project P] [--force] [--json]")
        }

        guard app == "codex" || app == "agy" else {
            return LightCLIResult(exitCode: 1, text: "error: adopt supports codex and agy; use pharos member register for \(app)")
        }

        if let existing = relay.listMembers().first(where: { $0.sessionID == sessionID }) {
            return LightCLIResult(exitCode: 1, text: "error: member '\(existing.name)' already has session id '\(sessionID)'")
        }

        var cwd = argv.option("dir")
        if cwd == nil || cwd!.isEmpty {
            cwd = resolvedEntry?.cwd
            if (cwd == nil || cwd!.isEmpty), let router {
                refreshInventories(target: host, router: router, store: invStore)
                if let refreshedInv = invStore.load(node: host) {
                    resolvedEntry = refreshedInv.sessions.first(where: { $0.id == sessionID })
                    cwd = resolvedEntry?.cwd
                }
            }
        }
        guard let finalCwd = cwd, !finalCwd.isEmpty else {
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
            project = URL(fileURLWithPath: finalCwd).lastPathComponent
        }

        do {
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

            if argv.flag("json") {
                let data = try? LightInventoryStore.jsonEncoder.encode(registered)
                return LightCLIResult(exitCode: 0, text: String(data: data ?? Data(), encoding: .utf8) ?? "{}")
            }

            let tmuxSession = registered.tmux?.session ?? argv.option("tmux") ?? validatedName
            return LightCLIResult(
                exitCode: 0,
                text: "adopted \(registered.name) (app \(registered.app)) on \(host) in tmux \(tmuxSession), session \(registered.sessionID)",
                notes: agents.notes
            )
        } catch {
            return LightCLIResult(exitCode: 1, text: "error: \(error.localizedDescription)")
        }
    }
}
