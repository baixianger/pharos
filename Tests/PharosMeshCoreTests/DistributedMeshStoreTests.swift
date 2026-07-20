import Crypto
import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshProtocol

final class DistributedMeshStoreTests: XCTestCase {
    func testStoreUsesWALAndPersistsVerifiedHashChainIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)

        let schemaVersion = try await store.schemaVersion()
        let journalMode = try await store.journalMode()
        XCTAssertEqual(schemaVersion, 1)
        XCTAssertEqual(journalMode.lowercased(), "wal")
        try await store.setMembershipEpoch(1, for: fixture.group)

        let first = try fixture.signedEvent(sequence: 1, payload: "one")
        let firstInsertion = try await store.insert(first, authorPublicKey: fixture.publicKey)
        let duplicateInsertion = try await store.insert(first, authorPublicKey: fixture.publicKey)
        XCTAssertEqual(firstInsertion, .inserted)
        XCTAssertEqual(duplicateInsertion, .duplicate)

        let firstHash = try DistributedMeshCrypto.digest(first)
        let second = try fixture.signedEvent(sequence: 2, payload: "two", previousHash: firstHash)
        let secondInsertion = try await store.insert(second, authorPublicKey: fixture.publicKey)
        XCTAssertEqual(secondInsertion, .inserted)

        let heads = try await store.authorHeads(for: fixture.group)
        XCTAssertEqual(heads, [MeshAuthorHead(endpointID: fixture.endpoint, sequence: 2,
                                              eventHash: try DistributedMeshCrypto.digest(second))])
        let events = try await store.events(for: fixture.group, author: fixture.endpoint, after: 0)
        XCTAssertEqual(events, [first, second])
    }

    func testStoreRejectsGapWrongHashAndRevokedEpoch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(2, for: fixture.group)

        let oldEpoch = try fixture.signedEvent(sequence: 1, payload: "old", epoch: 1)
        do {
            _ = try await store.insert(oldEpoch, authorPublicKey: fixture.publicKey)
            XCTFail("expected membership epoch rejection")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError,
                           .membershipEpochMismatch(expected: 2, actual: 1))
        }

        let gap = try fixture.signedEvent(sequence: 2, payload: "gap", epoch: 2,
                                          previousHash: Data(repeating: 1, count: 32))
        do {
            _ = try await store.insert(gap, authorPublicKey: fixture.publicKey)
            XCTFail("expected sequence rejection")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError,
                           .authorSequenceGap(expected: 1, actual: 2))
        }

        let first = try fixture.signedEvent(sequence: 1, payload: "one", epoch: 2)
        _ = try await store.insert(first, authorPublicKey: fixture.publicKey)
        let wrongHash = try fixture.signedEvent(sequence: 2, payload: "two", epoch: 2,
                                                previousHash: Data(repeating: 9, count: 32))
        do {
            _ = try await store.insert(wrongHash, authorPublicKey: fixture.publicKey)
            XCTFail("expected hash rejection")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .authorHashMismatch)
        }
    }

    func testAcceptedReceiptIsDurableIdempotencyGate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let host = MeshDeviceID()
        let sender = MeshDeviceID()
        let resource = try XCTUnwrap(MeshResourceID(rawValue: "tmux/session"))
        let command = MeshHostCommand(
            trustGroupID: fixture.group, senderDeviceID: sender,
            targetHostDeviceID: host, targetHostEndpointID: fixture.endpoint,
            resourceID: resource, expectedResourceGeneration: 7, action: .stop,
            idempotencyKey: "stop/tmux-session/generation-7",
            createdAt: .init(wallTimeMilliseconds: 100), deadlineMilliseconds: 1_000
        )
        let accepted = try await store.accept(
            command, on: host, currentResourceGeneration: 7,
            acceptedAt: .init(wallTimeMilliseconds: 110)
        )
        XCTAssertEqual(accepted.state, .accepted)

        var retry = command
        retry.id = MeshCommandID()
        let replay = try await store.accept(
            retry, on: host, currentResourceGeneration: 7,
            acceptedAt: .init(wallTimeMilliseconds: 900)
        )
        XCTAssertEqual(replay, accepted)

        var collision = retry
        collision.action = .spawn
        do {
            _ = try await store.accept(collision, on: host, currentResourceGeneration: 7,
                                       acceptedAt: .init(wallTimeMilliseconds: 115))
            XCTFail("same idempotency key must not alias different work")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .idempotencyCollision)
        }

        let lateReplay = try await store.accept(
            command, on: host, currentResourceGeneration: 8,
            acceptedAt: .init(wallTimeMilliseconds: 120)
        )
        XCTAssertEqual(lateReplay, accepted)

        var staleNewCommand = command
        staleNewCommand.id = MeshCommandID()
        staleNewCommand.idempotencyKey = "stop/tmux-session/new-command"
        do {
            _ = try await store.accept(staleNewCommand, on: host, currentResourceGeneration: 8,
                                       acceptedAt: .init(wallTimeMilliseconds: 120))
            XCTFail("expected generation rejection")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError,
                           .commandGenerationMismatch(expected: 8, actual: 7))
        }

        let executing = try await store.transitionReceipt(
            commandID: command.id, to: .executing, at: .init(wallTimeMilliseconds: 130)
        )
        XCTAssertEqual(executing.state, .executing)
        let executed = try await store.transitionReceipt(
            commandID: command.id, to: .executed, at: .init(wallTimeMilliseconds: 140),
            result: Data("ok".utf8)
        )
        XCTAssertEqual(executed.state, .executed)
        let storedExecuted = try await store.commandReceipt(id: command.id)
        XCTAssertEqual(storedExecuted, executed)

        let reopenedStore = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let reopenedReceipt = try await reopenedStore.commandReceipt(id: command.id)
        XCTAssertEqual(reopenedReceipt, executed)

        do {
            _ = try await store.transitionReceipt(
                commandID: command.id, to: .executing, at: .init(wallTimeMilliseconds: 150)
            )
            XCTFail("terminal receipt must not execute again")
        } catch {
            XCTAssertEqual(error as? MeshSchemaValidationError, .invalidStateTransition)
        }
    }

    private final class Fixture {
        let directory: URL
        let databaseURL: URL
        let group = MeshTrustGroupID()
        let device = MeshDeviceID()
        let endpoint = MeshEndpointID(rawValue: "fixture-author")!
        let privateKey = Curve25519.Signing.PrivateKey()
        var publicKey: Data { privateKey.publicKey.rawRepresentation }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pharos-distributed-store-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            databaseURL = directory.appendingPathComponent("replica.sqlite")
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func signedEvent(sequence: UInt64, payload: String, epoch: UInt64 = 1,
                         previousHash: Data? = nil) throws -> MeshReplicatedEvent {
            let event = MeshReplicatedEvent(
                id: .generate(), trustGroupID: group, authorDeviceID: device,
                authorEndpointID: endpoint, authorSequence: sequence,
                membershipEpoch: epoch,
                hybridTimestamp: .init(wallTimeMilliseconds: Int64(sequence * 100)),
                entity: MeshEntityReference(type: .message, id: "message-\(sequence)")!,
                operation: MeshOperationName(rawValue: "message.create.v1")!,
                payload: Data(payload.utf8), previousEventHash: previousHash
            )
            return try DistributedMeshCrypto.sign(event, with: privateKey)
        }
    }
}
