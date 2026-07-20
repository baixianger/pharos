import Foundation

/// UUIDv7 keeps event identifiers globally unique while retaining useful
/// creation-time locality in SQLite indexes. Ordering still uses the HLC below.
public struct MeshEventID: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: UUID

    public init?(rawValue: UUID) {
        var bytes = rawValue.uuid
        let version = withUnsafeBytes(of: &bytes) { ($0[6] & 0xf0) >> 4 }
        guard version == 7 else { return nil }
        self.rawValue = rawValue
    }

    public static func generate(at date: Date = Date()) -> Self {
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1_000))
        var random = SystemRandomNumberGenerator()
        var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &random) }
        bytes[0] = UInt8(truncatingIfNeeded: milliseconds >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: milliseconds >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: milliseconds >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: milliseconds >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: milliseconds >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: milliseconds)
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                               bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11],
                               bytes[12], bytes[13], bytes[14], bytes[15]))
        return MeshEventID(rawValue: uuid)!
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }
}

/// Hybrid logical time is deterministic under clock skew. The author endpoint
/// remains the final conflict-resolution tie-break outside this value.
public struct MeshHybridTimestamp: Codable, Hashable, Comparable, Sendable {
    public var wallTimeMilliseconds: Int64
    public var logical: UInt32

    public init(wallTimeMilliseconds: Int64, logical: UInt32 = 0) {
        self.wallTimeMilliseconds = wallTimeMilliseconds
        self.logical = logical
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.wallTimeMilliseconds != rhs.wallTimeMilliseconds {
            return lhs.wallTimeMilliseconds < rhs.wallTimeMilliseconds
        }
        return lhs.logical < rhs.logical
    }
}

/// Extensible rather than an enum so a newer peer can retain and forward an
/// entity type it cannot yet materialize.
public struct MeshEntityType: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard MeshSchemaText.isSafeToken(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let trustGroup = MeshEntityType(rawValue: "trust-group")!
    public static let project = MeshEntityType(rawValue: "project")!
    public static let issue = MeshEntityType(rawValue: "issue")!
    public static let room = MeshEntityType(rawValue: "room")!
    public static let roomMembership = MeshEntityType(rawValue: "room-membership")!
    public static let message = MeshEntityType(rawValue: "message")!
    public static let attachment = MeshEntityType(rawValue: "attachment")!
}

public struct MeshEntityReference: Codable, Hashable, Sendable {
    public var type: MeshEntityType
    public var id: String

    public init?(type: MeshEntityType, id: String) {
        guard MeshSchemaText.isSafeIdentifier(id) else { return nil }
        self.type = type
        self.id = id
    }
}

public struct MeshOperationName: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard MeshSchemaText.isSafeToken(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

/// Immutable wire/storage primitive. `signature` is Ed25519 and covers
/// `canonicalSigningBytes()`. Hash chains use the digest of `canonicalBytes()`.
public struct MeshReplicatedEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: MeshEventID
    public var trustGroupID: MeshTrustGroupID
    public var authorDeviceID: MeshDeviceID
    public var authorEndpointID: MeshEndpointID
    public var authorSequence: UInt64
    public var membershipEpoch: UInt64
    public var hybridTimestamp: MeshHybridTimestamp
    public var entity: MeshEntityReference
    public var operation: MeshOperationName
    public var payload: Data
    public var previousEventHash: Data?
    public var signature: Data

    public init(id: MeshEventID, trustGroupID: MeshTrustGroupID,
                authorDeviceID: MeshDeviceID, authorEndpointID: MeshEndpointID,
                authorSequence: UInt64, membershipEpoch: UInt64,
                hybridTimestamp: MeshHybridTimestamp, entity: MeshEntityReference,
                operation: MeshOperationName, payload: Data,
                previousEventHash: Data?, signature: Data = Data()) {
        self.id = id
        self.trustGroupID = trustGroupID
        self.authorDeviceID = authorDeviceID
        self.authorEndpointID = authorEndpointID
        self.authorSequence = authorSequence
        self.membershipEpoch = membershipEpoch
        self.hybridTimestamp = hybridTimestamp
        self.entity = entity
        self.operation = operation
        self.payload = payload
        self.previousEventHash = previousEventHash
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        guard authorSequence > 0, authorSequence <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidAuthorSequence
        }
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidMembershipEpoch
        }
        guard payload.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSchemaValidationError.payloadTooLarge
        }
        if authorSequence == 1 {
            guard previousEventHash == nil else { throw MeshSchemaValidationError.invalidPreviousHash }
        } else {
            guard previousEventHash?.count == 32 else { throw MeshSchemaValidationError.invalidPreviousHash }
        }
        if requireSignature, signature.count != 64 {
            throw MeshSchemaValidationError.invalidSignature
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshCanonicalJSON.encode(UnsignedEvent(event: self))
    }

    public func canonicalBytes() throws -> Data {
        try MeshCanonicalJSON.encode(self)
    }

    private struct UnsignedEvent: Codable {
        var id: MeshEventID
        var trustGroupID: MeshTrustGroupID
        var authorDeviceID: MeshDeviceID
        var authorEndpointID: MeshEndpointID
        var authorSequence: UInt64
        var membershipEpoch: UInt64
        var hybridTimestamp: MeshHybridTimestamp
        var entity: MeshEntityReference
        var operation: MeshOperationName
        var payload: Data
        var previousEventHash: Data?

        init(event: MeshReplicatedEvent) {
            id = event.id
            trustGroupID = event.trustGroupID
            authorDeviceID = event.authorDeviceID
            authorEndpointID = event.authorEndpointID
            authorSequence = event.authorSequence
            membershipEpoch = event.membershipEpoch
            hybridTimestamp = event.hybridTimestamp
            entity = event.entity
            operation = event.operation
            payload = event.payload
            previousEventHash = event.previousEventHash
        }
    }
}

public enum MeshSchemaValidationError: Error, Equatable, Sendable {
    case invalidAuthorSequence
    case invalidMembershipEpoch
    case invalidPreviousHash
    case invalidSignature
    case invalidDeadline
    case invalidResourceGeneration
    case invalidStateTransition
    case payloadTooLarge
}

enum MeshCanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }
}

enum MeshSchemaText {
    static func isSafeToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
            value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0)
            }
    }

    static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 &&
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
