import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshReplicaRPCError: Error, Equatable, Sendable {
    case invalidHeader
    case invalidBody
    case responseMismatch
    case remoteFailure(String)
    case peerNotTrusted
    case membershipEpochMismatch
    case hostUnavailable
    case synchronizationLimitExceeded
}

public enum MeshHostCommandExecutionOutcome: Equatable, Sendable {
    case executed(Data?)
    case failed(code: String)
}

/// Authenticated application router for one already-identified Iroh peer. The
/// transport supplies `remoteEndpointID` from the QUIC connection; no request
/// field is ever accepted as proof of peer identity.
public struct MeshReplicaRPCServer: Sendable {
    public let store: DistributedMeshStore
    public let hostIdentity: MeshDeviceIdentity?
    private let timestamp: @Sendable () -> MeshHybridTimestamp
    private let hostCommandHandler: (@Sendable (MeshHostCommand) async -> MeshHostCommandExecutionOutcome)?

    public init(
        store: DistributedMeshStore, hostIdentity: MeshDeviceIdentity? = nil,
        timestamp: @escaping @Sendable () -> MeshHybridTimestamp = {
            MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        }
    ) {
        self.store = store
        self.hostIdentity = hostIdentity
        self.hostCommandHandler = nil
        self.timestamp = timestamp
    }

    public init(
        store: DistributedMeshStore, hostIdentity: MeshDeviceIdentity?,
        hostCommandHandler: @escaping @Sendable (MeshHostCommand) async
            -> MeshHostCommandExecutionOutcome,
        timestamp: @escaping @Sendable () -> MeshHybridTimestamp = {
            MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        }
    ) {
        self.store = store
        self.hostIdentity = hostIdentity
        self.hostCommandHandler = hostCommandHandler
        self.timestamp = timestamp
    }

    public func handle(
        _ request: MeshTransportRequest,
        remoteEndpointID: MeshEndpointID
    ) async throws -> MeshTransportResponse {
        try request.validate()
        let header: MeshReplicaRPCHeader
        do { header = try MeshReplicaRPCHeader.decode(request.header) }
        catch { throw MeshReplicaRPCError.invalidHeader }
        guard header.disposition == .request else {
            throw MeshReplicaRPCError.invalidHeader
        }
        guard header.metadata == nil else {
            return try failure(for: header, code: "invalid-request")
        }

        do {
            _ = try await store.authorizeReplicaRPCPeer(
                in: header.trustGroupID, endpointID: remoteEndpointID,
                membershipEpoch: header.membershipEpoch
            )
        } catch let error as DistributedMeshStoreError {
            switch error {
            case .membershipEpochMismatch:
                return try failure(for: header, code: "membership-epoch-mismatch")
            case .rpcPeerNotTrusted:
                return try failure(for: header, code: "peer-not-trusted")
            default:
                return try failure(for: header, code: "request-failed")
            }
        }
        if let ticket = header.senderAddressTicket {
            do {
                try await store.refreshTrustedDeviceAddress(
                    in: header.trustGroupID, endpointID: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch,
                    addressTicket: ticket
                )
            } catch {
                return try failure(for: header, code: "address-refresh-failed")
            }
        }

        do {
            switch header.operation {
            case .syncVector:
                guard request.body == nil, header.metadata == nil else {
                    throw MeshReplicaRPCError.invalidBody
                }
                let vector = try await store.syncVector(
                    for: header.trustGroupID, requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                )
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(vector))

            case .syncRange:
                let range: MeshEventRangeRequest = try decodeBody(request.body)
                guard range.trustGroupID == header.trustGroupID,
                      range.membershipEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                let response = try await store.syncResponse(
                    for: range, requestedBy: remoteEndpointID
                )
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(response))

            case .syncAcknowledge:
                let vector: MeshSyncVector = try decodeBody(request.body)
                guard vector.trustGroupID == header.trustGroupID,
                      vector.membershipEpoch == header.membershipEpoch else {
                    throw MeshReplicaRPCError.invalidBody
                }
                try await store.acknowledge(
                    vector, requestedBy: remoteEndpointID
                )
                return try success(for: header)

            case .blobManifest:
                let blob: MeshBlobDigestRequest = try decodeBody(request.body)
                guard let manifest = try await store.blobManifest(
                    for: blob.digest, in: header.trustGroupID,
                    requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                ) else {
                    return try failure(for: header, code: "blob-not-found")
                }
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(manifest))

            case .blobChunk:
                let blob: MeshBlobChunkRequest = try decodeBody(request.body)
                let chunk = try await store.blobChunk(
                    for: blob.digest, index: blob.index,
                    in: header.trustGroupID, requestedBy: remoteEndpointID,
                    membershipEpoch: header.membershipEpoch
                )
                let metadata = MeshBlobChunkMetadata(
                    digest: chunk.blobDigest, index: chunk.index,
                    byteCount: chunk.data.count, chunkDigest: chunk.chunkDigest
                )
                return try success(
                    for: header, metadata: try metadata.canonicalBytes(), body: chunk.data
                )

            case .hostCommand:
                guard let hostIdentity else {
                    return try failure(for: header, code: "host-unavailable")
                }
                let command: MeshSignedHostCommand = try decodeBody(request.body)
                guard command.command.trustGroupID == header.trustGroupID,
                      command.membershipEpoch == header.membershipEpoch,
                      command.senderEndpointID == remoteEndpointID else {
                    return try failure(for: header, code: "command-identity-mismatch")
                }
                var receipt = try await store.accept(
                    command, on: hostIdentity, receivedAt: timestamp()
                )
                if receipt.receipt.state == .accepted,
                   let hostCommandHandler {
                    let claim = try await store.claimExecution(
                        commandID: command.command.id,
                        on: hostIdentity, at: timestamp()
                    )
                    receipt = claim.receipt
                    if claim.shouldExecute {
                        let outcome = await hostCommandHandler(command.command)
                        switch outcome {
                        case .executed(let result):
                            receipt = try await store.finishExecution(
                                commandID: command.command.id,
                                on: hostIdentity, outcome: .executed,
                                at: timestamp(), result: result
                            )
                        case .failed(let code):
                            receipt = try await store.finishExecution(
                                commandID: command.command.id,
                                on: hostIdentity, outcome: .failed,
                                at: timestamp(), failureCode: code
                            )
                        }
                    }
                }
                return try success(for: header, body: try MeshReplicaRPCJSON.encode(receipt))
            }
        } catch let error as MeshReplicaRPCError {
            switch error {
            case .invalidBody:
                return try failure(for: header, code: "invalid-request")
            default:
                return try failure(for: header, code: "request-failed")
            }
        } catch let error as DistributedMeshStoreError {
            switch error {
            case .membershipEpochMismatch:
                return try failure(for: header, code: "membership-epoch-mismatch")
            case .rpcPeerNotTrusted:
                return try failure(for: header, code: "peer-not-trusted")
            default:
                return try failure(for: header, code: "request-failed")
            }
        } catch {
            return try failure(for: header, code: "request-failed")
        }
    }

    private func success(
        for request: MeshReplicaRPCHeader, metadata: Data? = nil, body: Data? = nil
    ) throws -> MeshTransportResponse {
        let header = MeshReplicaRPCHeader(
            requestID: request.requestID, operation: request.operation,
            trustGroupID: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            disposition: .success, metadata: metadata
        )
        let response = MeshTransportResponse(header: try header.canonicalBytes(), body: body)
        try response.validate()
        return response
    }

    private func failure(
        for request: MeshReplicaRPCHeader, code: String
    ) throws -> MeshTransportResponse {
        let header = MeshReplicaRPCHeader(
            requestID: request.requestID, operation: request.operation,
            trustGroupID: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            disposition: .failure, errorCode: code
        )
        return MeshTransportResponse(header: try header.canonicalBytes())
    }

    private func decodeBody<T: Decodable>(_ body: Data?) throws -> T {
        guard let body else { throw MeshReplicaRPCError.invalidBody }
        do { return try MeshReplicaRPCJSON.decode(T.self, from: body) }
        catch { throw MeshReplicaRPCError.invalidBody }
    }
}

public struct MeshReplicaRPCClient: Sendable {
    private let transport: any MeshTransport

    public init(transport: any MeshTransport) { self.transport = transport }

    public func syncVector(
        for group: MeshTrustGroupID, membershipEpoch: UInt64
    ) async throws -> MeshSyncVector {
        let response = try await exchange(
            operation: .syncVector, group: group, membershipEpoch: membershipEpoch
        )
        let vector: MeshSyncVector = try decodeBody(response.body)
        try vector.validate()
        guard vector.trustGroupID == group,
              vector.membershipEpoch == membershipEpoch else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return vector
    }

    public func eventRange(
        _ request: MeshEventRangeRequest
    ) async throws -> MeshEventRangeResponse {
        let response = try await exchange(
            operation: .syncRange, group: request.trustGroupID,
            membershipEpoch: request.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(request)
        )
        let range: MeshEventRangeResponse = try decodeBody(response.body)
        try range.validate()
        guard range.request == request else { throw MeshReplicaRPCError.responseMismatch }
        return range
    }

    public func acknowledge(_ vector: MeshSyncVector) async throws {
        _ = try await exchange(
            operation: .syncAcknowledge, group: vector.trustGroupID,
            membershipEpoch: vector.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(vector)
        )
    }

    public func blobManifest(
        _ digest: MeshBlobDigest, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> MeshBlobManifest {
        let response = try await exchange(
            operation: .blobManifest, group: group,
            membershipEpoch: membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(MeshBlobDigestRequest(digest: digest))
        )
        let manifest: MeshBlobManifest = try decodeBody(response.body)
        try manifest.validate()
        guard manifest.digest == digest else { throw MeshReplicaRPCError.responseMismatch }
        return manifest
    }

    public func blobChunk(
        _ digest: MeshBlobDigest, index: Int, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> MeshBlobChunk {
        let response = try await exchange(
            operation: .blobChunk, group: group,
            membershipEpoch: membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(
                MeshBlobChunkRequest(digest: digest, index: index)
            )
        )
        guard let metadataBytes = response.header.metadata, let data = response.body else {
            throw MeshReplicaRPCError.invalidBody
        }
        let metadata = try MeshBlobChunkMetadata.decode(metadataBytes)
        guard metadata.digest == digest, metadata.index == index,
              metadata.byteCount == data.count,
              Data(SHA256.hash(data: data)) == metadata.chunkDigest.rawValue else {
            throw MeshReplicaRPCError.responseMismatch
        }
        return MeshBlobChunk(
            blobDigest: digest, index: index, data: data,
            chunkDigest: metadata.chunkDigest
        )
    }

    public func sendHostCommand(
        _ command: MeshSignedHostCommand
    ) async throws -> MeshSignedCommandReceipt {
        let response = try await exchange(
            operation: .hostCommand, group: command.command.trustGroupID,
            membershipEpoch: command.membershipEpoch,
            body: try MeshReplicaRPCJSON.encode(command)
        )
        let receipt: MeshSignedCommandReceipt = try decodeBody(response.body)
        do { try receipt.validateStructure() }
        catch { throw MeshReplicaRPCError.responseMismatch }
        let expectedFingerprint = Data(
            SHA256.hash(data: try command.command.canonicalIdempotencyBytes())
        )
        guard receipt.trustGroupID == command.command.trustGroupID,
              receipt.receipt.commandID == command.command.id,
              receipt.receipt.idempotencyKey == command.command.idempotencyKey,
              receipt.receipt.hostDeviceID == command.command.targetHostDeviceID,
              receipt.hostEndpointID == command.command.targetHostEndpointID,
              receipt.receipt.resourceID == command.command.resourceID,
              receipt.commandFingerprint == expectedFingerprint,
              receipt.deadlineMilliseconds == command.command.deadlineMilliseconds,
              let hostPublicKey = Self.publicKeyData(
                from: command.command.targetHostEndpointID
              ) else {
            throw MeshReplicaRPCError.responseMismatch
        }
        do {
            try MeshHostCommandCrypto.verify(
                receipt, hostPublicKey: hostPublicKey
            )
        } catch {
            throw MeshReplicaRPCError.responseMismatch
        }
        return receipt
    }

    private func exchange(
        operation: MeshReplicaRPCOperation, group: MeshTrustGroupID,
        membershipEpoch: UInt64, metadata: Data? = nil, body: Data? = nil
    ) async throws -> (header: MeshReplicaRPCHeader, body: Data?) {
        let requestHeader = MeshReplicaRPCHeader(
            operation: operation, trustGroupID: group,
            membershipEpoch: membershipEpoch, disposition: .request,
            senderAddressTicket: try await transport.localAddressTicket(),
            metadata: metadata
        )
        let request = MeshTransportRequest(
            header: try requestHeader.canonicalBytes(), body: body
        )
        let response = try await transport.exchange(request)
        try response.validate()
        let responseHeader: MeshReplicaRPCHeader
        do { responseHeader = try MeshReplicaRPCHeader.decode(response.header) }
        catch { throw MeshReplicaRPCError.invalidHeader }
        guard responseHeader.requestID == requestHeader.requestID,
              responseHeader.operation == operation,
              responseHeader.trustGroupID == group,
              responseHeader.membershipEpoch == membershipEpoch,
              responseHeader.disposition != .request else {
            throw MeshReplicaRPCError.responseMismatch
        }
        if responseHeader.disposition == .failure {
            guard response.body == nil else {
                throw MeshReplicaRPCError.responseMismatch
            }
            throw MeshReplicaRPCError.remoteFailure(responseHeader.errorCode ?? "unknown")
        }
        return (responseHeader, response.body)
    }

    private func decodeBody<T: Decodable>(_ body: Data?) throws -> T {
        guard let body else { throw MeshReplicaRPCError.invalidBody }
        do { return try MeshReplicaRPCJSON.decode(T.self, from: body) }
        catch { throw MeshReplicaRPCError.invalidBody }
    }

    private static func publicKeyData(from endpoint: MeshEndpointID) -> Data? {
        let text = endpoint.rawValue
        guard text.utf8.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = text.startIndex
        for _ in 0..<32 {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public struct MeshReplicaSyncReport: Equatable, Sendable {
    public var eventCount: Int
    public var snapshotCount: Int
    public var rangeCount: Int

    public init(eventCount: Int = 0, snapshotCount: Int = 0,
                rangeCount: Int = 0) {
        self.eventCount = eventCount
        self.snapshotCount = snapshotCount
        self.rangeCount = rangeCount
    }
}

/// One bounded pull/ack anti-entropy session. Peers run the same operation in
/// both directions; all writes still pass through the store's signature,
/// membership, sequence, hash-chain, and snapshot verification.
public struct MeshReplicaSyncSession: Sendable {
    public static let maximumRangeRounds = 4_096

    private let store: DistributedMeshStore
    private let client: MeshReplicaRPCClient

    public init(store: DistributedMeshStore, client: MeshReplicaRPCClient) {
        self.store = store
        self.client = client
    }

    public func synchronize(
        group: MeshTrustGroupID, membershipEpoch: UInt64,
        rangeLimit: Int = 256
    ) async throws -> MeshReplicaSyncReport {
        var report = MeshReplicaSyncReport()
        let remote = try await client.syncVector(
            for: group, membershipEpoch: membershipEpoch
        )
        guard remote.trustGroupID == group,
              remote.membershipEpoch == membershipEpoch else {
            throw MeshReplicaRPCError.responseMismatch
        }

        for _ in 0..<Self.maximumRangeRounds {
            let requests = try await store.missingRangeRequests(
                advertisedBy: remote, limit: rangeLimit
            )
            if requests.isEmpty {
                // ACK only the vector this peer advertised. Our local vector
                // can contain offline authors the remote has never received;
                // claiming those here would correctly fail its monotonic
                // acknowledgement validation.
                try await client.acknowledge(remote)
                return report
            }
            for request in requests {
                let response = try await client.eventRange(request)
                report.rangeCount += 1
                switch response.kind {
                case .events:
                    for event in response.events {
                        guard let author = try await store.trustedDevice(
                            in: group, endpointID: event.authorEndpointID,
                            membershipEpoch: membershipEpoch
                        ) else { throw MeshReplicaRPCError.peerNotTrusted }
                        _ = try await store.insert(
                            event, authorPublicKey: author.signingPublicKey
                        )
                        report.eventCount += 1
                    }
                case .snapshot:
                    guard let bundle = response.snapshot,
                          let creator = try await store.trustedDevice(
                            in: group,
                            endpointID: bundle.snapshot.creatorEndpointID,
                            membershipEpoch: membershipEpoch
                          ) else { throw MeshReplicaRPCError.peerNotTrusted }
                    try await store.installSnapshot(
                        bundle, creatorPublicKey: creator.signingPublicKey
                    )
                    report.snapshotCount += 1
                case .upToDate:
                    throw MeshReplicaRPCError.responseMismatch
                }
            }
        }
        throw MeshReplicaRPCError.synchronizationLimitExceeded
    }
}

/// Lazily reconstructs one content-addressed blob from a trusted peer. Every
/// chunk and the final digest are verified by the store before bytes become
/// visible to the product.
public struct MeshBlobFetchSession: Sendable {
    private let store: DistributedMeshStore
    private let client: MeshReplicaRPCClient

    public init(store: DistributedMeshStore, client: MeshReplicaRPCClient) {
        self.store = store
        self.client = client
    }

    public func fetch(
        _ digest: MeshBlobDigest, group: MeshTrustGroupID,
        membershipEpoch: UInt64
    ) async throws -> Data {
        if let existing = try await store.blobData(for: digest) {
            return existing
        }
        let manifest = try await client.blobManifest(
            digest, group: group, membershipEpoch: membershipEpoch
        )
        try await store.registerBlobManifest(manifest)
        for index in try await store.missingBlobChunkIndices(for: digest) {
            let chunk = try await client.blobChunk(
                digest, index: index, group: group,
                membershipEpoch: membershipEpoch
            )
            _ = try await store.receiveBlobChunk(chunk)
        }
        try await store.finalizeBlob(digest)
        guard let data = try await store.blobData(for: digest) else {
            throw MeshReplicaRPCError.invalidBody
        }
        return data
    }
}

private enum MeshReplicaRPCJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }
}
