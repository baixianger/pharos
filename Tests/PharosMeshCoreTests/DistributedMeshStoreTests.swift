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
        XCTAssertEqual(schemaVersion, 4)
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

    func testSignedSnapshotPersistsAcrossRestartAndRejectsTamperedState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = MeshDeviceIdentity.generate()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.irohSecretKeyBytes()
        )
        let endpoint = try identity.endpointID()
        let project = MeshEntityReference(type: .project, id: "snapshot-project")!
        let message = MeshEntityReference(type: .message, id: "snapshot-message")!
        let fieldEvent = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 100), entity: project,
            mutation: MeshFieldMutation(field: "name", value: Data("Snapshot".utf8))
        )
        let immutableEvent = try signedEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 2, timestamp: .init(wallTimeMilliseconds: 200), entity: message,
            operation: .immutablePutV1, payload: Data("hello".utf8),
            previousHash: try DistributedMeshCrypto.digest(fieldEvent)
        )
        let bundle: MeshReplicaSnapshotBundle
        do {
            let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            try await store.setMembershipEpoch(1, for: fixture.group)
            _ = try await store.insert(
                fieldEvent, authorPublicKey: try identity.signingPublicKeyBytes()
            )
            _ = try await store.insert(
                immutableEvent, authorPublicKey: try identity.signingPublicKeyBytes()
            )
            bundle = try await store.createSnapshot(
                for: fixture.group, identity: identity,
                createdAt: .init(wallTimeMilliseconds: 300)
            )
            try MeshReplicaSnapshotCrypto.verify(
                bundle, creatorPublicKey: try identity.signingPublicKeyBytes()
            )
            try await store.persistSnapshot(
                bundle, creatorPublicKey: try identity.signingPublicKeyBytes()
            )
        }
        XCTAssertEqual(bundle.snapshot.authorHeads.map(\.sequence), [2])
        XCTAssertEqual(bundle.state.fields.count, 1)
        XCTAssertEqual(bundle.state.immutableValues.count, 1)

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let persisted = try await reopened.latestSnapshot(in: fixture.group)
        XCTAssertEqual(persisted, bundle)

        var tampered = bundle
        tampered.state.fields[0].mutation.value = Data("tampered".utf8)
        do {
            try await reopened.persistSnapshot(
                tampered, creatorPublicKey: try identity.signingPublicKeyBytes()
            )
            XCTFail("tampered snapshot state must not replace the verified bundle")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaSnapshotCryptoError, .stateDigestMismatch
            )
        }
        let stillPersisted = try await reopened.latestSnapshot(in: fixture.group)
        XCTAssertEqual(stillPersisted, bundle)

        var collision = bundle
        collision.state.fields[0].mutation.value = Data("different-valid-state".utf8)
        collision.snapshot.stateDigest = try MeshReplicaSnapshotCrypto.digest(collision.state)
        collision.snapshot.signature = try identity.signature(
            for: collision.snapshot.canonicalSigningBytes()
        )
        do {
            try await reopened.persistSnapshot(
                collision, creatorPublicKey: try identity.signingPublicKeyBytes()
            )
            XCTFail("a snapshot ID must identify immutable bytes")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .snapshotIDCollision)
        }
    }

    func testSnapshotInstallRestoresStateAndHeadsBeforeDeletingCoveredEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = MeshDeviceIdentity.generate()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.irohSecretKeyBytes()
        )
        let publicKey = try identity.signingPublicKeyBytes()
        let endpoint = try identity.endpointID()
        let project = MeshEntityReference(type: .project, id: "installed-project")!
        let message = MeshEntityReference(type: .message, id: "installed-message")!
        let first = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 100), entity: project,
            mutation: MeshFieldMutation(field: "name", value: Data("Installed".utf8))
        )
        let second = try signedEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 2, timestamp: .init(wallTimeMilliseconds: 200), entity: message,
            operation: .immutablePutV1, payload: Data("message".utf8),
            previousHash: try DistributedMeshCrypto.digest(first)
        )
        let source = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await source.setMembershipEpoch(1, for: fixture.group)
        _ = try await source.insert(first, authorPublicKey: publicKey)
        _ = try await source.insert(second, authorPublicKey: publicKey)
        let bundle = try await source.createSnapshot(
            for: fixture.group, identity: identity,
            createdAt: .init(wallTimeMilliseconds: 300)
        )

        let targetURL = fixture.directory.appendingPathComponent("snapshot-target.sqlite")
        let target = try DistributedMeshStore(databaseURL: targetURL)
        try await target.setMembershipEpoch(1, for: fixture.group)
        try await target.installSnapshot(bundle, creatorPublicKey: publicKey)
        let targetFields = try await target.materializedFields(for: project, in: fixture.group)
        XCTAssertEqual(targetFields.first?.value, Data("Installed".utf8))
        let targetMessage = try await target.materializedImmutableValue(
            for: message, in: fixture.group
        )
        XCTAssertEqual(targetMessage, Data("message".utf8))
        let installedVector = try await target.syncVector(for: fixture.group)
        XCTAssertEqual(installedVector.authors.map(\.sequence), [2])
        let coveredEvents = try await target.events(
            for: fixture.group, author: endpoint, after: 0
        )
        XCTAssertEqual(coveredEvents, [])

        let third = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 3, timestamp: .init(wallTimeMilliseconds: 400), entity: project,
            mutation: MeshFieldMutation(field: "name", value: Data("Advanced".utf8)),
            previousHash: try XCTUnwrap(bundle.snapshot.authorHeads.first?.eventHash)
        )
        _ = try await target.insert(third, authorPublicKey: publicKey)
        let advanced = try await target.materializedFields(for: project, in: fixture.group)
        XCTAssertEqual(advanced.first?.value, Data("Advanced".utf8))
        do {
            try await target.installSnapshot(bundle, creatorPublicKey: publicKey)
            XCTFail("an older snapshot must not regress the local author head")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .snapshotDoesNotCoverLocalHead(endpoint)
            )
        }

        let recoveryURL = fixture.directory.appendingPathComponent("snapshot-recovery.sqlite")
        do {
            let recovery = try DistributedMeshStore(databaseURL: recoveryURL)
            try await recovery.setMembershipEpoch(1, for: fixture.group)
            try await recovery.installSnapshot(bundle, creatorPublicKey: publicKey)
        }
        try executeSQLite(
            at: recoveryURL,
            sql: "DELETE FROM materialized_registers; " +
                 "DELETE FROM materialized_immutable_values; " +
                 "UPDATE materialization_metadata SET version=0;"
        )
        let recovered = try DistributedMeshStore(databaseURL: recoveryURL)
        let recoveredFields = try await recovered.materializedFields(
            for: project, in: fixture.group
        )
        XCTAssertEqual(recoveredFields.first?.value, Data("Installed".utf8))
        let recoveredMessage = try await recovered.materializedImmutableValue(
            for: message, in: fixture.group
        )
        XCTAssertEqual(recoveredMessage, Data("message".utf8))
    }

    func testCompactionRequiresEveryActivePeerAcknowledgementAndPreservesContinuation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = MeshDeviceIdentity.generate()
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.irohSecretKeyBytes()
        )
        let publicKey = try identity.signingPublicKeyBytes()
        let endpoint = try identity.endpointID()
        let entity = MeshEntityReference(type: .issue, id: "compact-issue")!
        let first = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "title", value: Data("one".utf8))
        )
        let second = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 2, timestamp: .init(wallTimeMilliseconds: 200), entity: entity,
            mutation: MeshFieldMutation(field: "title", value: Data("two".utf8)),
            previousHash: try DistributedMeshCrypto.digest(first)
        )
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        _ = try await store.insert(first, authorPublicKey: publicKey)
        _ = try await store.insert(second, authorPublicKey: publicKey)
        let snapshot = try await store.createSnapshot(
            for: fixture.group, identity: identity,
            createdAt: .init(wallTimeMilliseconds: 250)
        )
        try await store.persistSnapshot(snapshot, creatorPublicKey: publicKey)

        let firstPeer = MeshDeviceID()
        let secondPeer = MeshDeviceID()
        let vector = try await store.syncVector(for: fixture.group)
        try await store.acknowledge(vector, from: firstPeer)
        do {
            _ = try await store.compactEvents(
                using: snapshot.snapshot.id, creatorPublicKey: publicKey,
                activePeers: [firstPeer, secondPeer]
            )
            XCTFail("all active peers must acknowledge before event deletion")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .compactionNotAcknowledged(
                    peer: secondPeer, author: endpoint, required: 2, actual: 0
                )
            )
        }
        let retained = try await store.events(for: fixture.group, author: endpoint, after: 0)
        XCTAssertEqual(retained, [first, second])

        try await store.acknowledge(vector, from: secondPeer)
        let removed = try await store.compactEvents(
            using: snapshot.snapshot.id, creatorPublicKey: publicKey,
            activePeers: [secondPeer, firstPeer, firstPeer]
        )
        XCTAssertEqual(removed, 2)
        let afterCompaction = try await store.events(
            for: fixture.group, author: endpoint, after: 0
        )
        XCTAssertEqual(afterCompaction, [])
        let fields = try await store.materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(fields.first?.value, Data("two".utf8))
        let compactedVector = try await store.syncVector(for: fixture.group)
        XCTAssertEqual(compactedVector, vector)
        let repeated = try await store.compactEvents(
            using: snapshot.snapshot.id, creatorPublicKey: publicKey,
            activePeers: [firstPeer, secondPeer]
        )
        XCTAssertEqual(repeated, 0)

        let third = try signedFieldEvent(
            group: fixture.group, device: identity.deviceID, endpoint: endpoint, key: key,
            sequence: 3, timestamp: .init(wallTimeMilliseconds: 300), entity: entity,
            mutation: MeshFieldMutation(field: "title", value: Data("three".utf8)),
            previousHash: try XCTUnwrap(snapshot.snapshot.authorHeads.first?.eventHash)
        )
        _ = try await store.insert(third, authorPublicKey: publicKey)
        let continued = try await store.materializedFields(for: entity, in: fixture.group)
        XCTAssertEqual(continued.first?.value, Data("three".utf8))

        let compactedRequest = MeshEventRangeRequest(
            trustGroupID: fixture.group, membershipEpoch: 1,
            authorEndpointID: endpoint, afterSequence: 0
        )
        let snapshotFallback = try await store.syncResponse(for: compactedRequest)
        XCTAssertEqual(snapshotFallback.kind, .snapshot)
        XCTAssertEqual(snapshotFallback.snapshot, snapshot)
        let incremental = try await store.syncResponse(for: MeshEventRangeRequest(
            trustGroupID: fixture.group, membershipEpoch: 1,
            authorEndpointID: endpoint, afterSequence: 2
        ))
        XCTAssertEqual(incremental.kind, .events)
        XCTAssertEqual(incremental.events, [third])
        let caughtUp = try await store.syncResponse(for: MeshEventRangeRequest(
            trustGroupID: fixture.group, membershipEpoch: 1,
            authorEndpointID: endpoint, afterSequence: 3
        ))
        XCTAssertEqual(caughtUp.kind, .upToDate)
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
        XCTAssertEqual(migratedVersion, 4)
        XCTAssertEqual(migratedEpoch, 9)

        let futureURL = fixture.directory.appendingPathComponent("future.sqlite")
        try executeSQLite(
            at: futureURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(5);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: futureURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsupportedSchemaVersion(5))
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
        XCTAssertEqual(schemaVersion, 4)
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
