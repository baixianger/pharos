import Foundation

public struct MeshBlobDigest: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == 32 else { return nil }
        self.rawValue = rawValue
    }

    public var hex: String {
        rawValue.map { String(format: "%02x", $0) }.joined()
    }
}

public struct MeshBlobManifest: Codable, Equatable, Sendable {
    public static let defaultChunkSize = 256 * 1024
    public static let maximumChunkSize = 1024 * 1024

    public var digest: MeshBlobDigest
    public var byteSize: UInt64
    public var mediaType: String?
    public var chunkSize: Int

    public init(digest: MeshBlobDigest, byteSize: UInt64,
                mediaType: String? = nil,
                chunkSize: Int = Self.defaultChunkSize) {
        self.digest = digest
        self.byteSize = byteSize
        self.mediaType = mediaType
        self.chunkSize = chunkSize
    }

    public var chunkCount: Int {
        guard byteSize > 0, chunkSize > 0 else { return 0 }
        return Int((byteSize - 1) / UInt64(chunkSize) + 1)
    }

    public func validate() throws {
        guard byteSize <= UInt64(DistributedMeshProtocol.maximumBlobBytes) else {
            throw MeshBlobValidationError.blobTooLarge
        }
        guard (1 ... Self.maximumChunkSize).contains(chunkSize) else {
            throw MeshBlobValidationError.invalidChunkSize
        }
        if let mediaType {
            guard !mediaType.isEmpty, mediaType.utf8.count <= 255,
                  !mediaType.unicodeScalars.contains(
                      where: CharacterSet.controlCharacters.contains
                  ) else {
                throw MeshBlobValidationError.invalidMediaType
            }
        }
    }

    public func expectedByteCount(forChunk index: Int) throws -> Int {
        try validate()
        guard index >= 0, index < chunkCount else {
            throw MeshBlobValidationError.invalidChunkIndex
        }
        if index < chunkCount - 1 { return chunkSize }
        return Int(byteSize - UInt64(index * chunkSize))
    }
}

public struct MeshBlobChunk: Codable, Equatable, Sendable {
    public var blobDigest: MeshBlobDigest
    public var index: Int
    public var data: Data
    public var chunkDigest: MeshBlobDigest

    public init(blobDigest: MeshBlobDigest, index: Int, data: Data,
                chunkDigest: MeshBlobDigest) {
        self.blobDigest = blobDigest
        self.index = index
        self.data = data
        self.chunkDigest = chunkDigest
    }

    public func validate(against manifest: MeshBlobManifest) throws {
        try manifest.validate()
        guard blobDigest == manifest.digest else {
            throw MeshBlobValidationError.manifestMismatch
        }
        guard data.count == (try manifest.expectedByteCount(forChunk: index)) else {
            throw MeshBlobValidationError.invalidChunkLength
        }
    }
}

public enum MeshBlobLocalState: String, Codable, Sendable {
    case pending
    case complete
    case corrupt
    case evicted
}

public enum MeshBlobValidationError: Error, Equatable, Sendable {
    case blobTooLarge
    case invalidChunkSize
    case invalidMediaType
    case invalidChunkIndex
    case invalidChunkLength
    case manifestMismatch
    case chunkDigestMismatch
    case blobDigestMismatch
}
