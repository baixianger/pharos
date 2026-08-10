import Crypto
import Foundation
import PharosMeshProtocol

/// Content-addressed attachment metadata and local verified blob cache.
/// Metadata is immutable replicated state; bytes are fetched lazily through a
/// trusted replica RPC and are never embedded in the event log.
public actor DistributedAttachmentRegistry {
    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let author: MeshLocalEventAuthor

    public init(replica: MeshLocalReplica, group: MeshTrustGroupID) {
        self.replica = replica
        self.group = group
        author = MeshLocalEventAuthor(replica: replica, trustGroupID: group)
    }

    @discardableResult
    public func put(
        data: Data, name rawName: String, mediaType: String
    ) async throws -> MeshAttachment {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw DistributedAttachmentRegistryError.invalidName }

        let digestData = Data(SHA256.hash(data: data))
        guard let digest = MeshBlobDigest(rawValue: digestData) else {
            throw DistributedAttachmentRegistryError.invalidDigest
        }
        let manifest = MeshBlobManifest(
            digest: digest, byteSize: UInt64(data.count), mediaType: mediaType
        )
        try manifest.validate()
        try await replica.store.registerBlobManifest(manifest)
        if try await replica.store.blobState(for: digest) != .complete {
            for index in 0..<manifest.chunkCount {
                let start = index * manifest.chunkSize
                let count = try manifest.expectedByteCount(forChunk: index)
                let bytes = data.subdata(in: start..<(start + count))
                _ = try await replica.store.receiveBlobChunk(MeshBlobChunk(
                    blobDigest: digest, index: index, data: bytes,
                    chunkDigest: MeshBlobDigest(
                        rawValue: Data(SHA256.hash(data: bytes))
                    )!
                ))
            }
            try await replica.store.finalizeBlob(digest)
        }

        let attachment = MeshAttachment(
            name: name, mimeType: mediaType,
            byteSize: data.count, sha256: digest.hex
        )
        guard let entity = MeshEntityReference(
            type: .attachment, id: attachment.id
        ) else { throw DistributedAttachmentRegistryError.invalidEntity }
        _ = try await author.putImmutable(try Self.encode(attachment), on: entity)
        return attachment
    }

    public func metadata(id: String) async throws -> MeshAttachment? {
        guard let entity = MeshEntityReference(type: .attachment, id: id),
              let value = try await replica.store.materializedImmutableValue(
                for: entity, in: group
              ) else { return nil }
        let attachment = try Self.decode(MeshAttachment.self, from: value)
        try Self.validate(attachment)
        return attachment
    }

    public func allMetadata() async throws -> [MeshAttachment] {
        var result: [MeshAttachment] = []
        for entity in try await replica.store.materializedImmutableEntities(
            of: .attachment, in: group
        ) {
            guard let value = try await replica.store.materializedImmutableValue(
                for: entity, in: group
            ), let attachment = try? Self.decode(MeshAttachment.self, from: value),
                  (try? Self.validate(attachment)) != nil
            else { continue }
            result.append(attachment)
        }
        return result.sorted { $0.id < $1.id }
    }

    public func localData(for attachment: MeshAttachment) async throws -> Data? {
        try Self.validate(attachment)
        guard let digest = Self.digest(fromHex: attachment.sha256) else {
            throw DistributedAttachmentRegistryError.invalidDigest
        }
        return try await replica.store.blobData(for: digest)
    }

    public static func digest(for attachment: MeshAttachment) throws -> MeshBlobDigest {
        try validate(attachment)
        guard let digest = digest(fromHex: attachment.sha256) else {
            throw DistributedAttachmentRegistryError.invalidDigest
        }
        return digest
    }

    private static func validate(_ attachment: MeshAttachment) throws {
        guard !attachment.id.isEmpty, attachment.id.utf8.count <= 512,
              !attachment.name.isEmpty, attachment.name.utf8.count <= 255,
              attachment.byteSize >= 0,
              attachment.byteSize <= DistributedMeshProtocol.maximumBlobBytes,
              digest(fromHex: attachment.sha256) != nil else {
            throw DistributedAttachmentRegistryError.invalidMetadata
        }
    }

    private static func digest(fromHex text: String) -> MeshBlobDigest? {
        guard text.utf8.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = text.startIndex
        for _ in 0..<32 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return MeshBlobDigest(rawValue: data)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum DistributedAttachmentRegistryError: LocalizedError, Equatable, Sendable {
    case invalidName
    case invalidDigest
    case invalidEntity
    case invalidMetadata

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Attachment names must contain 1–255 printable UTF-8 bytes."
        case .invalidDigest: "The attachment digest is invalid."
        case .invalidEntity: "Could not create a valid replicated attachment entity."
        case .invalidMetadata: "The replicated attachment metadata is invalid."
        }
    }
}
