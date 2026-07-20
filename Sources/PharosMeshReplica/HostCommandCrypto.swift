import Crypto
import Foundation
import PharosMeshIdentity
import PharosMeshProtocol

public enum MeshHostCommandCryptoError: Error, Equatable, Sendable {
    case identityMismatch
    case invalidPublicKey
    case invalidSignature
}

public enum MeshHostCommandCrypto {
    public static func sign(_ command: MeshHostCommand, membershipEpoch: UInt64,
                            with identity: MeshDeviceIdentity) throws
        -> MeshSignedHostCommand {
        guard command.senderDeviceID == identity.deviceID else {
            throw MeshHostCommandCryptoError.identityMismatch
        }
        let endpoint = try identity.endpointID()
        var envelope = MeshSignedHostCommand(
            command: command, membershipEpoch: membershipEpoch,
            senderEndpointID: endpoint
        )
        try envelope.validateStructure(requireSignature: false)
        envelope.signature = try identity.signature(for: envelope.canonicalSigningBytes())
        try envelope.validateStructure()
        return envelope
    }

    public static func verify(_ envelope: MeshSignedHostCommand,
                              senderPublicKey: Data) throws {
        try envelope.validateStructure()
        try verify(signature: envelope.signature,
                   data: envelope.canonicalSigningBytes(), publicKey: senderPublicKey)
    }

    public static func sign(_ receipt: MeshSignedCommandReceipt,
                            with identity: MeshDeviceIdentity) throws
        -> MeshSignedCommandReceipt {
        guard receipt.receipt.hostDeviceID == identity.deviceID,
              receipt.hostEndpointID == (try identity.endpointID()) else {
            throw MeshHostCommandCryptoError.identityMismatch
        }
        var signed = receipt
        try signed.validateStructure(requireSignature: false)
        signed.signature = try identity.signature(for: signed.canonicalSigningBytes())
        try signed.validateStructure()
        return signed
    }

    public static func verify(_ receipt: MeshSignedCommandReceipt,
                              hostPublicKey: Data) throws {
        try receipt.validateStructure()
        try verify(signature: receipt.signature,
                   data: receipt.canonicalSigningBytes(), publicKey: hostPublicKey)
    }

    private static func verify(signature: Data, data: Data, publicKey: Data) throws {
        let key: Curve25519.Signing.PublicKey
        do { key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey) }
        catch { throw MeshHostCommandCryptoError.invalidPublicKey }
        guard key.isValidSignature(signature, for: data) else {
            throw MeshHostCommandCryptoError.invalidSignature
        }
    }
}
