import Foundation
import PharosMeshCore

exit(await MeshHeadlessCLI.run(Array(CommandLine.arguments.dropFirst())))

private enum MeshHeadlessCLI {
    static func run(_ args: [String]) async -> Int32 {
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
            request.nodeID = MeshNodeIdentity.current
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
            return await runDistributed(Array(args.dropFirst()))

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
    private static func runDistributed(_ args: [String]) async -> Int32 {
        let command = args.first ?? "status"
        let migrationCommands = [
            "migration-status", "migration-prepare", "migration-import",
            "cutover", "rollback",
        ]
        let probeCommands = ["probe-serve", "probe"]
        guard command == "status" || command == "init" ||
                migrationCommands.contains(command) || probeCommands.contains(command) else {
            return usageError(
                "distributed status|init|probe-serve|probe|migration-status|" +
                "migration-prepare|cutover|rollback …"
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
        if migrationCommands.contains(command), dataDirectory == nil {
            return usageError("migration commands require --data-dir ABSOLUTE-PATH")
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
            if migrationCommands.contains(command) {
                return try await runMigrationCommand(
                    command, args: args, replica: replica
                )
            }
            if command == "probe-serve" {
                return try await runDistributedProbeServer(args, replica: replica)
            }
            if command == "probe" {
                return try await runDistributedProbe(args, replica: replica)
            }
            let activeGroup: MeshTrustGroupID?
            if command == "init" {
                activeGroup = try await replica.ensureActiveTrustGroup()
            } else {
                activeGroup = try replica.activeTrustGroup()
            }
            let status = DistributedStatus(
                protocolVersion: DistributedMeshProtocol.version,
                schemaVersion: DistributedMeshStore.currentSchemaVersion,
                deviceID: replica.identity.deviceID.rawValue.uuidString,
                endpointID: try replica.identity.endpointID().rawValue,
                activeTrustGroupID: activeGroup?.rawValue.uuidString,
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
                print("group\t\(status.activeTrustGroupID ?? "not-initialized")")
                print("schema\t\(status.schemaVersion)")
                print("database\t\(status.databasePath)")
                print("network\t\(status.networkState)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(
                Data("error: distributed command failed: \(error)\n".utf8)
            )
            return 1
        }
    }

    /// Starts only the identity-addressed Iroh transport and a bounded
    /// diagnostic ping handler. It never opens a legacy endpoint or mutates
    /// replica state, so operators can validate path selection before pairing
    /// or migration cutover.
    private static func runDistributedProbeServer(
        _ args: [String], replica: MeshLocalReplica
    ) async throws -> Int32 {
        let runtime = try await IrohEndpointRuntime.bind(
            secretKey: replica.identity.irohSecretKeyBytes(),
            relayPolicy: try distributedRelayPolicy(args),
            bindAddress: option("--bind", in: args)
        )
        let address = try await runtime.localAddress()
        let localEndpoint = address.endpointID.rawValue
        await runtime.startServing { request, remoteEndpointID in
            let ping = try JSONDecoder().decode(
                DistributedProbePing.self, from: request.header
            )
            guard ping.kind == "ping",
                  ping.senderEndpointID == remoteEndpointID.rawValue else {
                throw DistributedProbeError.identityMismatch
            }
            let response = DistributedProbePong(
                kind: "pong", nonce: ping.nonce,
                serverEndpointID: localEndpoint,
                observedPeerEndpointID: remoteEndpointID.rawValue
            )
            return MeshTransportResponse(header: try sortedJSON(response))
        }
        let status = DistributedProbeServerStatus(
            deviceID: replica.identity.deviceID.rawValue.uuidString,
            endpointID: address.endpointID.rawValue,
            ticket: address.ticket,
            networkState: "serving"
        )
        var statusLine = try sortedJSON(status)
        statusLine.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: statusLine)
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
        try await runtime.close()
        return 0
    }

    private static func runDistributedProbe(
        _ args: [String], replica: MeshLocalReplica
    ) async throws -> Int32 {
        guard let endpointText = option("--peer-endpoint", in: args),
              let endpointID = MeshEndpointID(rawValue: endpointText),
              let ticket = option("--peer-ticket", in: args), !ticket.isEmpty else {
            return usageError(
                "distributed probe --peer-endpoint ID --peer-ticket TICKET " +
                "--data-dir ABSOLUTE-PATH"
            )
        }
        let runtime = try await IrohEndpointRuntime.bind(
            secretKey: replica.identity.irohSecretKeyBytes(),
            relayPolicy: try distributedRelayPolicy(args),
            bindAddress: option("--bind", in: args)
        )
        do {
            let localEndpoint = try await runtime.localAddress().endpointID
            let nonce = UUID().uuidString
            let ping = DistributedProbePing(
                kind: "ping", nonce: nonce,
                senderEndpointID: localEndpoint.rawValue
            )
            let transport = IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(endpointID: endpointID, ticket: ticket)
            )
            let response = try await transport.exchange(MeshTransportRequest(
                header: try sortedJSON(ping), timeoutMilliseconds: 10_000
            ))
            let pong = try JSONDecoder().decode(
                DistributedProbePong.self, from: response.header
            )
            guard pong.kind == "pong", pong.nonce == nonce,
                  pong.serverEndpointID == endpointID.rawValue,
                  pong.observedPeerEndpointID == localEndpoint.rawValue else {
                throw DistributedProbeError.identityMismatch
            }
            let result = DistributedProbeResult(
                localEndpointID: localEndpoint.rawValue,
                peerEndpointID: endpointID.rawValue,
                path: await transport.path.rawValue,
                nonceVerified: true,
                peerIdentityVerified: true
            )
            print(String(decoding: try sortedJSON(result), as: UTF8.self))
            try await runtime.close()
            return 0
        } catch {
            try? await runtime.close()
            throw error
        }
    }

    private static func distributedRelayPolicy(
        _ args: [String]
    ) throws -> MeshIrohRelayPolicy {
        switch option("--relay", in: args) ?? "production" {
        case "production": return .production
        case "disabled": return .disabled
        default: throw DistributedProbeError.invalidRelayPolicy
        }
    }

    private static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func runMigrationCommand(
        _ command: String, args: [String], replica: MeshLocalReplica
    ) async throws -> Int32 {
        guard let groupText = option("--group", in: args),
              let groupUUID = UUID(uuidString: groupText) else {
            return usageError("migration commands require --group UUID")
        }
        let group = MeshTrustGroupID(rawValue: groupUUID)
        if command == "migration-status" {
            guard let state = try await replica.store.migrationState(for: group) else {
                FileHandle.standardError.write(Data("error: migration is not prepared\n".utf8))
                return 1
            }
            printMigrationState(state, json: args.contains("--json"))
            return 0
        }
        if command == "migration-import" {
            guard let sourcePath = option("--legacy-data-dir", in: args),
                  sourcePath.hasPrefix("/"), !sourcePath.hasPrefix("--") else {
                return usageError("migration-import requires --legacy-data-dir ABSOLUTE-PATH")
            }
            let epoch = option("--epoch", in: args).flatMap(UInt64.init) ?? 1
            guard epoch > 0, epoch <= UInt64(Int64.max) else {
                return usageError("--epoch must be a positive 64-bit integer")
            }
            let currentEpoch = try await replica.store.membershipEpoch(for: group)
            guard currentEpoch == nil || currentEpoch == epoch else {
                let message = "error: migration epoch \(epoch) does not match " +
                    "existing epoch \(currentEpoch!)\n"
                FileHandle.standardError.write(Data(message.utf8))
                return 1
            }
            let existingState = try await replica.store.migrationState(for: group)
            let expectedGeneration = option("--generation", in: args).flatMap(UInt64.init)
            if let existingState {
                guard existingState.mode != .distributed else {
                    FileHandle.standardError.write(Data(
                        "error: roll back distributed authority before re-import\n".utf8
                    ))
                    return 1
                }
                guard expectedGeneration == existingState.generation else {
                    return usageError(
                        "re-import requires current --generation \(existingState.generation)"
                    )
                }
            } else if expectedGeneration != nil {
                return usageError("first migration-import must not pass --generation")
            }
            let migration = try LegacyMeshMigration.export(
                sourceRoot: URL(fileURLWithPath: sourcePath, isDirectory: true),
                trustGroupID: group, membershipEpoch: epoch,
                identity: replica.identity
            )
            if currentEpoch == nil {
                try await replica.store.setMembershipEpoch(epoch, for: group)
            }
            let digest = try migration.inventory.digest()
            let state = try await LegacyMeshMigration.installForShadow(
                migration, into: replica.store,
                creatorPublicKey: replica.identity.signingPublicKeyBytes(),
                expectedGeneration: expectedGeneration
            )
            let digestHex = digest.map { String(format: "%02x", $0) }.joined()
            if args.contains("--json") {
                struct ImportResult: Codable {
                    var inventoryDigest: String
                    var counts: LegacyMigrationCounts
                    var cutover: MeshMigrationCutoverState
                    var networkState: String
                }
                let result = ImportResult(
                    inventoryDigest: digestHex,
                    counts: migration.inventory.counts, cutover: state,
                    networkState: "stopped"
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(result), as: UTF8.self))
            } else {
                print("inventory\t\(digestHex)")
                print("projects\t\(migration.inventory.counts.projects)")
                print("issues\t\(migration.inventory.counts.issues)")
                print("rooms\t\(migration.inventory.counts.rooms)")
                print("messages\t\(migration.inventory.counts.messages)")
                print("attachments\t\(migration.inventory.counts.attachments)")
                print("mode\t\(state.mode.rawValue)")
                print("network\tstopped")
            }
            return 0
        }
        guard let digestText = option("--inventory", in: args),
              let digest = hexData(digestText), digest.count == 32 else {
            return usageError("migration command requires --inventory SHA256")
        }
        let now = MeshHybridTimestamp(
            wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let state: MeshMigrationCutoverState
        switch command {
        case "migration-prepare":
            state = try await replica.store.prepareMigration(
                for: group, inventoryDigest: digest, at: now
            )
        case "cutover", "rollback":
            guard let generationText = option("--generation", in: args),
                  let generation = UInt64(generationText), generation > 0 else {
                return usageError("cutover and rollback require --generation N")
            }
            if command == "cutover" {
                state = try await replica.store.cutOverMigration(
                    for: group, inventoryDigest: digest,
                    expectedGeneration: generation, at: now
                )
            } else {
                state = try await replica.store.rollBackMigration(
                    for: group, inventoryDigest: digest,
                    expectedGeneration: generation, at: now
                )
            }
        default:
            return usageError(command)
        }
        printMigrationState(state, json: args.contains("--json"))
        return 0
    }

    private static func printMigrationState(
        _ state: MeshMigrationCutoverState, json: Bool
    ) {
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(state) {
                print(String(decoding: data, as: UTF8.self))
            }
        } else {
            let inventory = state.inventoryDigest.map {
                String(format: "%02x", $0)
            }.joined()
            let legacyWrites = state.legacyMayWrite ? "enabled" : "disabled"
            let distributedWrites = state.distributedMayWrite ? "enabled" : "disabled"
            print("group\t\(state.trustGroupID.rawValue.uuidString)")
            print("inventory\t\(inventory)")
            print("generation\t\(state.generation)")
            print("mode\t\(state.mode.rawValue)")
            print("legacy-writes\t\(legacyWrites)")
            print("distributed-writes\t\(distributedWrites)")
            print("network\tstopped")
        }
    }

    private static func hexData(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }

    private struct DistributedStatus: Codable {
        var protocolVersion: Int
        var schemaVersion: Int
        var deviceID: String
        var endpointID: String
        var activeTrustGroupID: String?
        var databasePath: String
        var networkState: String
    }

    private struct DistributedProbePing: Codable {
        var kind: String
        var nonce: String
        var senderEndpointID: String
    }

    private struct DistributedProbePong: Codable {
        var kind: String
        var nonce: String
        var serverEndpointID: String
        var observedPeerEndpointID: String
    }

    private struct DistributedProbeServerStatus: Codable {
        var deviceID: String
        var endpointID: String
        var ticket: String
        var networkState: String
    }

    private struct DistributedProbeResult: Codable {
        var localEndpointID: String
        var peerEndpointID: String
        var path: String
        var nonceVerified: Bool
        var peerIdentityVerified: Bool
    }

    private enum DistributedProbeError: Error {
        case identityMismatch
        case invalidRelayPolicy
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
      distributed probe-serve --data-dir ABSOLUTE-PATH [--relay production|disabled] [--bind HOST:PORT]
      distributed probe --peer-endpoint ID --peer-ticket TICKET --data-dir ABSOLUTE-PATH [--relay production|disabled] [--bind HOST:PORT]
      distributed migration-status --group UUID --data-dir ABSOLUTE-PATH [--json]
      distributed migration-import --group UUID --legacy-data-dir ABSOLUTE-PATH --data-dir ABSOLUTE-PATH [--epoch N] [--generation N] [--json]
      distributed migration-prepare --group UUID --inventory SHA256 --data-dir ABSOLUTE-PATH
      distributed cutover --group UUID --inventory SHA256 --generation N --data-dir ABSOLUTE-PATH
      distributed rollback --group UUID --inventory SHA256 --generation N --data-dir ABSOLUTE-PATH

    Add `--endpoint HOST:PORT` to any client command to dial a remote broker.
    """
}
