import Foundation
import Crypto
import PharosMeshProtocol
import SQLite3

public enum DistributedMeshStoreError: Error, Equatable, Sendable {
    case openFailed(String)
    case sqlite(code: Int32, message: String)
    case eventIDCollision
    case authorSequenceGap(expected: UInt64, actual: UInt64)
    case authorHashMismatch
    case membershipEpochMismatch(expected: UInt64, actual: UInt64)
    case wrongCommandHost
    case commandGenerationMismatch(expected: UInt64, actual: UInt64)
    case idempotencyCollision
    case corruptStoredValue
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

/// One serialized SQLite connection per local replica. No method contacts a
/// broker or network transport; callers explicitly choose the database URL.
public actor DistributedMeshStore {
    private let databaseAddress: UInt
    private var database: OpaquePointer { OpaquePointer(bitPattern: databaseAddress)! }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL) throws {
        var handle: OpaquePointer?
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
            try Self.execute(handle, sql: Self.schema)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        databaseAddress = UInt(bitPattern: handle)
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

    /// Inserts only a structurally and cryptographically verified event. The
    /// caller supplies the trusted membership public key; this method checks it
    /// before opening the write transaction.
    public func insert(_ event: MeshReplicatedEvent, authorPublicKey: Data) throws -> MeshEventInsertion {
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
            return .inserted
        }
    }

    public func authorHeads(for group: MeshTrustGroupID) throws -> [MeshAuthorHead] {
        try query(
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
        try query(
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

    private enum Binding {
        case integer(Int64)
        case text(String)
        case blob(Data)
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

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private static func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS schema_metadata(version INTEGER NOT NULL);
    INSERT INTO schema_metadata(version) SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM schema_metadata);
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
}

private enum MeshCanonicalStoreJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
