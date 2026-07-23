import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum DistributedMeshCryptoError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidSignature
}

/// Crypto operations stay outside the portable schema target. Membership code
/// must first bind this public key to the event's trusted device and endpoint.
public enum DistributedMeshCrypto {
    public static func sign(
        _ event: MeshReplicatedEvent, with identity: MeshDeviceIdentity
    ) throws -> MeshReplicatedEvent {
        var signed = event
        signed.signature = try identity.signature(for: event.canonicalSigningBytes())
        try signed.validateStructure()
        return signed
    }

    public static func sign(_ event: MeshReplicatedEvent,
                            with privateKey: Curve25519.Signing.PrivateKey) throws -> MeshReplicatedEvent {
        var signed = event
        signed.signature = try privateKey.signature(for: event.canonicalSigningBytes())
        try signed.validateStructure()
        return signed
    }

    public static func verify(_ event: MeshReplicatedEvent, publicKey: Data) throws {
        try event.validateStructure()
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw DistributedMeshCryptoError.invalidPublicKey
        }
        guard key.isValidSignature(event.signature, for: try event.canonicalSigningBytes()) else {
            throw DistributedMeshCryptoError.invalidSignature
        }
    }

    public static func digest(_ event: MeshReplicatedEvent) throws -> Data {
        Data(SHA256.hash(data: try event.canonicalBytes()))
    }
}
