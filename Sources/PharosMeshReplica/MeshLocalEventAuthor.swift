import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshLocalEventAuthorError: Error, Equatable, Sendable {
    case missingMembershipEpoch
    case concurrentWriterDidNotSettle
}

/// Authors one device's signed hash chain without assuming it is the only
/// process using that device identity. Sequence/hash races are retried against
/// SQLite's committed head; HLC state is rebuilt from that head after restart.
public actor MeshLocalEventAuthor {
    private let replica: MeshLocalReplica
    private let trustGroupID: MeshTrustGroupID
    private let nowMilliseconds: @Sendable () -> Int64
    private var clock = MeshHybridClock()

    public init(
        replica: MeshLocalReplica,
        trustGroupID: MeshTrustGroupID,
        nowMilliseconds: @escaping @Sendable () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1_000)
        }
    ) {
        self.replica = replica
        self.trustGroupID = trustGroupID
        self.nowMilliseconds = nowMilliseconds
    }

    @discardableResult
    public func setField(
        _ field: String, value: Data,
        on entity: MeshEntityReference
    ) async throws -> MeshReplicatedEvent {
        let mutation = MeshFieldMutation(field: field, value: value)
        return try await append(
            entity: entity, operation: .fieldSetV1,
            payload: mutation.canonicalBytes()
        )
    }

    @discardableResult
    public func deleteField(
        _ field: String, on entity: MeshEntityReference
    ) async throws -> MeshReplicatedEvent {
        let mutation = MeshFieldMutation(field: field, value: nil, isDeleted: true)
        return try await append(
            entity: entity, operation: .fieldSetV1,
            payload: mutation.canonicalBytes()
        )
    }

    @discardableResult
    public func putImmutable(
        _ value: Data, on entity: MeshEntityReference
    ) async throws -> MeshReplicatedEvent {
        try await append(entity: entity, operation: .immutablePutV1, payload: value)
    }

    @discardableResult
    public func append(
        entity: MeshEntityReference, operation: MeshOperationName, payload: Data
    ) async throws -> MeshReplicatedEvent {
        let endpoint = try replica.identity.endpointID()
        let publicKey = try replica.identity.signingPublicKeyBytes()

        for _ in 0..<16 {
            guard let epoch = try await replica.store.membershipEpoch(
                for: trustGroupID
            ) else {
                throw MeshLocalEventAuthorError.missingMembershipEpoch
            }
            let state = try await replica.store.localAuthorState(
                in: trustGroupID, endpoint: endpoint
            )
            let now = nowMilliseconds()
            let timestamp: MeshHybridTimestamp
            if let previous = state.lastTimestamp {
                timestamp = try clock.observe(previous, nowMilliseconds: now)
            } else {
                timestamp = try clock.tick(nowMilliseconds: now)
            }
            let event = try DistributedMeshCrypto.sign(
                MeshReplicatedEvent(
                    id: .generate(), trustGroupID: trustGroupID,
                    authorDeviceID: replica.identity.deviceID,
                    authorEndpointID: endpoint,
                    authorSequence: (state.head?.sequence ?? 0) + 1,
                    membershipEpoch: epoch, hybridTimestamp: timestamp,
                    entity: entity, operation: operation, payload: payload,
                    previousEventHash: state.head?.eventHash
                ),
                with: replica.identity
            )
            do {
                _ = try await replica.store.insert(
                    event, authorPublicKey: publicKey
                )
                return event
            } catch let error as DistributedMeshStoreError {
                switch error {
                case .authorSequenceGap, .authorHashMismatch,
                     .nonMonotonicHybridTimestamp:
                    continue
                default:
                    throw error
                }
            }
        }
        throw MeshLocalEventAuthorError.concurrentWriterDidNotSettle
    }
}
