import Foundation

public enum MeshReplicaRPCOperation: String, Codable, CaseIterable, Sendable {
    case syncVector = "sync.vector.v1"
    case syncRange = "sync.range.v1"
    case syncAcknowledge = "sync.acknowledge.v1"
    case syncOffer = "sync.offer.v1"
    case syncIngest = "sync.ingest.v1"
    case blobManifest = "blob.manifest.v1"
    case blobChunk = "blob.chunk.v1"
    case hostResource = "host.resource.v1"
    case hostPresence = "host.presence.v1"
    case hostCommand = "host.command.v1"
    case membershipTransition = "membership.transition.v1"
    case membershipTransitionNext = "membership.transition.next.v1"
    case membershipVote = "membership.vote.v2"
}

public enum MeshReplicaRPCDisposition: String, Codable, Sendable {
    case request
    case success
    case failure
}

/// Small routing metadata carried in the transport header. Typed application
/// payloads stay in the bounded transport body so event batches and snapshots
/// do not inflate the header through nested base64 encoding.
public struct MeshReplicaRPCHeader: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumMetadataBytes = 64 * 1024
    public static let maximumAddressTicketBytes = 16 * 1024

    public var version: Int
    public var requestID: UUID
    public var operation: MeshReplicaRPCOperation
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var disposition: MeshReplicaRPCDisposition
    public var senderAddressTicket: String?
    public var metadata: Data?
    public var errorCode: String?

    public init(
        version: Int = Self.version, requestID: UUID = UUID(),
        operation: MeshReplicaRPCOperation, trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64, disposition: MeshReplicaRPCDisposition,
        senderAddressTicket: String? = nil,
        metadata: Data? = nil, errorCode: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.disposition = disposition
        self.senderAddressTicket = senderAddressTicket
        self.metadata = metadata
        self.errorCode = errorCode
    }

    public func validate() throws {
        guard version == Self.version else {
            throw MeshReplicaRPCValidationError.unsupportedVersion
        }
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshReplicaRPCValidationError.invalidMembershipEpoch
        }
        guard metadata?.count ?? 0 <= Self.maximumMetadataBytes else {
            throw MeshReplicaRPCValidationError.metadataTooLarge
        }
        if let senderAddressTicket {
            guard !senderAddressTicket.isEmpty,
                  senderAddressTicket.utf8.count <= Self.maximumAddressTicketBytes else {
                throw MeshReplicaRPCValidationError.invalidAddressTicket
            }
        }
        switch disposition {
        case .request:
            guard errorCode == nil else {
                throw MeshReplicaRPCValidationError.invalidDisposition
            }
        case .success:
            guard errorCode == nil, senderAddressTicket == nil else {
                throw MeshReplicaRPCValidationError.invalidDisposition
            }
        case .failure:
            guard let errorCode, Self.isSafeErrorCode(errorCode), metadata == nil,
                  senderAddressTicket == nil else {
                throw MeshReplicaRPCValidationError.invalidDisposition
            }
        }
    }

    public func canonicalBytes() throws -> Data {
        try validate()
        return try MeshReplicaRPCJSON.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshReplicaRPCValidationError.metadataTooLarge
        }
        let value: Self = try MeshReplicaRPCJSON.decode(Self.self, from: data)
        try value.validate()
        return value
    }

    private static func isSafeErrorCode(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}

public struct MeshBlobDigestRequest: Codable, Equatable, Sendable {
    public var digest: MeshBlobDigest

    public init(digest: MeshBlobDigest) { self.digest = digest }
}

public struct MeshBlobChunkRequest: Codable, Equatable, Sendable {
    public var digest: MeshBlobDigest
    public var index: Int

    public init(digest: MeshBlobDigest, index: Int) {
        self.digest = digest
        self.index = index
    }
}

public struct MeshHostResourceRequest: Codable, Equatable, Sendable {
    public var resourceID: MeshResourceID

    public init(resourceID: MeshResourceID) { self.resourceID = resourceID }
}

/// One expiring Host observation for a stable agent resource. Runtime-private
/// details (tmux socket, pane, cwd) never leave the owning Host.
public struct MeshAgentPresenceRecord: Codable, Equatable, Sendable {
    public var resourceID: MeshResourceID
    public var state: MeshSessionState
    public var observedAtMilliseconds: Int64
    public var stateReason: String?
    public var kind: String?

    public init(
        resourceID: MeshResourceID, state: MeshSessionState,
        observedAtMilliseconds: Int64, stateReason: String? = nil,
        kind: String? = nil
    ) {
        self.resourceID = resourceID
        self.state = state
        self.observedAtMilliseconds = observedAtMilliseconds
        self.stateReason = stateReason
        self.kind = kind
    }

    public func validate() throws {
        guard observedAtMilliseconds > 0,
              Self.isSafeOptionalText(stateReason, maximumBytes: 256),
              Self.isSafeOptionalText(kind, maximumBytes: 64) else {
            throw MeshReplicaRPCValidationError.invalidAgentPresence
        }
    }

    private static func isSafeOptionalText(
        _ value: String?, maximumBytes: Int
    ) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }
}

/// Short-lived, Host-authoritative presence. It is transported over the same
/// authenticated peer RPC as replica sync but deliberately is not CRDT state:
/// an unavailable Host must age to unknown instead of leaving a permanent
/// busy/idle value in history.
public struct MeshAgentPresenceSnapshot: Codable, Equatable, Sendable {
    public static let version = 1
    public static let maximumRecords = 2_048
    public static let maximumLifetimeMilliseconds: Int64 = 30_000

    public var version: Int
    public var hostDeviceID: MeshDeviceID
    public var hostEndpointID: MeshEndpointID
    public var generatedAtMilliseconds: Int64
    public var expiresAtMilliseconds: Int64
    public var records: [MeshAgentPresenceRecord]

    public init(
        version: Int = Self.version, hostDeviceID: MeshDeviceID,
        hostEndpointID: MeshEndpointID, generatedAtMilliseconds: Int64,
        expiresAtMilliseconds: Int64,
        records: [MeshAgentPresenceRecord]
    ) {
        self.version = version
        self.hostDeviceID = hostDeviceID
        self.hostEndpointID = hostEndpointID
        self.generatedAtMilliseconds = generatedAtMilliseconds
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.records = records
    }

    public func validate() throws {
        guard version == Self.version,
              generatedAtMilliseconds > 0,
              expiresAtMilliseconds > generatedAtMilliseconds,
              expiresAtMilliseconds - generatedAtMilliseconds
                <= Self.maximumLifetimeMilliseconds,
              records.count <= Self.maximumRecords,
              Set(records.map(\.resourceID)).count == records.count else {
            throw MeshReplicaRPCValidationError.invalidAgentPresence
        }
        try records.forEach { try $0.validate() }
    }

    public func isFresh(
        at nowMilliseconds: Int64,
        allowedClockSkewMilliseconds: Int64 = 5_000
    ) -> Bool {
        generatedAtMilliseconds <= nowMilliseconds + allowedClockSkewMilliseconds
            && expiresAtMilliseconds > nowMilliseconds
    }
}

public struct MeshBlobChunkMetadata: Codable, Equatable, Sendable {
    public var digest: MeshBlobDigest
    public var index: Int
    public var byteCount: Int
    public var chunkDigest: MeshBlobDigest

    public init(digest: MeshBlobDigest, index: Int, byteCount: Int,
                chunkDigest: MeshBlobDigest) {
        self.digest = digest
        self.index = index
        self.byteCount = byteCount
        self.chunkDigest = chunkDigest
    }

    public func validate() throws {
        guard index >= 0, byteCount >= 0,
              byteCount <= MeshBlobManifest.maximumChunkSize else {
            throw MeshReplicaRPCValidationError.invalidBlobChunk
        }
    }

    public func canonicalBytes() throws -> Data {
        try validate()
        return try MeshReplicaRPCJSON.encode(self)
    }

    public static func decode(_ data: Data) throws -> Self {
        let value: Self = try MeshReplicaRPCJSON.decode(Self.self, from: data)
        try value.validate()
        return value
    }
}

public enum MeshReplicaRPCValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidMembershipEpoch
    case metadataTooLarge
    case invalidDisposition
    case invalidBlobChunk
    case invalidAddressTicket
    case invalidAgentPresence
}

private enum MeshReplicaRPCJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }
}
