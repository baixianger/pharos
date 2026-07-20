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
    case snapshotDoesNotCoverLocalHead(MeshEndpointID)
    case snapshotHeadHashMismatch(MeshEndpointID)
    case snapshotNotFound
    case snapshotIDCollision
    case snapshotCheckpointUnavailable(MeshEndpointID)
    case compactionNotAcknowledged(peer: MeshDeviceID, author: MeshEndpointID,
                                   required: UInt64, actual: UInt64)
    case wrongCommandHost
    case wrongCommandEndpoint
    case commandSenderNotTrusted
    case commandSenderUnauthorized
    case hostIdentityMismatch
    case hostResourceNotFound
    case hostResourceRetired
    case resourceGenerationOverflow
    case commandGenerationMismatch(expected: UInt64, actual: UInt64)
    case idempotencyCollision
    case rpcPeerNotTrusted
    case migrationNotPrepared
    case migrationInventoryMismatch
    case migrationGenerationMismatch(expected: UInt64, actual: UInt64)
    case invalidMigrationTransition(from: MeshMigrationMode, to: MeshMigrationMode)
    case distributedWritesDisabled(MeshMigrationMode)
    case unsafeDatabasePath
    case corruptStoredValue
    case unsupportedSchemaVersion(Int)
}

public enum MeshEventInsertion: Equatable, Sendable {
    case inserted
    case duplicate
}

public enum MeshBlobChunkInsertion: Equatable, Sendable {
    case inserted
    case duplicate
}

public enum MeshBlobStoreError: Error, Equatable, Sendable {
    case manifestCollision
    case notRegistered
    case chunkCollision
    case incomplete
    case unavailable
    case unsafeStoragePath
    case fileIO
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
    public nonisolated static let currentSchemaVersion = 7
    private let databaseAddress: UInt
    private let blobDirectoryPath: String
    private var materializationNeedsRebuild: Bool
    private var database: OpaquePointer { OpaquePointer(bitPattern: databaseAddress)! }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        try Self.validateDatabaseLocation(databaseURL)
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
            guard (1 ... Self.currentSchemaVersion).contains(version) else {
                throw DistributedMeshStoreError.unsupportedSchemaVersion(version)
            }
            requiresMaterializationRebuild = version < 3
            try Self.execute(handle, sql: Self.schemaV1)
            try Self.execute(handle, sql: Self.schemaV2)
            try Self.execute(handle, sql: Self.schemaV3)
            try Self.execute(handle, sql: Self.schemaV4)
            try Self.execute(handle, sql: Self.schemaV5)
            try Self.execute(handle, sql: Self.schemaV6)
            try Self.execute(handle, sql: Self.schemaV7)
            let materializationVersion = try Self.readMaterializationVersion(handle)
            requiresMaterializationRebuild = version < 4 || materializationVersion != 2
            try Self.execute(handle, sql: "COMMIT")
            try Self.secureDatabaseFiles(databaseURL)
        } catch {
            try? Self.execute(handle, sql: "ROLLBACK")
            sqlite3_close(handle)
            throw error
        }
        databaseAddress = UInt(bitPattern: handle)
        blobDirectoryPath = databaseURL.deletingLastPathComponent()
            .appendingPathComponent(databaseURL.lastPathComponent + ".blobs", isDirectory: true)
            .path
        materializationNeedsRebuild = requiresMaterializationRebuild
    }

    private static func validateDatabaseLocation(_ databaseURL: URL) throws {
        let parent = databaseURL.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw DistributedMeshStoreError.unsafeDatabasePath
        }
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        let values = try databaseURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw DistributedMeshStoreError.unsafeDatabasePath
        }
    }

    private static func secureDatabaseFiles(_ databaseURL: URL) throws {
        for file in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DistributedMeshStoreError.unsafeDatabasePath
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path
            )
        }
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

    public func migrationState(
        for group: MeshTrustGroupID
    ) throws -> MeshMigrationCutoverState? {
        try queryOne(
            "SELECT envelope FROM migration_cutovers WHERE trust_group_id=?",
            [.text(group.rawValue.uuidString)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let state = try? JSONDecoder().decode(
                    MeshMigrationCutoverState.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            try state.validate()
            return state
        }
    }

    /// Starts (or idempotently resumes) a read-only distributed shadow. This
    /// never changes the legacy store and does not grant distributed writes.
    public func prepareMigration(
        for group: MeshTrustGroupID, inventoryDigest: Data,
        at timestamp: MeshHybridTimestamp
    ) throws -> MeshMigrationCutoverState {
        guard inventoryDigest.count == 32 else {
            throw MeshMigrationValidationError.invalidInventoryDigest
        }
        return try transaction {
            if let existing = try migrationState(for: group) {
                guard existing.inventoryDigest == inventoryDigest else {
                    throw DistributedMeshStoreError.migrationInventoryMismatch
                }
                return existing
            }
            let state = MeshMigrationCutoverState(
                trustGroupID: group, inventoryDigest: inventoryDigest,
                generation: 1, mode: .shadow, updatedAt: timestamp
            )
            try storeMigrationState(state)
            return state
        }
    }

    /// Atomically transfers write authority to the distributed replica after
    /// the caller has frozen legacy writes and verified the final inventory.
    public func cutOverMigration(
        for group: MeshTrustGroupID, inventoryDigest: Data,
        expectedGeneration: UInt64, at timestamp: MeshHybridTimestamp
    ) throws -> MeshMigrationCutoverState {
        try transitionMigration(
            for: group, inventoryDigest: inventoryDigest,
            expectedGeneration: expectedGeneration, to: .distributed,
            at: timestamp
        )
    }

    /// Records a newly verified shadow/final-delta inventory without changing
    /// write authority. A distributed-authoritative group must roll back before
    /// importing legacy state again.
    public func refreshMigrationInventory(
        for group: MeshTrustGroupID, inventoryDigest: Data,
        expectedGeneration: UInt64, at timestamp: MeshHybridTimestamp
    ) throws -> MeshMigrationCutoverState {
        guard inventoryDigest.count == 32 else {
            throw MeshMigrationValidationError.invalidInventoryDigest
        }
        return try transaction {
            guard let current = try migrationState(for: group) else {
                throw DistributedMeshStoreError.migrationNotPrepared
            }
            guard current.generation == expectedGeneration else {
                throw DistributedMeshStoreError.migrationGenerationMismatch(
                    expected: current.generation, actual: expectedGeneration
                )
            }
            guard current.mode != .distributed else {
                throw DistributedMeshStoreError.invalidMigrationTransition(
                    from: current.mode, to: current.mode
                )
            }
            guard current.generation < UInt64(Int64.max) else {
                throw MeshMigrationValidationError.invalidGeneration
            }
            if current.inventoryDigest == inventoryDigest { return current }
            let next = MeshMigrationCutoverState(
                trustGroupID: group, inventoryDigest: inventoryDigest,
                generation: current.generation + 1, mode: current.mode,
                updatedAt: timestamp
            )
            try storeMigrationState(next)
            return next
        }
    }

    /// One-command rollback: distributed becomes read-only and legacy regains
    /// write authority. Both stores remain intact for audit and re-cutover.
    public func rollBackMigration(
        for group: MeshTrustGroupID, inventoryDigest: Data,
        expectedGeneration: UInt64, at timestamp: MeshHybridTimestamp
    ) throws -> MeshMigrationCutoverState {
        try transitionMigration(
            for: group, inventoryDigest: inventoryDigest,
            expectedGeneration: expectedGeneration, to: .rolledBack,
            at: timestamp
        )
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

    /// Resolves the authenticated transport identity only when it belongs to
    /// the exact current membership epoch. Old rows remain available for audit
    /// and rollback, but cannot authorize a new RPC after revocation advances
    /// the epoch.
    public func trustedDevice(in group: MeshTrustGroupID,
                              endpointID: MeshEndpointID,
                              membershipEpoch: UInt64) throws -> MeshPairedDevice? {
        guard membershipEpoch <= UInt64(Int64.max) else { return nil }
        return try queryOne(
            "SELECT envelope FROM trusted_devices WHERE trust_group_id=? " +
            "AND endpoint_id=? AND membership_epoch=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(endpointID.rawValue),
             .integer(Int64(membershipEpoch))]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let device = try? JSONDecoder().decode(MeshPairedDevice.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try device.validateBinding()
            return device
        }
    }

    public func authorizeReplicaRPCPeer(
        in group: MeshTrustGroupID, endpointID: MeshEndpointID,
        membershipEpoch: UInt64
    ) throws -> MeshPairedDevice {
        try requireReplicaRPCPeer(
            in: group, endpointID: endpointID,
            membershipEpoch: membershipEpoch
        )
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
            try requireDistributedWriteAuthorityIfMigrating(event.trustGroupID)

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

    public func syncVector(
        for group: MeshTrustGroupID, requestedBy endpointID: MeshEndpointID,
        membershipEpoch: UInt64
    ) throws -> MeshSyncVector {
        _ = try requireReplicaRPCPeer(
            in: group, endpointID: endpointID,
            membershipEpoch: membershipEpoch
        )
        return try syncVector(for: group)
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

    /// Returns a contiguous event range, an explicit caught-up marker, or the
    /// latest covering snapshot when the requested prefix has been compacted.
    public func syncResponse(for request: MeshEventRangeRequest) throws
        -> MeshEventRangeResponse {
        let batch = try eventBatch(for: request)
        if let first = batch.first, first.authorSequence == request.afterSequence + 1 {
            let response = MeshEventRangeResponse(
                request: request, kind: .events, events: batch
            )
            try response.validate()
            return response
        }
        let head = try authorHead(
            group: request.trustGroupID, endpoint: request.authorEndpointID
        )?.sequence ?? 0
        if head <= request.afterSequence {
            let response = MeshEventRangeResponse(request: request, kind: .upToDate)
            try response.validate()
            return response
        }
        guard let snapshot = try coveringSnapshot(
            in: request.trustGroupID, author: request.authorEndpointID,
            after: request.afterSequence
        ) else {
            throw DistributedMeshStoreError.snapshotNotFound
        }
        let response = MeshEventRangeResponse(
            request: request, kind: .snapshot, snapshot: snapshot
        )
        try response.validate()
        return response
    }

    public func syncResponse(
        for request: MeshEventRangeRequest,
        requestedBy endpointID: MeshEndpointID
    ) throws -> MeshEventRangeResponse {
        _ = try requireReplicaRPCPeer(
            in: request.trustGroupID, endpointID: endpointID,
            membershipEpoch: request.membershipEpoch
        )
        return try syncResponse(for: request)
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

    public func acknowledge(
        _ vector: MeshSyncVector, requestedBy endpointID: MeshEndpointID
    ) throws {
        let peer = try requireReplicaRPCPeer(
            in: vector.trustGroupID, endpointID: endpointID,
            membershipEpoch: vector.membershipEpoch
        )
        try acknowledge(vector, from: peer.descriptor.id)
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
            "SELECT value FROM materialized_immutable_values WHERE trust_group_id=? " +
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

    public func createSnapshot(
        for group: MeshTrustGroupID,
        identity: MeshDeviceIdentity,
        createdAt: MeshHybridTimestamp
    ) throws -> MeshReplicaSnapshotBundle {
        try ensureMaterializedState()
        guard let epoch = try membershipEpoch(for: group) else {
            throw DistributedMeshStoreError.membershipEpochMismatch(expected: 0, actual: 0)
        }
        let heads = try authorHeads(for: group).map {
            MeshSnapshotAuthorHead(
                endpointID: $0.endpointID, sequence: $0.sequence, eventHash: $0.eventHash
            )
        }
        let fields = try snapshotFields(in: group)
        let immutableValues = try snapshotImmutableValues(in: group)
        let state = try MeshReplicaState(
            fields: fields, immutableValues: immutableValues
        )
        return try MeshReplicaSnapshotCrypto.make(
            trustGroupID: group, membershipEpoch: epoch, identity: identity,
            createdAt: createdAt, authorHeads: heads, state: state
        )
    }

    public func persistSnapshot(_ bundle: MeshReplicaSnapshotBundle,
                                creatorPublicKey: Data) throws {
        try MeshReplicaSnapshotCrypto.verify(bundle, creatorPublicKey: creatorPublicKey)
        guard let epoch = try membershipEpoch(for: bundle.snapshot.trustGroupID),
              epoch == bundle.snapshot.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: bundle.snapshot.trustGroupID) ?? 0,
                actual: bundle.snapshot.membershipEpoch
            )
        }
        let envelope = try MeshCanonicalStoreJSON.encode(bundle)
        guard envelope.count <= DistributedMeshProtocol.maximumBlobBytes +
                DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSnapshotValidationError.snapshotTooLarge
        }
        try transaction {
            try storeSnapshot(bundle, envelope: envelope)
        }
    }

    /// Installs a trusted snapshot atomically. Local heads may advance but never
    /// regress or fork. Existing event rows are retained; only the separately
    /// acknowledgement-gated compaction API may delete history.
    public func installSnapshot(_ bundle: MeshReplicaSnapshotBundle,
                                creatorPublicKey: Data) throws {
        let envelope = try validatedSnapshotEnvelope(
            bundle, creatorPublicKey: creatorPublicKey
        )
        try transaction {
            try installSnapshotState(bundle, envelope: envelope)
        }
        materializationNeedsRebuild = false
    }

    /// Atomically installs a verified final-delta snapshot and records its
    /// shadow inventory. Blob bytes must be verified before calling this API.
    public func installMigrationSnapshot(
        _ bundle: MeshReplicaSnapshotBundle, creatorPublicKey: Data,
        inventoryDigest: Data, expectedGeneration: UInt64?
    ) throws -> MeshMigrationCutoverState {
        guard inventoryDigest.count == 32 else {
            throw MeshMigrationValidationError.invalidInventoryDigest
        }
        let envelope = try validatedSnapshotEnvelope(
            bundle, creatorPublicKey: creatorPublicKey
        )
        let state = try transaction { () -> MeshMigrationCutoverState in
            let next: MeshMigrationCutoverState
            if let current = try migrationState(for: bundle.snapshot.trustGroupID) {
                guard current.mode != .distributed else {
                    throw DistributedMeshStoreError.invalidMigrationTransition(
                        from: current.mode, to: current.mode
                    )
                }
                guard let expectedGeneration,
                      current.generation == expectedGeneration else {
                    throw DistributedMeshStoreError.migrationGenerationMismatch(
                        expected: current.generation, actual: expectedGeneration ?? 0
                    )
                }
                if current.inventoryDigest == inventoryDigest {
                    next = current
                } else {
                    guard current.generation < UInt64(Int64.max) else {
                        throw MeshMigrationValidationError.invalidGeneration
                    }
                    next = MeshMigrationCutoverState(
                        trustGroupID: current.trustGroupID,
                        inventoryDigest: inventoryDigest,
                        generation: current.generation + 1, mode: current.mode,
                        updatedAt: bundle.snapshot.createdAt
                    )
                }
            } else {
                guard expectedGeneration == nil else {
                    throw DistributedMeshStoreError.migrationNotPrepared
                }
                next = MeshMigrationCutoverState(
                    trustGroupID: bundle.snapshot.trustGroupID,
                    inventoryDigest: inventoryDigest, generation: 1,
                    mode: .shadow, updatedAt: bundle.snapshot.createdAt
                )
            }
            try installSnapshotState(bundle, envelope: envelope)
            try storeMigrationState(next)
            return next
        }
        materializationNeedsRebuild = false
        return state
    }

    /// Deletes history covered by a signed snapshot only after every active
    /// peer has durably acknowledged each author checkpoint.
    ///
    /// Prefer `compactEventsUsingCurrentMembership` in product code. This
    /// lower-level variant exists for deterministic recovery tools and tests
    /// whose peer set comes from an independently verified membership view.
    public func compactEvents(
        using snapshotID: MeshEventID,
        creatorPublicKey: Data,
        activePeers: [MeshDeviceID]
    ) throws -> Int {
        guard let bundle = try storedSnapshot(id: snapshotID) else {
            throw DistributedMeshStoreError.snapshotNotFound
        }
        try MeshReplicaSnapshotCrypto.verify(bundle, creatorPublicKey: creatorPublicKey)
        let group = bundle.snapshot.trustGroupID
        guard let epoch = try membershipEpoch(for: group),
              epoch == bundle.snapshot.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: group) ?? 0,
                actual: bundle.snapshot.membershipEpoch
            )
        }
        let peers = Array(Set(activePeers)).sorted()
        return try transaction {
            var removed = 0
            for checkpoint in bundle.snapshot.authorHeads {
                guard let local = try authorHead(
                    group: group, endpoint: checkpoint.endpointID
                ), local.sequence >= checkpoint.sequence else {
                    throw DistributedMeshStoreError.snapshotCheckpointUnavailable(
                        checkpoint.endpointID
                    )
                }
                let localHash: Data?
                if local.sequence == checkpoint.sequence {
                    localHash = local.eventHash
                } else {
                    localHash = try eventHash(
                        group: group, endpoint: checkpoint.endpointID,
                        sequence: checkpoint.sequence
                    )
                }
                guard localHash == checkpoint.eventHash else {
                    throw DistributedMeshStoreError.snapshotHeadHashMismatch(
                        checkpoint.endpointID
                    )
                }
                for peer in peers {
                    let acknowledged = try acknowledgement(
                        group: group, peer: peer, author: checkpoint.endpointID
                    ) ?? 0
                    guard acknowledged >= checkpoint.sequence else {
                        throw DistributedMeshStoreError.compactionNotAcknowledged(
                            peer: peer, author: checkpoint.endpointID,
                            required: checkpoint.sequence, actual: acknowledged
                        )
                    }
                }
                try run(
                    "DELETE FROM events WHERE trust_group_id=? AND author_endpoint_id=? " +
                    "AND author_sequence<=?",
                    [.text(group.rawValue.uuidString), .text(checkpoint.endpointID.rawValue),
                     .integer(Int64(checkpoint.sequence))]
                )
                removed += Int(sqlite3_changes(database))
            }
            return removed
        }
    }

    /// Derives the acknowledgement barrier from the exact current membership
    /// epoch before deleting any covered history. A snapshot creator does not
    /// acknowledge its own checkpoint; every other trusted installation does.
    /// Advancing the epoch revokes the old snapshot and peer set together.
    public func compactEventsUsingCurrentMembership(
        using snapshotID: MeshEventID,
        creatorPublicKey: Data
    ) throws -> Int {
        guard let bundle = try storedSnapshot(id: snapshotID) else {
            throw DistributedMeshStoreError.snapshotNotFound
        }
        let group = bundle.snapshot.trustGroupID
        guard let epoch = try membershipEpoch(for: group),
              epoch == bundle.snapshot.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: group) ?? 0,
                actual: bundle.snapshot.membershipEpoch
            )
        }
        let peers = try trustedReplicaPeers(
            in: group, membershipEpoch: epoch,
            excluding: bundle.snapshot.creatorEndpointID
        )
        return try compactEvents(
            using: snapshotID, creatorPublicKey: creatorPublicKey,
            activePeers: peers
        )
    }

    public func latestSnapshot(in group: MeshTrustGroupID) throws -> MeshReplicaSnapshotBundle? {
        let bundle = try queryOne(
            "SELECT envelope FROM snapshots WHERE trust_group_id=? " +
            "ORDER BY created_at_ms DESC, snapshot_id DESC LIMIT 1",
            [.text(group.rawValue.uuidString)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let bundle = try? JSONDecoder().decode(
                      MeshReplicaSnapshotBundle.self, from: data
                  ) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return bundle
        }
        if let bundle { try verifyStoredSnapshot(bundle) }
        return bundle
    }

    private func coveringSnapshot(in group: MeshTrustGroupID,
                                  author: MeshEndpointID,
                                  after sequence: UInt64) throws
        -> MeshReplicaSnapshotBundle? {
        let bundles = try query(
            "SELECT envelope FROM snapshots WHERE trust_group_id=? " +
            "ORDER BY created_at_ms DESC, snapshot_id DESC",
            [.text(group.rawValue.uuidString)]
        ) { statement -> MeshReplicaSnapshotBundle in
            guard let data = Self.columnData(statement, index: 0),
                  let bundle = try? JSONDecoder().decode(
                      MeshReplicaSnapshotBundle.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            return bundle
        }
        for bundle in bundles {
            try verifyStoredSnapshot(bundle)
            if bundle.snapshot.authorHeads.contains(where: {
                $0.endpointID == author && $0.sequence > sequence
            }) {
                return bundle
            }
        }
        return nil
    }

    public func registerBlobManifest(_ manifest: MeshBlobManifest) throws {
        try manifest.validate()
        let envelope = try MeshCanonicalStoreJSON.encode(manifest)
        try transaction {
            if let existing = try blobTransfer(digest: manifest.digest) {
                guard existing.manifest == manifest else {
                    throw MeshBlobStoreError.manifestCollision
                }
                return
            }
            try run(
                "INSERT INTO blob_transfers(digest, envelope, local_state) VALUES(?, ?, ?)",
                [.blob(manifest.digest.rawValue), .blob(envelope),
                 .text(MeshBlobLocalState.pending.rawValue)]
            )
        }
    }

    public func blobManifest(for digest: MeshBlobDigest) throws -> MeshBlobManifest? {
        try blobTransfer(digest: digest)?.manifest
    }

    public func blobManifest(
        for digest: MeshBlobDigest, in group: MeshTrustGroupID,
        requestedBy endpointID: MeshEndpointID, membershipEpoch: UInt64
    ) throws -> MeshBlobManifest? {
        _ = try requireReplicaRPCPeer(
            in: group, endpointID: endpointID,
            membershipEpoch: membershipEpoch
        )
        return try blobManifest(for: digest)
    }

    /// Reads one verified bounded chunk from a complete local blob. The caller
    /// can place the returned bytes directly in a transport body without ever
    /// allocating or sending more than the manifest's chunk size.
    public func blobChunk(for digest: MeshBlobDigest, index: Int) throws -> MeshBlobChunk {
        guard let transfer = try blobTransfer(digest: digest) else {
            throw MeshBlobStoreError.notRegistered
        }
        guard transfer.state == .complete else { throw MeshBlobStoreError.unavailable }
        let expected = try transfer.manifest.expectedByteCount(forChunk: index)
        let file = URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(digest.hex).blob")
        guard (try? Self.isRegularFile(file)) == true else {
            if FileManager.default.fileExists(atPath: file.path) {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            try setBlobState(.corrupt, digest: digest)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value == transfer.manifest.byteSize else {
            try setBlobState(.corrupt, digest: digest)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch { throw MeshBlobStoreError.fileIO }
        defer { try? handle.close() }
        let bytes: Data
        do {
            try handle.seek(
                toOffset: UInt64(index) * UInt64(transfer.manifest.chunkSize)
            )
            bytes = try handle.read(upToCount: expected) ?? Data()
        } catch {
            throw MeshBlobStoreError.fileIO
        }
        guard bytes.count == expected else {
            try setBlobState(.corrupt, digest: digest)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        guard let chunkDigest = MeshBlobDigest(rawValue: Self.sha256(bytes)) else {
            throw MeshBlobStoreError.fileIO
        }
        return MeshBlobChunk(
            blobDigest: digest, index: index, data: bytes,
            chunkDigest: chunkDigest
        )
    }

    public func blobChunk(
        for digest: MeshBlobDigest, index: Int, in group: MeshTrustGroupID,
        requestedBy endpointID: MeshEndpointID, membershipEpoch: UInt64
    ) throws -> MeshBlobChunk {
        _ = try requireReplicaRPCPeer(
            in: group, endpointID: endpointID,
            membershipEpoch: membershipEpoch
        )
        return try blobChunk(for: digest, index: index)
    }

    public func blobState(for digest: MeshBlobDigest) throws -> MeshBlobLocalState? {
        try blobTransfer(digest: digest)?.state
    }

    public func receiveBlobChunk(_ chunk: MeshBlobChunk) throws -> MeshBlobChunkInsertion {
        guard let transfer = try blobTransfer(digest: chunk.blobDigest) else {
            throw MeshBlobStoreError.notRegistered
        }
        guard transfer.state != .complete else {
            throw MeshBlobStoreError.unavailable
        }
        try chunk.validate(against: transfer.manifest)
        guard Self.sha256(chunk.data) == chunk.chunkDigest.rawValue else {
            throw MeshBlobValidationError.chunkDigestMismatch
        }
        try ensureBlobStorageDirectory()
        let directory = try ensureChunkDirectory(for: chunk.blobDigest)
        let file = directory.appendingPathComponent("\(chunk.index).chunk")
        if let existing = try receivedChunk(
            digest: chunk.blobDigest, index: chunk.index
        ) {
            guard try Self.isRegularFile(file) else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            guard existing.digest == chunk.chunkDigest,
                  existing.byteSize == chunk.data.count,
                  let stored = try? Data(contentsOf: file), stored == chunk.data else {
                throw MeshBlobStoreError.chunkCollision
            }
            return .duplicate
        }
        try Self.writePrivateFile(chunk.data, to: file)
        return try transaction {
            if let existing = try receivedChunk(
                digest: chunk.blobDigest, index: chunk.index
            ) {
                guard existing.digest == chunk.chunkDigest,
                      existing.byteSize == chunk.data.count else {
                    throw MeshBlobStoreError.chunkCollision
                }
                return .duplicate
            }
            try run(
                "INSERT INTO blob_received_chunks(digest, chunk_index, chunk_digest, byte_size) " +
                "VALUES(?, ?, ?, ?)",
                [.blob(chunk.blobDigest.rawValue), .integer(Int64(chunk.index)),
                 .blob(chunk.chunkDigest.rawValue), .integer(Int64(chunk.data.count))]
            )
            try run(
                "UPDATE blob_transfers SET local_state=? WHERE digest=?",
                [.text(MeshBlobLocalState.pending.rawValue),
                 .blob(chunk.blobDigest.rawValue)]
            )
            return .inserted
        }
    }

    public func missingBlobChunkIndices(for digest: MeshBlobDigest) throws -> [Int] {
        guard let transfer = try blobTransfer(digest: digest) else {
            throw MeshBlobStoreError.notRegistered
        }
        try ensureBlobStorageDirectory()
        let directory = chunkDirectory(for: digest)
        var missing: [Int] = []
        for index in 0..<transfer.manifest.chunkCount {
            guard let received = try receivedChunk(digest: digest, index: index) else {
                missing.append(index)
                continue
            }
            let file = directory.appendingPathComponent("\(index).chunk")
            guard (try? Self.isRegularFile(file)) == true,
                  let data = try? Data(contentsOf: file),
                  data.count == received.byteSize,
                  Self.sha256(data) == received.digest.rawValue else {
                try run(
                    "DELETE FROM blob_received_chunks WHERE digest=? AND chunk_index=?",
                    [.blob(digest.rawValue), .integer(Int64(index))]
                )
                missing.append(index)
                continue
            }
        }
        return missing
    }

    public func finalizeBlob(_ digest: MeshBlobDigest) throws {
        guard let transfer = try blobTransfer(digest: digest) else {
            throw MeshBlobStoreError.notRegistered
        }
        if transfer.state == .complete {
            _ = try blobData(for: digest)
            return
        }
        let missing = try missingBlobChunkIndices(for: digest)
        guard missing.isEmpty else { throw MeshBlobStoreError.incomplete }
        try ensureBlobStorageDirectory()
        let root = URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
        let temporary = root.appendingPathComponent(".\(digest.hex).\(UUID().uuidString).tmp")
        let final = root.appendingPathComponent("\(digest.hex).blob")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: nil,
            attributes: [.posixPermissions: 0o600]
        ), let handle = try? FileHandle(forWritingTo: temporary) else {
            throw MeshBlobStoreError.fileIO
        }
        var published = false
        defer {
            try? handle.close()
            if !published { try? FileManager.default.removeItem(at: temporary) }
        }
        var hasher = SHA256()
        var written = 0
        let directory = chunkDirectory(for: digest)
        do {
            for index in 0..<transfer.manifest.chunkCount {
                let data = try Data(contentsOf: directory.appendingPathComponent("\(index).chunk"))
                hasher.update(data: data)
                try handle.write(contentsOf: data)
                written += data.count
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            throw MeshBlobStoreError.fileIO
        }
        guard written == Int(transfer.manifest.byteSize),
              Data(hasher.finalize()) == digest.rawValue else {
            try resetCorruptBlob(digest, chunkDirectory: directory)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        do {
            if FileManager.default.fileExists(atPath: final.path) {
                guard try Self.isRegularFile(final) else {
                    throw MeshBlobStoreError.unsafeStoragePath
                }
                let existing = try Data(contentsOf: final)
                if existing.count == written, Self.sha256(existing) == digest.rawValue {
                    try FileManager.default.removeItem(at: temporary)
                } else {
                    let quarantined = root.appendingPathComponent(
                        "\(digest.hex).corrupt.\(UUID().uuidString)"
                    )
                    try FileManager.default.moveItem(at: final, to: quarantined)
                    try FileManager.default.moveItem(at: temporary, to: final)
                }
            } else {
                try FileManager.default.moveItem(at: temporary, to: final)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: final.path
            )
            published = true
        } catch let error as MeshBlobStoreError {
            throw error
        } catch {
            throw MeshBlobStoreError.fileIO
        }
        try transaction {
            try run(
                "UPDATE blob_transfers SET local_state=? WHERE digest=?",
                [.text(MeshBlobLocalState.complete.rawValue), .blob(digest.rawValue)]
            )
            try run(
                "DELETE FROM blob_received_chunks WHERE digest=?",
                [.blob(digest.rawValue)]
            )
        }
        try? FileManager.default.removeItem(at: directory)
    }

    public func blobData(for digest: MeshBlobDigest) throws -> Data? {
        guard let transfer = try blobTransfer(digest: digest) else { return nil }
        guard transfer.state == .complete else {
            if transfer.state == .evicted { return nil }
            throw MeshBlobStoreError.unavailable
        }
        let file = URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(digest.hex).blob")
        guard (try? Self.isRegularFile(file)) == true else {
            if FileManager.default.fileExists(atPath: file.path) {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            try setBlobState(.corrupt, digest: digest)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        guard let data = try? Data(contentsOf: file),
              data.count == Int(transfer.manifest.byteSize),
              Self.sha256(data) == digest.rawValue else {
            try setBlobState(.corrupt, digest: digest)
            throw MeshBlobValidationError.blobDigestMismatch
        }
        return data
    }

    public func evictBlob(_ digest: MeshBlobDigest) throws {
        guard try blobTransfer(digest: digest) != nil else {
            throw MeshBlobStoreError.notRegistered
        }
        let file = URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(digest.hex).blob")
        if FileManager.default.fileExists(atPath: file.path) {
            guard try Self.isRegularFile(file) else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            do { try FileManager.default.removeItem(at: file) }
            catch { throw MeshBlobStoreError.fileIO }
        }
        let directory = chunkDirectory(for: digest)
        if FileManager.default.fileExists(atPath: directory.path) {
            let values = try? directory.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw MeshBlobStoreError.fileIO }
        }
        try transaction {
            try run(
                "DELETE FROM blob_received_chunks WHERE digest=?",
                [.blob(digest.rawValue)]
            )
            try setBlobState(.evicted, digest: digest)
        }
    }

    /// Replays retained events into derived tables. This is safe after an
    /// interrupted migration because materialized state is disposable and the
    /// immutable event log remains the source of truth.
    public func rebuildMaterializedState() throws {
        let snapshots = try latestStoredSnapshots()
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
            try run("DELETE FROM materialized_immutable_values")
            try run("DELETE FROM quarantined_events")
            for bundle in snapshots {
                try applySnapshotState(bundle.state, in: bundle.snapshot.trustGroupID)
            }
            for (event, envelope) in retained {
                try materialize(event, envelope: envelope)
            }
            try run("UPDATE materialization_metadata SET version=2")
        }
        materializationNeedsRebuild = false
    }

    private func ensureMaterializedState() throws {
        if materializationNeedsRebuild {
            try rebuildMaterializedState()
        }
    }

    private func snapshotFields(in group: MeshTrustGroupID) throws -> [MeshSnapshotField] {
        try query(
            "SELECT entity_type, entity_id, field_name, value, is_deleted, source_event_id, " +
            "wall_time_ms, logical_time, author_endpoint_id FROM materialized_registers " +
            "WHERE trust_group_id=? ORDER BY entity_type, entity_id, field_name",
            [.text(group.rawValue.uuidString)]
        ) { statement in
            guard let type = MeshEntityType(rawValue: Self.columnText(statement, index: 0)),
                  let entity = MeshEntityReference(
                      type: type, id: Self.columnText(statement, index: 1)
                  ),
                  let eventUUID = UUID(uuidString: Self.columnText(statement, index: 5)),
                  let eventID = MeshEventID(rawValue: eventUUID),
                  let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 8)) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            let isDeleted = sqlite3_column_int64(statement, 4) != 0
            return MeshSnapshotField(
                entity: entity,
                mutation: MeshFieldMutation(
                    field: Self.columnText(statement, index: 2),
                    value: Self.columnData(statement, index: 3), isDeleted: isDeleted
                ),
                sourceEventID: eventID,
                timestamp: MeshHybridTimestamp(
                    wallTimeMilliseconds: sqlite3_column_int64(statement, 6),
                    logical: UInt32(sqlite3_column_int64(statement, 7))
                ),
                authorEndpointID: endpoint
            )
        }
    }

    private func snapshotImmutableValues(in group: MeshTrustGroupID) throws
        -> [MeshSnapshotImmutable] {
        try query(
            "SELECT entity_type, entity_id, value, source_event_id, wall_time_ms, " +
            "logical_time, author_endpoint_id FROM materialized_immutable_values " +
            "WHERE trust_group_id=? ORDER BY entity_type, entity_id",
            [.text(group.rawValue.uuidString)]
        ) { statement in
            guard let type = MeshEntityType(rawValue: Self.columnText(statement, index: 0)),
                  let entity = MeshEntityReference(
                      type: type, id: Self.columnText(statement, index: 1)
                  ),
                  let value = Self.columnData(statement, index: 2),
                  let eventUUID = UUID(uuidString: Self.columnText(statement, index: 3)),
                  let eventID = MeshEventID(rawValue: eventUUID),
                  let endpoint = MeshEndpointID(rawValue: Self.columnText(statement, index: 6))
            else { throw DistributedMeshStoreError.corruptStoredValue }
            return MeshSnapshotImmutable(
                entity: entity, value: value, sourceEventID: eventID,
                timestamp: MeshHybridTimestamp(
                    wallTimeMilliseconds: sqlite3_column_int64(statement, 4),
                    logical: UInt32(sqlite3_column_int64(statement, 5))
                ),
                authorEndpointID: endpoint
            )
        }
    }

    private func applySnapshotState(_ state: MeshReplicaState,
                                    in group: MeshTrustGroupID) throws {
        try state.validate()
        for field in state.fields {
            try run(
                "INSERT INTO materialized_registers(trust_group_id, entity_type, entity_id, " +
                "field_name, value, is_deleted, source_event_id, wall_time_ms, logical_time, " +
                "author_endpoint_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(group.rawValue.uuidString), .text(field.entity.type.rawValue),
                 .text(field.entity.id), .text(field.mutation.field),
                 field.mutation.value.map(Binding.blob) ?? .null,
                 .integer(field.mutation.isDeleted ? 1 : 0),
                 .text(field.sourceEventID.rawValue.uuidString),
                 .integer(field.timestamp.wallTimeMilliseconds),
                 .integer(Int64(field.timestamp.logical)),
                 .text(field.authorEndpointID.rawValue)]
            )
        }
        for immutable in state.immutableValues {
            try run(
                "INSERT INTO materialized_immutable_values(trust_group_id, entity_type, " +
                "entity_id, value, source_event_id, wall_time_ms, logical_time, " +
                "author_endpoint_id) VALUES(?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(group.rawValue.uuidString), .text(immutable.entity.type.rawValue),
                 .text(immutable.entity.id), .blob(immutable.value),
                 .text(immutable.sourceEventID.rawValue.uuidString),
                 .integer(immutable.timestamp.wallTimeMilliseconds),
                 .integer(Int64(immutable.timestamp.logical)),
                 .text(immutable.authorEndpointID.rawValue)]
            )
        }
    }

    private func validatedSnapshotEnvelope(
        _ bundle: MeshReplicaSnapshotBundle, creatorPublicKey: Data
    ) throws -> Data {
        try MeshReplicaSnapshotCrypto.verify(bundle, creatorPublicKey: creatorPublicKey)
        try ensureMaterializedState()
        let group = bundle.snapshot.trustGroupID
        guard let epoch = try membershipEpoch(for: group),
              epoch == bundle.snapshot.membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: try membershipEpoch(for: group) ?? 0,
                actual: bundle.snapshot.membershipEpoch
            )
        }
        let envelope = try MeshCanonicalStoreJSON.encode(bundle)
        guard envelope.count <= DistributedMeshProtocol.maximumBlobBytes +
                DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSnapshotValidationError.snapshotTooLarge
        }
        return envelope
    }

    private func installSnapshotState(
        _ bundle: MeshReplicaSnapshotBundle, envelope: Data
    ) throws {
        let group = bundle.snapshot.trustGroupID
        let remoteHeads = Dictionary(
            uniqueKeysWithValues: bundle.snapshot.authorHeads.map { ($0.endpointID, $0) }
        )
        for local in try authorHeads(for: group) {
            guard let remote = remoteHeads[local.endpointID],
                  remote.sequence >= local.sequence else {
                throw DistributedMeshStoreError.snapshotDoesNotCoverLocalHead(local.endpointID)
            }
            if remote.sequence == local.sequence, remote.eventHash != local.eventHash {
                throw DistributedMeshStoreError.snapshotHeadHashMismatch(local.endpointID)
            }
        }
        try run(
            "DELETE FROM materialized_registers WHERE trust_group_id=?",
            [.text(group.rawValue.uuidString)]
        )
        try run(
            "DELETE FROM materialized_immutable_values WHERE trust_group_id=?",
            [.text(group.rawValue.uuidString)]
        )
        try applySnapshotState(bundle.state, in: group)
        try run(
            "DELETE FROM author_heads WHERE trust_group_id=?",
            [.text(group.rawValue.uuidString)]
        )
        for head in bundle.snapshot.authorHeads {
            try run(
                "INSERT INTO author_heads(trust_group_id, author_endpoint_id, sequence, " +
                "event_hash) VALUES(?, ?, ?, ?)",
                [.text(group.rawValue.uuidString), .text(head.endpointID.rawValue),
                 .integer(Int64(head.sequence)), .blob(head.eventHash)]
            )
        }
        try storeSnapshot(bundle, envelope: envelope)
        try run("UPDATE materialization_metadata SET version=2")
    }

    private func storeSnapshot(_ bundle: MeshReplicaSnapshotBundle,
                               envelope: Data) throws {
        if let existing = try queryOne(
            "SELECT envelope FROM snapshots WHERE snapshot_id=? LIMIT 1",
            [.text(bundle.snapshot.id.rawValue.uuidString)],
            transform: { statement -> Data in
                guard let data = Self.columnData(statement, index: 0) else {
                    throw DistributedMeshStoreError.corruptStoredValue
                }
                return data
            }
        ) {
            if existing == envelope { return }
            guard let existingBundle = try? JSONDecoder().decode(
                    MeshReplicaSnapshotBundle.self, from: existing
                  ),
                  (try? verifyStoredSnapshot(existingBundle)) != nil,
                  existingBundle.state == bundle.state,
                  (try? existingBundle.snapshot.canonicalSigningBytes()) ==
                    (try? bundle.snapshot.canonicalSigningBytes()) else {
                throw DistributedMeshStoreError.snapshotIDCollision
            }
            // Ed25519 implementations may blind signing internally. Two valid
            // signatures over identical unsigned snapshot bytes do not create
            // distinct snapshot content or break idempotent migration import.
            return
        }
        try run(
            "INSERT INTO snapshots(snapshot_id, trust_group_id, envelope, created_at_ms) " +
            "VALUES(?, ?, ?, ?)",
            [.text(bundle.snapshot.id.rawValue.uuidString),
             .text(bundle.snapshot.trustGroupID.rawValue.uuidString), .blob(envelope),
             .integer(bundle.snapshot.createdAt.wallTimeMilliseconds)]
        )
    }

    private func storedSnapshot(id: MeshEventID) throws -> MeshReplicaSnapshotBundle? {
        let bundle = try queryOne(
            "SELECT envelope FROM snapshots WHERE snapshot_id=? LIMIT 1",
            [.text(id.rawValue.uuidString)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let bundle = try? JSONDecoder().decode(
                      MeshReplicaSnapshotBundle.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            return bundle
        }
        if let bundle { try verifyStoredSnapshot(bundle) }
        return bundle
    }

    private func latestStoredSnapshots() throws -> [MeshReplicaSnapshotBundle] {
        let stored = try query(
            "SELECT trust_group_id, envelope FROM snapshots " +
            "ORDER BY trust_group_id, created_at_ms DESC, snapshot_id DESC"
        ) { statement -> (String, MeshReplicaSnapshotBundle) in
            guard let data = Self.columnData(statement, index: 1),
                  let bundle = try? JSONDecoder().decode(
                      MeshReplicaSnapshotBundle.self, from: data
                  ) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (Self.columnText(statement, index: 0), bundle)
        }
        var seen: Set<String> = []
        var result: [MeshReplicaSnapshotBundle] = []
        for (group, bundle) in stored where seen.insert(group).inserted {
            try verifyStoredSnapshot(bundle)
            result.append(bundle)
        }
        return result
    }

    private func verifyStoredSnapshot(_ bundle: MeshReplicaSnapshotBundle) throws {
        guard let publicKey = Self.publicKeyData(
            from: bundle.snapshot.creatorEndpointID
        ) else { throw DistributedMeshStoreError.corruptStoredValue }
        do {
            try MeshReplicaSnapshotCrypto.verify(bundle, creatorPublicKey: publicKey)
        } catch {
            throw DistributedMeshStoreError.corruptStoredValue
        }
    }

    private static func publicKeyData(from endpoint: MeshEndpointID) -> Data? {
        let value = endpoint.rawValue
        guard value.utf8.count == 64 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    public func registerHostResource(
        in group: MeshTrustGroupID, on host: MeshDeviceIdentity,
        resourceID: MeshResourceID, allowedActions: Set<MeshHostAction>,
        at timestamp: MeshHybridTimestamp
    ) throws -> MeshHostResource {
        let endpoint = try host.endpointID()
        return try transaction {
            try requireDistributedWriteAuthorityIfMigrating(group)
            if let existing = try hostResource(
                in: group, hostDeviceID: host.deviceID, resourceID: resourceID
            ) {
                guard existing.hostEndpointID == endpoint else {
                    throw DistributedMeshStoreError.hostIdentityMismatch
                }
                guard existing.state == .active else {
                    throw DistributedMeshStoreError.hostResourceRetired
                }
                let normalized = allowedActions.sorted { $0.rawValue < $1.rawValue }
                guard existing.allowedActions == normalized else {
                    throw MeshSchemaValidationError.invalidStateTransition
                }
                return existing
            }
            let resource = MeshHostResource(
                trustGroupID: group, hostDeviceID: host.deviceID,
                hostEndpointID: endpoint, resourceID: resourceID, generation: 1,
                allowedActions: allowedActions, updatedAt: timestamp
            )
            try resource.validate()
            try storeHostResource(resource, insert: true)
            return resource
        }
    }

    /// Explicitly advances authority when a display name is reused by a new
    /// process/tmux session. Restarting Pharos alone does not advance it.
    public func replaceHostResource(
        in group: MeshTrustGroupID, on host: MeshDeviceIdentity,
        resourceID: MeshResourceID, allowedActions: Set<MeshHostAction>,
        at timestamp: MeshHybridTimestamp
    ) throws -> MeshHostResource {
        let endpoint = try host.endpointID()
        return try transaction {
            try requireDistributedWriteAuthorityIfMigrating(group)
            guard let current = try hostResource(
                in: group, hostDeviceID: host.deviceID, resourceID: resourceID
            ) else { throw DistributedMeshStoreError.hostResourceNotFound }
            guard current.hostEndpointID == endpoint else {
                throw DistributedMeshStoreError.hostIdentityMismatch
            }
            guard timestamp >= current.updatedAt else {
                throw MeshSchemaValidationError.invalidStateTransition
            }
            guard current.generation < UInt64(Int64.max) else {
                throw DistributedMeshStoreError.resourceGenerationOverflow
            }
            let replacement = MeshHostResource(
                trustGroupID: group, hostDeviceID: host.deviceID,
                hostEndpointID: endpoint, resourceID: resourceID,
                generation: current.generation + 1, allowedActions: allowedActions,
                updatedAt: timestamp
            )
            try replacement.validate()
            try storeHostResource(replacement, insert: false)
            return replacement
        }
    }

    public func retireHostResource(
        in group: MeshTrustGroupID, on host: MeshDeviceIdentity,
        resourceID: MeshResourceID, at timestamp: MeshHybridTimestamp
    ) throws -> MeshHostResource {
        let endpoint = try host.endpointID()
        return try transaction {
            try requireDistributedWriteAuthorityIfMigrating(group)
            guard var resource = try hostResource(
                in: group, hostDeviceID: host.deviceID, resourceID: resourceID
            ) else { throw DistributedMeshStoreError.hostResourceNotFound }
            guard resource.hostEndpointID == endpoint else {
                throw DistributedMeshStoreError.hostIdentityMismatch
            }
            if resource.state == .retired { return resource }
            guard timestamp >= resource.updatedAt else {
                throw MeshSchemaValidationError.invalidStateTransition
            }
            resource.state = .retired
            resource.updatedAt = timestamp
            try storeHostResource(resource, insert: false)
            return resource
        }
    }

    public func hostResource(in group: MeshTrustGroupID, hostDeviceID: MeshDeviceID,
                             resourceID: MeshResourceID) throws -> MeshHostResource? {
        try queryOne(
            "SELECT host_endpoint_id, generation, state, envelope FROM host_resources " +
            "WHERE trust_group_id=? " +
            "AND host_device_id=? AND resource_id=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(hostDeviceID.rawValue.uuidString),
             .text(resourceID.rawValue)]
        ) { statement in
            guard let rowEndpoint = MeshEndpointID(
                    rawValue: Self.columnText(statement, index: 0)
                  ),
                  let rowState = MeshHostResourceState(
                    rawValue: Self.columnText(statement, index: 2)
                  ),
                  let data = Self.columnData(statement, index: 3),
                  let value = try? JSONDecoder().decode(MeshHostResource.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try value.validate()
            guard value.trustGroupID == group,
                  value.hostDeviceID == hostDeviceID,
                  value.resourceID == resourceID,
                  value.hostEndpointID == rowEndpoint,
                  value.generation == UInt64(sqlite3_column_int64(statement, 1)),
                  value.state == rowState else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return value
        }
    }

    /// Authenticates and journals a directed command before any side effect.
    /// Stale, retired, disallowed, and already-expired work receives a signed
    /// terminal receipt instead of being reported as accepted.
    public func accept(_ envelope: MeshSignedHostCommand, on host: MeshDeviceIdentity,
                       receivedAt: MeshHybridTimestamp) throws -> MeshSignedCommandReceipt {
        try envelope.validateStructure()
        let command = envelope.command
        let hostEndpoint = try host.endpointID()
        guard command.targetHostDeviceID == host.deviceID else {
            throw DistributedMeshStoreError.wrongCommandHost
        }
        guard command.targetHostEndpointID == hostEndpoint else {
            throw DistributedMeshStoreError.wrongCommandEndpoint
        }
        guard let sender = try trustedCommandSender(
            group: command.trustGroupID, deviceID: command.senderDeviceID,
            membershipEpoch: envelope.membershipEpoch
        ) else { throw DistributedMeshStoreError.commandSenderNotTrusted }
        guard sender.descriptor.endpointID == envelope.senderEndpointID else {
            throw DistributedMeshStoreError.wrongCommandEndpoint
        }
        guard sender.descriptor.roles.contains(.controller) else {
            throw DistributedMeshStoreError.commandSenderUnauthorized
        }
        try MeshHostCommandCrypto.verify(envelope, senderPublicKey: sender.signingPublicKey)

        let fingerprint = Data(SHA256.hash(data: try command.canonicalIdempotencyBytes()))
        return try transaction {
            if let existing = try storedReceipt(
                commandID: command.id, group: command.trustGroupID,
                hostDeviceID: host.deviceID, idempotencyKey: command.idempotencyKey
            ) {
                guard existing.fingerprint == fingerprint else {
                    throw DistributedMeshStoreError.idempotencyCollision
                }
                return existing.receipt
            }
            try requireDistributedWriteAuthorityIfMigrating(command.trustGroupID)
            let currentEpoch = try membershipEpoch(for: command.trustGroupID) ?? 0
            guard currentEpoch == envelope.membershipEpoch else {
                throw DistributedMeshStoreError.membershipEpochMismatch(
                    expected: currentEpoch, actual: envelope.membershipEpoch
                )
            }
            guard let resource = try hostResource(
                in: command.trustGroupID, hostDeviceID: host.deviceID,
                resourceID: command.resourceID
            ) else { throw DistributedMeshStoreError.hostResourceNotFound }
            guard resource.hostEndpointID == hostEndpoint else {
                throw DistributedMeshStoreError.hostIdentityMismatch
            }

            let state: MeshCommandReceiptState
            let failureCode: String?
            if receivedAt.wallTimeMilliseconds >= command.deadlineMilliseconds {
                state = .expired
                failureCode = "deadline-expired"
            } else if resource.state != .active {
                state = .rejected
                failureCode = "resource-retired"
            } else if command.expectedResourceGeneration != resource.generation {
                state = .rejected
                failureCode = "stale-resource-generation"
            } else if !resource.allowedActions.contains(command.action) {
                state = .rejected
                failureCode = "action-not-allowed"
            } else {
                state = .accepted
                failureCode = nil
            }
            let receipt = MeshCommandReceipt(
                commandID: command.id, idempotencyKey: command.idempotencyKey,
                hostDeviceID: host.deviceID, resourceID: command.resourceID,
                resourceGeneration: resource.generation, state: state,
                acceptedAt: receivedAt, updatedAt: receivedAt,
                failureCode: failureCode
            )
            let signed = try MeshHostCommandCrypto.sign(
                MeshSignedCommandReceipt(
                    receipt: receipt, trustGroupID: command.trustGroupID,
                    hostEndpointID: hostEndpoint, commandFingerprint: fingerprint,
                    deadlineMilliseconds: command.deadlineMilliseconds
                ),
                with: host
            )
            try run(
                "INSERT INTO command_receipts_v2(command_id, trust_group_id, idempotency_key, " +
                "command_fingerprint, host_device_id, host_endpoint_id, resource_id, " +
                "resource_generation, state, receipt) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                [.text(command.id.rawValue.uuidString),
                 .text(command.trustGroupID.rawValue.uuidString),
                 .text(command.idempotencyKey), .blob(fingerprint),
                 .text(host.deviceID.rawValue.uuidString), .text(hostEndpoint.rawValue),
                 .text(command.resourceID.rawValue), .integer(Int64(resource.generation)),
                 .text(state.rawValue), .blob(try MeshCanonicalStoreJSON.encode(signed))]
            )
            return signed
        }
    }

    public func commandReceipt(id: MeshCommandID) throws -> MeshSignedCommandReceipt? {
        try queryOne(
            "SELECT state, command_fingerprint, receipt FROM command_receipts_v2 " +
            "WHERE command_id=? LIMIT 1",
            [.text(id.rawValue.uuidString)]
        ) { statement in
            guard let rowState = MeshCommandReceiptState(
                    rawValue: Self.columnText(statement, index: 0)
                  ),
                  let fingerprint = Self.columnData(statement, index: 1),
                  let data = Self.columnData(statement, index: 2),
                  let value = try? JSONDecoder().decode(
                    MeshSignedCommandReceipt.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            try verifyStoredCommandReceipt(value)
            guard value.receipt.commandID == id,
                  value.receipt.state == rowState,
                  value.commandFingerprint == fingerprint else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return value
        }
    }

    public func claimExecution(
        commandID: MeshCommandID, on host: MeshDeviceIdentity,
        at timestamp: MeshHybridTimestamp
    ) throws -> MeshCommandExecutionClaim {
        try transaction {
            guard var signed = try commandReceipt(id: commandID) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try verifyHostIdentity(host, for: signed)
            guard signed.receipt.state == .accepted else {
                return MeshCommandExecutionClaim(receipt: signed, shouldExecute: false)
            }
            if timestamp.wallTimeMilliseconds >= signed.deadlineMilliseconds {
                signed = try transitionSignedReceipt(
                    signed, to: .expired, on: host, at: timestamp,
                    result: nil, failureCode: "deadline-expired"
                )
                return MeshCommandExecutionClaim(receipt: signed, shouldExecute: false)
            }
            signed = try transitionSignedReceipt(
                signed, to: .executing, on: host, at: timestamp,
                result: nil, failureCode: nil
            )
            return MeshCommandExecutionClaim(receipt: signed, shouldExecute: true)
        }
    }

    public func finishExecution(
        commandID: MeshCommandID, on host: MeshDeviceIdentity,
        outcome: MeshCommandReceiptState, at timestamp: MeshHybridTimestamp,
        result: Data? = nil, failureCode: String? = nil
    ) throws -> MeshSignedCommandReceipt {
        guard outcome == .executed || outcome == .failed else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
        return try transaction {
            guard let signed = try commandReceipt(id: commandID) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try verifyHostIdentity(host, for: signed)
            return try transitionSignedReceipt(
                signed, to: outcome, on: host, at: timestamp,
                result: result, failureCode: failureCode
            )
        }
    }

    public func unfinishedCommandReceipts(on host: MeshDeviceIdentity) throws
        -> [MeshSignedCommandReceipt] {
        let endpoint = try host.endpointID()
        return try query(
            "SELECT state, command_fingerprint, receipt FROM command_receipts_v2 " +
            "WHERE host_device_id=? " +
            "AND host_endpoint_id=? AND state IN ('accepted', 'executing') ORDER BY command_id",
            [.text(host.deviceID.rawValue.uuidString), .text(endpoint.rawValue)]
        ) { statement in
            guard let rowState = MeshCommandReceiptState(
                    rawValue: Self.columnText(statement, index: 0)
                  ),
                  let fingerprint = Self.columnData(statement, index: 1),
                  let data = Self.columnData(statement, index: 2),
                  let receipt = try? JSONDecoder().decode(
                    MeshSignedCommandReceipt.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            try verifyStoredCommandReceipt(receipt)
            guard receipt.receipt.state == rowState,
                  receipt.commandFingerprint == fingerprint else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return receipt
        }
    }

    private func storedReceipt(commandID: MeshCommandID, group: MeshTrustGroupID,
                               hostDeviceID: MeshDeviceID, idempotencyKey: String) throws
        -> (receipt: MeshSignedCommandReceipt, fingerprint: Data)? {
        try queryOne(
            "SELECT receipt, command_fingerprint FROM command_receipts_v2 WHERE command_id=? " +
            "OR (trust_group_id=? AND host_device_id=? AND idempotency_key=?) LIMIT 1",
            [.text(commandID.rawValue.uuidString), .text(group.rawValue.uuidString),
             .text(hostDeviceID.rawValue.uuidString), .text(idempotencyKey)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let fingerprint = Self.columnData(statement, index: 1),
                  let value = try? JSONDecoder().decode(
                    MeshSignedCommandReceipt.self, from: data
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            try verifyStoredCommandReceipt(value)
            guard value.commandFingerprint == fingerprint else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (value, fingerprint)
        }
    }

    private func storeHostResource(_ resource: MeshHostResource, insert: Bool) throws {
        let envelope = try MeshCanonicalStoreJSON.encode(resource)
        if insert {
            try run(
                "INSERT INTO host_resources(trust_group_id, host_device_id, host_endpoint_id, " +
                "resource_id, generation, state, envelope) VALUES(?, ?, ?, ?, ?, ?, ?)",
                [.text(resource.trustGroupID.rawValue.uuidString),
                 .text(resource.hostDeviceID.rawValue.uuidString),
                 .text(resource.hostEndpointID.rawValue), .text(resource.resourceID.rawValue),
                 .integer(Int64(resource.generation)), .text(resource.state.rawValue),
                 .blob(envelope)]
            )
        } else {
            try run(
                "UPDATE host_resources SET host_endpoint_id=?, generation=?, state=?, envelope=? " +
                "WHERE trust_group_id=? AND host_device_id=? AND resource_id=?",
                [.text(resource.hostEndpointID.rawValue), .integer(Int64(resource.generation)),
                 .text(resource.state.rawValue), .blob(envelope),
                 .text(resource.trustGroupID.rawValue.uuidString),
                 .text(resource.hostDeviceID.rawValue.uuidString),
                 .text(resource.resourceID.rawValue)]
            )
        }
    }

    private func trustedCommandSender(group: MeshTrustGroupID, deviceID: MeshDeviceID,
                                      membershipEpoch: UInt64) throws -> MeshPairedDevice? {
        try queryOne(
            "SELECT envelope FROM trusted_devices WHERE trust_group_id=? AND device_id=? " +
            "AND membership_epoch=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(deviceID.rawValue.uuidString),
             .integer(Int64(membershipEpoch))]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let device = try? JSONDecoder().decode(MeshPairedDevice.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try device.validateBinding()
            return device
        }
    }

    private func requireReplicaRPCPeer(
        in group: MeshTrustGroupID, endpointID: MeshEndpointID,
        membershipEpoch: UInt64
    ) throws -> MeshPairedDevice {
        let current = try self.membershipEpoch(for: group) ?? 0
        guard current == membershipEpoch else {
            throw DistributedMeshStoreError.membershipEpochMismatch(
                expected: current, actual: membershipEpoch
            )
        }
        guard let peer = try trustedDevice(
            in: group, endpointID: endpointID,
            membershipEpoch: membershipEpoch
        ) else { throw DistributedMeshStoreError.rpcPeerNotTrusted }
        return peer
    }

    private func verifyStoredCommandReceipt(_ receipt: MeshSignedCommandReceipt) throws {
        try receipt.validateStructure()
        guard let publicKey = Self.publicKeyData(from: receipt.hostEndpointID) else {
            throw DistributedMeshStoreError.corruptStoredValue
        }
        do { try MeshHostCommandCrypto.verify(receipt, hostPublicKey: publicKey) }
        catch { throw DistributedMeshStoreError.corruptStoredValue }
    }

    private func verifyHostIdentity(_ host: MeshDeviceIdentity,
                                    for receipt: MeshSignedCommandReceipt) throws {
        try verifyStoredCommandReceipt(receipt)
        guard receipt.receipt.hostDeviceID == host.deviceID,
              receipt.hostEndpointID == (try host.endpointID()) else {
            throw DistributedMeshStoreError.hostIdentityMismatch
        }
    }

    private func transitionSignedReceipt(
        _ current: MeshSignedCommandReceipt, to next: MeshCommandReceiptState,
        on host: MeshDeviceIdentity, at timestamp: MeshHybridTimestamp,
        result: Data?, failureCode: String?
    ) throws -> MeshSignedCommandReceipt {
        try current.receipt.validateTransition(to: next)
        guard timestamp >= current.receipt.updatedAt,
              (result?.count ?? 0) <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
        if let failureCode {
            guard failureCode.utf8.count <= 128,
                  !failureCode.isEmpty,
                  !failureCode.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                  ) else { throw MeshSchemaValidationError.invalidStateTransition }
        }
        var updated = current
        updated.receipt.state = next
        updated.receipt.updatedAt = timestamp
        updated.receipt.result = result
        updated.receipt.failureCode = failureCode
        updated.signature = Data()
        updated = try MeshHostCommandCrypto.sign(updated, with: host)
        try run(
            "UPDATE command_receipts_v2 SET state=?, receipt=? WHERE command_id=?",
            [.text(next.rawValue), .blob(try MeshCanonicalStoreJSON.encode(updated)),
             .text(updated.receipt.commandID.rawValue.uuidString)]
        )
        return updated
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

    private func eventHash(group: MeshTrustGroupID, endpoint: MeshEndpointID,
                           sequence: UInt64) throws -> Data? {
        try queryOne(
            "SELECT event_hash FROM events WHERE trust_group_id=? AND author_endpoint_id=? " +
            "AND author_sequence=? LIMIT 1",
            [.text(group.rawValue.uuidString), .text(endpoint.rawValue),
             .integer(Int64(sequence))]
        ) { statement in
            guard let hash = Self.columnData(statement, index: 0) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return hash
        }
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
            "SELECT wall_time_ms, logical_time, author_endpoint_id, source_event_id " +
            "FROM materialized_immutable_values WHERE trust_group_id=? AND entity_type=? " +
            "AND entity_id=? LIMIT 1",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id)]
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
        // Immutable-ID collisions resolve to the earliest deterministic stamp,
        // independent of arrival order. Normal UUIDv7 entity IDs never collide.
        if let existing,
           !Self.materializationStamp(
               timestamp: existing.0, endpoint: existing.1,
               eventID: existing.2,
               winsOver: (event.hybridTimestamp, event.authorEndpointID, event.id)
           ) {
            return
        }
        try run(
            "INSERT INTO materialized_immutable_values(trust_group_id, entity_type, entity_id, " +
            "value, source_event_id, wall_time_ms, logical_time, author_endpoint_id) " +
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT(trust_group_id, entity_type, entity_id) DO UPDATE SET " +
            "value=excluded.value, source_event_id=excluded.source_event_id, " +
            "wall_time_ms=excluded.wall_time_ms, logical_time=excluded.logical_time, " +
            "author_endpoint_id=excluded.author_endpoint_id",
            [.text(event.trustGroupID.rawValue.uuidString), .text(event.entity.type.rawValue),
             .text(event.entity.id), .blob(event.payload), .text(event.id.rawValue.uuidString),
             .integer(event.hybridTimestamp.wallTimeMilliseconds),
             .integer(Int64(event.hybridTimestamp.logical)),
             .text(event.authorEndpointID.rawValue)]
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

    private func blobTransfer(digest: MeshBlobDigest) throws
        -> (manifest: MeshBlobManifest, state: MeshBlobLocalState)? {
        try queryOne(
            "SELECT envelope, local_state FROM blob_transfers WHERE digest=? LIMIT 1",
            [.blob(digest.rawValue)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let manifest = try? JSONDecoder().decode(MeshBlobManifest.self, from: data),
                  let state = MeshBlobLocalState(
                      rawValue: Self.columnText(statement, index: 1)
                  ) else { throw DistributedMeshStoreError.corruptStoredValue }
            try manifest.validate()
            return (manifest, state)
        }
    }

    private func receivedChunk(digest: MeshBlobDigest, index: Int) throws
        -> (digest: MeshBlobDigest, byteSize: Int)? {
        try queryOne(
            "SELECT chunk_digest, byte_size FROM blob_received_chunks " +
            "WHERE digest=? AND chunk_index=? LIMIT 1",
            [.blob(digest.rawValue), .integer(Int64(index))]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let chunkDigest = MeshBlobDigest(rawValue: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            return (chunkDigest, Int(sqlite3_column_int64(statement, 1)))
        }
    }

    private func setBlobState(_ state: MeshBlobLocalState,
                              digest: MeshBlobDigest) throws {
        try run(
            "UPDATE blob_transfers SET local_state=? WHERE digest=?",
            [.text(state.rawValue), .blob(digest.rawValue)]
        )
    }

    private func resetCorruptBlob(_ digest: MeshBlobDigest,
                                  chunkDirectory: URL) throws {
        try transaction {
            try run(
                "DELETE FROM blob_received_chunks WHERE digest=?",
                [.blob(digest.rawValue)]
            )
            try setBlobState(.corrupt, digest: digest)
        }
        if FileManager.default.fileExists(atPath: chunkDirectory.path) {
            let values = try? chunkDirectory.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            do { try FileManager.default.removeItem(at: chunkDirectory) }
            catch { throw MeshBlobStoreError.fileIO }
        }
    }

    private func ensureBlobStorageDirectory() throws {
        try Self.ensurePrivateDirectory(
            URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
        )
    }

    private func chunkDirectory(for digest: MeshBlobDigest) -> URL {
        URL(fileURLWithPath: blobDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(digest.hex).chunks", isDirectory: true)
    }

    private func ensureChunkDirectory(for digest: MeshBlobDigest) throws -> URL {
        let directory = chunkDirectory(for: digest)
        try Self.ensurePrivateDirectory(directory)
        return directory
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try? url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )
            guard values?.isSymbolicLink != true, values?.isDirectory == true else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
        } else {
            do {
                try manager.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MeshBlobStoreError.fileIO
            }
        }
        do {
            try manager.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path
            )
        } catch {
            throw MeshBlobStoreError.fileIO
        }
    }

    private static func writePrivateFile(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path),
           (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw MeshBlobStoreError.unsafeStoragePath
        }
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch let error as MeshBlobStoreError {
            throw error
        } catch {
            throw MeshBlobStoreError.fileIO
        }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func isRegularFile(_ url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            )
            guard values.isSymbolicLink != true else {
                throw MeshBlobStoreError.unsafeStoragePath
            }
            return values.isRegularFile == true
        } catch let error as MeshBlobStoreError {
            throw error
        } catch {
            throw MeshBlobStoreError.fileIO
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

    private func trustedReplicaPeers(
        in group: MeshTrustGroupID, membershipEpoch: UInt64,
        excluding creatorEndpointID: MeshEndpointID
    ) throws -> [MeshDeviceID] {
        guard membershipEpoch <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidMembershipEpoch
        }
        return try query(
            "SELECT envelope FROM trusted_devices WHERE trust_group_id=? " +
            "AND membership_epoch=? AND endpoint_id<>? ORDER BY device_id",
            [.text(group.rawValue.uuidString), .integer(Int64(membershipEpoch)),
             .text(creatorEndpointID.rawValue)]
        ) { statement in
            guard let data = Self.columnData(statement, index: 0),
                  let device = try? JSONDecoder().decode(MeshPairedDevice.self, from: data) else {
                throw DistributedMeshStoreError.corruptStoredValue
            }
            try device.validateBinding()
            return device.descriptor.id
        }
    }

    private func transitionMigration(
        for group: MeshTrustGroupID, inventoryDigest: Data,
        expectedGeneration: UInt64, to nextMode: MeshMigrationMode,
        at timestamp: MeshHybridTimestamp
    ) throws -> MeshMigrationCutoverState {
        guard inventoryDigest.count == 32 else {
            throw MeshMigrationValidationError.invalidInventoryDigest
        }
        return try transaction {
            guard let current = try migrationState(for: group) else {
                throw DistributedMeshStoreError.migrationNotPrepared
            }
            guard current.inventoryDigest == inventoryDigest else {
                throw DistributedMeshStoreError.migrationInventoryMismatch
            }
            guard current.generation == expectedGeneration else {
                throw DistributedMeshStoreError.migrationGenerationMismatch(
                    expected: current.generation, actual: expectedGeneration
                )
            }
            let allowed = switch (current.mode, nextMode) {
            case (.shadow, .distributed), (.rolledBack, .distributed),
                 (.distributed, .rolledBack): true
            default: false
            }
            guard allowed else {
                throw DistributedMeshStoreError.invalidMigrationTransition(
                    from: current.mode, to: nextMode
                )
            }
            guard current.generation < UInt64(Int64.max) else {
                throw MeshMigrationValidationError.invalidGeneration
            }
            let next = MeshMigrationCutoverState(
                trustGroupID: group, inventoryDigest: inventoryDigest,
                generation: current.generation + 1, mode: nextMode,
                updatedAt: timestamp
            )
            try storeMigrationState(next)
            return next
        }
    }

    private func storeMigrationState(_ state: MeshMigrationCutoverState) throws {
        try state.validate()
        try run(
            "INSERT INTO migration_cutovers(trust_group_id, inventory_digest, generation, " +
            "mode, envelope) VALUES(?, ?, ?, ?, ?) " +
            "ON CONFLICT(trust_group_id) DO UPDATE SET " +
            "inventory_digest=excluded.inventory_digest, generation=excluded.generation, " +
            "mode=excluded.mode, envelope=excluded.envelope",
            [.text(state.trustGroupID.rawValue.uuidString),
             .blob(state.inventoryDigest), .integer(Int64(state.generation)),
             .text(state.mode.rawValue), .blob(try MeshCanonicalStoreJSON.encode(state))]
        )
    }

    private func requireDistributedWriteAuthorityIfMigrating(
        _ group: MeshTrustGroupID
    ) throws {
        guard let state = try migrationState(for: group) else { return }
        guard state.distributedMayWrite else {
            throw DistributedMeshStoreError.distributedWritesDisabled(state.mode)
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

    private static let schemaV4 = """
    CREATE TABLE IF NOT EXISTS materialized_immutable_values(
      trust_group_id TEXT NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
      value BLOB NOT NULL, source_event_id TEXT NOT NULL, wall_time_ms INTEGER NOT NULL,
      logical_time INTEGER NOT NULL, author_endpoint_id TEXT NOT NULL,
      PRIMARY KEY(trust_group_id, entity_type, entity_id));
    CREATE INDEX IF NOT EXISTS materialized_immutable_source
      ON materialized_immutable_values(source_event_id);
    UPDATE schema_metadata SET version=4;
    """

    private static let schemaV5 = """
    CREATE TABLE IF NOT EXISTS blob_transfers(
      digest BLOB PRIMARY KEY CHECK(length(digest)=32), envelope BLOB NOT NULL,
      local_state TEXT NOT NULL
        CHECK(local_state IN ('pending', 'complete', 'corrupt', 'evicted')));
    CREATE TABLE IF NOT EXISTS blob_received_chunks(
      digest BLOB NOT NULL, chunk_index INTEGER NOT NULL CHECK(chunk_index >= 0),
      chunk_digest BLOB NOT NULL CHECK(length(chunk_digest)=32),
      byte_size INTEGER NOT NULL CHECK(byte_size >= 0),
      PRIMARY KEY(digest, chunk_index),
      FOREIGN KEY(digest) REFERENCES blob_transfers(digest) ON DELETE CASCADE);
    UPDATE schema_metadata SET version=5;
    """

    /// The v1 receipt table is intentionally retained as a rollback journal.
    /// New authenticated command handling writes only to command_receipts_v2.
    private static let schemaV6 = """
    CREATE TABLE IF NOT EXISTS host_resources(
      trust_group_id TEXT NOT NULL, host_device_id TEXT NOT NULL,
      host_endpoint_id TEXT NOT NULL, resource_id TEXT NOT NULL,
      generation INTEGER NOT NULL CHECK(generation > 0),
      state TEXT NOT NULL CHECK(state IN ('active', 'retired')),
      envelope BLOB NOT NULL,
      PRIMARY KEY(trust_group_id, host_device_id, resource_id));
    CREATE TABLE IF NOT EXISTS command_receipts_v2(
      command_id TEXT PRIMARY KEY, trust_group_id TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      command_fingerprint BLOB NOT NULL CHECK(length(command_fingerprint)=32),
      host_device_id TEXT NOT NULL, host_endpoint_id TEXT NOT NULL,
      resource_id TEXT NOT NULL, resource_generation INTEGER NOT NULL CHECK(resource_generation > 0),
      state TEXT NOT NULL
        CHECK(state IN ('accepted', 'executing', 'executed', 'failed', 'rejected', 'expired')),
      receipt BLOB NOT NULL,
      UNIQUE(trust_group_id, host_device_id, idempotency_key));
    CREATE INDEX IF NOT EXISTS command_receipts_v2_recovery
      ON command_receipts_v2(host_device_id, state);
    UPDATE schema_metadata SET version=6;
    """

    private static let schemaV7 = """
    CREATE TABLE IF NOT EXISTS migration_cutovers(
      trust_group_id TEXT PRIMARY KEY,
      inventory_digest BLOB NOT NULL CHECK(length(inventory_digest)=32),
      generation INTEGER NOT NULL CHECK(generation > 0),
      mode TEXT NOT NULL CHECK(mode IN ('shadow', 'distributed', 'rolled-back')),
      envelope BLOB NOT NULL);
    UPDATE schema_metadata SET version=7;
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
