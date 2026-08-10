import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

public enum LegacyMeshMigrationError: Error, Equatable, Sendable {
    case unsafeSourceDirectory
    case missingRegistry
    case unsupportedFile(String)
    case malformedRegistry
    case malformedMailboxStore
    case malformedTranscript(String)
    case duplicateEntity(String)
    case invalidAttachment(String)
    case fileTooLarge(String)
    case inventoryMismatch
}

public enum LegacyMigrationFileKind: String, Codable, Sendable {
    case registry
    case mailboxes
    case transcript
    case attachmentMetadata = "attachment-metadata"
    case attachmentData = "attachment-data"
}

public struct LegacyMigrationInventoryEntry: Codable, Equatable, Sendable {
    public var relativePath: String
    public var kind: LegacyMigrationFileKind
    public var byteSize: UInt64
    public var sha256: Data
}

public struct LegacyMigrationCounts: Codable, Equatable, Sendable {
    public var projects: Int
    public var issues: Int
    public var rooms: Int
    public var messages: Int
    public var memberships: Int
    public var unreadMessages: Int
    public var attachments: Int
}

public struct LegacyMigrationInventory: Codable, Equatable, Sendable {
    public static let version = 1
    public var version: Int
    public var files: [LegacyMigrationInventoryEntry]
    public var counts: LegacyMigrationCounts

    public init(files: [LegacyMigrationInventoryEntry], counts: LegacyMigrationCounts) {
        version = Self.version
        self.files = files.sorted { $0.relativePath < $1.relativePath }
        self.counts = counts
    }

    public func digest() throws -> Data {
        Data(SHA256.hash(data: try LegacyMigrationJSON.encode(self)))
    }
}

public struct LegacyMigrationBlob: Equatable, Sendable {
    public var manifest: MeshBlobManifest
    public var data: Data
}

public struct LegacyMeshMigrationExport: Sendable {
    public var inventory: LegacyMigrationInventory
    public var genesis: MeshReplicaSnapshotBundle
    public var blobs: [LegacyMigrationBlob]
}

/// Offline-only legacy export/import. The caller must pass a source root; this
/// type never resolves MeshPaths, environment variables, sockets, or endpoints.
public enum LegacyMeshMigration {
    private static let maximumLegacyFileBytes = UInt64(
        DistributedMeshProtocol.maximumBlobBytes
    )

    public static func export(
        sourceRoot: URL, trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64, identity: MeshDeviceIdentity
    ) throws -> LegacyMeshMigrationExport {
        let root = sourceRoot.standardizedFileURL
        try requireDirectory(root)
        let registryURL = root.appendingPathComponent("projects.json")
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            throw LegacyMeshMigrationError.missingRegistry
        }

        var entries: [LegacyMigrationInventoryEntry] = []
        var fields: [MeshSnapshotField] = []
        var immutable: [MeshSnapshotImmutable] = []
        var blobs: [LegacyMigrationBlob] = []
        var seenFields = Set<String>()
        var seenImmutableEntities = Set<String>()
        let endpoint = try identity.endpointID()

        let registryData = try readRegularFile(registryURL)
        entries.append(inventoryEntry("projects.json", .registry, registryData))
        let legacyIssueAttachments = root.appendingPathComponent(
            "attachments", isDirectory: true
        )
        let registryObject = try JSONSerialization.jsonObject(with: registryData)
        let projects: [[String: Any]]
        let groups: [String]
        let trash: [[String: Any]]
        if let flatProjects = registryObject as? [[String: Any]] {
            projects = flatProjects
            groups = []
            trash = []
        } else if let store = registryObject as? [String: Any],
                  let storeProjects = store["projects"] as? [[String: Any]] {
            projects = storeProjects
            groups = store["groups"] as? [String] ?? []
            trash = store["trash"] as? [[String: Any]] ?? []
        } else {
            throw LegacyMeshMigrationError.malformedRegistry
        }
        var issueCount = 0
        for (index, project) in projects.enumerated() {
            guard let identifier = project["id"] as? String, UUID(uuidString: identifier) != nil else {
                throw LegacyMeshMigrationError.malformedRegistry
            }
            let issues = project["issues"] as? [[String: Any]] ?? []
            issueCount += issues.count
            try appendRegistryFields(
                type: .project, id: identifier, object: project,
                allowedFields: [
                    "name", "githubRemote", "tags", "yolo", "tmux", "addedAt",
                    "playbooks", "notes", "updates", "milestones",
                ],
                sourceKey: "projects.json#\(index)", endpoint: endpoint,
                to: &fields, seen: &seenFields
            )
            for (issueIndex, issue) in issues.enumerated() {
                guard let issueID = issue["id"] as? String,
                      UUID(uuidString: issueID) != nil else {
                    throw LegacyMeshMigrationError.malformedRegistry
                }
                var replicatedIssue = issue
                replicatedIssue["projectID"] = identifier
                if var attachments = issue["attachments"] as? [[String: Any]] {
                    for attachmentIndex in attachments.indices {
                        guard let attachmentID = attachments[attachmentIndex]["id"] as? String,
                              UUID(uuidString: attachmentID) != nil,
                              let storedName = attachments[attachmentIndex]["storedName"] as? String,
                              !storedName.isEmpty,
                              let originalName = attachments[attachmentIndex]["originalName"] as? String,
                              let expectedSize = attachments[attachmentIndex]["byteSize"] as? NSNumber
                        else { throw LegacyMeshMigrationError.malformedRegistry }
                        let file = legacyIssueAttachments
                            .appendingPathComponent(issueID, isDirectory: true)
                            .appendingPathComponent(storedName)
                        guard file.standardizedFileURL.path.hasPrefix(
                            legacyIssueAttachments.standardizedFileURL.path + "/"
                        ), FileManager.default.fileExists(atPath: file.path) else {
                            throw LegacyMeshMigrationError.invalidAttachment(attachmentID)
                        }
                        let bytes = try readRegularFile(file)
                        guard bytes.count == expectedSize.intValue else {
                            throw LegacyMeshMigrationError.invalidAttachment(attachmentID)
                        }
                        let digestBytes = Data(SHA256.hash(data: bytes))
                        let attachment = MeshAttachment(
                            id: attachmentID, name: originalName,
                            mimeType: legacyMIMEType(for: storedName),
                            byteSize: bytes.count, sha256: hex(digestBytes)
                        )
                        let relative = "attachments/\(issueID)/\(storedName)"
                        entries.append(inventoryEntry(relative, .attachmentData, bytes))
                        let digest = MeshBlobDigest(rawValue: digestBytes)!
                        blobs.append(LegacyMigrationBlob(
                            manifest: MeshBlobManifest(
                                digest: digest, byteSize: UInt64(bytes.count),
                                mediaType: attachment.mimeType, chunkSize: 1024 * 1024
                            ),
                            data: bytes
                        ))
                        try appendImmutable(
                            type: .attachment, id: attachmentID,
                            value: try LegacyMigrationJSON.encode(attachment),
                            sourceKey: relative, endpoint: endpoint,
                            to: &immutable, seen: &seenImmutableEntities
                        )
                        attachments[attachmentIndex]["meshAttachment"] =
                            try JSONSerialization.jsonObject(
                                with: LegacyMigrationJSON.encode(attachment)
                            )
                    }
                    replicatedIssue["attachments"] = attachments
                }
                try appendRegistryFields(
                    type: .issue, id: issueID, object: replicatedIssue,
                    allowedFields: [
                        "projectID", "number", "title", "status", "priority", "body",
                        "createdAt", "updatedAt", "attachments", "labels", "sortOrder",
                        "milestoneID", "parent", "relations",
                    ],
                    sourceKey: "projects.json#\(index).issues#\(issueIndex)",
                    endpoint: endpoint, to: &fields, seen: &seenFields
                )
            }
        }
        for (index, name) in groups.enumerated() {
            try appendRegistryFields(
                type: .projectGroup,
                id: deterministicIdentifier("projects.json#groups#\(index):\(name)"),
                object: ["name": name], allowedFields: ["name"],
                sourceKey: "projects.json#groups#\(index)", endpoint: endpoint,
                to: &fields, seen: &seenFields
            )
        }
        for (index, item) in trash.enumerated() {
            guard let identifier = item["id"] as? String,
                  UUID(uuidString: identifier) != nil else {
                throw LegacyMeshMigrationError.malformedRegistry
            }
            try appendRegistryFields(
                type: .trashItem, id: identifier, object: item,
                allowedFields: ["deletedAt", "payload"],
                sourceKey: "projects.json#trash#\(index)", endpoint: endpoint,
                to: &fields, seen: &seenFields
            )
        }

        let mailboxURL = root.appendingPathComponent("mesh-mailboxes.json")
        let mailboxStore: LegacyMailboxStore
        if FileManager.default.fileExists(atPath: mailboxURL.path) {
            let data = try readRegularFile(mailboxURL)
            entries.append(inventoryEntry("mesh-mailboxes.json", .mailboxes, data))
            guard let decoded = try? JSONDecoder().decode(LegacyMailboxStore.self, from: data),
                  decoded.version == 1 else {
                throw LegacyMeshMigrationError.malformedMailboxStore
            }
            mailboxStore = decoded
        } else {
            mailboxStore = LegacyMailboxStore(version: 1, rooms: [:])
        }

        let meshRoot = root.appendingPathComponent("mesh", isDirectory: true)
        var transcripts: [String: [MeshMsg]] = [:]
        if FileManager.default.fileExists(atPath: meshRoot.path) {
            try requireDirectory(meshRoot)
            for url in try directoryContents(meshRoot) where url.pathExtension == "jsonl" {
                let room = url.deletingPathExtension().lastPathComponent
                let relativePath = "mesh/\(url.lastPathComponent)"
                let data = try readRegularFile(url)
                entries.append(inventoryEntry(relativePath, .transcript, data))
                var messages: [MeshMsg] = []
                for (index, line) in data.split(separator: 0x0a).enumerated() {
                    guard let message = try? JSONDecoder().decode(MeshMsg.self, from: Data(line)),
                          message.room == room else {
                        throw LegacyMeshMigrationError.malformedTranscript(relativePath)
                    }
                    messages.append(message)
                    try appendImmutable(
                        type: .message,
                        id: deterministicIdentifier("\(relativePath)#\(index)"),
                        value: try LegacyMigrationJSON.encode(message),
                        sourceKey: "\(relativePath)#\(index)", endpoint: endpoint,
                        timestamp: timestamp(message.ts),
                        to: &immutable, seen: &seenImmutableEntities
                    )
                }
                transcripts[room] = messages
            }
        }

        let roomNames = Set(mailboxStore.rooms.keys).union(transcripts.keys).sorted()
        var membershipCount = 0
        var unreadCount = 0
        for room in roomNames {
            let stored = mailboxStore.rooms[room] ?? LegacyMailboxRoom(members: [:], mailboxes: [:])
            membershipCount += stored.members.count
            unreadCount += stored.mailboxes.values.reduce(0) { $0 + $1.count }
            let roomState = LegacyRoomGenesis(
                name: room, members: stored.members,
                unreadByMember: stored.mailboxes,
                transcriptMessageCount: transcripts[room]?.count ?? 0
            )
            try appendImmutable(
                type: .room, id: room, value: try LegacyMigrationJSON.encode(roomState),
                sourceKey: "room:\(room)", endpoint: endpoint,
                to: &immutable, seen: &seenImmutableEntities
            )
        }

        let attachmentsRoot = meshRoot.appendingPathComponent("attachments", isDirectory: true)
        if FileManager.default.fileExists(atPath: attachmentsRoot.path) {
            try requireDirectory(attachmentsRoot)
            for directory in try directoryContents(attachmentsRoot) {
                try requireDirectory(directory)
                let identifier = directory.lastPathComponent
                let metadataURL = directory.appendingPathComponent("metadata.json")
                let dataURL = directory.appendingPathComponent("data")
                let metadata = try readRegularFile(metadataURL)
                let bytes = try readRegularFile(dataURL)
                guard let attachment = try? JSONDecoder().decode(MeshAttachment.self, from: metadata),
                      attachment.id == identifier,
                      attachment.byteSize == bytes.count,
                      attachment.sha256.lowercased() == hex(SHA256.hash(data: bytes)),
                      bytes.count <= DistributedMeshProtocol.maximumBlobBytes else {
                    throw LegacyMeshMigrationError.invalidAttachment(identifier)
                }
                let base = "mesh/attachments/\(identifier)"
                entries.append(inventoryEntry("\(base)/metadata.json", .attachmentMetadata, metadata))
                entries.append(inventoryEntry("\(base)/data", .attachmentData, bytes))
                let digest = MeshBlobDigest(rawValue: Data(SHA256.hash(data: bytes)))!
                blobs.append(LegacyMigrationBlob(
                    manifest: MeshBlobManifest(
                        digest: digest, byteSize: UInt64(bytes.count),
                        mediaType: attachment.mimeType, chunkSize: 1024 * 1024
                    ),
                    data: bytes
                ))
                try appendImmutable(
                    type: .attachment, id: identifier,
                    value: try LegacyMigrationJSON.encode(attachment),
                    sourceKey: "\(base)/metadata.json", endpoint: endpoint,
                    to: &immutable, seen: &seenImmutableEntities
                )
            }
        }

        let inventory = LegacyMigrationInventory(
            files: entries,
            counts: LegacyMigrationCounts(
                projects: projects.count, issues: issueCount, rooms: roomNames.count,
                messages: transcripts.values.reduce(0) { $0 + $1.count },
                memberships: membershipCount, unreadMessages: unreadCount,
                attachments: blobs.count
            )
        )
        let inventoryData = try LegacyMigrationJSON.encode(inventory)
        try appendImmutable(
            type: .trustGroup, id: "legacy-inventory-v1", value: inventoryData,
            sourceKey: "legacy-inventory-v1", endpoint: endpoint,
            to: &immutable, seen: &seenImmutableEntities
        )
        let state = try MeshReplicaState(fields: fields, immutableValues: immutable)
        let digest = try inventory.digest()
        let genesis = try deterministicGenesis(
            trustGroupID: trustGroupID, membershipEpoch: membershipEpoch,
            identity: identity, inventoryDigest: digest, state: state
        )
        return LegacyMeshMigrationExport(
            inventory: inventory, genesis: genesis,
            blobs: blobs.sorted { $0.manifest.digest.hex < $1.manifest.digest.hex }
        )
    }

    public static func install(
        _ migration: LegacyMeshMigrationExport,
        into store: DistributedMeshStore,
        creatorPublicKey: Data
    ) async throws {
        _ = try validate(migration)
        try await installBlobs(migration, into: store)
        try await store.installSnapshot(migration.genesis, creatorPublicKey: creatorPublicKey)
    }

    public static func installForShadow(
        _ migration: LegacyMeshMigrationExport,
        into store: DistributedMeshStore, creatorPublicKey: Data,
        expectedGeneration: UInt64?
    ) async throws -> MeshMigrationCutoverState {
        let digest = try validate(migration)
        try await installBlobs(migration, into: store)
        return try await store.installMigrationSnapshot(
            migration.genesis, creatorPublicKey: creatorPublicKey,
            inventoryDigest: digest, expectedGeneration: expectedGeneration
        )
    }

    private static func validate(
        _ migration: LegacyMeshMigrationExport
    ) throws -> Data {
        let expected = try migration.inventory.digest()
        let embedded = migration.genesis.state.immutableValues.first {
            $0.entity.type == .trustGroup && $0.entity.id == "legacy-inventory-v1"
        }?.value
        let inventoryBlobs = migration.inventory.files.filter {
            $0.kind == .attachmentData
        }.map { ($0.sha256, $0.byteSize) }
        let suppliedBlobs = migration.blobs.map {
            ($0.manifest.digest.rawValue, $0.manifest.byteSize)
        }
        guard migration.genesis.snapshot.id == deterministicEventID(expected),
              embedded == (try LegacyMigrationJSON.encode(migration.inventory)),
              inventoryBlobs.count == migration.inventory.counts.attachments,
              suppliedBlobs.count == inventoryBlobs.count,
              zip(inventoryBlobs.sorted(by: blobTupleLessThan),
                  suppliedBlobs.sorted(by: blobTupleLessThan)).allSatisfy({
                    $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1
                  }) else {
            throw LegacyMeshMigrationError.inventoryMismatch
        }
        return expected
    }

    private static func installBlobs(
        _ migration: LegacyMeshMigrationExport,
        into store: DistributedMeshStore
    ) async throws {
        for blob in migration.blobs {
            guard Data(SHA256.hash(data: blob.data)) == blob.manifest.digest.rawValue,
                  UInt64(blob.data.count) == blob.manifest.byteSize else {
                throw LegacyMeshMigrationError.inventoryMismatch
            }
            try await store.registerBlobManifest(blob.manifest)
            if try await store.blobState(for: blob.manifest.digest) == .complete {
                guard try await store.blobData(for: blob.manifest.digest) == blob.data else {
                    throw LegacyMeshMigrationError.inventoryMismatch
                }
                continue
            }
            for index in 0..<blob.manifest.chunkCount {
                let start = index * blob.manifest.chunkSize
                let count = try blob.manifest.expectedByteCount(forChunk: index)
                let bytes = blob.data.subdata(in: start..<(start + count))
                _ = try await store.receiveBlobChunk(MeshBlobChunk(
                    blobDigest: blob.manifest.digest, index: index, data: bytes,
                    chunkDigest: MeshBlobDigest(
                        rawValue: Data(SHA256.hash(data: bytes))
                    )!
                ))
            }
            try await store.finalizeBlob(blob.manifest.digest)
        }
    }

    private static func blobTupleLessThan(
        _ lhs: (Data, UInt64), _ rhs: (Data, UInt64)
    ) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0.lexicographicallyPrecedes(rhs.0) }
        return lhs.1 < rhs.1
    }

    private static func deterministicGenesis(
        trustGroupID: MeshTrustGroupID, membershipEpoch: UInt64,
        identity: MeshDeviceIdentity, inventoryDigest: Data,
        state: MeshReplicaState
    ) throws -> MeshReplicaSnapshotBundle {
        let endpoint = try identity.endpointID()
        var headSeed = Data("legacy-migration-genesis-head-v1".utf8)
        headSeed.append(inventoryDigest)
        let virtualGenesisHead = MeshSnapshotAuthorHead(
            endpointID: endpoint, sequence: 1,
            eventHash: Data(SHA256.hash(data: headSeed))
        )
        var snapshot = MeshReplicaSnapshot(
            id: deterministicEventID(inventoryDigest), trustGroupID: trustGroupID,
            membershipEpoch: membershipEpoch, creatorDeviceID: identity.deviceID,
            creatorEndpointID: endpoint,
            createdAt: .init(wallTimeMilliseconds: 0),
            authorHeads: [virtualGenesisHead],
            stateDigest: try MeshReplicaSnapshotCrypto.digest(state)
        )
        snapshot.signature = try identity.signature(for: snapshot.canonicalSigningBytes())
        try snapshot.validate()
        return MeshReplicaSnapshotBundle(snapshot: snapshot, state: state)
    }

    private static func appendImmutable(
        type: MeshEntityType, id: String, value: Data, sourceKey: String,
        endpoint: MeshEndpointID, timestamp: MeshHybridTimestamp = .init(wallTimeMilliseconds: 0),
        to values: inout [MeshSnapshotImmutable], seen: inout Set<String>
    ) throws {
        guard let entity = MeshEntityReference(type: type, id: id) else {
            throw LegacyMeshMigrationError.duplicateEntity(id)
        }
        let key = "\(type.rawValue)\u{0}\(id)"
        guard seen.insert(key).inserted else {
            throw LegacyMeshMigrationError.duplicateEntity(id)
        }
        values.append(MeshSnapshotImmutable(
            entity: entity, value: value,
            sourceEventID: deterministicEventID(Data(sourceKey.utf8)),
            timestamp: timestamp, authorEndpointID: endpoint
        ))
    }

    private static func appendRegistryFields(
        type: MeshEntityType, id: String, object: [String: Any],
        allowedFields: [String], sourceKey: String, endpoint: MeshEndpointID,
        to fields: inout [MeshSnapshotField], seen: inout Set<String>
    ) throws {
        guard let entity = MeshEntityReference(type: type, id: id) else {
            throw LegacyMeshMigrationError.malformedRegistry
        }
        var values: [(String, Any)] = [("_deleted", false)]
        values += allowedFields.compactMap { field in
            guard let value = object[field], !(value is NSNull) else { return nil }
            return (field, value)
        }
        for (field, value) in values {
            let key = "\(type.rawValue)\u{0}\(id)\u{0}\(field)"
            guard seen.insert(key).inserted else {
                throw LegacyMeshMigrationError.duplicateEntity(id)
            }
            let fieldSource = "\(sourceKey)#\(field)"
            fields.append(MeshSnapshotField(
                entity: entity,
                mutation: MeshFieldMutation(
                    field: field, value: try canonicalJSONObject(value)
                ),
                sourceEventID: deterministicEventID(Data(fieldSource.utf8)),
                timestamp: .init(wallTimeMilliseconds: 0),
                authorEndpointID: endpoint
            ))
        }
    }

    private static func deterministicIdentifier(_ value: String) -> String {
        hex(SHA256.hash(data: Data(value.utf8)))
    }

    private static func legacyMIMEType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "md", "markdown": return "text/markdown"
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private static func deterministicEventID(_ seed: Data) -> MeshEventID {
        let digest = Array(SHA256.hash(data: seed))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return MeshEventID(rawValue: uuid)!
    }

    private static func inventoryEntry(
        _ path: String, _ kind: LegacyMigrationFileKind, _ data: Data
    ) -> LegacyMigrationInventoryEntry {
        LegacyMigrationInventoryEntry(
            relativePath: path, kind: kind, byteSize: UInt64(data.count),
            sha256: Data(SHA256.hash(data: data))
        )
    }

    private static func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LegacyMeshMigrationError.unsafeSourceDirectory
        }
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LegacyMeshMigrationError.unsafeSourceDirectory
        }
        guard let size = values.fileSize, size >= 0,
              UInt64(size) <= maximumLegacyFileBytes else {
            throw LegacyMeshMigrationError.fileTooLarge(url.lastPathComponent)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private static func directoryContents(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey,
                                                   .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func canonicalJSONObject(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]
            )
        } catch {
            throw LegacyMeshMigrationError.malformedRegistry
        }
    }

    private static func timestamp(_ seconds: Double) -> MeshHybridTimestamp {
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds <= Double(Int64.max) else {
            return .init(wallTimeMilliseconds: 0)
        }
        return .init(wallTimeMilliseconds: Int64(milliseconds))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct LegacyMailboxStore: Codable {
    var version: Int
    var rooms: [String: LegacyMailboxRoom]
}

private struct LegacyMailboxRoom: Codable {
    var members: [String: String]
    var mailboxes: [String: [MeshMsg]]
}

private struct LegacyRoomGenesis: Codable {
    var name: String
    var members: [String: String]
    var unreadByMember: [String: [MeshMsg]]
    var transcriptMessageCount: Int
}

private enum LegacyMigrationJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }
}
