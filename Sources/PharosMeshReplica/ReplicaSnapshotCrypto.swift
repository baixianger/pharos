import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshReplicaSnapshotCryptoError: Error, Equatable, Sendable {
    case invalidPublicKey
    case endpointKeyMismatch
    case stateDigestMismatch
    case invalidSignature
}

public enum MeshReplicaSnapshotCrypto {
    public static func make(
        trustGroupID: MeshTrustGroupID,
        membershipEpoch: UInt64,
        identity: MeshDeviceIdentity,
        createdAt: MeshHybridTimestamp,
        authorHeads: [MeshSnapshotAuthorHead],
        state: MeshReplicaState
    ) throws -> MeshReplicaSnapshotBundle {
        try state.validate()
        var snapshot = MeshReplicaSnapshot(
            trustGroupID: trustGroupID,
            membershipEpoch: membershipEpoch,
            creatorDeviceID: identity.deviceID,
            creatorEndpointID: try identity.endpointID(),
            createdAt: createdAt,
            authorHeads: authorHeads,
            stateDigest: try digest(state)
        )
        snapshot.signature = try identity.signature(for: snapshot.canonicalSigningBytes())
        try snapshot.validate()
        return MeshReplicaSnapshotBundle(snapshot: snapshot, state: state)
    }

    public static func verify(_ bundle: MeshReplicaSnapshotBundle,
                              creatorPublicKey: Data) throws {
        try bundle.snapshot.validate()
        try bundle.state.validate()
        guard try digest(bundle.state) == bundle.snapshot.stateDigest else {
            throw MeshReplicaSnapshotCryptoError.stateDigestMismatch
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: creatorPublicKey)
        } catch {
            throw MeshReplicaSnapshotCryptoError.invalidPublicKey
        }
        let endpoint = creatorPublicKey.map { String(format: "%02x", $0) }.joined()
        guard bundle.snapshot.creatorEndpointID.rawValue == endpoint else {
            throw MeshReplicaSnapshotCryptoError.endpointKeyMismatch
        }
        guard key.isValidSignature(
            bundle.snapshot.signature,
            for: try bundle.snapshot.canonicalSigningBytes()
        ) else {
            throw MeshReplicaSnapshotCryptoError.invalidSignature
        }
    }

    public static func digest(_ state: MeshReplicaState) throws -> Data {
        Data(SHA256.hash(data: try state.canonicalBytes()))
    }
}
