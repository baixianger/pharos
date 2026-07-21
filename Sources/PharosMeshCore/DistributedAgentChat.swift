import Foundation
import PharosMeshProtocol
import PharosMeshReplica

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
        try await chat.join(room: room, nick: nick, memberID: memberID)
        return room
    }

    public func leave(room name: String, memberID: String) async throws {
        try await chat.leave(room: try await room(named: name), memberID: memberID)
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
        return try await chat.send(
            room: membership.room, from: membership.member.nick, text: text,
            to: targets, replyTo: reply, attachments: attachments
        )
    }

    @discardableResult
    public func say(
        room name: String, nick: String, text: String, targets: [String] = [],
        replyToID: String? = nil, attachments: [MeshAttachment] = []
    ) async throws -> MeshMsg {
        let room = try await room(named: name)
        let reply = try await reply(for: replyToID, in: room)
        return try await chat.send(
            room: room, from: nick, text: text, to: targets,
            replyTo: reply, attachments: attachments
        )
    }

    public func history(room name: String, limit: Int? = nil) async throws -> [MeshMsg] {
        try await chat.messages(in: try await room(named: name), limit: limit)
    }

    /// Returns and consumes messages addressed to the alias currently bound to
    /// this stable session id. A local set of immutable message ids provides
    /// exact-once hook delivery without introducing replicated read markers.
    public func receive(memberID: String) async throws -> [MeshMsg] {
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
        var delivered: [MeshMsg] = []
        for membership in memberships {
            let nick = membership.member.nick
            delivered += try await chat.messages(in: membership.room).filter {
                !alreadySeen.contains($0.stableID) &&
                $0.from != nick && $0.to.contains(where: {
                    $0.localizedCaseInsensitiveCompare(nick) == .orderedSame
                })
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
    case memberNotJoined(String, String)
    case memberNotJoinedAnywhere(String)
    case ambiguousRoom([String])
    case corruptDeliveryReceipts

    public var errorDescription: String? {
        switch self {
        case .roomNotFound(let room): "Room not found: \(room). Sync and try again."
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
}

/// Shared command adapter used by both the macOS app executable (`pharos
/// mesh`) and the portable helper (`pharos-mesh`). Keeping this here prevents
/// the two installed CLIs from drifting back onto different transports.
public enum DistributedAgentCLI {
    public static let commands: Set<String> = [
        "capabilities", "create", "list", "history", "join", "say", "send",
        "recv", "who", "leave", "rename-member", "rename", "delete", "rm",
        "attachment",
    ]

    public static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first, commands.contains(command) else { return 2 }
        do {
            let replica: MeshLocalReplica
            if let path = option("--data-dir", in: args) {
                guard path.hasPrefix("/") else { return usage("--data-dir requires an absolute path") }
                replica = try MeshLocalReplica.openIsolated(
                    rootURL: URL(fileURLWithPath: path, isDirectory: true)
                )
            } else {
                replica = try MeshLocalReplica.openDefault()
            }
            let group = try await replica.ensureActiveTrustGroup()
            let agent = DistributedAgentChat(replica: replica, group: group)
            let chat = DistributedChatRegistry(replica: replica, group: group)
            switch command {
            case "capabilities":
                print("distributed-mesh-v1\nlocal-first\nfield-level-conflicts\nagent-delivery-v1\nblob-sha256")
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
                print("joined \(args[1]) as \(args[2])")
            case "say":
                guard args.count >= 4 else {
                    return usage("say <room> <nick> <text> [--member ID] [--reply ID] [--attach FILE]")
                }
                let attachments = try await attachments(in: args, replica: replica, group: group)
                _ = try await agent.say(
                    room: args[1], nick: args[2], text: args[3],
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
            case "leave":
                guard args.count >= 3 else { return usage("leave <room> <nick|member-id> [--member ID]") }
                let memberID = try await resolveMemberID(
                    room: args[1], value: option("--member", in: args) ?? args[2], chat: chat
                )
                try await agent.leave(room: args[1], memberID: memberID); print("left \(args[1])")
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

    public var errorDescription: String? {
        "Attachment bytes are not local yet. Open Pharos to sync/fetch them and retry."
    }
}

/// Hook adapter for the new architecture. It consumes only structured hook
/// JSON, persists Host-local observations, and never reads terminal output.
public enum DistributedHookCLI {
    public static func run(_ mode: String, args: [String]) async -> Int32 {
        do {
            let payload = readHookPayload()
            let session = (payload?["session_id"] as? String)
                ?? ProcessInfo.processInfo.environment["PHAROS_MESH_SESSION"]
            let replica = try MeshLocalReplica.openDefault()
            let group = try await replica.ensureActiveTrustGroup()
            if mode == "session-start" || mode == "mark" {
                try persistObservation(mode: mode, payload: payload ?? [:], session: session, root: replica.rootURL)
                return 0
            }
            guard let session, !session.isEmpty else { return 0 }
            if payload?["stop_hook_active"] as? Bool == true { return 0 }
            let agent = DistributedAgentChat(replica: replica, group: group)
            let messages = try await agent.receive(memberID: session)
            guard !messages.isEmpty else {
                if mode == "post-tool", args.contains("--codex") {
                    printJSON(["suppressOutput": true])
                }
                return 0
            }
            let memberships = try await agent.memberships(memberID: session)
            let nick = memberships.first?.member.nick ?? "agent"
            let text = continuation(
                nick: nick, memberID: session, messages: messages,
                postTool: mode == "post-tool"
            )
            if mode == "post-tool" {
                var value: [String: Any] = [
                    "hookSpecificOutput": [
                        "hookEventName": "PostToolUse", "additionalContext": text,
                    ],
                ]
                if args.contains("--codex") { value["suppressOutput"] = true }
                printJSON(value)
            } else if args.contains("--codex") {
                printJSON(["decision": "block", "reason": text, "suppressOutput": true])
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

    private static func persistObservation(
        mode: String, payload: [String: Any], session: String?, root: URL
    ) throws {
        guard let session, !session.isEmpty else { return }
        let file = root.appendingPathComponent("agent-host-observations-v1.json")
        var document: [String: Any] = ["version": 1, "sessions": [:]]
        if let data = try? Data(contentsOf: file),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            document = existing
        }
        var sessions = document["sessions"] as? [String: Any] ?? [:]
        sessions[session] = [
            "mode": mode,
            "event": payload["hook_event_name"] as? String ?? "SessionStart",
            "state": hookState(payload),
            "reason": payload["reason"] as? String ?? "",
            "cwd": payload["cwd"] as? String ?? FileManager.default.currentDirectoryPath,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        document["sessions"] = sessions
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func hookState(_ payload: [String: Any]) -> String {
        switch payload["hook_event_name"] as? String {
        case "UserPromptSubmit", "PostToolUse", "ElicitationResult", "PostToolUseFailure": "busy"
        case "PermissionRequest": "blocked"
        case "Stop", "StopFailure": "stopped"
        case "SessionEnd": "gone"
        default: "present"
        }
    }

    private static func printJSON(_ value: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }
}
