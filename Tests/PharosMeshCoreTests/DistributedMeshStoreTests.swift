import Crypto
import CSQLite
import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol

final class DistributedMeshStoreTests: XCTestCase {
    func testStoreUsesWALAndPersistsVerifiedHashChainIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)

        let schemaVersion = try await store.schemaVersion()
        let journalMode = try await store.journalMode()
        XCTAssertEqual(schemaVersion, 2)
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

    func testV1MigrationPreservesStateAndRejectsFutureSchema() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try executeSQLite(
            at: fixture.databaseURL,
            sql: """
            CREATE TABLE schema_metadata(version INTEGER NOT NULL);
            INSERT INTO schema_metadata VALUES(1);
            CREATE TABLE membership_epochs(
              trust_group_id TEXT PRIMARY KEY, epoch INTEGER NOT NULL CHECK(epoch > 0));
            INSERT INTO membership_epochs VALUES('\(fixture.group.rawValue.uuidString)', 9);
            """
        )

        let migrated = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let migratedVersion = try await migrated.schemaVersion()
        let migratedEpoch = try await migrated.membershipEpoch(for: fixture.group)
        XCTAssertEqual(migratedVersion, 2)
        XCTAssertEqual(migratedEpoch, 9)

        let futureURL = fixture.directory.appendingPathComponent("future.sqlite")
        try executeSQLite(
            at: futureURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(3);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: futureURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsupportedSchemaVersion(3))
        }

        let ambiguousURL = fixture.directory.appendingPathComponent("ambiguous.sqlite")
        try executeSQLite(
            at: ambiguousURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(1); " +
                 "INSERT INTO schema_metadata VALUES(2);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: ambiguousURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .corruptStoredValue)
        }
    }

    func testPairingRedemptionIsDurableAcrossRestartAndSingleUseAcrossConnections() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inviter = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let acceptor = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let invitation: MeshTrustInvitation
        do {
            let issuingStore = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            let issuingService = MeshTrustPairingService(
                identity: inviter, invitationStore: issuingStore
            )
            invitation = try await issuingService.issueInvitation(
                trustGroupID: fixture.group,
                membershipEpoch: 1,
                inviterAddressTicket: "isolated-inviter-ticket",
                requestedRoles: [.replica],
                now: now
            )
        }

        let acceptorService = MeshTrustPairingService(
            identity: acceptor, invitationStore: MeshMemoryInvitationUseStore()
        )
        let acceptance = try acceptorService.createAcceptance(
            for: invitation,
            acceptingAddressTicket: "isolated-acceptor-ticket",
            displayName: "Test iPhone",
            now: now
        )

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let reopenedService = MeshTrustPairingService(identity: inviter, invitationStore: reopened)
        _ = try await reopenedService.redeem(acceptance, for: invitation, now: now)

        let reopenedAgain = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let persistedDevice = try await reopenedAgain.trustedDevice(
            in: fixture.group, id: acceptor.deviceID
        )
        XCTAssertEqual(persistedDevice?.descriptor.endpointID, try acceptor.endpointID())
        XCTAssertEqual(persistedDevice?.addressTicket, "isolated-acceptor-ticket")
        let finalService = MeshTrustPairingService(
            identity: inviter, invitationStore: reopenedAgain
        )
        do {
            _ = try await finalService.redeem(acceptance, for: invitation, now: now)
            XCTFail("a consumed invitation must remain consumed after reopen")
        } catch {
            XCTAssertEqual(error as? MeshTrustPairingError, .invitationAlreadyConsumed)
        }
    }

    func testConcurrentSQLiteConnectionsHaveExactlyOnePairingWinner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inviter = MeshDeviceIdentity.generate()
        let acceptor = MeshDeviceIdentity.generate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let issuingStore = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let issuingService = MeshTrustPairingService(identity: inviter, invitationStore: issuingStore)
        let invitation = try await issuingService.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 1,
            inviterAddressTicket: "isolated-inviter-ticket",
            requestedRoles: [.controller],
            now: now
        )
        let acceptance = try MeshTrustPairingService(
            identity: acceptor, invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: invitation,
            acceptingAddressTicket: "isolated-acceptor-ticket",
            displayName: "Concurrent Test Device",
            now: now
        )
        let stores = try (0..<8).map { _ in
            try DistributedMeshStore(databaseURL: fixture.databaseURL)
        }

        let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for store in stores {
                group.addTask {
                    let service = MeshTrustPairingService(
                        identity: inviter, invitationStore: store
                    )
                    do {
                        _ = try await service.redeem(acceptance, for: invitation, now: now)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 }.count, 1)
    }

    func testMembershipEpochAdvanceRevokesPendingInvitationWithoutTrustingDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let inviter = MeshDeviceIdentity.generate()
        let acceptor = MeshDeviceIdentity.generate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = MeshTrustPairingService(identity: inviter, invitationStore: store)
        let invitation = try await service.issueInvitation(
            trustGroupID: fixture.group,
            membershipEpoch: 1,
            inviterAddressTicket: "isolated-inviter-ticket",
            requestedRoles: [.replica],
            now: now
        )
        let acceptance = try MeshTrustPairingService(
            identity: acceptor, invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: invitation,
            acceptingAddressTicket: "isolated-acceptor-ticket",
            displayName: "Revoked Test Device",
            now: now
        )

        try await store.setMembershipEpoch(2, for: fixture.group)
        do {
            _ = try await service.redeem(acceptance, for: invitation, now: now)
            XCTFail("an epoch change must revoke pending invitations")
        } catch {
            XCTAssertEqual(error as? MeshTrustPairingError, .membershipEpochMismatch)
        }
        let trusted = try await store.trustedDevice(in: fixture.group, id: acceptor.deviceID)
        XCTAssertNil(trusted)
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

private func executeSQLite(at url: URL, sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil
    ) == SQLITE_OK, let database else {
        throw NSError(domain: "DistributedMeshStoreTests", code: 1)
    }
    defer { sqlite3_close(database) }
    var message: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(database, sql, nil, nil, &message)
    guard result == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? "sqlite error \(result)"
        sqlite3_free(message)
        throw NSError(domain: "DistributedMeshStoreTests", code: Int(result),
                      userInfo: [NSLocalizedDescriptionKey: detail])
    }
}
