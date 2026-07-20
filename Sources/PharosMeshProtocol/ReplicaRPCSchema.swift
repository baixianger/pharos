import Foundation

public enum MeshReplicaRPCOperation: String, Codable, CaseIterable, Sendable {
    case syncVector = "sync.vector.v1"
    case syncRange = "sync.range.v1"
    case syncAcknowledge = "sync.acknowledge.v1"
    case blobManifest = "blob.manifest.v1"
    case blobChunk = "blob.chunk.v1"
    case hostCommand = "host.command.v1"
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

    public var version: Int
    public var requestID: UUID
    public var operation: MeshReplicaRPCOperation
    public var trustGroupID: MeshTrustGroupID
    public var membershipEpoch: UInt64
    public var disposition: MeshReplicaRPCDisposition
    public var metadata: Data?
    public var errorCode: String?

    public init(
        version: Int = Self.version, requestID: UUID = UUID(),
        operation: MeshReplicaRPCOperation, trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64, disposition: MeshReplicaRPCDisposition,
        metadata: Data? = nil, errorCode: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
        self.trustGroupID = trustGroupID
        self.membershipEpoch = membershipEpoch
        self.disposition = disposition
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
        switch disposition {
        case .request, .success:
            guard errorCode == nil else {
                throw MeshReplicaRPCValidationError.invalidDisposition
            }
        case .failure:
            guard let errorCode, Self.isSafeErrorCode(errorCode), metadata == nil else {
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
