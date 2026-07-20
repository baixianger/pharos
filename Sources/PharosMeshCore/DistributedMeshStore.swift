import Foundation
import Crypto
import CSQLite
import PharosMeshIdentity
import PharosMeshProtocol

public enum DistributedMeshStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case eventIDCollision
    case authorSequenceGap(expected: UInt64, actual: UInt64)
    case authorHashMismatch
    case nonMonotonicHybridTimestamp
    case membershipEpochMismatch(expected: UInt64, actual: UInt64)
    case syncVectorTrustGroupMismatch
    case acknowledgementRegression(current: UInt64, proposed: UInt64)
    case acknowledgementBeyondLocalHead(local: UInt64, proposed: UInt64)
    case wrongCommandHost
    case commandGenerationMismatch(expected: UInt64, actual: UInt64)
    case idempotencyCollision
    case corruptStoredValue
    case unsupportedSchemaVersion(Int)
}

public enum MeshEventInsertion: Equatable, Sendable {
    case inserted
    case duplicate
}

public struct MeshAuthorHead: Codable, Equatable, Sendable {
    public var endpointID: MeshEndpointID
    public var sequence: UInt64
    public var eventHash: Data

    public init(endpointID: MeshEndpointID, sequence: UInt64, eventHash: Data) {
        self.endpointID = endpointID
        self.sequence = sequence
        self.eventHash = eventHash
    }
}

public struct MeshMaterializedField: Codable, Equatable, Sendable {
    public var field: String
    public var value: Data?
    public var isDeleted: Bool
    public var sourceEventID: MeshEventID
    public var timestamp: MeshHybridTimestamp
    public var authorEndpointID: MeshEndpointID

    public init(field: String, value: Data?, isDeleted: Bool,
                sourceEventID: MeshEventID, timestamp: MeshHybridTimestamp,
                authorEndpointID: MeshEndpointID) {
        self.field = field
        self.value = value
        self.isDeleted = isDeleted
        self.sourceEventID = sourceEventID
        self.timestamp = timestamp
        self.authorEndpointID = authorEndpointID
    }
}

public struct MeshQuarantinedEvent: Codable, Equatable, Sendable {
    public var eventID: MeshEventID
    public var reason: String
    public var receivedAtMilliseconds: Int64

    public init(eventID: MeshEventID, reason: String, receivedAtMilliseconds: Int64) {
        self.eventID = eventID
        self.reason = reason
        self.receivedAtMilliseconds = receivedAtMilliseconds
    }
}

/// One serialized SQLite connection per local replica. No method contacts a
/// broker or network transport; callers explicitly choose the database URL.
public actor DistributedMeshStore {
    private let databaseAddress: UInt
    private var materializationNeedsRebuild: Bool
    private var database: OpaquePointer { OpaquePointer(bitPattern: databaseAddress)! }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        var requiresMaterializationRebuild = false
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw DistributedMeshStoreError.openFailed(message)
        }
        do {
            try Self.execute(handle, sql: "PRAGMA journal_mode=WAL")
            try Self.execute(handle, sql: "PRAGMA synchronous=FULL")
            try Self.execute(handle, sql: "PRAGMA foreign_keys=ON")
            try Self.execute(handle, sql: "PRAGMA busy_timeout=5000")
            try Self.execute(handle, sql: "BEGIN IMMEDIATE")
            try Self.execute(handle, sql: Self.schemaMetadata)
            let version = try Self.readSchemaVersion(handle)
            guard (1 ... 3).contains(version) else {
                throw DistributedMeshStoreError.unsupportedSchemaVersion(version)
            }
            requiresMaterializationRebuild = version < 3
            try Self.execute(handle, sql: Self.schemaV1)
            try Self.execute(handle, sql: Self.schemaV2)
            try Self.execute(handle, sql: Self.schemaV3)
            let materializationVersion = try Self.readMaterializationVersion(handle)
            requiresMaterializationRebuild = requiresMaterializationRebuild ||
                materializationVersion != 1
            try Self.execute(handle, sql: "COMMIT")
        } catch {
            try? Self.execute(handle, sql: "ROLLBACK")
            sqlite3_close(handle)
            throw error
        }
        databaseAddress = UInt(bitPattern: handle)
        materializationNeedsRebuild = requiresMaterializationRebuild
    }

    deinit {
        if let handle = OpaquePointer(bitPattern: databaseAddress) { sqlite3_close(handle) }
    }

    public func journalMode() throws -> String {
        try scalarText("PRAGMA journal_mode") ?? ""
    }

    public func schemaVersion() throws -> Int {
        Int(try scalarInt64("SELECT version FROM schema_metadata LIMIT 1") ?? 0)
    }

    public func setMembershipEpoch(_ epoch: UInt64, for group: MeshTrustGroupID) throws {
        guard epoch > 0, epoch <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidMembershipEpoch
        }
        try transaction {
            let current = try membershipEpoch(for: group)
            guard current == nil || epoch >= current! else {
                throw DistributedMeshStoreError.membershipEpochMismatch(
                    expected: current!, actual: epoch
                )
            }
            try run(
                "INSERT INTO membership_epochs(trust_group_id, epoch) VALUES(?, ?) " +
                "ON CONFLICT(trust_group_id) DO UPDATE SET epoch=excluded.epoch",
                [.text(group.rawValue.uuidString), .integer(Int64(epoch))]
            )
        }
    }

    public func membershipEpoch(for group: MeshTrustGroupID) throws -> UInt64? {
        try queryOne(
            "SELECT epoch FROM membership_epochs WHERE trust_group_id=?",
            [.text(group.rawValue.uuidString)]
        ) { UInt64(sqlite3_column_int64($0, 0)) }
    }

    /// The pending record persists only invitation and nonce digests. The raw
    /// QR/deep-link bearer secret is never written to the replica database.
    public func register(_ record: MeshInvitationUseRecord) throws {
        try record.validate()
        try transaction {
            if let currentEpoch = try membershipEpoch(for: record.trustGroupID),
               currentEpoch != record.membershipEpoch {
                throw MeshTrustPairingError.membershipEpochMismatch
            }
            guard try invitationRecord(nonceDigest: record.nonceDigest) == nil else {
                throw MeshTrustPairingError.duplicateInvitation
            }
            try run(
                "INSERT INTO pairing_invitations(trust_group_id, membership_epoch, " +
                "invitation_digest, nonce_digest, expires_at_ms) VALUES(?, ?, ?, ?, ?)",
                [.text(record.trustGroupID.rawValue.uuidString),
                 .integer(Int64(record.membershipEpoch)),
                 .blob(record.invitationDigest), .blob(record.nonceDigest),
                 .integer(record.expiresAtMilliseconds)]
            )
        }
    }

    /// `BEGIN IMMEDIATE` serializes redemption across independent SQLite
    /// connections. Exactly one process can change `consumed_at_ms` from NULL.
    public func consume(_ record: MeshInvitationUseRecord, accepting device: MeshPairedDevice,
                        at milliseconds: Int64)
        throws -> MeshInvitationConsumption {
        try record.validate()
        try device.validateBinding()
        return try transaction { () -> MeshInvitationConsumption in
            guard let stored = try invitationRecord(nonceDigest: record.nonceDigest) else {
                return .unknown
            }
            guard stored.record == record else { return .mismatch }
            guard stored.consumedAtMilliseconds == nil else { return .alreadyConsumed }
            guard milliseconds < stored.record.expiresAtMilliseconds else { return .expired }
            if let currentEpoch = try membershipEpoch(for: record.trustGroupID),
               currentEpoch != record.membershipEpoch {
                return .membershipEpochMismatch
            }
            guard try trustedDeviceMatching(
                group: record.trustGroupID,
                deviceID: device.descriptor.id,
                endpointID: device.descriptor.endpointID
            ) == nil else {
                return .deviceAlreadyTrusted
            }
            try run(
                "INSERT INTO trusted_devices(trust_group_id, device_id, endpoint_id, " +
                "membership_epoch, envelope) VALUES(?, ?, ?, ?, ?)",
                [.text(record.trustGroupID.rawValue.uuidString),
                 .text(device.descriptor.id.rawValue.uuidString),
                 .text(device.descriptor.endpointID.rawValue),
                 .integer(Int64(record.membershipEpoch)),
                 .blob(try MeshCanonicalStoreJSON.encode(device))]
            )
            try run(
                "UPDATE pairing_invitations SET consumed_at_ms=? " +
                "WHERE nonce_digest=? AND consumed_at_ms IS NULL",
                [.integer(milliseconds), .blob(record.nonceDigest)]
            )
            return .consumed
        }
    }

    public func trustedDevice(in group: MeshTrustGroupID,
                              id: MeshDeviceID) throws -> MeshPairedDevice? {
        try queryOne(
            "SELECT envelope FROM trusted_devices WHERE trust_group_id=? AND device_id=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(id.rawValue.uuidString)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let device = try? JSONDecoder().decode(MeshPairedDevice.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return device
        }
    }

    /// Inserts only a structurally and cryptographically verified event. The
    /// caller supplies the trusted membership public key; this method checks it
    /// before opening the write transaction.
    public func insert(_ event: MeshReplicatedEvent, authorPublicKey: Data) throws -> MeshEventInsertion {
        try ensureMaterializedState()
        try DistributedMeshCrypto.verify(event, publicKey: authorPublicKey)
        let bytes = try event.canonicalBytes()
        let digest = try DistributedMeshCrypto.digest(event)

        return try transaction {
            if let existing = try queryOne(
                "SELECT envelope FROM events WHERE event_id=?",
                [.text(event.id.rawValue.uuidString)],
                transform: {
                    guard let data = Self.columnData($0, index: 0) else {
                        throw DistributedMeshStoreError.corruptStoredValue
                    }
                    return data
                }
            ) {
                guard existing == bytes else { throw DistributedMeshStoreError.eventIDCollision }
                return .duplicate
            }

            let storedEpoch = try membershipEpoch(for: event.trustGroupID)
            guard storedEpoch == event.membershipEpoch else {
                throw DistributedMeshStoreError.membershipEpochMismatch(
                    expected: storedEpoch ?? 0, actual: event.membershipEpoch
                )
            }

            let head = try authorHead(group: event.trustGroupID, endpoint: event.authorEndpointID)
            let expectedSequence = (head?.sequence ?? 0) + 1
            guard event.authorSequence == expectedSequence else {
                throw DistributedMeshStoreError.authorSequenceGap(
                    expected: expectedSequence, actual: event.authorSequence
                )
            }
            guard event.previousEventHash == head?.eventHash else {
                throw DistributedMeshStoreError.authorHashMismatch
            }
            if head != nil,
               let previousTimestamp = try authorTimestamp(
                   group: event.trustGroupID, endpoint: event.authorEndpointID,
                   sequence: event.authorSequence - 1
               ), event.hybridTimestamp <= previousTimestamp {
                throw DistributedMeshStoreError.nonMonotonicHybridTimestamp
            }

            try run(
                "INSERT INTO events(event_id, trust_group_id, author_endpoint_id, author_sequence, " +
                "membership_epoch, wall_time_ms, logical_time, entity_type, entity_id, operation, " +
                "envelope, event_hash) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [
                    .text(event.id.rawValue.uuidString),
                    .text(event.trustGroupID.rawValue.uuidString),
                    .text(event.authorEndpointID.rawValue),
                    .integer(Int64(event.authorSequence)),
                    .integer(Int64(event.membershipEpoch)),
                    .integer(event.hybridTimestamp.wallTimeMilliseconds),
                    .integer(Int64(event.hybridTimestamp.logical)),
                    .text(event.entity.type.rawValue), .text(event.entity.id),
                    .text(event.operation.rawValue), .blob(bytes), .blob(digest),
                ]
            )
            try run(
                "INSERT INTO author_heads(trust_group_id, author_endpoint_id, sequence, event_hash) " +
                "VALUES(?, ?, ?, ?) ON CONFLICT(trust_group_id, author_endpoint_id) DO UPDATE SET " +
                "sequence=excluded.sequence, event_hash=excluded.event_hash",
                [.text(event.trustGroupID.rawValue.uuidString),
                 .text(event.authorEndpointID.rawValue),
                 .integer(Int64(event.authorSequence)), .blob(digest)]
            )
            try materialize(event, envelope: bytes)
            return .inserted
        }
    }

    public func authorHeads(for group: MeshTrustGroupID) throws -> [MeshAuthorHead] {
        return try query(
            "SELECT author_endpoint_id, sequence, event_hash FROM author_heads " +
            "WHERE trust_group_id=? ORDER BY author_endpoint_id",
            [.text(group.rawValue.uuidString)]
        ) { statement in
            guard let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 0)),
                  let hash = Self.columnData(statement, index: 2) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return MeshAuthorHead(endpointID: endpoint,
                                  sequence: UInt64(sqlite3_column_int64(statement, 1)),
                                  eventHash: hash)
        }
    }

    public func events(for group: MeshTrustGroupID, author: MeshEndpointID,
                       after sequence: UInt64, limit: Int = 256) throws -> [MeshReplicatedEvent] {
        guard sequence <= UInt64(Int64.max) else {
            throw MeshReplicationValidationError.sequenceOutOfRange
        }
        return try query(
            "SELECT envelope FROM events WHERE trust_group_id=? AND author_endpoint_id=? " +
            "AND author_sequence>? ORDER BY author_sequence LIMIT ?",
            [.text(group.rawValue.uuidString), .text(author.rawValue),
             .integer(Int64(sequence)), .integer(Int64(max(1, min(limit, 1_024))))]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let event = try? JSONDecoder().decode(MeshReplicatedEvent.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return event
        }
    }

    public func syncVector(for group: MeshTrustGroupID) throws -> MeshSyncVector {
        guard let epoch = try membershipEpoch(for: group) else {
            throw DistributedMeshStoreError.membershipEpochMismatch(expected: 0, actual: 0)
        }
        let authors = try authorHeads(for: group).map {
            MeshAuthorSequence(endpointID: $0.endpointID, sequence: $0.sequence)
        }
        return try MeshSyncVector(
            trustGroupID: group, membershipEpoch: epoch, authors: authors
        )
    }

    /// Computes bounded requests for the ranges advertised by a remote peer but
    /// absent locally. Repeated vector exchange advances ranges larger than the
    /// protocol maximum without an unbounded allocation.
    public func missingRangeRequests(advertisedBy remote: MeshSyncVector,
                                     limit: Int = 256) throws -> [MeshEventRangeRequest] {
        try remote.validate()
        guard (1 ... MeshEventRangeRequest.maximumLimit).contains(limit) else {
            throw MeshReplicationValidationError.invalidRangeLimit
        }
        guard let localEpoch = try membershipEpoch(for: remote.trustGroupID),
              localEpoch == remote.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: remote.trustGroupID) ?? 0,
                actual: remote.membershipEpoch
            )
        }
        let local = try syncVector(for: remote.trustGroupID)
        return remote.authors.compactMap { author in
            let localSequence = local.sequence(for: author.endpointID)
            guard author.sequence > localSequence else { return nil }
            return MeshEventRangeRequest(
                trustGroupID: remote.trustGroupID,
                membershipEpoch: remote.membershipEpoch,
                authorEndpointID: author.endpointID,
                afterSequence: localSequence,
                limit: min(limit, Int(author.sequence - localSequence))
            )
        }
    }

    public func eventBatch(for request: MeshEventRangeRequest) throws -> [MeshReplicatedEvent] {
        try request.validate()
        guard let epoch = try membershipEpoch(for: request.trustGroupID),
              epoch == request.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: request.trustGroupID) ?? 0,
                actual: request.membershipEpoch
            )
        }
        return try events(
            for: request.trustGroupID, author: request.authorEndpointID,
            after: request.afterSequence, limit: request.limit
        )
    }

    /// Persists a peer's applied vector monotonically. An acknowledgement may
    /// not claim an event this replica does not possess.
    public func acknowledge(_ vector: MeshSyncVector, from peer: MeshDeviceID) throws {
        try vector.validate()
        guard let epoch = try membershipEpoch(for: vector.trustGroupID),
              epoch == vector.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: vector.trustGroupID) ?? 0,
                actual: vector.membershipEpoch
            )
        }
        try transaction {
            for author in vector.authors {
                let local = try authorHead(
                    group: vector.trustGroupID, endpoint: author.endpointID
                )?.sequence ?? 0
                guard author.sequence <= local else {
                    throw DistributedMeshStoreError.acknowledgementBeyondLocalHead(
                        local: local, proposed: author.sequence
                    )
                }
                let current = try acknowledgement(
                    group: vector.trustGroupID, peer: peer, author: author.endpointID
                )
                guard current == nil || author.sequence >= current! else {
                    throw DistributedMeshStoreError.acknowledgementRegression(
                        current: current!, proposed: author.sequence
                    )
                }
                try run(
                    "INSERT INTO peer_acknowledgements(trust_group_id, peer_device_id, " +
                    "author_endpoint_id, sequence) VALUES(?, ?, ?, ?) " +
                    "ON CONFLICT(trust_group_id, peer_device_id, author_endpoint_id) DO UPDATE SET " +
                    "sequence=excluded.sequence",
                    [.text(vector.trustGroupID.rawValue.uuidString),
                     .text(peer.rawValue.uuidString), .text(author.endpointID.rawValue),
                     .integer(Int64(author.sequence))]
                )
            }
        }
    }

    public func acknowledgementVector(for group: MeshTrustGroupID,
                                      peer: MeshDeviceID) throws -> MeshSyncVector {
        guard let epoch = try membershipEpoch(for: group) else {
            throw DistributedMeshStoreError.membershipEpochMismatch(expected: 0, actual: 0)
        }
        let authors = try query(
            "SELECT author_endpoint_id, sequence FROM peer_acknowledgements " +
            "WHERE trust_group_id=? AND peer_device_id=? ORDER BY author_endpoint_id",
            [.text(group.rawValue.uuidString), .text(peer.rawValue.uuidString)]
        ) { statement in
            guard let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 0)) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return MeshAuthorSequence(
                endpointID: endpoint, sequence: UInt64(sqlite3_column_int64(statement, 1))
            )
        }
        return try MeshSyncVector(
            trustGroupID: group, membershipEpoch: epoch, authors: authors
        )
    }

    public func materializedFields(for entity: MeshEntityReference,
                                   in group: MeshTrustGroupID) throws -> [MeshMaterializedField] {
        try ensureMaterializedState()
        return try query(
            "SELECT field_name, value, is_deleted, source_event_id, wall_time_ms, logical_time, " +
            "author_endpoint_id FROM materialized_registers WHERE trust_group_id=? " +
            "AND entity_type=? AND entity_id=? ORDER BY field_name",
            [.text(group.rawValue.uuidString), .text(entity.type.rawValue), .text(entity.id)]
        ) { statement in
            guard let eventUUID = UUID(uuidString: Self.columnText(statement, index: 3)),
                  let eventID = MeshEventID(rawValue: eventUUID),
                  let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 6)) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return MeshMaterializedField(
                field: Self.columnText(statement, index: 0),
                value: Self.columnData(statement, index: 1),
                isDeleted: sqlite3_column_int64(statement, 2) != 0,
                sourceEventID: eventID,
                timestamp: MeshHybridTimestamp(
                    wallTimeMilliseconds: sqlite3_column_int64(statement, 4),
                    logical: UInt32(sqlite3_column_int64(statement, 5))
                ),
                authorEndpointID: endpoint
            )
        }
    }

    public func materializedImmutableValue(for entity: MeshEntityReference,
                                           in group: MeshTrustGroupID) throws -> Data? {
        try ensureMaterializedState()
        return try queryOne(
            "SELECT value FROM materialized_entities WHERE trust_group_id=? " +
            "AND entity_type=? AND entity_id=?",
            [.text(group.rawValue.uuidString), .text(entity.type.rawValue), .text(entity.id)]
        ) { statement in
            guard let value = Self.columnData(statement, index: 0) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return value
        }
    }

    public func quarantinedEvents() throws -> [MeshQuarantinedEvent] {
        try ensureMaterializedState()
        return try query(
            "SELECT event_id, reason, received_at_ms FROM quarantined_events " +
            "ORDER BY received_at_ms, event_id"
        ) { statement in
            guard let uuid = UUID(uuidString: Self.columnText(statement, index: 0)),
                  let eventID = MeshEventID(rawValue: uuid) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return MeshQuarantinedEvent(
                eventID: eventID, reason: Self.columnText(statement, index: 1),
                receivedAtMilliseconds: sqlite3_column_int64(statement, 2)
            )
        }
    }

    /// Replays retained events into derived tables. This is safe after an
    /// interrupted migration because materialized state is disposable and the
    /// immutable event log remains the source of truth.
    public func rebuildMaterializedState() throws {
        let retained = try query(
            "SELECT envelope FROM events ORDER BY wall_time_ms, logical_time, " +
            "author_endpoint_id, event_id"
        ) { statement -> (MeshReplicatedEvent, Data) in
            guard let data = Self.columnData(statement, index: 0),
                  let event = try? JSONDecoder().decode(MeshReplicatedEvent.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (event, data)
        }
        try transaction {
            try run("DELETE FROM materialized_registers")
            try run("DELETE FROM materialized_entities")
            try run("DELETE FROM quarantined_events")
            for (event, envelope) in retained {
                try materialize(event, envelope: envelope)
            }
            try run("UPDATE materialization_metadata SET version=1")
        }
        materializationNeedsRebuild = false
    }

    private func ensureMaterializedState() throws {
        if materializationNeedsRebuild {
            try rebuildMaterializedState()
        }
    }

    /// Creates the durable accepted receipt that gates side effects. A retry by
    /// command ID or idempotency key returns the original receipt unchanged.
    public func accept(_ command: MeshHostCommand, on host: MeshDeviceID,
                       currentResourceGeneration: UInt64,
                       acceptedAt: MeshHybridTimestamp) throws -> MeshCommandReceipt {
        try command.validate()
        guard command.targetHostDeviceID == host else {
            throw DistributedMeshStoreError.wrongCommandHost
        }

        let fingerprint = Data(SHA256.hash(data: try command.canonicalIdempotencyBytes()))
        return try transaction {
            if let existing = try storedReceipt(commandID: command.id,
                                                idempotencyKey: command.idempotencyKey) {
                guard existing.fingerprint == fingerprint else {
                    throw DistributedMeshStoreError.idempotencyCollision
                }
                return existing.receipt
            }
            guard command.expectedResourceGeneration == currentResourceGeneration else {
                throw DistributedMeshStoreError.commandGenerationMismatch(
                    expected: currentResourceGeneration, actual: command.expectedResourceGeneration
                )
            }
            let receipt = MeshCommandReceipt(
                commandID: command.id, idempotencyKey: command.idempotencyKey,
                hostDeviceID: host, resourceID: command.resourceID,
                resourceGeneration: currentResourceGeneration, state: .accepted,
                acceptedAt: acceptedAt, updatedAt: acceptedAt
            )
            try run(
                "INSERT INTO command_receipts(command_id, idempotency_key, command_fingerprint, " +
                "host_device_id, resource_id, resource_generation, state, receipt) " +
                "VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(command.id.rawValue.uuidString), .text(command.idempotencyKey),
                 .blob(fingerprint), .text(host.rawValue.uuidString), .text(command.resourceID.rawValue),
                 .integer(Int64(currentResourceGeneration)), .text(receipt.state.rawValue),
                 .blob(try MeshCanonicalStoreJSON.encode(receipt))]
            )
            return receipt
        }
    }

    public func commandReceipt(id: MeshCommandID) throws -> MeshCommandReceipt? {
        try queryOne(
            "SELECT receipt FROM command_receipts WHERE command_id=? LIMIT 1",
            [.text(id.rawValue.uuidString)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let value = try? JSONDecoder().decode(MeshCommandReceipt.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return value
        }
    }

    public func transitionReceipt(commandID: MeshCommandID, to next: MeshCommandReceiptState,
                                  at timestamp: MeshHybridTimestamp, result: Data? = nil,
                                  failureCode: String? = nil) throws -> MeshCommandReceipt {
        try transaction {
            guard var current = try commandReceipt(id: commandID) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try current.validateTransition(to: next)
            current.state = next
            current.updatedAt = timestamp
            current.result = result
            current.failureCode = failureCode
            try run(
                "UPDATE command_receipts SET state=?, receipt=? WHERE command_id=?",
                [.text(next.rawValue), .blob(try MeshCanonicalStoreJSON.encode(current)),
                 .text(commandID.rawValue.uuidString)]
            )
            return current
        }
    }

    private func storedReceipt(commandID: MeshCommandID, idempotencyKey: String) throws
        -> (receipt: MeshCommandReceipt, fingerprint: Data)? {
        try queryOne(
            "SELECT receipt, command_fingerprint FROM command_receipts " +
            "WHERE command_id=? OR idempotency_key=? LIMIT 1",
            [.text(commandID.rawValue.uuidString), .text(idempotencyKey)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let fingerprint = Self.columnData(statement, index: 1),
                  let value = try? JSONDecoder().decode(MeshCommandReceipt.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (value, fingerprint)
        }
    }

    private func authorHead(group: MeshTrustGroupID,
                            endpoint: MeshEndpointID) throws -> MeshAuthorHead? {
        try queryOne(
            "SELECT sequence, event_hash FROM author_heads WHERE trust_group_id=? AND author_endpoint_id=?",
            [.text(group.rawValue.uuidString), .text(endpoint.rawValue)]
        ) { statement in
            guard let hash = Self.columnData(statement, index: 1) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return MeshAuthorHead(endpointID: endpoint,
                                  sequence: UInt64(sqlite3_column_int64(statement, 0)),
                                  eventHash: hash)
        }
    }

    private func authorTimestamp(group: MeshTrustGroupID, endpoint: MeshEndpointID,
                                 sequence: UInt64) throws -> MeshHybridTimestamp? {
        try queryOne(
            "SELECT wall_time_ms, logical_time FROM events WHERE trust_group_id=? " +
            "AND author_endpoint_id=? AND author_sequence=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(endpoint.rawValue),
             .integer(Int64(sequence))]
        ) { statement in
            MeshHybridTimestamp(
                wallTimeMilliseconds: sqlite3_column_int64(statement, 0),
                logical: UInt32(sqlite3_column_int64(statement, 1))
            )
        }
    }

    private func acknowledgement(group: MeshTrustGroupID, peer: MeshDeviceID,
                                 author: MeshEndpointID) throws -> UInt64? {
        try queryOne(
            "SELECT sequence FROM peer_acknowledgements WHERE trust_group_id=? " +
            "AND peer_device_id=? AND author_endpoint_id=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(peer.rawValue.uuidString),
             .text(author.rawValue)]
        ) { UInt64(sqlite3_column_int64($0, 0)) }
    }

    private func materialize(_ event: MeshReplicatedEvent, envelope: Data) throws {
        if event.operation == .fieldSetV1 {
            do {
                let mutation = try JSONDecoder().decode(MeshFieldMutation.self, from: event.payload)
                try mutation.validate()
                try materializeField(mutation, from: event)
            } catch {
                try quarantineSemantic(
                    event: event, envelope: envelope, reason: "invalid-field-mutation"
                )
            }
        } else if event.operation == .immutablePutV1 {
            try materializeImmutable(event)
        }
    }

    private func materializeField(_ mutation: MeshFieldMutation,
                                  from event: MeshReplicatedEvent) throws {
        let existing = try queryOne(
            "SELECT wall_time_ms, logical_time, author_endpoint_id, source_event_id " +
            "FROM materialized_registers WHERE trust_group_id=? AND entity_type=? " +
            "AND entity_id=? AND field_name=? LIMIT 1",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id), .text(mutation.field)]
        ) { statement -> (MeshHybridTimestamp, MeshEndpointID, MeshEventID) in
            guard let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 2)),
                  let uuid = UUID(uuidString: Self.columnText(statement, index: 3)),
                  let eventID = MeshEventID(rawValue: uuid) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (
                MeshHybridTimestamp(
                    wallTimeMilliseconds: sqlite3_column_int64(statement, 0),
                    logical: UInt32(sqlite3_column_int64(statement, 1))
                ), endpoint, eventID
            )
        }
        if let existing,
           !Self.materializationStamp(
               timestamp: event.hybridTimestamp, endpoint: event.authorEndpointID, eventID: event.id,
               winsOver: existing
           ) {
            return
        }
        try run(
            "INSERT INTO materialized_registers(trust_group_id, entity_type, entity_id, " +
            "field_name, value, is_deleted, source_event_id, wall_time_ms, logical_time, " +
            "author_endpoint_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT(trust_group_id, entity_type, entity_id, field_name) DO UPDATE SET " +
            "value=excluded.value, is_deleted=excluded.is_deleted, " +
            "source_event_id=excluded.source_event_id, wall_time_ms=excluded.wall_time_ms, " +
            "logical_time=excluded.logical_time, author_endpoint_id=excluded.author_endpoint_id",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id), .text(mutation.field),
             mutation.value.map(Binding.blob) ?? .null,
             .integer(mutation.isDeleted ? 1 : 0), .text(event.id.rawValue.uuidString),
             .integer(event.hybridTimestamp.wallTimeMilliseconds),
             .integer(Int64(event.hybridTimestamp.logical)),
             .text(event.authorEndpointID.rawValue)]
        )
    }

    private func materializeImmutable(_ event: MeshReplicatedEvent) throws {
        let existing = try queryOne(
            "SELECT e.envelope FROM materialized_entities m JOIN events e " +
            "ON e.event_id=m.source_event_id WHERE m.trust_group_id=? AND m.entity_type=? " +
            "AND m.entity_id=? LIMIT 1",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id)]
        ) { statement -> MeshReplicatedEvent in
            guard let data = Self.columnData(statement, index: 0),
                  let value = try? JSONDecoder().decode(MeshReplicatedEvent.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return value
        }
        // Immutable-ID collisions resolve to the earliest deterministic stamp,
        // independent of arrival order. Normal UUIDv7 entity IDs never collide.
        if let existing,
           !Self.materializationStamp(
               timestamp: existing.hybridTimestamp, endpoint: existing.authorEndpointID,
               eventID: existing.id,
               winsOver: (event.hybridTimestamp, event.authorEndpointID, event.id)
           ) {
            return
        }
        try run(
            "INSERT INTO materialized_entities(trust_group_id, entity_type, entity_id, value, " +
            "source_event_id) VALUES(?, ?, ?, ?, ?) " +
            "ON CONFLICT(trust_group_id, entity_type, entity_id) DO UPDATE SET " +
            "value=excluded.value, source_event_id=excluded.source_event_id",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id), .blob(event.payload), .text(event.id.rawValue.uuidString)]
        )
    }

    private func quarantineSemantic(event: MeshReplicatedEvent, envelope: Data,
                                    reason: String) throws {
        try run(
            "INSERT INTO quarantined_events(event_id, reason, envelope, received_at_ms) " +
            "VALUES(?, ?, ?, ?) ON CONFLICT(event_id) DO UPDATE SET reason=excluded.reason, " +
            "envelope=excluded.envelope, received_at_ms=excluded.received_at_ms",
            [.text(event.id.rawValue.uuidString), .text(reason), .blob(envelope),
             .integer(Self.currentMilliseconds())]
        )
    }

    private static func currentMilliseconds() -> Int64 {
        let value = Date().timeIntervalSince1970 * 1_000
        if !value.isFinite { return 0 }
        return Int64(max(Double(Int64.min), min(Double(Int64.max), value)))
    }

    private static func materializationStamp(
        timestamp: MeshHybridTimestamp, endpoint: MeshEndpointID, eventID: MeshEventID,
        winsOver existing: (MeshHybridTimestamp, MeshEndpointID, MeshEventID)
    ) -> Bool {
        if timestamp != existing.0 { return timestamp > existing.0 }
        if endpoint != existing.1 { return endpoint > existing.1 }
        return eventID > existing.2
    }

    private func invitationRecord(nonceDigest: Data) throws
        -> (record: MeshInvitationUseRecord, consumedAtMilliseconds: Int64?)? {
        try queryOne(
            "SELECT trust_group_id, membership_epoch, invitation_digest, nonce_digest, " +
            "expires_at_ms, consumed_at_ms FROM pairing_invitations WHERE nonce_digest=? LIMIT 1",
            [.blob(nonceDigest)]
        ) { statement in
            guard let groupUUID = UUID(uuidString: Self.columnText(statement, index: 0)),
                  let invitationDigest = Self.columnData(statement, index: 2),
                  let storedNonceDigest = Self.columnData(statement, index: 3) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            let consumed = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 5)
            return (
                MeshInvitationUseRecord(
                    trustGroupID: MeshTrustGroupID(rawValue: groupUUID),
                    membershipEpoch: UInt64(sqlite3_column_int64(statement, 1)),
                    invitationDigest: invitationDigest,
                    nonceDigest: storedNonceDigest,
                    expiresAtMilliseconds: sqlite3_column_int64(statement, 4)
                ),
                consumed
            )
        }
    }

    private func trustedDeviceMatching(group: MeshTrustGroupID, deviceID: MeshDeviceID,
                                       endpointID: MeshEndpointID) throws -> MeshPairedDevice? {
        try queryOne(
            "SELECT envelope FROM trusted_devices WHERE trust_group_id=? " +
            "AND (device_id=? OR endpoint_id=?) LIMIT 1",
            [.text(group.rawValue.uuidString), .text(deviceID.rawValue.uuidString),
             .text(endpointID.rawValue)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let device = try? JSONDecoder().decode(MeshPairedDevice.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return device
        }
    }

    private enum Binding {
        case integer(Int64)
        case text(String)
        case blob(Data)
        case null
    }

    private func run(_ sql: String, _ bindings: [Binding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw sqliteError(result) }
    }

    private func query<T>(_ sql: String, _ bindings: [Binding] = [],
                          transform: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: values.append(try transform(statement))
            case SQLITE_DONE: return values
            case let code: throw sqliteError(code)
            }
        }
    }

    private func queryOne<T>(_ sql: String, _ bindings: [Binding] = [],
                             transform: (OpaquePointer) throws -> T) throws -> T? {
        try query(sql, bindings, transform: transform).first
    }

    private func scalarText(_ sql: String) throws -> String? {
        try queryOne(sql) { Self.columnText($0, index: 0) }
    }

    private func scalarInt64(_ sql: String) throws -> Int64? {
        try queryOne(sql) { sqlite3_column_int64($0, 0) }
    }

    private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(result) }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32 = switch binding {
                case .integer(let value): sqlite3_bind_int64(statement, index, value)
                case .text(let value):
                    value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
                case .blob(let data):
                    data.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient)
                    }
                case .null: sqlite3_bind_null(statement, index)
                }
                guard code == SQLITE_OK else { throw sqliteError(code) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Self.execute(database, sql: "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try Self.execute(database, sql: "COMMIT")
            return value
        } catch {
            try? Self.execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func sqliteError(_ code: Int32) -> DistributedMeshStoreError {
        .sqlite(code: code, message: String(cString: sqlite3_errmsg(database)))
    }

    private static func execute(_ database: OpaquePointer, sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw DistributedMeshStoreError.sqlite(code: result, message: text)
        }
    }

    private static func readSchemaVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*), MIN(version), MAX(version) FROM schema_metadata",
            -1, &statement, nil
        )
        guard prepareResult == SQLITE_OK, let statement else {
            throw DistributedMeshStoreError.sqlite(
                code: prepareResult, message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw DistributedMeshStoreError.sqlite(
                code: stepResult, message: String(cString: sqlite3_errmsg(database))
            )
        }
        let count = sqlite3_column_int64(statement, 0)
        let minimum = sqlite3_column_int64(statement, 1)
        let maximum = sqlite3_column_int64(statement, 2)
        guard count == 1, minimum == maximum else {
            throw DistributedMeshStoreError.corruptStoredValue
        }
        return Int(minimum)
    }

    private static func readMaterializationVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*), MIN(version), MAX(version) FROM materialization_metadata",
            -1, &statement, nil
        )
        guard result == SQLITE_OK, let statement else {
            throw DistributedMeshStoreError.sqlite(
                code: result, message: String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw DistributedMeshStoreError.sqlite(
                code: step, message: String(cString: sqlite3_errmsg(database))
            )
        }
        guard sqlite3_column_int64(statement, 0) == 1,
              sqlite3_column_int64(statement, 1) == sqlite3_column_int64(statement, 2) else {
            throw DistributedMeshStoreError.corruptStoredValue
        }
        return Int(sqlite3_column_int64(statement, 1))
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static let schemaMetadata = """
    CREATE TABLE IF NOT EXISTS schema_metadata(version INTEGER NOT NULL);
    INSERT INTO schema_metadata(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM schema_metadata);
    """

    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS membership_epochs(
      trust_group_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL CHECK(epoch > 0));
    CREATE TABLE IF NOT EXISTS events(
      event_id TEXT PRIMARY KEY, trust_group_id TEXT NOT NULL, author_endpoint_id TEXT NOT NULL,
      author_sequence INTEGER NOT NULL, membership_epoch INTEGER NOT NULL,
      wall_time_ms INTEGER NOT NULL, logical_time INTEGER NOT NULL,
      entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL,
      envelope BLOB NOT NULL, event_hash BLOB NOT NULL CHECK(length(event_hash)=32),
      UNIQUE(trust_group_id, author_endpoint_id, author_sequence));
    CREATE INDEX IF NOT EXISTS events_entity ON events(trust_group_id, entity_type, entity_id);
    CREATE TABLE IF NOT EXISTS author_heads(
      trust_group_id TEXT NOT NULL, author_endpoint_id TEXT NOT NULL,
      sequence INTEGER NOT NULL, event_hash BLOB NOT NULL CHECK(length(event_hash)=32),
      PRIMARY KEY(trust_group_id, author_endpoint_id));
    CREATE TABLE IF NOT EXISTS peer_acknowledgements(
      trust_group_id TEXT NOT NULL, peer_device_id TEXT NOT NULL, author_endpoint_id TEXT NOT NULL,
      sequence INTEGER NOT NULL, PRIMARY KEY(trust_group_id, peer_device_id, author_endpoint_id));
    CREATE TABLE IF NOT EXISTS materialized_entities(
      trust_group_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      value BLOB NOT NULL, source_event_id TEXT NOT NULL,
      PRIMARY KEY(trust_group_id, entity_type, entity_id));
    CREATE TABLE IF NOT EXISTS blob_manifests(
      digest BLOB PRIMARY KEY CHECK(length(digest)=32), byte_size INTEGER NOT NULL,
      media_type TEXT, local_state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS snapshots(
      snapshot_id TEXT PRIMARY KEY, trust_group_id TEXT NOT NULL, envelope BLOB NOT NULL,
      created_at_ms INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS quarantined_events(
      event_id TEXT PRIMARY KEY, reason TEXT NOT NULL, envelope BLOB NOT NULL,
      received_at_ms INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS command_receipts(
      command_id TEXT PRIMARY KEY, idempotency_key TEXT NOT NULL UNIQUE,
      command_fingerprint BLOB NOT NULL CHECK(length(command_fingerprint)=32),
      host_device_id TEXT NOT NULL, resource_id TEXT NOT NULL,
      resource_generation INTEGER NOT NULL, state TEXT NOT NULL, receipt BLOB NOT NULL);
    """

    private static let schemaV2 = """
    CREATE TABLE IF NOT EXISTS pairing_invitations(
      trust_group_id TEXT NOT NULL,
      membership_epoch INTEGER NOT NULL CHECK(membership_epoch > 0),
      invitation_digest BLOB NOT NULL UNIQUE CHECK(length(invitation_digest)=32),
      nonce_digest BLOB PRIMARY KEY CHECK(length(nonce_digest)=32),
      expires_at_ms INTEGER NOT NULL, consumed_at_ms INTEGER);
    CREATE INDEX IF NOT EXISTS pairing_invitations_expiry
      ON pairing_invitations(expires_at_ms) WHERE consumed_at_ms IS NULL;
    CREATE TABLE IF NOT EXISTS trusted_devices(
      trust_group_id TEXT NOT NULL, device_id TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      membership_epoch INTEGER NOT NULL CHECK(membership_epoch > 0), envelope BLOB NOT NULL,
      PRIMARY KEY(trust_group_id, device_id), UNIQUE(trust_group_id, endpoint_id));
    UPDATE schema_metadata SET version=2;
    """

    private static let schemaV3 = """
    CREATE TABLE IF NOT EXISTS materialized_registers(
      trust_group_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      field_name TEXT NOT NULL, value BLOB, is_deleted INTEGER NOT NULL CHECK(is_deleted IN (0, 1)),
      source_event_id TEXT NOT NULL, wall_time_ms INTEGER NOT NULL,
      logical_time INTEGER NOT NULL, author_endpoint_id TEXT NOT NULL,
      PRIMARY KEY(trust_group_id, entity_type, entity_id, field_name));
    CREATE INDEX IF NOT EXISTS materialized_registers_source
      ON materialized_registers(source_event_id);
    CREATE TABLE IF NOT EXISTS materialization_metadata(version INTEGER NOT NULL);
    INSERT INTO materialization_metadata(version)
      SELECT 0 WHERE NOT EXISTS(SELECT 1 FROM materialization_metadata);
    UPDATE schema_metadata SET version=3;
    """
}

extension DistributedMeshStore: MeshInvitationUseStore {}

private enum MeshCanonicalStoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
