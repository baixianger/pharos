import Foundation

public struct MeshSnapshotAuthorHead: Codable, Equatable, Sendable {
    public var endpointID: MeshEndpointID
    public var sequence: UInt64
    public var eventHash: Data

    public init(endpointID: MeshEndpointID, sequence: UInt64, eventHash: Data) {
        self.endpointID = endpointID
        self.sequence = sequence
        self.eventHash = eventHash
    }

    public func validate() throws {
        guard sequence > 0, sequence <= UInt64(Int64.max) else {
            throw MeshSnapshotValidationError.invalidAuthorHead
        }
        guard eventHash.count == 32 else {
            throw MeshSnapshotValidationError.invalidAuthorHead
        }
    }
}

public struct MeshSnapshotField: Codable, Equatable, Sendable {
    public var entity: MeshEntityReference
    public var mutation: MeshFieldMutation
    public var sourceEventID: MeshEventID
    public var timestamp: MeshHybridTimestamp
    public var authorEndpointID: MeshEndpointID

    public init(entity: MeshEntityReference, mutation: MeshFieldMutation,
                sourceEventID: MeshEventID, timestamp: MeshHybridTimestamp,
                authorEndpointID: MeshEndpointID) {
        self.entity = entity
        self.mutation = mutation
        self.sourceEventID = sourceEventID
        self.timestamp = timestamp
        self.authorEndpointID = authorEndpointID
    }

    public func validate() throws { try mutation.validate() }
}

public struct MeshSnapshotImmutable: Codable, Equatable, Sendable {
    public var entity: MeshEntityReference
    public var value: Data
    public var sourceEventID: MeshEventID
    public var timestamp: MeshHybridTimestamp
    public var authorEndpointID: MeshEndpointID

    public init(entity: MeshEntityReference, value: Data, sourceEventID: MeshEventID,
                timestamp: MeshHybridTimestamp, authorEndpointID: MeshEndpointID) {
        self.entity = entity
        self.value = value
        self.sourceEventID = sourceEventID
        self.timestamp = timestamp
        self.authorEndpointID = authorEndpointID
    }

    public func validate() throws {
        guard value.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSnapshotValidationError.snapshotTooLarge
        }
    }
}

public struct MeshReplicaState: Codable, Equatable, Sendable {
    public var fields: [MeshSnapshotField]
    public var immutableValues: [MeshSnapshotImmutable]

    public init(fields: [MeshSnapshotField], immutableValues: [MeshSnapshotImmutable]) throws {
        self.fields = fields.sorted(by: Self.fieldLessThan)
        self.immutableValues = immutableValues.sorted(by: Self.immutableLessThan)
        try validate()
    }

    public func validate() throws {
        guard fields == fields.sorted(by: Self.fieldLessThan),
              immutableValues == immutableValues.sorted(by: Self.immutableLessThan) else {
            throw MeshSnapshotValidationError.nonCanonicalState
        }
        for field in fields { try field.validate() }
        for immutable in immutableValues { try immutable.validate() }
        for index in fields.indices.dropFirst() {
            let previous = fields[fields.index(before: index)]
            let current = fields[index]
            if previous.entity == current.entity &&
                previous.mutation.field == current.mutation.field {
                throw MeshSnapshotValidationError.duplicateEntityState
            }
        }
        for index in immutableValues.indices.dropFirst() {
            let previous = immutableValues[immutableValues.index(before: index)]
            let current = immutableValues[index]
            if previous.entity == current.entity {
                throw MeshSnapshotValidationError.duplicateEntityState
            }
        }
        guard try canonicalBytes().count <= DistributedMeshProtocol.maximumBlobBytes else {
            throw MeshSnapshotValidationError.snapshotTooLarge
        }
    }

    public func canonicalBytes() throws -> Data {
        try MeshSnapshotJSON.encode(self)
    }

    private static func fieldLessThan(_ lhs: MeshSnapshotField,
                                      _ rhs: MeshSnapshotField) -> Bool {
        let left = (lhs.entity.type.rawValue, lhs.entity.id, lhs.mutation.field)
        let right = (rhs.entity.type.rawValue, rhs.entity.id, rhs.mutation.field)
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        return left.2 < right.2
    }

    private static func immutableLessThan(_ lhs: MeshSnapshotImmutable,
                                          _ rhs: MeshSnapshotImmutable) -> Bool {
        if lhs.entity.type.rawValue != rhs.entity.type.rawValue {
            return lhs.entity.type.rawValue < rhs.entity.type.rawValue
        }
        return lhs.entity.id < rhs.entity.id
    }
}

public struct MeshReplicaSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id: MeshEventID
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var creatorDeviceID: MeshDeviceID
    public var creatorEndpointID: MeshEndpointID
    public var createdAt: MeshHybridTimestamp
    public var authorHeads: [MeshSnapshotAuthorHead]
    public var stateDigest: Data
    public var signature: Data

    public init(id: MeshEventID = .generate(), trustGroupID: MeshTrustGroupID,
                membershipEpoch: UInt64, creatorDeviceID: MeshDeviceID,
                creatorEndpointID: MeshEndpointID, createdAt: MeshHybridTimestamp,
                authorHeads: [MeshSnapshotAuthorHead], stateDigest: Data,
                signature: Data = Data()) {
        self.id = id
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.creatorDeviceID = creatorDeviceID
        self.creatorEndpointID = creatorEndpointID
        self.createdAt = createdAt
        self.authorHeads = authorHeads.sorted { $0.endpointID < $1.endpointID }
        self.stateDigest = stateDigest
        self.signature = signature
    }

    public func validate(requireSignature: Bool = true) throws {
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshSnapshotValidationError.invalidMembershipEpoch
        }
        guard stateDigest.count == 32 else { throw MeshSnapshotValidationError.invalidStateDigest }
        if requireSignature, signature.count != 64 {
            throw MeshSnapshotValidationError.invalidSignature
        }
        var previous: MeshEndpointID?
        var seen: Set<MeshEndpointID> = []
        for head in authorHeads {
            try head.validate()
            guard seen.insert(head.endpointID).inserted else {
                throw MeshSnapshotValidationError.duplicateAuthor
            }
            if let previous, previous > head.endpointID {
                throw MeshSnapshotValidationError.nonCanonicalHeads
            }
            previous = head.endpointID
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshSnapshotJSON.encode(Unsigned(snapshot: self))
    }

    private struct Unsigned: Codable {
        var id: MeshEventID
        var trustGroupID: MeshTrustGroupID
        var membershipEpoch: UInt64
        var creatorDeviceID: MeshDeviceID
        var creatorEndpointID: MeshEndpointID
        var createdAt: MeshHybridTimestamp
        var authorHeads: [MeshSnapshotAuthorHead]
        var stateDigest: Data

        init(snapshot: MeshReplicaSnapshot) {
            id = snapshot.id
            trustGroupID = snapshot.trustGroupID
            membershipEpoch = snapshot.membershipEpoch
            creatorDeviceID = snapshot.creatorDeviceID
            creatorEndpointID = snapshot.creatorEndpointID
            createdAt = snapshot.createdAt
            authorHeads = snapshot.authorHeads
            stateDigest = snapshot.stateDigest
        }
    }
}

public struct MeshReplicaSnapshotBundle: Codable, Equatable, Sendable {
    public var snapshot: MeshReplicaSnapshot
    public var state: MeshReplicaState

    public init(snapshot: MeshReplicaSnapshot, state: MeshReplicaState) {
        self.snapshot = snapshot
        self.state = state
    }
}

public enum MeshSnapshotValidationError: Error, Equatable, Sendable {
    case invalidMembershipEpoch
    case invalidAuthorHead
    case invalidStateDigest
    case invalidSignature
    case duplicateAuthor
    case nonCanonicalHeads
    case nonCanonicalState
    case duplicateEntityState
    case snapshotTooLarge
}

private enum MeshSnapshotJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }
}
