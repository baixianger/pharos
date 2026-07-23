import Foundation
import PharosMeshControl
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Agent-facing compatibility surface for the distributed chat registry.
///
/// Durable rooms, aliases, and messages are replicated. Delivery receipts are
/// intentionally device-local: consuming a hook notification on one coding
/// session must not create a CRDT write or race another device's UI state.
public actor DistributedAgentChat {
    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let chat: DistributedChatRegistry
    private let receiptURL: URL

    public init(replica: MeshLocalReplica, group: MeshTrustGroupID) {
        self.replica = replica
        self.group = group
        chat = DistributedChatRegistry(replica: replica, group: group)
        receiptURL = replica.rootURL.appendingPathComponent(
            "agent-delivery-v1.json", isDirectory: false
        )
    }

    public func rooms() async throws -> [MeshRoomInfo] {
        try await chat.rooms()
    }

    public func room(named name: String) async throws -> MeshRoomInfo {
        guard let room = try await chat.rooms().first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else { throw DistributedAgentChatError.roomNotFound(name) }
        return room
    }

    @discardableResult
    public func join(room name: String, nick: String, memberID: String) async throws -> MeshRoomInfo {
        let room = try await room(named: name)
        try await ensureLocalPresenceAuthority(memberID: memberID)
        try await chat.join(room: room, nick: nick, memberID: memberID)
        return room
    }

    /// Ensure every locally joined coding session has a Host-authoritative
    /// presence resource. This deliberately grants no poke/stop/attach
    /// capability; Pharos-owned spawn upgrades the same resource separately.
    public func ensureLocalPresenceAuthority(memberID: String) async throws {
        guard let resourceID = MeshResourceID(rawValue: memberID) else {
            throw DistributedAgentChatError.invalidMemberID(memberID)
        }
        if let existing = try await replica.store.hostResource(
            in: group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        ) {
            guard existing.state == .active else {
                throw DistributedMeshStoreError.hostResourceRetired
            }
            return
        }
        _ = try await replica.store.registerHostResource(
            in: group, on: replica.identity, resourceID: resourceID,
            allowedActions: [.presence], at: Self.nowTimestamp()
        )
    }

    public func leave(room name: String, memberID: String) async throws {
        try await chat.leave(room: try await room(named: name), memberID: memberID)
        guard try await memberships(memberID: memberID).isEmpty,
              let resourceID = MeshResourceID(rawValue: memberID),
              let resource = try await replica.store.hostResource(
                in: group, hostDeviceID: replica.identity.deviceID,
                resourceID: resourceID
              ), resource.state == .active else { return }

        // The final room membership is the durable lifetime boundary for an
        // agent identity. Keeping its Host resource or observation after this
        // point creates an unaddressable ghost that remote clients can still
        // mistake for live presence. Leaving only one of several rooms must
        // not retire the shared session resource.
        _ = try await replica.store.retireHostResource(
            in: group, on: replica.identity, resourceID: resourceID,
            at: max(resource.updatedAt, Self.nowTimestamp())
        )
        try? DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        ).remove(resourceID)
        try DistributedHookCLI.removeLocalObservation(
            memberID: memberID, root: replica.rootURL
        )
    }

    public func renameMember(room name: String, memberID: String, to nick: String) async throws {
        try await chat.renameMember(
            room: try await room(named: name), memberID: memberID, to: nick
        )
    }

    public func memberships(memberID: String) async throws -> [DistributedAgentMembership] {
        var result: [DistributedAgentMembership] = []
        for room in try await chat.rooms() {
            if let member = try await chat.members(in: room).first(where: { $0.id == memberID }) {
                result.append(.init(room: room, member: member))
            }
        }
        return result.sorted { $0.room.name < $1.room.name }
    }

    /// Materializes the durable membership set once for Host lifecycle audits.
    /// Presence snapshots may contain thousands of resources; scanning every
    /// room separately for every resource would turn cleanup into O(R × M).
    public func membershipMemberIDs() async throws -> Set<String> {
        var result: Set<String> = []
        for room in try await chat.rooms() {
            result.formUnion(try await chat.members(in: room).map(\.id))
        }
        return result
    }

    /// Move one coding-session identity to its verified successor on the same
    /// Host seat. The caller must prove that relationship from Host-local hook
    /// observations; nick, cwd, and host names alone are never identity.
    @discardableResult
    public func rebindMember(from oldMemberID: String, to newMemberID: String) async throws -> Bool {
        guard oldMemberID != newMemberID else { return false }
        let oldMemberships = try await memberships(memberID: oldMemberID)
        guard !oldMemberships.isEmpty else { return false }
        let newRoomIDs = Set(
            try await memberships(memberID: newMemberID).compactMap(\.room.replicaID)
        )
        let migratedResource = try await prepareHostResourceRebind(
            from: oldMemberID, to: newMemberID
        )

        // Preserve exact-once delivery and messages that were addressed to the
        // predecessor before the replicated membership moved to the successor.
        let receiptLock = try DistributedAgentFileLock(
            url: receiptURL.appendingPathExtension("lock")
        )
        defer { receiptLock.unlock() }
        var receipts = try loadReceipts()
        let inherited = Set(receipts.inheritedMemberIDs?[newMemberID] ?? [])
            .union(receipts.inheritedMemberIDs?[oldMemberID] ?? [])
            .union([oldMemberID])
        var inheritedByMember = receipts.inheritedMemberIDs ?? [:]
        inheritedByMember[newMemberID] = inherited.sorted()
        inheritedByMember[oldMemberID] = nil
        receipts.inheritedMemberIDs = inheritedByMember
        let seen = Set(receipts.seenByMember[newMemberID] ?? [])
            .union(receipts.seenByMember[oldMemberID] ?? [])
        receipts.seenByMember[newMemberID] = Array(seen).sorted()
        receipts.seenByMember[oldMemberID] = nil
        try saveReceipts(receipts)

        for membership in oldMemberships {
            if membership.room.replicaID.map(newRoomIDs.contains) != true {
                try await chat.join(
                    room: membership.room, nick: membership.member.nick,
                    memberID: newMemberID
                )
            }
            try await chat.leave(room: membership.room, memberID: oldMemberID)
        }
        if let (oldResourceID, bindings, retirementTimestamp) = migratedResource {
            _ = try await replica.store.retireHostResource(
                in: group, on: replica.identity, resourceID: oldResourceID,
                at: retirementTimestamp
            )
            try bindings.remove(oldResourceID)
        }
        return true
    }

    private func prepareHostResourceRebind(
        from oldMemberID: String, to newMemberID: String
    ) async throws -> (
        MeshResourceID, DistributedHostResourceBindings, MeshHybridTimestamp
    )? {
        guard let oldResourceID = MeshResourceID(rawValue: oldMemberID),
              let newResourceID = MeshResourceID(rawValue: newMemberID),
              let oldResource = try await replica.store.hostResource(
                in: group, hostDeviceID: replica.identity.deviceID,
                resourceID: oldResourceID
              ), oldResource.state == .active else { return nil }
        let bindings = DistributedHostResourceBindings(dataDirectory: replica.rootURL)
        let oldBinding = try bindings.load(oldResourceID)
        let newBinding = try DistributedHostResourceBinding(
            resourceID: newResourceID,
            tmuxSession: oldBinding.tmuxSession,
            tmuxSocket: oldBinding.tmuxSocket
        )
        try bindings.save(newBinding, for: newResourceID)
        do {
            _ = try await replica.store.registerHostResource(
                in: group, on: replica.identity, resourceID: newResourceID,
                allowedActions: Set(oldResource.allowedActions),
                at: Self.nowTimestamp()
            )
        } catch {
            try? bindings.remove(newResourceID)
            throw error
        }
        return (
            oldResourceID, bindings,
            max(oldResource.updatedAt, Self.nowTimestamp())
        )
    }

    private static func nowTimestamp() -> MeshHybridTimestamp {
        MeshHybridTimestamp(
            wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }

    @discardableResult
    public func send(
        text: String, memberID: String, roomName: String? = nil,
        targets: [String] = [], replyToID: String? = nil,
        attachments: [MeshAttachment] = []
    ) async throws -> MeshMsg {
        let all = try await memberships(memberID: memberID)
        let membership: DistributedAgentMembership
        if let roomName {
            guard let exact = all.first(where: {
                $0.room.name.localizedCaseInsensitiveCompare(roomName) == .orderedSame
            }) else { throw DistributedAgentChatError.memberNotJoined(memberID, roomName) }
            membership = exact
        } else {
            guard all.count == 1, let only = all.first else {
                throw all.isEmpty
                    ? DistributedAgentChatError.memberNotJoinedAnywhere(memberID)
                    : DistributedAgentChatError.ambiguousRoom(all.map(\.room.name))
            }
            membership = only
        }
        let reply = try await reply(for: replyToID, in: membership.room)
        let targetMemberIDs = try await chat.memberIDs(
            in: membership.room, matching: targets
        )
        return try await chat.send(
            room: membership.room, fromMemberID: membership.member.id,
            text: text, toMemberIDs: targetMemberIDs,
            replyTo: reply, attachments: attachments
        )
    }

    @discardableResult
    public func say(
        room name: String, memberID: String, text: String, targets: [String] = [],
        replyToID: String? = nil, attachments: [MeshAttachment] = []
    ) async throws -> MeshMsg {
        try await send(
            text: text, memberID: memberID, roomName: name,
            targets: targets, replyToID: replyToID,
            attachments: attachments
        )
    }

    public func history(room name: String, limit: Int? = nil) async throws -> [MeshMsg] {
        try await chat.messages(in: try await room(named: name), limit: limit)
    }

    /// Returns and consumes messages addressed to the alias currently bound to
    /// this stable session id. A local set of immutable message ids provides
    /// exact-once hook delivery without introducing replicated read markers.
    public func receive(memberID: String) async throws -> [MeshMsg] {
        let receiptLock = try DistributedAgentFileLock(
            url: receiptURL.appendingPathExtension("lock")
        )
        defer { receiptLock.unlock() }
        let delivered = try await pending(memberID: memberID)
        if !delivered.isEmpty {
            var receipts = try loadReceipts()
            var seen = receipts.seenByMember[memberID] ?? []
            seen.append(contentsOf: delivered.map(\.stableID))
            // Bound local housekeeping without weakening normal exact-once
            // behavior. The newest 20k directed messages are ample for hooks.
            receipts.seenByMember[memberID] = Array(seen.suffix(20_000))
            try saveReceipts(receipts)
        }
        return delivered
    }

    public func peek(memberID: String) async throws -> [MeshMsg] {
        try await pending(memberID: memberID)
    }

    private func pending(memberID: String) async throws -> [MeshMsg] {
        let memberships = try await memberships(memberID: memberID)
        guard !memberships.isEmpty else {
            throw DistributedAgentChatError.memberNotJoinedAnywhere(memberID)
        }
        let receipts = try loadReceipts()
        let alreadySeen = Set(receipts.seenByMember[memberID] ?? [])
        let deliveryMemberIDs = Set(receipts.inheritedMemberIDs?[memberID] ?? [])
            .union([memberID])
        var delivered: [MeshMsg] = []
        for membership in memberships {
            let nick = membership.member.nick
            delivered += try await chat.messages(in: membership.room).filter {
                !alreadySeen.contains($0.stableID) &&
                ($0.authorMemberID.map { !deliveryMemberIDs.contains($0) } ?? ($0.from != nick)) &&
                (!$0.targetMemberIDs.isEmpty
                    ? $0.targetMemberIDs.contains(where: deliveryMemberIDs.contains)
                    : $0.to.contains(where: {
                        $0.localizedCaseInsensitiveCompare(nick) == .orderedSame
                    }))
            }
        }
        delivered.sort { $0.ts == $1.ts ? $0.stableID < $1.stableID : $0.ts < $1.ts }
        return delivered
    }

    private func loadReceipts() throws -> AgentDeliveryReceipts {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else {
            return AgentDeliveryReceipts()
        }
        let data = try Data(contentsOf: receiptURL)
        guard let receipts = try? JSONDecoder().decode(AgentDeliveryReceipts.self, from: data),
              receipts.version == 1 else {
            throw DistributedAgentChatError.corruptDeliveryReceipts
        }
        return receipts
    }

    private func reply(for id: String?, in room: MeshRoomInfo) async throws -> MeshReply? {
        guard let id, let message = try await chat.messages(in: room).first(where: {
            $0.stableID == id
        }) else { return nil }
        return MeshReply(
            messageID: message.stableID, from: message.from,
            authorMemberID: message.authorMemberID,
            preview: message.text, ts: message.ts
        )
    }

    private func saveReceipts(_ receipts: AgentDeliveryReceipts) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(receipts).write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: receiptURL.path
        )
    }
}

public struct DistributedAgentMembership: Sendable, Equatable {
    public var room: MeshRoomInfo
    public var member: DistributedChatMember

    public init(room: MeshRoomInfo, member: DistributedChatMember) {
        self.room = room
        self.member = member
    }
}

public enum DistributedAgentChatError: LocalizedError, Equatable, Sendable {
    case roomNotFound(String)
    case invalidMemberID(String)
    case memberNotJoined(String, String)
    case memberNotJoinedAnywhere(String)
    case ambiguousRoom([String])
    case corruptDeliveryReceipts

    public var errorDescription: String? {
        switch self {
        case .roomNotFound(let room): "Room not found: \(room). Sync and try again."
        case .invalidMemberID(let member): "Invalid agent session ID: \(member)."
        case .memberNotJoined(let member, let room):
            "Session \(member) has not joined \(room)."
        case .memberNotJoinedAnywhere(let member):
            "Session \(member) has not joined any room."
        case .ambiguousRoom(let rooms):
            "Session belongs to multiple rooms (\(rooms.joined(separator: ", "))); pass --room."
        case .corruptDeliveryReceipts:
            "The local agent delivery receipt file is corrupt."
        }
    }
}

private struct AgentDeliveryReceipts: Codable, Sendable {
    var version = 1
    var seenByMember: [String: [String]] = [:]
    var inheritedMemberIDs: [String: [String]]?
}

/// Shared command adapter used by both the macOS app executable (`pharos
/// mesh`) and the portable helper (`pharos-mesh`). Keeping this here prevents
/// the two installed CLIs from drifting back onto different transports.
public enum DistributedAgentCLI {
    public static let commands: Set<String> = [
        "capabilities", "create", "list", "history", "join", "claim", "say", "send",
        "recv", "who", "leave", "rename-member", "rename", "delete", "rm",
        "attachment", "stop", "attach-local", "presence",
    ]

    public static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first, commands.contains(command) else { return 2 }
        do {
            let replica: MeshLocalReplica
            if let path = option("--data-dir", in: args) {
                guard path.hasPrefix("/") else { return usage("--data-dir requires an absolute path") }
                // Spelling the normal product directory explicitly must not
                // switch the CLI onto the fixture-only identity-v1.json. That
                // made an authenticated peer dial with a second Endpoint ID
                // and every presence RPC correctly failed as peer-not-trusted.
                replica = try MeshLocalReplica.openHeadless(
                    dataDirectory: URL(fileURLWithPath: path, isDirectory: true)
                )
            } else {
                replica = try MeshLocalReplica.openDefault(headless: true)
            }
            let group = try await replica.ensureActiveTrustGroup()
            let agent = DistributedAgentChat(replica: replica, group: group)
            let chat = DistributedChatRegistry(replica: replica, group: group)
            switch command {
            case "capabilities":
                print("distributed-mesh-v1\nlocal-first\nfield-level-conflicts\nagent-delivery-v1\nagent-presence-v1\nblob-sha256")
            case "create":
                guard args.count >= 2 else { return usage("create <room>") }
                _ = try await chat.createRoom(named: args[1]); print("created \(args[1])")
            case "list":
                let rooms = try await agent.rooms()
                if rooms.isEmpty { print("(no rooms)") }
                for room in rooms { print("\(room.name)  [\(room.members.joined(separator: ", "))]") }
            case "history":
                guard args.count >= 2 else { return usage("history <room> [--limit N]") }
                printMessages(try await agent.history(
                    room: args[1], limit: option("--limit", in: args).flatMap(Int.init)
                ), empty: "(no history)")
            case "join":
                guard args.count >= 3,
                      let memberID = option("--session", in: args)
                        ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                      !memberID.isEmpty else {
                    return usage("join <room> <nick> --session <id> [--kind codex|claude]")
                }
                _ = try await agent.join(room: args[1], nick: args[2], memberID: memberID)
                if let kind = option("--kind", in: args), ["codex", "claude"].contains(kind) {
                    try DistributedHookCLI.recordLocalAgentKind(
                        kind, memberID: memberID, rootURL: replica.rootURL
                    )
                }
                print("joined \(args[1]) as \(args[2])")
            case "claim":
                guard let memberID = option("--member", in: args)
                        ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                      !memberID.isEmpty else {
                    return usage("claim --member <session-id> [--kind codex|claude]")
                }
                let environment = ProcessInfo.processInfo.environment
                guard let tmux = environment["TMUX"], !tmux.isEmpty,
                      let pane = environment["TMUX_PANE"], !pane.isEmpty else {
                    return usage(
                        "claim must run inside the exact tmux pane that owns the agent"
                    )
                }
                guard !(try await agent.memberships(memberID: memberID)).isEmpty else {
                    return usage(
                        "claim requires an existing Mesh membership for this session"
                    )
                }
                try DistributedHookCLI.persistObservation(
                    mode: "claim",
                    payload: [
                        "session_id": memberID,
                        "hook_event_name": "HostLocalClaim",
                        "cwd": FileManager.default.currentDirectoryPath,
                    ],
                    session: memberID,
                    root: replica.rootURL
                )
                if let kind = option("--kind", in: args),
                   ["codex", "claude"].contains(kind) {
                    try DistributedHookCLI.recordLocalAgentKind(
                        kind, memberID: memberID, rootURL: replica.rootURL
                    )
                }
                guard let presence = DistributedHookCLI.verifiedLocalAgentPresence(
                    rootURL: replica.rootURL
                )[memberID] else {
                    throw DistributedAgentCLIError.agentResourceNotLocal
                }
                let sameSeatClaims = DistributedHookCLI.verifiedLocalAgentPresence(
                    rootURL: replica.rootURL
                ).values.filter {
                    $0.tmuxPane == pane
                        && $0.tmuxSocket == String(
                            tmux.split(separator: ",", maxSplits: 1)[0]
                        )
                }.count
                let result = try await DistributedAgentResourceReconciler(
                    dataDirectory: replica.rootURL
                ).reconcile(
                    memberID: memberID,
                    presence: presence,
                    seatIsConflicted: sameSeatClaims > 1,
                    replica: replica,
                    group: group,
                    now: MeshHybridTimestamp(
                        wallTimeMilliseconds: Int64(
                            Date().timeIntervalSince1970 * 1_000
                        )
                    )
                )
                guard result.readiness == .managed else {
                    throw DistributedAgentCLIError.agentResourceNotLocal
                }
                print("claimed \(memberID) on this Host")
            case "say":
                guard args.count >= 4,
                      let memberID = option("--member", in: args)
                        ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                      !memberID.isEmpty else {
                    return usage("say <room> <nick> <text> --member ID [--reply ID] [--attach FILE]")
                }
                let attachments = try await attachments(in: args, replica: replica, group: group)
                _ = try await agent.say(
                    room: args[1], memberID: memberID, text: args[3],
                    targets: targets(in: args, text: args[3]),
                    replyToID: option("--reply", in: args), attachments: attachments
                )
                print("sent")
            case "send":
                guard args.count >= 2, !args[1].hasPrefix("--"),
                      let memberID = option("--member", in: args)
                        ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                      !memberID.isEmpty else {
                    return usage("send <text> [@target ...] [--room ROOM] [--member SESSION] [--reply ID] [--attach FILE]")
                }
                let attachments = try await attachments(in: args, replica: replica, group: group)
                _ = try await agent.send(
                    text: args[1], memberID: memberID,
                    roomName: option("--room", in: args),
                    targets: targets(in: args, text: args[1]),
                    replyToID: option("--reply", in: args), attachments: attachments
                )
                print("sent")
            case "recv":
                guard let memberID = option("--member", in: args)
                        ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"],
                      !memberID.isEmpty else {
                    return usage("recv [<nick>] --member <session-id>")
                }
                printMessages(try await agent.receive(memberID: memberID), empty: "(no unread)")
            case "who":
                var any = false
                for room in try await agent.rooms() {
                    for member in try await chat.members(in: room) {
                        any = true
                        print("\(member.nick)  [replicated membership · liveness is Host-local]  room: \(room.name)  session \(member.id.prefix(8))")
                    }
                }
                if !any { print("(nobody has joined yet)") }
            case "presence":
                if args.contains("--local") {
                    let snapshot = try await DistributedHookCLI.hostPresenceSnapshot(
                        replica: replica, group: group
                    )
                    for record in snapshot.records {
                        print([
                            "local", record.resourceID.rawValue,
                            record.state.rawValue, record.kind ?? "unknown",
                            String(record.observedAtMilliseconds),
                        ].joined(separator: "\t"))
                    }
                    if snapshot.records.isEmpty {
                        print("(no verified local agent presence)")
                    }
                    return 0
                }
                let runtime = try await IrohEndpointRuntime.bind(
                    secretKey: replica.identity.irohSecretKeyBytes(),
                    expectedEndpointID: try replica.identity.endpointID()
                )
                do {
                    guard let epoch = try await replica.store.membershipEpoch(
                        for: group
                    ) else { throw DistributedAgentCLIError.missingMembership }
                    let peers = try await replica.store.trustedDevices(
                        in: group, membershipEpoch: epoch
                    ).filter { $0.descriptor.roles.contains(.host) }
                    var count = 0
                    for peer in peers {
                        let transport = IrohMeshTransport(
                            runtime: runtime,
                            remote: MeshIrohEndpointAddress(
                                endpointID: peer.descriptor.endpointID,
                                ticket: peer.addressTicket
                            )
                        )
                        let client = MeshReplicaRPCClient(transport: transport)
                        let snapshot: MeshAgentPresenceSnapshot
                        do {
                            snapshot = try await client.hostPresence(
                                group: group, membershipEpoch: epoch
                            )
                        } catch {
                            FileHandle.standardError.write(Data(
                                "presence \(peer.descriptor.displayName): \(error)\n".utf8
                            ))
                            continue
                        }
                        guard snapshot.hostDeviceID == peer.descriptor.id,
                              snapshot.hostEndpointID == peer.descriptor.endpointID,
                              snapshot.isFresh(at: Int64(
                                Date().timeIntervalSince1970 * 1_000
                              )) else {
                            FileHandle.standardError.write(Data(
                                "presence \(peer.descriptor.displayName): rejected stale or mismatched snapshot\n".utf8
                            ))
                            continue
                        }
                        for record in snapshot.records {
                            guard let resource = try? await client.hostResource(
                                record.resourceID, group: group,
                                membershipEpoch: epoch
                            ), resource.state == .active,
                              resource.hostDeviceID == peer.descriptor.id,
                              resource.hostEndpointID == peer.descriptor.endpointID
                            else { continue }
                            count += 1
                            print([
                                peer.descriptor.displayName,
                                record.resourceID.rawValue,
                                record.state.rawValue,
                                record.kind ?? "unknown",
                                String(record.observedAtMilliseconds),
                            ].joined(separator: "\t"))
                        }
                    }
                    if count == 0 { print("(no verified remote agent presence)") }
                    try await runtime.close()
                } catch {
                    try? await runtime.close()
                    throw error
                }
            case "leave":
                guard args.count >= 3 else { return usage("leave <room> <nick|member-id> [--member ID]") }
                let memberID = try await resolveMemberID(
                    room: args[1], value: option("--member", in: args) ?? args[2], chat: chat
                )
                try await agent.leave(room: args[1], memberID: memberID); print("left \(args[1])")
            case "stop":
                guard args.count >= 3 else { return usage("stop <room> <nick|member-id> [--member ID]") }
                let memberID = try await resolveMemberID(
                    room: args[1], value: option("--member", in: args) ?? args[2], chat: chat
                )
                let runtime = try await IrohEndpointRuntime.bind(
                    secretKey: replica.identity.irohSecretKeyBytes(),
                    expectedEndpointID: try replica.identity.endpointID()
                )
                do {
                    try await DistributedHostController.stopAgent(
                        memberID: memberID, runtime: runtime,
                        replica: replica, group: group
                    )
                    try await runtime.close()
                } catch {
                    try? await runtime.close()
                    throw error
                }
                for joinedRoom in try await chat.rooms() {
                    if try await chat.members(in: joinedRoom).contains(where: { $0.id == memberID }) {
                        try await chat.leave(room: joinedRoom, memberID: memberID)
                    }
                }
                print("stopped \(args[2])")
            case "attach-local":
                guard args.count >= 2,
                      let resourceID = MeshResourceID(rawValue: args[1]),
                      let resource = try await replica.store.hostResource(
                        in: group, hostDeviceID: replica.identity.deviceID,
                        resourceID: resourceID
                      ), resource.state == .active else {
                    throw DistributedAgentCLIError.agentResourceNotLocal
                }
                return try DistributedHostCommandExecutor(
                    bindings: DistributedHostResourceBindings(
                        dataDirectory: replica.rootURL
                    )
                ).attachLocal(resourceID: resourceID)
            case "rename-member":
                guard args.count >= 4 else { return usage("rename-member <room> <nick|member-id> <new-nick> [--member ID]") }
                let memberID = try await resolveMemberID(
                    room: args[1], value: option("--member", in: args) ?? args[2], chat: chat
                )
                try await agent.renameMember(room: args[1], memberID: memberID, to: args[3])
                print("renamed member to \(args[3])")
            case "rename":
                guard args.count >= 3 else { return usage("rename <room> <new-name>") }
                try await chat.renameRoom(try await agent.room(named: args[1]), to: args[2])
                print("renamed \(args[1]) to \(args[2])")
            case "delete", "rm":
                guard args.count >= 2 else { return usage("delete <room>") }
                try await chat.deleteRoom(try await agent.room(named: args[1])); print("deleted \(args[1])")
            case "attachment":
                guard args.count >= 3 else { return usage("attachment put|get …") }
                let registry = DistributedAttachmentRegistry(replica: replica, group: group)
                if args[1] == "put" {
                    let file = URL(fileURLWithPath: args[2]).standardizedFileURL
                    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                    let value = try await registry.put(
                        data: data, name: option("--name", in: args) ?? file.lastPathComponent,
                        mediaType: option("--mime", in: args) ?? "application/octet-stream"
                    )
                    print(value.id)
                } else if args[1] == "get" {
                    guard let metadata = try await registry.metadata(id: args[2]),
                          let data = try await registry.localData(for: metadata) else {
                        throw DistributedAgentCLIError.attachmentNotLocal
                    }
                    let output = option("--out", in: args) ?? metadata.name
                    try data.write(to: URL(fileURLWithPath: output), options: .atomic)
                    print(URL(fileURLWithPath: output).standardizedFileURL.path)
                } else { return usage("attachment put|get …") }
            default:
                return 2
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func attachments(
        in args: [String], replica: MeshLocalReplica, group: MeshTrustGroupID
    ) async throws -> [MeshAttachment] {
        guard let path = option("--attach", in: args) else { return [] }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        return [try await DistributedAttachmentRegistry(replica: replica, group: group).put(
            data: try Data(contentsOf: file, options: [.mappedIfSafe]),
            name: file.lastPathComponent, mediaType: "application/octet-stream"
        )]
    }

    private static func resolveMemberID(
        room name: String, value: String, chat: DistributedChatRegistry
    ) async throws -> String {
        let room = try await chat.rooms().first(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        })
        guard let room else { throw DistributedAgentChatError.roomNotFound(name) }
        let members = try await chat.members(in: room)
        if let exact = members.first(where: { $0.id == value }) { return exact.id }
        let matches = members.filter {
            $0.nick.localizedCaseInsensitiveCompare(value) == .orderedSame
        }
        guard matches.count == 1, let match = matches.first else {
            throw DistributedAgentChatError.memberNotJoined(value, name)
        }
        return match.id
    }

    private static func option(_ name: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private static func targets(in args: [String], text: String) -> [String] {
        var result = args.dropFirst().compactMap { token -> String? in
            guard token.hasPrefix("@"), token.count > 1 else { return nil }
            return String(token.dropFirst())
        }
        if let expression = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9._-])@([A-Za-z0-9._-]+)"#
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                if let range = Range(match.range(at: 1), in: text) {
                    result.append(String(text[range]))
                }
            }
        }
        return Array(Set(result)).sorted()
    }

    private static func printMessages(_ messages: [MeshMsg], empty: String) {
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

    private static func usage(_ detail: String) -> Int32 {
        FileHandle.standardError.write(Data("usage: pharos mesh \(detail)\n".utf8))
        return 2
    }
}

public enum DistributedAgentCLIError: LocalizedError, Sendable {
    case attachmentNotLocal
    case agentResourceNotLocal
    case missingMembership

    public var errorDescription: String? {
        switch self {
        case .attachmentNotLocal:
            "Attachment bytes are not local yet. Open Pharos to sync/fetch them and retry."
        case .agentResourceNotLocal:
            "This Host does not own an active agent resource with that ID."
        case .missingMembership:
            "This device does not have an active Mesh membership epoch."
        }
    }
}

/// Hook adapter for the new architecture. It consumes only structured hook
/// JSON, persists Host-local observations, and never reads terminal output.
public enum DistributedHookCLI {
    static let rebindRecencySeconds: Double = 1_800
    /// A spawn registers Host authority immediately before it publishes room
    /// membership. Keep a bounded grace window so a concurrent snapshot never
    /// retires that legitimate in-flight resource.
    public static let orphanResourceGraceMilliseconds: Int64 = 60_000
    /// Without an exact tmux socket+pane, a hook observation proves only that
    /// the process was alive when the hook ran. Do not let an abandoned
    /// session remain Busy/Present forever merely because its Host is online.
    public static let unboundPresenceLeaseSeconds: Double = 120
    /// Host-local structured presence. It is intentionally not replicated:
    /// room membership is durable shared truth, while a coding session's
    /// liveness expires and is only authoritative on its owning Host.
    public struct LocalAgentPresence: Codable, Equatable, Sendable {
        public var state: String
        public var updatedAt: Double
        public var cwd: String?
        public var tmuxPane: String?
        public var tmuxSocket: String?
        public var kind: String?
        public var mode: String?
        public var event: String?
        public var reason: String?

        public init(
            state: String, updatedAt: Double, cwd: String? = nil,
            tmuxPane: String? = nil, tmuxSocket: String? = nil,
            kind: String? = nil, mode: String? = nil,
            event: String? = nil, reason: String? = nil
        ) {
            self.state = state
            self.updatedAt = updatedAt
            self.cwd = cwd
            self.tmuxPane = tmuxPane
            self.tmuxSocket = tmuxSocket
            self.kind = kind
            self.mode = mode
            self.event = event
            self.reason = reason
        }
    }

    private struct LocalPresenceDocument: Codable {
        var version: Int
        var sessions: [String: LocalAgentPresence]
    }

    public static func localAgentPresence(
        rootURL: URL? = nil
    ) -> [String: LocalAgentPresence] {
        guard let root = rootURL ?? (try? MeshLocalReplica.defaultRootURL()),
              let data = try? Data(contentsOf: root.appendingPathComponent(
                "agent-host-observations-v1.json"
              )),
              let document = try? JSONDecoder().decode(
                LocalPresenceDocument.self, from: data
              ), document.version == 1 else { return [:] }
        return document.sessions
    }

    /// Presence suitable for UI/control decisions. A bound tmux seat has an
    /// independently verifiable lifetime and may stay quiet while idle;
    /// unbound observations must renew their structured-hook lease.
    public static func verifiedLocalAgentPresence(
        rootURL: URL? = nil,
        now: Double = Date().timeIntervalSince1970
    ) -> [String: LocalAgentPresence] {
        localAgentPresence(rootURL: rootURL).filter { _, presence in
            if let pane = presence.tmuxPane, !pane.isEmpty,
               let socket = presence.tmuxSocket, !socket.isEmpty {
                return true
            }
            let age = now - presence.updatedAt
            return age >= -5 && age <= unboundPresenceLeaseSeconds
        }
    }

    /// Builds a privacy-bounded presence snapshot containing only observations
    /// whose stable resource is actively owned by this Host. This is the
    /// authority boundary used by authenticated peer RPC and later Gossip.
    public static func hostPresenceSnapshot(
        replica: MeshLocalReplica, group: MeshTrustGroupID,
        lifetimeMilliseconds: Int64 = 15_000,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        seatInspector: any DistributedTmuxSeatInspecting =
            DistributedTmuxSeatInspector()
    ) async throws -> MeshAgentPresenceSnapshot {
        let lifetime = min(
            max(lifetimeMilliseconds, 1),
            MeshAgentPresenceSnapshot.maximumLifetimeMilliseconds
        )
        let hostEndpointID = try replica.identity.endpointID()
        var records: [MeshAgentPresenceRecord] = []
        let chat = DistributedAgentChat(replica: replica, group: group)
        let memberIDs = try await chat.membershipMemberIDs()
        let bindings = DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        )
        // Old test/spawn paths could leave an active Host capability after
        // both its room membership and local observation disappeared. Those
        // resources never enter the observation loop below, so audit the
        // signed Host table itself. Retirement is durable and replicated;
        // audit rows remain available while control authority is removed.
        for resource in try await replica.store.hostResources(
            in: group, hostDeviceID: replica.identity.deviceID
        ) where resource.state == .active
            && !memberIDs.contains(resource.resourceID.rawValue)
            && nowMilliseconds - resource.updatedAt.wallTimeMilliseconds
                >= orphanResourceGraceMilliseconds {
            _ = try await replica.store.retireHostResource(
                in: group, on: replica.identity,
                resourceID: resource.resourceID,
                at: max(
                    resource.updatedAt,
                    MeshHybridTimestamp(
                        wallTimeMilliseconds: nowMilliseconds
                    )
                )
            )
            try? bindings.remove(resource.resourceID)
            try? removeLocalObservation(
                memberID: resource.resourceID.rawValue,
                root: replica.rootURL
            )
        }
        let verifiedPresence = verifiedLocalAgentPresence(
            rootURL: replica.rootURL,
            now: Double(nowMilliseconds) / 1_000
        )
        var exactSeatClaims: [String: [String]] = [:]
        for (memberID, presence) in verifiedPresence {
            guard let pane = presence.tmuxPane, !pane.isEmpty,
                  let socket = presence.tmuxSocket, !socket.isEmpty else {
                continue
            }
            exactSeatClaims["\(socket)\u{0}\(pane)", default: []].append(memberID)
        }
        let conflictedMembers = Set(
            exactSeatClaims.values
                .filter { $0.count > 1 }
                .flatMap { $0 }
        )
        let reconciler = DistributedAgentResourceReconciler(
            dataDirectory: replica.rootURL,
            seatInspector: seatInspector
        )
        for (memberID, presence) in localAgentPresence(rootURL: replica.rootURL) {
            guard let resourceID = MeshResourceID(rawValue: memberID),
                  let state = MeshSessionState(rawValue: presence.state)
            else { continue }
            // Preserve the last structured hook observation, including its
            // original timestamp. The snapshot TTL proves that the Host is
            // currently reachable; the record timestamp says when the agent
            // state was last observed. Dropping an older busy record here
            // made remote clients show Unknown while the owning Mac still
            // showed the exact same last-known state.
            var resource = try await replica.store.hostResource(
                    in: group, hostDeviceID: replica.identity.deviceID,
                    resourceID: resourceID
                  )
            if !memberIDs.contains(memberID) {
                if let orphan = resource, orphan.state == .active,
                   orphan.hostEndpointID == hostEndpointID {
                    _ = try await replica.store.retireHostResource(
                        in: group, on: replica.identity,
                        resourceID: resourceID,
                        at: max(
                            orphan.updatedAt,
                            MeshHybridTimestamp(
                                wallTimeMilliseconds: nowMilliseconds
                            )
                        )
                    )
                    try? DistributedHostResourceBindings(
                        dataDirectory: replica.rootURL
                    ).remove(resourceID)
                }
                try removeLocalObservation(
                    memberID: memberID, root: replica.rootURL
                )
                continue
            }
            // Stale unbound observations still participate in orphan cleanup
            // above, but they cannot publish presence or renew capabilities.
            guard verifiedPresence[memberID] != nil else { continue }
            let reconcileResult = try await reconciler.reconcile(
                memberID: memberID, presence: presence,
                seatIsConflicted: conflictedMembers.contains(memberID),
                replica: replica, group: group,
                now: MeshHybridTimestamp(
                    wallTimeMilliseconds: nowMilliseconds
                )
            )
            resource = reconcileResult.resource
            if presence.tmuxPane?.isEmpty == false,
               presence.tmuxSocket?.isEmpty == false,
               reconcileResult.readiness != .managed {
                // A stale or multiply-claimed tmux seat must not stay present
                // forever merely because an old hook observation exists.
                continue
            }
            guard let resource, resource.state == .active,
                  resource.hostEndpointID == hostEndpointID,
                  resource.allowedActions.contains(.presence) else { continue }
            let reason = presence.reason?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let kind = presence.kind?.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            records.append(MeshAgentPresenceRecord(
                resourceID: resourceID, state: state,
                observedAtMilliseconds: Int64(presence.updatedAt * 1_000),
                stateReason: reason?.isEmpty == false ? reason : nil,
                kind: kind?.isEmpty == false ? kind : nil
            ))
        }
        let snapshot = MeshAgentPresenceSnapshot(
            hostDeviceID: replica.identity.deviceID,
            hostEndpointID: hostEndpointID,
            generatedAtMilliseconds: nowMilliseconds,
            expiresAtMilliseconds: nowMilliseconds + lifetime,
            records: records.sorted {
                $0.resourceID.rawValue < $1.resourceID.rawValue
            }
        )
        try snapshot.validate()
        return snapshot
    }

    public static func recordLocalAgentKind(
        _ kind: String, memberID: String, rootURL: URL? = nil
    ) throws {
        guard ["codex", "claude"].contains(kind),
              let root = rootURL ?? (try? MeshLocalReplica.defaultRootURL())
        else { return }
        let file = root.appendingPathComponent("agent-host-observations-v1.json")
        let fileLock = try DistributedAgentFileLock(
            url: file.appendingPathExtension("lock")
        )
        defer { fileLock.unlock() }
        var document = LocalPresenceDocument(version: 1, sessions: [:])
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONDecoder().decode(LocalPresenceDocument.self, from: data),
           existing.version == 1 {
            document = existing
        }
        guard var presence = document.sessions[memberID] else { return }
        presence.kind = kind
        document.sessions[memberID] = presence
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path
        )
    }

    /// Resolve the current coding session from structured hook observations.
    /// Pane/socket identity is exact when available; the cwd fallback supports
    /// observations written by the first distributed rollout and only wins
    /// when one live session matches.
    public static func currentSessionID(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rootURL: URL? = nil,
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        now: Double = Date().timeIntervalSince1970
    ) -> String? {
        guard let root = rootURL ?? (try? MeshLocalReplica.defaultRootURL()) else { return nil }
        let file = root.appendingPathComponent("agent-host-observations-v1.json")
        guard let data = try? Data(contentsOf: file),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = document["sessions"] as? [String: Any] else { return nil }
        let pane = environment["TMUX_PANE"]
        let socket = environment["TMUX"].flatMap { value in
            value.split(separator: ",", maxSplits: 1).first.map(String.init)
        }
        let cwd = currentDirectory
        let candidates = sessions.compactMap { id, raw -> (String, Double, Bool, Bool)? in
            guard let value = raw as? [String: Any],
                  (value["state"] as? String) != "gone" else { return nil }
            let exactPane = pane != nil && value["tmuxPane"] as? String == pane
                && (value["tmuxSocket"] as? String) == socket
            let updatedAt = value["updatedAt"] as? Double ?? 0
            let age = now - updatedAt
            let hasBoundSeat = (value["tmuxPane"] as? String)?.isEmpty == false
                || (value["tmuxSocket"] as? String)?.isEmpty == false
            let exactCWD = value["cwd"] as? String == cwd
                && !hasBoundSeat && age >= -5
                && age <= unboundPresenceLeaseSeconds
            guard exactPane || exactCWD else { return nil }
            return (id, updatedAt, exactPane, exactCWD)
        }
        if let exact = candidates.filter(\.2).max(by: { $0.1 < $1.1 }) {
            return exact.0
        }
        let cwdMatches = candidates.filter(\.3)
        return cwdMatches.count == 1 ? cwdMatches[0].0 : nil
    }

    /// A clear/resume successor may reclaim only the exact recent tmux seat.
    /// This is Host-local proof; it deliberately rejects hostname, nick, and
    /// cwd-only matches so two co-located agents cannot collapse together.
    static func rebindCandidate(
        sessionID: String, source: String?, payload: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rootURL: URL? = nil, now: Double = Date().timeIntervalSince1970
    ) -> String? {
        guard source == "clear" || source == "resume",
              let pane = environment["TMUX_PANE"], !pane.isEmpty,
              let tmux = environment["TMUX"],
              let socket = tmux.split(separator: ",", maxSplits: 1).first.map(String.init)
        else { return nil }
        let cwd = payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath
        return localAgentPresence(rootURL: rootURL)
            .filter { id, value in
                id != sessionID && value.state != "gone"
                    && value.tmuxPane == pane && value.tmuxSocket == socket
                    && value.cwd == cwd
                    && now - value.updatedAt >= 0
                    && now - value.updatedAt <= rebindRecencySeconds
            }
            .max { $0.value.updatedAt < $1.value.updatedAt }?.key
    }

    public static func run(_ mode: String, args: [String]) async -> Int32 {
        do {
            let payload = readHookPayload()
            let session = (payload?["session_id"] as? String)
                ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"]
            let replica = try MeshLocalReplica.openDefault(headless: true)
            let group = try await replica.ensureActiveTrustGroup()
            if mode == "session-start" {
                let predecessor = session.flatMap {
                    rebindCandidate(
                        sessionID: $0, source: payload?["source"] as? String,
                        payload: payload ?? [:], rootURL: replica.rootURL
                    )
                }
                let predecessorKind = predecessor.flatMap {
                    localAgentPresence(rootURL: replica.rootURL)[$0]?.kind
                }
                try persistObservation(mode: mode, payload: payload ?? [:], session: session, root: replica.rootURL)
                if let session, let predecessor {
                    if let predecessorKind {
                        try recordLocalAgentKind(
                            predecessorKind, memberID: session,
                            rootURL: replica.rootURL
                        )
                    }
                    let agent = DistributedAgentChat(replica: replica, group: group)
                    if try await agent.rebindMember(from: predecessor, to: session) {
                        try removeLocalObservation(
                            memberID: predecessor, root: replica.rootURL
                        )
                    }
                }
                return 0
            }
            if mode == "mark" {
                try persistObservation(mode: mode, payload: payload ?? [:], session: session, root: replica.rootURL)
                return 0
            }
            guard let session, !session.isEmpty else { return 0 }
            if payload?["stop_hook_active"] as? Bool == true {
                if mode == "stop" {
                    try persistObservation(
                        mode: mode, payload: payload ?? [:], session: session,
                        root: replica.rootURL
                    )
                }
                return 0
            }
            let agent = DistributedAgentChat(replica: replica, group: group)
            // Delivery hooks also own the turn-state boundary. The initial
            // Stop observation is corrected back to busy below only when an
            // unread Mesh message prevents the agent from actually stopping.
            if mode == "stop" || mode == "post-tool" {
                try persistObservation(
                    mode: mode, payload: payload ?? [:], session: session,
                    root: replica.rootURL
                )
            }
            let messages = try await agent.receive(memberID: session)
            if mode == "stop", !messages.isEmpty {
                var resumed = payload ?? [:]
                resumed["hook_event_name"] = "UserPromptSubmit"
                try persistObservation(
                    mode: mode, payload: resumed, session: session,
                    root: replica.rootURL
                )
            }
            guard !messages.isEmpty else {
                return 0
            }
            let memberships = try await agent.memberships(memberID: session)
            let nick = memberships.first?.member.nick ?? "agent"
            let text = continuation(
                nick: nick, memberID: session, messages: messages,
                postTool: mode == "post-tool"
            )
            if mode == "post-tool" {
                let value: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PostToolUse", "additionalContext": text,
                    ],
                ]
                printJSON(value)
            } else if args.contains("--codex") {
                printJSON(["decision": "block", "reason": text])
            } else {
                printJSON([
                    "hookSpecificOutput": [
                        "hookEventName": "Stop", "additionalContext": text,
                    ],
                ])
            }
        } catch {
            // Hooks are intentionally fail-open. A locked Keychain, absent
            // membership, or temporarily unavailable replica must not disturb
            // the coding agent.
        }
        return 0
    }

    private static func readHookPayload() -> [String: Any]? {
        let data = FileHandle.standardInput.availableData
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func continuation(
        nick: String, memberID: String, messages: [MeshMsg], postTool: Bool
    ) -> String {
        let rooms = Dictionary(grouping: messages, by: \.room)
        var lines = [
            "New mesh message(s) for @\(nick) — \(messages.count) pending in " +
            "\(rooms.keys.sorted().joined(separator: ", ")) (not an error):",
        ]
        for message in messages.suffix(10) {
            lines.append("  [\(message.room)] \(message.from): \(message.text)")
        }
        if postTool {
            lines.append("When you reach a natural pause, reply with `pharos mesh send \"…\" @<sender> --room <room> --member \(memberID)` if needed.")
        } else {
            lines.append("Messages are already acknowledged locally. Reply with `pharos mesh send \"…\" @<sender> --room <room> --member \(memberID)` if needed.")
        }
        return lines.joined(separator: "\n")
    }

    static func persistObservation(
        mode: String, payload: [String: Any], session: String?, root: URL
    ) throws {
        guard let session, !session.isEmpty else { return }
        let file = root.appendingPathComponent("agent-host-observations-v1.json")
        let fileLock = try DistributedAgentFileLock(
            url: file.appendingPathExtension("lock")
        )
        defer { fileLock.unlock() }
        var document: [String: Any] = ["version": 1, "sessions": [:]]
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            document = existing
        }
        var sessions = document["sessions"] as? [String: Any] ?? [:]
        let previous = sessions[session] as? [String: Any]
        let state = hookState(payload)
            ?? previous?["state"] as? String
            ?? "busy"
        let reason = hookReason(payload: payload, state: state, previous: previous)
        var observation: [String: Any] = [
            "mode": mode,
            "event": payload["hook_event_name"] as? String ?? "SessionStart",
            "state": state,
            "reason": reason ?? "",
            "cwd": payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        if let pane = ProcessInfo.processInfo.environment["TMUX_PANE"] {
            observation["tmuxPane"] = pane
        }
        if let value = ProcessInfo.processInfo.environment["TMUX"],
           let socket = value.split(separator: ",", maxSplits: 1).first {
            observation["tmuxSocket"] = String(socket)
        }
        if let kind = previous?["kind"] as? String {
            observation["kind"] = kind
        }
        sessions[session] = observation
        document["sessions"] = sessions
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func removeLocalObservation(memberID: String, root: URL) throws {
        let file = root.appendingPathComponent("agent-host-observations-v1.json")
        let fileLock = try DistributedAgentFileLock(
            url: file.appendingPathExtension("lock")
        )
        defer { fileLock.unlock() }
        guard let data = try? Data(contentsOf: file),
              var document = try? JSONDecoder().decode(LocalPresenceDocument.self, from: data)
        else { return }
        document.sessions[memberID] = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: file, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path
        )
    }

    private static func hookState(_ payload: [String: Any]) -> String? {
        switch payload["hook_event_name"] as? String {
        case "UserPromptSubmit", "PostToolUse", "ElicitationResult", "PostToolUseFailure": "busy"
        case "PermissionRequest": "blocked"
        case "PreToolUse": "blocked"
        // A Stop hook means the current turn completed and the long-lived
        // coding-agent process is back at its composer. It is not a process
        // stop. SessionEnd remains the authoritative process/session boundary.
        case "Stop": "idle"
        case "StopFailure": "stopped"
        case "SessionEnd":
            switch payload["reason"] as? String {
            case "clear", "resume": "stopped"
            default: "gone"
            }
        case "Notification":
            switch payload["notification_type"] as? String {
            case "permission_prompt", "elicitation_dialog": "blocked"
            case "idle_prompt": "idle"
            case "elicitation_complete", "elicitation_response": "busy"
            default: nil
            }
        case "SessionStart": "busy"
        default: nil
        }
    }

    private static func hookReason(
        payload: [String: Any], state: String, previous: [String: Any]?
    ) -> String? {
        let event = payload["hook_event_name"] as? String
        let notification = payload["notification_type"] as? String
        let proposed: String?
        switch event {
        case "PermissionRequest":
            proposed = (payload["tool_name"] as? String).map { "permission:\($0)" }
                ?? "permission"
        case "PreToolUse": proposed = "form"
        case "Notification" where notification == "permission_prompt":
            proposed = "permission"
        case "Notification" where notification == "elicitation_dialog":
            proposed = "elicitation"
        case "StopFailure":
            proposed = "api_error:" + (payload["error"] as? String ?? "unknown")
        default: proposed = nil
        }
        if state == "blocked",
           let prior = previous?["reason"] as? String,
           prior.hasPrefix("form"), proposed?.hasPrefix("form") != true {
            return prior
        }
        return proposed
    }

    private static func printJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}

/// Advisory Host-local lock for read-modify-write state files. Independent
/// hook processes serialize here without turning ephemeral presence or delivery
/// receipts into replicated Mesh data and without requiring a daemon.
private final class DistributedAgentFileLock {
    private var descriptor: Int32?

    init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
#if canImport(Darwin)
        let fd = Darwin.open(
            url.path, O_CREAT | O_RDWR | O_EXLOCK, S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
#elseif canImport(Glibc)
        let fd = Glibc.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0, Glibc.lockf(fd, F_LOCK, 0) == 0 else {
            if fd >= 0 { Glibc.close(fd) }
            throw CocoaError(.fileWriteUnknown)
        }
        descriptor = fd
#endif
    }

    func unlock() {
        guard let descriptor else { return }
#if canImport(Darwin)
        Darwin.close(descriptor)
#elseif canImport(Glibc)
        _ = Glibc.lockf(descriptor, F_ULOCK, 0)
        Glibc.close(descriptor)
#endif
        self.descriptor = nil
    }

    deinit { unlock() }
}
