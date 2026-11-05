import Crypto
import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshProtocol

final class DistributedMeshCryptoTests: XCTestCase {
    func testSignedEventVerifiesAndTamperingFails() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let event = makeEvent(payload: Data("hello".utf8))
        let signed = try DistributedMeshCrypto.sign(event, with: privateKey)

        XCTAssertEqual(signed.signature.count, 64)
        XCTAssertNoThrow(try DistributedMeshCrypto.verify(
            signed, publicKey: privateKey.publicKey.rawRepresentation
        ))

        var tampered = signed
        tampered.payload = Data("goodbye".utf8)
        XCTAssertThrowsError(try DistributedMeshCrypto.verify(
            tampered, publicKey: privateKey.publicKey.rawRepresentation
        )) {
            XCTAssertEqual($0 as? DistributedMeshCryptoError, .invalidSignature)
        }
    }

    func testDigestIncludesSignatureAndBuildsAuthorHashChain() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let first = try DistributedMeshCrypto.sign(makeEvent(payload: Data("one".utf8)), with: privateKey)
        let firstDigest = try DistributedMeshCrypto.digest(first)
        XCTAssertEqual(firstDigest.count, 32)

        var second = makeEvent(payload: Data("two".utf8), sequence: 2)
        second.previousEventHash = firstDigest
        second = try DistributedMeshCrypto.sign(second, with: privateKey)
        try DistributedMeshCrypto.verify(second, publicKey: privateKey.publicKey.rawRepresentation)
        XCTAssertNotEqual(try DistributedMeshCrypto.digest(second), firstDigest)
    }

    private func makeEvent(payload: Data, sequence: UInt64 = 1) -> MeshReplicatedEvent {
        MeshReplicatedEvent(
            id: .generate(), trustGroupID: MeshTrustGroupID(),
            authorDeviceID: MeshDeviceID(),
            authorEndpointID: MeshEndpointID(rawValue: "author-endpoint")!,
            authorSequence: sequence, membershipEpoch: 1,
            hybridTimestamp: .init(wallTimeMilliseconds: 1_721_467_260_000),
            entity: MeshEntityReference(type: .message, id: UUID().uuidString)!,
            operation: MeshOperationName(rawValue: "message.create.v1")!,
            payload: payload, previousEventHash: nil
        )
    }
}
