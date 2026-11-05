import Foundation
import PharosMeshProtocol

/// Local-first projection for the durable part of Mesh chat.
///
/// Rooms and memberships use field-level registers because they can be renamed
/// or retired. Messages are immutable append-only values. Presence, typing,
/// unread notification delivery, and agent liveness deliberately stay outside
/// this registry because they are expiring Host observations rather than
/// replicated truth.
public actor DistributedChatRegistry {
    private static let deletedField = "_deleted"

    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let author: MeshLocalEventAuthor

    public init(
        replica: MeshLocalReplica, group: MeshTrustGroupID,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.replica = replica
        self.group = group
        author = MeshLocalEventAuthor(
            replica: replica, trustGroupID: group,
            nowMilliseconds: nowMilliseconds
        )
    }

    public func rooms() async throws -> [MeshRoomInfo] {
        let records = try await roomRecords()
        let memberships = try await membershipRecords()
        return records.map { room in
            let roomMemberships = memberships
                .filter { $0.roomID == room.id }
                .sorted {
                    let order = $0.nick.localizedCaseInsensitiveCompare($1.nick)
                    return order == .orderedSame
                        ? $0.memberID < $1.memberID : order == .orderedAscending
                }
            return MeshRoomInfo(
                name: room.name,
                members: roomMemberships.map(\.nick),
                memberIDs: roomMemberships.map(\.memberID),
                replicaID: room.id
            )
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame
                ? ($0.replicaID ?? "") < ($1.replicaID ?? "")
                : order == .orderedAscending
        }
    }

    public func members(in room: MeshRoomInfo) async throws -> [DistributedChatMember] {
        let record = try await resolveRoom(room)
        return try await membershipRecords()
            .filter { $0.roomID == record.id }
            .map { DistributedChatMember(id: $0.memberID, nick: $0.nick) }
            .sorted {
                let order = $0.nick.localizedCaseInsensitiveCompare($1.nick)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    /// Returns every stable member identity matching a mention token. Exact
    /// IDs win; a display alias intentionally expands to all matching members
    /// so duplicate nicks can never be silently collapsed to one recipient.
    public func memberIDs(
        in room: MeshRoomInfo, matching aliasesOrIDs: [String]
    ) async throws -> [String] {
        let record = try await resolveRoom(room)
        let members = try await membershipRecords().filter { $0.roomID == record.id }
        var result = Set<String>()
        for value in aliasesOrIDs {
            if let exact = members.first(where: { $0.memberID == value }) {
                result.insert(exact.memberID)
                continue
            }
            for member in members where
                member.nick.localizedCaseInsensitiveCompare(value) == .orderedSame {
                result.insert(member.memberID)
            }
        }
        return result.sorted()
    }

    /// Stable identity for the human using this replica. Each trusted device
    /// has its own member ID; `human` is only the shared display alias.
    public func localHumanMember(in room: MeshRoomInfo) async throws -> DistributedChatMember {
        let memberID = Self.humanMemberID(deviceID: replica.identity.deviceID)
        if let existing = try await members(in: room).first(where: { $0.id == memberID }) {
            return existing
        }
        try await join(room: room, nick: "human", memberID: memberID)
        return DistributedChatMember(id: memberID, nick: "human")
    }

    @discardableResult
    public func createRoom(named rawName: String) async throws -> MeshRoomInfo {
        let name = try Self.validName(rawName)
        if try await roomRecords().contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw DistributedChatRegistryError.duplicateRoom(name)
        }
        let roomID = UUID().uuidString
        guard let entity = MeshEntityReference(type: .room, id: roomID) else {
            throw DistributedChatRegistryError.invalidEntity
        }
        try await set([
            Self.deletedField: try Self.encode(false),
            "name": try Self.encode(name),
            "createdAt": try Self.encode(Date().timeIntervalSince1970),
        ], on: entity)
        let humanID = Self.humanMemberID(deviceID: replica.identity.deviceID)
        try await join(roomID: roomID, nick: "human", memberID: humanID)
        return MeshRoomInfo(
            name: name, members: ["human"], memberIDs: [humanID],
            replicaID: roomID
        )
    }

    public func renameRoom(_ room: MeshRoomInfo, to rawName: String) async throws {
        let name = try Self.validName(rawName)
        let record = try await resolveRoom(room)
        if try await roomRecords().contains(where: {
            $0.id != record.id &&
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            throw DistributedChatRegistryError.duplicateRoom(name)
        }
        _ = try await author.setField(
            "name", value: try Self.encode(name), on: try Self.roomEntity(record.id)
        )
    }

    public func deleteRoom(_ room: MeshRoomInfo) async throws {
        let record = try await resolveRoom(room)
        _ = try await author.setField(
            Self.deletedField, value: try Self.encode(true),
            on: try Self.roomEntity(record.id)
        )
    }

    public func join(
        room: MeshRoomInfo, nick: String, memberID: String
    ) async throws {
        try await join(roomID: try await resolveRoom(room).id,
                       nick: nick, memberID: memberID)
    }

    public func leave(
        room: MeshRoomInfo, memberID: String
    ) async throws {
        let record = try await resolveRoom(room)
        for membership in try await membershipRecords()
        where membership.roomID == record.id && membership.memberID == memberID {
            _ = try await author.setField(
                Self.deletedField, value: try Self.encode(true),
                on: try Self.membershipEntity(membership.entityID)
            )
        }
    }

    public func renameMember(
        room: MeshRoomInfo, memberID: String, to rawNick: String
    ) async throws {
        let nick = try Self.validName(rawNick)
        let record = try await resolveRoom(room)
        guard let membership = try await membershipRecords().first(where: {
            $0.roomID == record.id && $0.memberID == memberID
        }) else { throw DistributedChatRegistryError.memberNotFound }
        _ = try await author.setField(
            "nick", value: try Self.encode(nick),
            on: try Self.membershipEntity(membership.entityID)
        )
    }

    @discardableResult
    public func send(
        room: MeshRoomInfo, fromMemberID: String, text: String,
        toMemberIDs: [String] = [], replyTo: MeshReply? = nil,
        attachments: [MeshAttachment] = [],
        sentAt: Date = Date()
    ) async throws -> MeshMsg {
        let record = try await resolveRoom(room)
        let memberships = try await membershipRecords().filter { $0.roomID == record.id }
        guard let authorMembership = memberships.first(where: {
            $0.memberID == fromMemberID
        }) else {
            throw DistributedChatRegistryError.memberNotFound
        }
        let targets = Set(toMemberIDs)
        let targetMembers = memberships
            .filter { targets.contains($0.memberID) }
            .sorted { $0.memberID < $1.memberID }
        guard targetMembers.count == targets.count else {
            throw DistributedChatRegistryError.memberNotFound
        }
        let messageID = UUID().uuidString
        guard let entity = MeshEntityReference(type: .message, id: messageID) else {
            throw DistributedChatRegistryError.invalidEntity
        }
        let payload = DistributedMessagePayloadV2(
            version: 2, roomID: record.id, roomName: record.name,
            authorMemberID: authorMembership.memberID,
            authorNickSnapshot: authorMembership.nick, text: text,
            timestamp: sentAt.timeIntervalSince1970,
            targetMemberIDs: targetMembers.map(\.memberID),
            targetNickSnapshots: targetMembers.map(\.nick), replyTo: replyTo,
            attachments: attachments
        )
        _ = try await author.putImmutable(try Self.encode(payload), on: entity)
        return payload.message(id: messageID, currentRoomName: record.name)
    }

    public func messages(
        in room: MeshRoomInfo, limit: Int? = nil
    ) async throws -> [MeshMsg] {
        let record = try await resolveRoom(room)
        var result: [MeshMsg] = []
        for entity in try await replica.store.materializedImmutableEntities(
            of: .message, in: group
        ) {
            guard let value = try await replica.store.materializedImmutableValue(
                for: entity, in: group
            ) else { continue }
            if let payload = try? Self.decode(DistributedMessagePayloadV2.self, from: value),
               payload.version == 2, payload.roomID == record.id {
                result.append(payload.message(id: entity.id, currentRoomName: record.name))
                continue
            }
            if let payload = try? Self.decode(DistributedMessagePayloadV1.self, from: value),
               payload.version == 1, payload.roomID == record.id {
                result.append(payload.message(id: entity.id, currentRoomName: record.name))
                continue
            }
            // Legacy migration snapshots stored the canonical MeshMsg directly.
            if var legacy = try? Self.decode(MeshMsg.self, from: value),
               legacy.room == record.legacyName {
                legacy.id = legacy.id ?? entity.id
                legacy.room = record.name
                result.append(legacy)
            }
        }
        result.sort {
            $0.ts == $1.ts ? $0.stableID < $1.stableID : $0.ts < $1.ts
        }
        guard let limit, limit >= 0, result.count > limit else { return result }
        return Array(result.suffix(limit))
    }

    private func join(roomID: String, nick rawNick: String,
                      memberID rawMemberID: String) async throws {
        let nick = try Self.validName(rawNick)
        let memberID = try Self.validIdentifier(rawMemberID)
        if let existing = try await membershipRecords().first(where: {
            $0.roomID == roomID && $0.memberID == memberID
        }) {
            try await set([
                Self.deletedField: try Self.encode(false),
                "nick": try Self.encode(nick),
            ], on: try Self.membershipEntity(existing.entityID))
            return
        }
        let entityID = UUID().uuidString
        try await set([
            Self.deletedField: try Self.encode(false),
            "roomID": try Self.encode(roomID),
            "memberID": try Self.encode(memberID),
            "nick": try Self.encode(nick),
        ], on: try Self.membershipEntity(entityID))
    }

    private func roomRecords() async throws -> [RoomRecord] {
        var result: [String: RoomRecord] = [:]
        for entity in try await replica.store.materializedImmutableEntities(
            of: .room, in: group
        ) {
            guard let value = try await replica.store.materializedImmutableValue(
                for: entity, in: group
            ), let legacy = try? Self.decode(LegacyRoomPayload.self, from: value)
            else { continue }
            result[entity.id] = RoomRecord(
                id: entity.id, name: legacy.name, legacyName: legacy.name,
                createdAt: 0
            )
        }
        for entity in try await replica.store.materializedEntities(of: .room, in: group) {
            let fields = try await activeFields(for: entity)
            if Self.isDeleted(fields) {
                result.removeValue(forKey: entity.id)
                continue
            }
            guard let name: String = try Self.decode("name", from: fields) else {
                continue
            }
            let previous = result[entity.id]
            result[entity.id] = RoomRecord(
                id: entity.id, name: name,
                legacyName: previous?.legacyName ?? name,
                createdAt: try Self.decode("createdAt", from: fields) ?? previous?.createdAt ?? 0
            )
        }
        return result.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
        }
    }

    private func membershipRecords() async throws -> [MembershipRecord] {
        var result: [MembershipRecord] = []
        let rooms = Dictionary(uniqueKeysWithValues: try await roomRecords().map {
            ($0.id, $0)
        })

        // Preserve legacy membership aliases from the imported genesis.
        for entity in try await replica.store.materializedImmutableEntities(
            of: .room, in: group
        ) {
            guard let room = rooms[entity.id],
                  let value = try await replica.store.materializedImmutableValue(
                    for: entity, in: group
                  ), let legacy = try? Self.decode(LegacyRoomPayload.self, from: value)
            else { continue }
            result.append(contentsOf: legacy.members.map { nick, memberID in
                MembershipRecord(
                    entityID: "legacy:\(entity.id):\(memberID)",
                    roomID: room.id, memberID: memberID, nick: nick
                )
            })
        }

        for entity in try await replica.store.materializedEntities(
            of: .roomMembership, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields),
                  let roomID: String = try Self.decode("roomID", from: fields),
                  rooms[roomID] != nil,
                  let memberID: String = try Self.decode("memberID", from: fields),
                  let nick: String = try Self.decode("nick", from: fields)
            else { continue }
            result.removeAll { $0.roomID == roomID && $0.memberID == memberID }
            result.append(MembershipRecord(
                entityID: entity.id, roomID: roomID,
                memberID: memberID, nick: nick
            ))
        }
        return result
    }

    private func resolveRoom(_ room: MeshRoomInfo) async throws -> RoomRecord {
        let records = try await roomRecords()
        if let id = room.replicaID, let record = records.first(where: { $0.id == id }) {
            return record
        }
        guard let record = records.first(where: {
            $0.name.localizedCaseInsensitiveCompare(room.name) == .orderedSame
        }) else { throw DistributedChatRegistryError.roomNotFound }
        return record
    }

    private func set(_ fields: [String: Data],
                     on entity: MeshEntityReference) async throws {
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            _ = try await author.setField(key, value: value, on: entity)
        }
    }

    private func activeFields(
        for entity: MeshEntityReference
    ) async throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try await replica.store.materializedFields(
            for: entity, in: group
        ).compactMap { field in
            guard !field.isDeleted, let value = field.value else { return nil }
            return (field.field, value)
        })
    }

    private static func roomEntity(_ id: String) throws -> MeshEntityReference {
        guard let entity = MeshEntityReference(type: .room, id: id) else {
            throw DistributedChatRegistryError.invalidEntity
        }
        return entity
    }

    private static func membershipEntity(_ id: String) throws -> MeshEntityReference {
        guard let entity = MeshEntityReference(type: .roomMembership, id: id) else {
            throw DistributedChatRegistryError.invalidEntity
        }
        return entity
    }

    private static func validName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw DistributedChatRegistryError.invalidName }
        return value
    }

    private static func validIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw DistributedChatRegistryError.invalidMemberID }
        return value
    }

    private static func humanMemberID(deviceID: MeshDeviceID) -> String {
        "human@\(deviceID.rawValue.uuidString)"
    }

    private static func isDeleted(_ fields: [String: Data]) -> Bool {
        guard let value = fields[deletedField] else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: value)) == true
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private static func decode<T: Decodable>(
        _ field: String, from fields: [String: Data]
    ) throws -> T? {
        guard let value = fields[field] else { return nil }
        return try decode(T.self, from: value)
    }
}

public enum DistributedChatRegistryError: LocalizedError, Equatable, Sendable {
    case duplicateRoom(String)
    case roomNotFound
    case memberNotFound
    case invalidEntity
    case invalidName
    case invalidMemberID

    public var errorDescription: String? {
        switch self {
        case .duplicateRoom(let name): "A room named \(name) already exists."
        case .roomNotFound: "Room not found. Sync and try again."
        case .memberNotFound: "Member not found. Sync and try again."
        case .invalidEntity: "Could not create a valid replicated chat entity."
        case .invalidName: "Names must contain 1–128 printable UTF-8 bytes."
        case .invalidMemberID: "The member identity is invalid."
        }
    }
}

public struct DistributedChatMember: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var nick: String

    public init(id: String, nick: String) {
        self.id = id
        self.nick = nick
    }
}

private struct RoomRecord: Sendable {
    var id: String
    var name: String
    var legacyName: String
    var createdAt: Double
}

private struct MembershipRecord: Sendable {
    var entityID: String
    var roomID: String
    var memberID: String
    var nick: String
}

private struct DistributedMessagePayloadV2: Codable, Sendable {
    var version: Int
    var roomID: String
    var roomName: String
    var authorMemberID: String
    var authorNickSnapshot: String
    var text: String
    var timestamp: Double
    var targetMemberIDs: [String]
    var targetNickSnapshots: [String]
    var replyTo: MeshReply?
    var attachments: [MeshAttachment]

    func message(id: String, currentRoomName: String) -> MeshMsg {
        MeshMsg(
            id: id, from: authorNickSnapshot, room: currentRoomName, text: text,
            ts: timestamp, to: targetNickSnapshots,
            authorMemberID: authorMemberID, targetMemberIDs: targetMemberIDs,
            replyTo: replyTo,
            attachments: attachments.isEmpty ? nil : attachments
        )
    }
}

private struct DistributedMessagePayloadV1: Codable, Sendable {
    var version: Int
    var roomID: String
    var roomName: String
    var from: String
    var text: String
    var timestamp: Double
    var targets: [String]
    var replyTo: MeshReply?
    var attachments: [MeshAttachment]

    func message(id: String, currentRoomName: String) -> MeshMsg {
        MeshMsg(
            id: id, from: from, room: currentRoomName, text: text,
            ts: timestamp, to: targets, replyTo: replyTo,
            attachments: attachments.isEmpty ? nil : attachments
        )
    }
}

/// Decode shape for legacy migration snapshots. Unread mailboxes remain input
/// for the later per-device read-marker adapter; they are not presented as
/// durable chat history here.
private struct LegacyRoomPayload: Codable, Sendable {
    var name: String
    var members: [String: String]
    var unreadByMember: [String: [MeshMsg]]
    var transcriptMessageCount: Int
}
