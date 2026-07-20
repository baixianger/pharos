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
        XCTAssertEqual(schemaVersion, 3)
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

    func testVectorExchangeRequestsOnlyMissingBoundedRangesAndPersistsAcknowledgements() async throws {
        let sourceFixture = try Fixture()
        defer { sourceFixture.remove() }
        let replicaURL = sourceFixture.directory.appendingPathComponent("replica-two.sqlite")
        let source = try DistributedMeshStore(databaseURL: sourceFixture.databaseURL)
        let replica = try DistributedMeshStore(databaseURL: replicaURL)
        try await source.setMembershipEpoch(1, for: sourceFixture.group)
        try await replica.setMembershipEpoch(1, for: sourceFixture.group)

        let secondKey = Curve25519.Signing.PrivateKey()
        let secondEndpoint = try XCTUnwrap(MeshEndpointID(rawValue: "second-author"))
        let secondDevice = MeshDeviceID()
        let first = try sourceFixture.signedEvent(sequence: 1, payload: "one")
        let firstHash = try DistributedMeshCrypto.digest(first)
        let second = try sourceFixture.signedEvent(
            sequence: 2, payload: "two", previousHash: firstHash
        )
        let other = try signedEvent(
            group: sourceFixture.group, device: secondDevice, endpoint: secondEndpoint,
            key: secondKey, sequence: 1, timestamp: .init(wallTimeMilliseconds: 150),
            entity: MeshEntityReference(type: .message, id: "other-message")!,
            operation: MeshOperationName(rawValue: "message.create.v1")!,
            payload: Data("other".utf8)
        )
        _ = try await source.insert(first, authorPublicKey: sourceFixture.publicKey)
        _ = try await source.insert(second, authorPublicKey: sourceFixture.publicKey)
        _ = try await source.insert(other, authorPublicKey: secondKey.publicKey.rawRepresentation)
        _ = try await replica.insert(first, authorPublicKey: sourceFixture.publicKey)

        let advertised = try await source.syncVector(for: sourceFixture.group)
        let requests = try await replica.missingRangeRequests(
            advertisedBy: advertised, limit: 1
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.limit == 1 })
        for request in requests {
            let batch = try await source.eventBatch(for: request)
            XCTAssertEqual(batch.count, 1)
            let key = request.authorEndpointID == sourceFixture.endpoint
                ? sourceFixture.publicKey : secondKey.publicKey.rawRepresentation
            _ = try await replica.insert(batch[0], authorPublicKey: key)
        }
        let replicatedVector = try await replica.syncVector(for: sourceFixture.group)
        XCTAssertEqual(replicatedVector, advertised)

        let peer = MeshDeviceID()
        try await source.acknowledge(advertised, from: peer)
        let persistedAcknowledgement = try await source.acknowledgementVector(
            for: sourceFixture.group, peer: peer
        )
        XCTAssertEqual(persistedAcknowledgement, advertised)
        let regressed = try MeshSyncVector(
            trustGroupID: sourceFixture.group, membershipEpoch: 1,
            authors: [MeshAuthorSequence(endpointID: sourceFixture.endpoint, sequence: 1)]
        )
        do {
            try await source.acknowledge(regressed, from: peer)
            XCTFail("acknowledgements must be monotonic")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .acknowledgementRegression(current: 2, proposed: 1)
            )
        }
    }

    func testFieldMaterializationConvergesAcrossArrivalOrderAndTombstones() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let urls = (0..<3).map {
            fixture.directory.appendingPathComponent("materialized-\($0).sqlite")
        }
        let stores = try urls.map { try DistributedMeshStore(databaseURL: $0) }
        for store in stores { try await store.setMembershipEpoch(1, for: fixture.group) }

        let entity = MeshEntityReference(type: .project, id: "project-1")!
        let keyA = Curve25519.Signing.PrivateKey()
        let keyB = Curve25519.Signing.PrivateKey()
        let endpointA = MeshEndpointID(rawValue: "author-a")!
        let endpointB = MeshEndpointID(rawValue: "author-b")!
        let eventA = try signedFieldEvent(
            group: fixture.group, device: MeshDeviceID(), endpoint: endpointA, key: keyA,
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "name", value: Data("Alpha".utf8))
        )
        let eventB = try signedFieldEvent(
            group: fixture.group, device: MeshDeviceID(), endpoint: endpointB, key: keyB,
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "name", value: Data("Beta".utf8))
        )

        let orders = [[eventA, eventB], [eventB, eventA], [eventA, eventB]]
        for (store, order) in zip(stores, orders) {
            for event in order {
                let key = event.authorEndpointID == endpointA
                    ? keyA.publicKey.rawRepresentation : keyB.publicKey.rawRepresentation
                _ = try await store.insert(event, authorPublicKey: key)
            }
        }
        let fields = try await stores[0].materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].value, Data("Beta".utf8))
        XCTAssertEqual(fields[0].authorEndpointID, endpointB)
        for store in stores.dropFirst() {
            let replicaFields = try await store.materializedFields(for: entity, in: fixture.group)
            XCTAssertEqual(replicaFields, fields)
        }

        let tombstone = try signedFieldEvent(
            group: fixture.group, device: eventA.authorDeviceID, endpoint: endpointA, key: keyA,
            sequence: 2, timestamp: .init(wallTimeMilliseconds: 200), entity: entity,
            mutation: MeshFieldMutation(field: "name", value: nil, isDeleted: true),
            previousHash: try DistributedMeshCrypto.digest(eventA)
        )
        for store in stores {
            _ = try await store.insert(tombstone, authorPublicKey: keyA.publicKey.rawRepresentation)
            let value = try await store.materializedFields(for: entity, in: fixture.group)
            XCTAssertEqual(value.first?.isDeleted, true)
            XCTAssertNil(value.first?.value)
        }
    }

    func testMalformedKnownMutationIsRetainedButNeverMaterialized() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let entity = MeshEntityReference(type: .issue, id: "issue-1")!
        let malformed = try signedEvent(
            group: fixture.group, device: fixture.device, endpoint: fixture.endpoint,
            key: fixture.privateKey, sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            operation: .fieldSetV1, payload: Data(#"{"field":"name"}"#.utf8)
        )

        let insertion = try await store.insert(malformed, authorPublicKey: fixture.publicKey)
        XCTAssertEqual(insertion, .inserted)
        let events = try await store.events(
            for: fixture.group, author: fixture.endpoint, after: 0
        )
        XCTAssertEqual(events, [malformed])
        let fields = try await store.materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(fields, [])
        let quarantined = try await store.quarantinedEvents()
        XCTAssertEqual(quarantined.map(\.eventID), [malformed.id])
        XCTAssertEqual(quarantined.first?.reason, "invalid-field-mutation")
    }

    func testImmutableIDCollisionConvergesToEarliestDeterministicStamp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stores = try (0..<2).map {
            try DistributedMeshStore(databaseURL: fixture.directory
                .appendingPathComponent("immutable-\($0).sqlite"))
        }
        for store in stores { try await store.setMembershipEpoch(1, for: fixture.group) }
        let entity = MeshEntityReference(type: .message, id: "message-collision")!
        let keyA = Curve25519.Signing.PrivateKey()
        let keyB = Curve25519.Signing.PrivateKey()
        let eventA = try signedEvent(
            group: fixture.group, device: MeshDeviceID(), endpoint: MeshEndpointID(rawValue: "a")!,
            key: keyA, sequence: 1, timestamp: .init(wallTimeMilliseconds: 100),
            entity: entity, operation: .immutablePutV1, payload: Data("earlier".utf8)
        )
        let eventB = try signedEvent(
            group: fixture.group, device: MeshDeviceID(), endpoint: MeshEndpointID(rawValue: "b")!,
            key: keyB, sequence: 1, timestamp: .init(wallTimeMilliseconds: 100),
            entity: entity, operation: .immutablePutV1, payload: Data("later".utf8)
        )
        for event in [eventB, eventA] {
            let key = event.authorEndpointID.rawValue == "a" ? keyA : keyB
            _ = try await stores[0].insert(event, authorPublicKey: key.publicKey.rawRepresentation)
        }
        for event in [eventA, eventB] {
            let key = event.authorEndpointID.rawValue == "a" ? keyA : keyB
            _ = try await stores[1].insert(event, authorPublicKey: key.publicKey.rawRepresentation)
        }
        let first = try await stores[0].materializedImmutableValue(for: entity, in: fixture.group)
        let second = try await stores[1].materializedImmutableValue(for: entity, in: fixture.group)
        XCTAssertEqual(first, Data("earlier".utf8))
        XCTAssertEqual(second, first)
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
        XCTAssertEqual(migratedVersion, 3)
        XCTAssertEqual(migratedEpoch, 9)

        let futureURL = fixture.directory.appendingPathComponent("future.sqlite")
        try executeSQLite(
            at: futureURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(4);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: futureURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsupportedSchemaVersion(4))
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

    func testV2MigrationRebuildsMaterializedStateFromRetainedEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entity = MeshEntityReference(type: .issue, id: "migration-issue")!
        let event = try signedFieldEvent(
            group: fixture.group, device: fixture.device, endpoint: fixture.endpoint,
            key: fixture.privateKey, sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "title", value: Data("Retained".utf8))
        )
        do {
            let oldStore = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            try await oldStore.setMembershipEpoch(1, for: fixture.group)
            _ = try await oldStore.insert(event, authorPublicKey: fixture.publicKey)
        }
        try executeSQLite(
            at: fixture.databaseURL,
            sql: "DELETE FROM materialized_registers; UPDATE schema_metadata SET version=2;"
        )

        let migrated = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let fields = try await migrated.materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(fields.map(\.field), ["title"])
        XCTAssertEqual(fields.first?.value, Data("Retained".utf8))
        let schemaVersion = try await migrated.schemaVersion()
        XCTAssertEqual(schemaVersion, 3)
    }

    func testInterruptedV3MaterializationRebuildIsRetriedOnNextRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let entity = MeshEntityReference(type: .project, id: "retry-project")!
        let event = try signedFieldEvent(
            group: fixture.group, device: fixture.device, endpoint: fixture.endpoint,
            key: fixture.privateKey, sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "name", value: Data("Recovered".utf8))
        )
        do {
            let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            try await store.setMembershipEpoch(1, for: fixture.group)
            _ = try await store.insert(event, authorPublicKey: fixture.publicKey)
        }
        try executeSQLite(
            at: fixture.databaseURL,
            sql: "DELETE FROM materialized_registers; " +
                 "UPDATE materialization_metadata SET version=0;"
        )

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let fields = try await reopened.materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(fields.first?.value, Data("Recovered".utf8))
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

    private func signedFieldEvent(
        group: MeshTrustGroupID, device: MeshDeviceID, endpoint: MeshEndpointID,
        key: Curve25519.Signing.PrivateKey, sequence: UInt64,
        timestamp: MeshHybridTimestamp, entity: MeshEntityReference,
        mutation: MeshFieldMutation, previousHash: Data? = nil
    ) throws -> MeshReplicatedEvent {
        try signedEvent(
            group: group, device: device, endpoint: endpoint, key: key,
            sequence: sequence, timestamp: timestamp, entity: entity,
            operation: .fieldSetV1, payload: try mutation.canonicalBytes(),
            previousHash: previousHash
        )
    }

    private func signedEvent(
        group: MeshTrustGroupID, device: MeshDeviceID, endpoint: MeshEndpointID,
        key: Curve25519.Signing.PrivateKey, sequence: UInt64,
        timestamp: MeshHybridTimestamp, entity: MeshEntityReference,
        operation: MeshOperationName, payload: Data, previousHash: Data? = nil
    ) throws -> MeshReplicatedEvent {
        try DistributedMeshCrypto.sign(
            MeshReplicatedEvent(
                id: .generate(), trustGroupID: group, authorDeviceID: device,
                authorEndpointID: endpoint, authorSequence: sequence,
                membershipEpoch: 1, hybridTimestamp: timestamp, entity: entity,
                operation: operation, payload: payload, previousEventHash: previousHash
            ),
            with: key
        )
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
