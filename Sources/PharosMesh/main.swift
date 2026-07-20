import Foundation
import PharosMeshCore

exit(MeshHeadlessCLI.run(Array(CommandLine.arguments.dropFirst())))

private enum MeshHeadlessCLI {
    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 2
        }
        if let endpoint = option("--endpoint", in: args) {
            guard meshSplitHostPort(endpoint) != nil else {
                return usageError("--endpoint HOST:PORT")
            }
            MeshClient.remoteEndpoint = endpoint
        }

        switch command {
        case "serve", "daemon":
            configureServer(Array(args.dropFirst()))
            MeshBroker.runDaemon()

        case "node":
            return runNode(Array(args.dropFirst()))

        case "capabilities":
            return printResponse(MeshClient.send(MeshRequest(cmd: "capabilities")))

        case "pair":
            if args.count >= 3, args[1] == "redeem" {
                guard let url = URL(string: args[2]), let invitation = MeshPairingLink(url: url) else {
                    return usageError("pair redeem <pharos://pair?...>")
                }
                var request = MeshRequest(cmd: "pairing-redeem", memberID: invitation.brokerID)
                request.payload = invitation.token
                let response = MeshClient.send(request, to: invitation.endpoint)
                guard response.ok, let payload = response.payload,
                      let data = payload.data(using: .utf8),
                      let credential = try? JSONDecoder().decode(MeshPairingCredential.self, from: data),
                      credential.brokerID == invitation.brokerID else { return printResponse(response) }
                MeshPaths.setDialEndpointFile(invitation.endpoint)
                MeshPaths.setControlTokenFile(credential.controlToken)
                print("paired \(invitation.endpoint) as Broker \(credential.brokerID)")
                return 0
            }
            guard let endpoint = option("--endpoint", in: args),
                  meshSplitHostPort(endpoint) != nil else {
                return usageError("pair --endpoint HOST:PORT | pair redeem <link>")
            }
            let response = MeshClient.send(MeshRequest(cmd: "pairing-create",
                                                       timeoutMs: 300_000, host: endpoint),
                                           to: endpoint)
            guard response.ok, let link = response.payload else { return printResponse(response) }
            printTerminalQRCode(link)
            print(link)
            print("expires in 5 minutes · single use")
            return 0

        case "create":
            guard args.count >= 2 else { return usageError("create <room>") }
            return printResponse(MeshClient.send(MeshRequest(cmd: "create", room: args[1])))

        case "list":
            let response = MeshClient.send(MeshRequest(cmd: "list"))
            guard response.ok else { return printResponse(response) }
            for room in response.rooms ?? [] {
                print("\(room.name)\t\(room.members.joined(separator: ","))")
            }
            return 0

        case "history":
            guard args.count >= 2 else { return usageError("history <room> [--limit N]") }
            let limit = option("--limit", in: args).flatMap(Int.init) ?? 30
            let response = MeshClient.send(MeshRequest(cmd: "history", room: args[1], limit: limit))
            guard response.ok else { return printResponse(response) }
            printMessages(response.messages ?? [])
            return 0

        case "join":
            guard args.count >= 3, let session = option("--session", in: args), !session.isEmpty else {
                return usageError("join <room> <nick> --session <id> [--kind codex|claude]")
            }
            var request = MeshRequest(cmd: "join", room: args[1], nick: args[2])
            request.session = session
            request.memberID = session
            request.project = FileManager.default.currentDirectoryPath
            request.host = ProcessInfo.processInfo.hostName
            request.kind = option("--kind", in: args)
            let response = MeshClient.send(request)
            guard response.ok else { return printResponse(response) }
            print("joined \(args[1]) as \(args[2])")
            printMessages(response.messages ?? [])
            return 0

        case "say":
            guard args.count >= 4 else { return usageError("say <room> <nick> <text> [--reply ID] [--attach FILE]") }
            let memberID = option("--member", in: args)
                ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"]
            var request = MeshRequest(cmd: "say", room: args[1], nick: args[2], memberID: memberID,
                                      text: args[3])
            request.to = mentions(in: args[3])
            request.replyToID = option("--reply", in: args)
            if request.replyToID != nil || option("--attach", in: args) != nil {
                let capabilities = MeshClient.send(MeshRequest(cmd: "capabilities"))
                guard capabilities.capabilities?.contains("mesh-v2") == true else {
                    FileHandle.standardError.write(Data("error: broker does not support replies or attachments\n".utf8))
                    return 1
                }
            }
            if let path = option("--attach", in: args) {
                do {
                    request.attachments = [try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: path))]
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    return 1
                }
            }
            return printResponse(MeshClient.send(request))

        case "send":
            guard args.count >= 2, !args[1].hasPrefix("--") else {
                return usageError("send <text> [--room ROOM] [--member SESSION] [--reply ID] [--attach FILE]")
            }
            guard let memberID = option("--member", in: args)
                    ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                  !memberID.isEmpty else {
                FileHandle.standardError.write(Data("error: pass --member <session-id> or set PHAROS_MESH_SESSION\n".utf8))
                return 2
            }
            var request = MeshRequest(cmd: "say", room: option("--room", in: args),
                                      memberID: memberID, text: args[1])
            let textMentions = mentions(in: args[1]) ?? []
            request.to = textMentions + args.dropFirst(2).compactMap {
                $0.hasPrefix("@") ? String($0.dropFirst()) : nil
            }.filter { !textMentions.contains($0) }
            request.replyToID = option("--reply", in: args)
            if let path = option("--attach", in: args) {
                do {
                    request.attachments = [try MeshClient.uploadAttachment(fileAt: URL(fileURLWithPath: path))]
                } catch {
                    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                    return 1
                }
            }
            return printResponse(MeshClient.send(request))

        case "recv":
            let nick = args.dropFirst().first.flatMap { $0.hasPrefix("--") ? nil : $0 }
            let memberID = option("--member", in: args)
                ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"]
            guard nick != nil || memberID != nil else {
                return usageError("recv [<nick>] [--member <session-id>]")
            }
            var request = MeshRequest(cmd: "recv", nick: nick)
            request.memberID = memberID
            request.project = FileManager.default.currentDirectoryPath
            let response = MeshClient.send(request)
            guard response.ok else { return printResponse(response) }
            printMessages(response.messages ?? [])
            return 0

        case "attachment":
            return runAttachment(Array(args.dropFirst()))

        case "registry":
            return runRegistry(Array(args.dropFirst()))

        case "distributed":
            return runDistributed(Array(args.dropFirst()))

        case "--help", "-h", "help":
            print(usage)
            return 0

        case "--version", "version":
            print("pharos-mesh 0.10.0")
            return 0

        default:
            return usageError(command)
        }
    }

    private static func runAttachment(_ args: [String]) -> Int32 {
        guard let command = args.first else { return usageError("attachment put|get …") }
        switch command {
        case "put":
            guard args.count >= 2 else { return usageError("attachment put <file>") }
            let url = URL(fileURLWithPath: args[1]).standardizedFileURL
            do {
                let attachment = try MeshClient.uploadAttachment(
                    fileAt: url, id: option("--id", in: args), name: option("--name", in: args))
                print(attachment.id)
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "get":
            guard args.count >= 2 else { return usageError("attachment get <id> [--out path]") }
            let output = option("--out", in: args).map(URL.init(fileURLWithPath:))
                ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(args[1])
            do {
                let result = try MeshClient.downloadAttachment(id: args[1], to: output)
                print(result.path)
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        default:
            return usageError("attachment put|get …")
        }
    }

    /// Initializes or reports the isolated local-first replica only. It never
    /// starts a listener, dials a peer, or reads legacy Broker state.
    private static func runDistributed(_ args: [String]) -> Int32 {
        let command = args.first ?? "status"
        guard command == "status" || command == "init" else {
            return usageError(
                "distributed status|init [--json] [--data-dir ABSOLUTE-PATH]"
            )
        }
        let dataDirectory: String?
        if args.contains("--data-dir") {
            guard let candidate = option("--data-dir", in: args),
                  candidate.hasPrefix("/"), !candidate.hasPrefix("--") else {
                return usageError("--data-dir requires an absolute path")
            }
            dataDirectory = candidate
        } else {
            dataDirectory = nil
        }
        do {
            let replica: MeshLocalReplica
            if let dataDirectory {
                replica = try MeshLocalReplica.openIsolated(
                    rootURL: URL(fileURLWithPath: dataDirectory, isDirectory: true)
                )
            } else {
                replica = try MeshLocalReplica.openDefault()
            }
            let status = DistributedStatus(
                protocolVersion: DistributedMeshProtocol.version,
                schemaVersion: DistributedMeshStore.currentSchemaVersion,
                deviceID: replica.identity.deviceID.rawValue.uuidString,
                endpointID: try replica.identity.endpointID().rawValue,
                databasePath: replica.rootURL
                    .appendingPathComponent("replica-v1.sqlite").path,
                networkState: "stopped"
            )
            if args.contains("--json") {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(status), as: UTF8.self))
            } else {
                print("device\t\(status.deviceID)")
                print("endpoint\t\(status.endpointID)")
                print("schema\t\(status.schemaVersion)")
                print("database\t\(status.databasePath)")
                print("network\t\(status.networkState)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("error: could not open distributed replica: \(error)\n".utf8)
            )
            return 1
        }
    }

    private struct DistributedStatus: Codable {
        var protocolVersion: Int
        var schemaVersion: Int
        var deviceID: String
        var endpointID: String
        var databasePath: String
        var networkState: String
    }

    private static func runNode(_ args: [String]) -> Int32 {
        let command = args.first ?? "run"
        switch command {
        case "run":
            let endpoint = option("--endpoint", in: args)
                ?? ProcessInfo.processInfo.environment["PHAROS_MESH_ENDPOINT"]
            return MeshNode.run(endpoint: endpoint, buildID: option("--build-id", in: args))
        case "install":
            let endpoint = option("--endpoint", in: args)
            let buildID = option("--build-id", in: args)
            if let endpoint, meshSplitHostPort(endpoint) == nil { return usageError("node install [--endpoint HOST:PORT]") }
            do {
                let path = try MeshNodeService.install(endpoint: endpoint, buildID: buildID)
                print("installed \(path)")
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "uninstall":
            do {
                try MeshNodeService.uninstall()
                print("uninstalled pharos node service")
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "path":
            guard args.count >= 2 else { return usageError("node path list|set|clear …") }
            do {
                switch args[1] {
                case "list":
                    for (id, path) in MeshNodeProjectPaths.all().sorted(by: { $0.key < $1.key }) {
                        print("\(id)\t\(path)")
                    }
                case "set":
                    guard args.count >= 4 else { return usageError("node path set <project-uuid> <directory>") }
                    try MeshNodeProjectPaths.set(projectID: args[2], path: args[3])
                    print("registered \(args[2])")
                case "clear":
                    guard args.count >= 3 else { return usageError("node path clear <project-uuid>") }
                    try MeshNodeProjectPaths.clear(projectID: args[2])
                    print("cleared \(args[2])")
                default:
                    return usageError("node path list|set|clear …")
                }
                return 0
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                return 1
            }
        case "list":
            let response = MeshClient.send(MeshRequest(cmd: "node-list"))
            guard response.ok else { return printResponse(response) }
            for node in response.nodes ?? [] {
                print("\(node.id)\t\(node.host)\t\(node.tailscaleIP ?? "-")\t\(node.buildID ?? "-")")
            }
            return 0
        case "commands":
            let response = MeshClient.send(MeshRequest(cmd: "node-command-list",
                                                       nodeID: option("--node", in: args)))
            guard response.ok else { return printResponse(response) }
            for command in response.commands ?? [] {
                print("\(command.id)\t\(command.nodeID)\t\(command.action.rawValue)\t"
                      + "\(command.state.rawValue)\t\(command.attempts)/\(command.maxAttempts)\t"
                      + "\(command.result ?? "-")")
            }
            return 0
        case "reconcile":
            guard args.count >= 2 else { return usageError("node reconcile <node-id> [--wait]") }
            return enqueueNodeAction(nodeID: args[1], action: .reconcile, payload: Optional<String>.none,
                                     idempotencyKey: "reconcile:\(UUID().uuidString)", wait: args.contains("--wait"))
        case "spawn":
            guard args.count >= 5, ["claude", "codex"].contains(args[4]) else {
                return usageError("node spawn <node-id> <project-uuid> <session> <claude|codex> [--room R --nick N] [--wait]")
            }
            let payload = MeshNodeSpawnPayload(projectID: args[2], sessionName: args[3], agent: args[4],
                                               yolo: !args.contains("--no-yolo"),
                                               room: option("--room", in: args),
                                               nick: option("--nick", in: args))
            return enqueueNodeAction(nodeID: args[1], action: .spawnAgent, payload: payload,
                                     idempotencyKey: "spawn:\(args[1]):\(args[3]):\(UUID().uuidString)",
                                     wait: args.contains("--wait"))
        case "stop":
            guard args.count >= 3 else { return usageError("node stop <node-id> <member-id> [--wait]") }
            return enqueueNodeAction(nodeID: args[1], action: .stopSession,
                                     payload: MeshNodeStopPayload(memberID: args[2]),
                                     idempotencyKey: "stop:\(args[1]):\(args[2]):\(UUID().uuidString)",
                                     wait: args.contains("--wait"))
        default:
            return usageError("node run|install|uninstall|list|commands|path|spawn|stop|reconcile …")
        }
    }

    private static func enqueueNodeAction<T: Encodable>(nodeID: String, action: MeshNodeCommandAction,
                                                        payload: T?, idempotencyKey: String,
                                                        wait: Bool) -> Int32 {
        let payloadString: String?
        if let payload, let data = try? JSONEncoder().encode(payload) {
            payloadString = String(data: data, encoding: .utf8)
        } else {
            payloadString = nil
        }
        let response = MeshClient.send(MeshRequest(cmd: "node-command-enqueue", payload: payloadString,
                                                   nodeID: nodeID, action: action.rawValue,
                                                   idempotencyKey: idempotencyKey,
                                                   deadline: Date().timeIntervalSince1970 + 3_600,
                                                   maxAttempts: 120))
        guard response.ok, let command = response.command else { return printResponse(response) }
        print(command.id)
        guard wait else { return 0 }
        for _ in 0..<360 {
            let current = MeshClient.send(MeshRequest(cmd: "node-command-list", nodeID: nodeID))
                .commands?.first(where: { $0.id == command.id })
            if let current, current.state.isTerminal {
                print("\(current.state.rawValue): \(current.result ?? "")")
                return current.state == .succeeded ? 0 : 1
            }
            usleep(500_000)
        }
        FileHandle.standardError.write(Data("error: timed out waiting for node command\n".utf8))
        return 1
    }

    private static func runRegistry(_ args: [String]) -> Int32 {
        guard let command = args.first else { return usageError("registry get|import …") }
        do {
            switch command {
            case "get":
                let snapshot = try MeshClient.fetchRegistry()
                if let destination = option("--output", in: args) {
                    try Data(snapshot.payload.utf8).write(to: URL(fileURLWithPath: destination), options: .atomic)
                } else {
                    print(snapshot.payload)
                }
                FileHandle.standardError.write(Data("revision \(snapshot.revision)\n".utf8))
                return 0
            case "import":
                guard args.count >= 2, let expected = option("--expected", in: args) else {
                    return usageError("registry import <projects.json> --expected REVISION")
                }
                let payload = try String(contentsOfFile: args[1], encoding: .utf8)
                let revision = try MeshClient.replaceRegistry(payload: payload, expectedRevision: expected)
                print(revision)
                return 0
            default:
                return usageError("registry get|import …")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func configureServer(_ args: [String]) {
        var environment = ProcessInfo.processInfo.environment
        if let bind = option("--bind", in: args) {
            environment["PHAROS_MESH_TCP"] = bind
            environment["PHAROS_MESH_TCP_INSECURE"] = "1"
        }
        if let directory = option("--data-dir", in: args) {
            environment["PHAROS_MESH_DIR"] = directory
            environment["PHAROS_MESH_DATA_DIR"] = directory
        }
        for (key, value) in environment { setenv(key, value, 1) }
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func mentions(in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9._-]+)"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let values = expression.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        return values.isEmpty ? nil : Array(Set(values)).sorted()
    }

    private static func printMessages(_ messages: [MeshMsg]) {
        if messages.isEmpty { print("(no messages)") }
        for message in messages {
            print("id: \(message.stableID)")
            if let reply = message.replyTo {
                print("  ↳ \(reply.from): \(reply.preview)")
            }
            print("[\(message.room)] \(message.from): \(message.text)")
            for attachment in message.attachments ?? [] {
                print("  attachment: \(attachment.name) (\(attachment.byteSize) bytes, id \(attachment.id))")
                print("  download: pharos-mesh attachment get \(attachment.id) --out \(attachment.name)")
            }
        }
    }

    private static func printResponse(_ response: MeshResponse) -> Int32 {
        if response.ok {
            if let capabilities = response.capabilities { print(capabilities.joined(separator: "\n")) }
            else if let note = response.note { print(note) }
            else { print("ok") }
            return 0
        }
        FileHandle.standardError.write(Data("error: \(response.error ?? "unknown error")\n".utf8))
        return 1
    }

    private static func printTerminalQRCode(_ value: String) {
        let candidates = ["/opt/homebrew/bin/qrencode", "/usr/local/bin/qrencode", "/usr/bin/qrencode"]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-t", "ANSIUTF8", value]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try? process.run()
        process.waitUntilExit()
    }

    private static func usageError(_ detail: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: pharos-mesh \(detail)\n".utf8))
        return 2
    }

    private static let usage = """
    pharos-mesh — headless Pharos Mesh broker and client

      serve [--bind HOST:PORT] [--data-dir PATH]
      node run --endpoint HOST:PORT
      node install [--endpoint HOST:PORT]
      node uninstall
      capabilities [--endpoint HOST:PORT]
      pair --endpoint HOST:PORT
      create <room>
      list
      history <room> [--limit N]
      join <room> <nick> --session <id> [--kind codex|claude]
      send <text> [@target ...] [--room ROOM] [--member SESSION] [--reply ID] [--attach FILE]
      say <room> <nick> <text> [--member SESSION] [--reply ID] [--attach FILE]
      recv [<nick>] [--member <session-id>]
      attachment put <file> [--id UUID] [--name DISPLAY-NAME]
      attachment get <id> [--out PATH]
      registry get [--output PATH]
      registry import <projects.json> --expected REVISION
      distributed status|init [--json] [--data-dir ABSOLUTE-PATH]

    Add `--endpoint HOST:PORT` to any client command to dial a remote broker.
    """
}
