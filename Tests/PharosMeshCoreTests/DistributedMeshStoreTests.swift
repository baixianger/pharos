import Crypto
import CSQLite
import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol

final class DistributedMeshStoreTests: XCTestCase {
    func testPortableLocalReplicaFactorySharesIdentityAndStoreWithoutLegacyPaths() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.directory.appendingPathComponent(
            "distributed/replica", isDirectory: true
        )
        let identityStorage = MeshMemoryIdentityStorage()
        let first = try MeshLocalReplica.open(
            rootURL: root, identityStorage: identityStorage
        )
        try await first.store.setMembershipEpoch(4, for: fixture.group)

        let reopened = try MeshLocalReplica.open(
            rootURL: root, identityStorage: identityStorage
        )
        XCTAssertEqual(reopened.identity, first.identity)
        let reopenedEpoch = try await reopened.store.membershipEpoch(for: fixture.group)
        XCTAssertEqual(reopenedEpoch, 4)
        XCTAssertEqual(reopened.rootURL, root.standardizedFileURL)
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
                as? NSNumber
        )
        let databasePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("replica-v1.sqlite").path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(databasePermissions.intValue & 0o777, 0o600)

        let linkedRoot = fixture.directory.appendingPathComponent("linked-replica")
        try FileManager.default.createSymbolicLink(
            at: linkedRoot, withDestinationURL: root
        )
        XCTAssertThrowsError(try MeshLocalReplica.open(
            rootURL: linkedRoot, identityStorage: MeshMemoryIdentityStorage()
        )) {
            XCTAssertEqual($0 as? MeshLocalReplicaError, .invalidDataDirectory)
        }

        let unsafeRoot = fixture.directory.appendingPathComponent("unsafe", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: unsafeRoot.appendingPathComponent("replica-v1.sqlite"),
            withDestinationURL: fixture.databaseURL
        )
        XCTAssertThrowsError(try MeshLocalReplica.open(
            rootURL: unsafeRoot, identityStorage: MeshMemoryIdentityStorage()
        )) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsafeDatabasePath)
        }
    }

    func testAuthenticatedReplicaRPCRoutesSyncBlobsCommandsAndRevocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hostDirectory = fixture.directory.appendingPathComponent("host", isDirectory: true)
        let clientDirectory = fixture.directory.appendingPathComponent("client", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hostDirectory, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: clientDirectory, withIntermediateDirectories: true
        )
        let hostStore = try DistributedMeshStore(
            databaseURL: hostDirectory.appendingPathComponent("replica.sqlite")
        )
        let clientStore = try DistributedMeshStore(
            databaseURL: clientDirectory.appendingPathComponent("replica.sqlite")
        )
        try await hostStore.setMembershipEpoch(1, for: fixture.group)
        try await clientStore.setMembershipEpoch(1, for: fixture.group)
        let host = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let controller = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        try await pairDevice(
            controller, roles: [.controller], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            host, roles: [.host, .replica], invitedBy: controller,
            in: fixture.group, store: clientStore
        )

        let entity = MeshEntityReference(type: .project, id: "rpc-project")!
        let mutation = MeshFieldMutation(
            field: "title", value: Data("RPC Project".utf8)
        )
        let hostKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: host.irohSecretKeyBytes()
        )
        let event = try signedFieldEvent(
            group: fixture.group, device: host.deviceID,
            endpoint: try host.endpointID(), key: hostKey, sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 1_000), entity: entity,
            mutation: mutation
        )
        _ = try await hostStore.insert(
            event, authorPublicKey: try host.signingPublicKeyBytes()
        )

        let blobData = Data("bounded-rpc-blob-payload".utf8)
        let manifest = blobManifest(for: blobData, chunkSize: 7)
        try await hostStore.registerBlobManifest(manifest)
        for chunk in try blobChunks(for: blobData, manifest: manifest) {
            _ = try await hostStore.receiveBlobChunk(chunk)
        }
        try await hostStore.finalizeBlob(manifest.digest)

        let resourceID = MeshResourceID(rawValue: "agent/rpc-test")!
        _ = try await hostStore.registerHostResource(
            in: fixture.group, on: host, resourceID: resourceID,
            allowedActions: [.poke],
            at: .init(wallTimeMilliseconds: 1_000)
        )

        let server = MeshReplicaRPCServer(
            store: hostStore, hostIdentity: host,
            timestamp: { MeshHybridTimestamp(wallTimeMilliseconds: 2_000) }
        )
        let transport = ReplicaRPCServerTransport(
            server: server, remoteEndpointID: try controller.endpointID()
        )
        let client = MeshReplicaRPCClient(transport: transport)
        let report = try await MeshReplicaSyncSession(
            store: clientStore, client: client
        ).synchronize(group: fixture.group, membershipEpoch: 1, rangeLimit: 1)
        XCTAssertEqual(report, MeshReplicaSyncReport(eventCount: 1, rangeCount: 1))
        let fields = try await clientStore.materializedFields(
            for: entity, in: fixture.group
        )
        XCTAssertEqual(fields.first?.value, mutation.value)
        let clientVector = try await clientStore.syncVector(for: fixture.group)
        let hostVector = try await hostStore.syncVector(for: fixture.group)
        XCTAssertEqual(clientVector, hostVector)

        let fetchedManifest = try await client.blobManifest(
            manifest.digest, group: fixture.group, membershipEpoch: 1
        )
        XCTAssertEqual(fetchedManifest, manifest)
        try await clientStore.registerBlobManifest(fetchedManifest)
        for index in 0..<manifest.chunkCount {
            let chunk = try await client.blobChunk(
                manifest.digest, index: index, group: fixture.group,
                membershipEpoch: 1
            )
            _ = try await clientStore.receiveBlobChunk(chunk)
        }
        try await clientStore.finalizeBlob(manifest.digest)
        let fetchedBlob = try await clientStore.blobData(for: manifest.digest)
        XCTAssertEqual(fetchedBlob, blobData)

        let command = MeshHostCommand(
            trustGroupID: fixture.group, senderDeviceID: controller.deviceID,
            targetHostDeviceID: host.deviceID,
            targetHostEndpointID: try host.endpointID(), resourceID: resourceID,
            expectedResourceGeneration: 1, action: .poke,
            idempotencyKey: "rpc-command-1",
            createdAt: .init(wallTimeMilliseconds: 1_000),
            deadlineMilliseconds: 3_000
        )
        let signedCommand = try MeshHostCommandCrypto.sign(
            command, membershipEpoch: 1, with: controller
        )
        let receipt = try await client.sendHostCommand(signedCommand)
        XCTAssertEqual(receipt.receipt.state, .accepted)
        try MeshHostCommandCrypto.verify(
            receipt, hostPublicKey: try host.signingPublicKeyBytes()
        )

        let unknown = MeshDeviceIdentity.generate()
        let unauthorized = MeshReplicaRPCClient(transport: ReplicaRPCServerTransport(
            server: server, remoteEndpointID: try unknown.endpointID()
        ))
        do {
            _ = try await unauthorized.syncVector(
                for: fixture.group, membershipEpoch: 1
            )
            XCTFail("an unpaired Endpoint ID must not enter the RPC router")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaRPCError,
                .remoteFailure("peer-not-trusted")
            )
        }

        try await hostStore.setMembershipEpoch(2, for: fixture.group)
        do {
            _ = try await client.syncVector(for: fixture.group, membershipEpoch: 1)
            XCTFail("a stale membership epoch must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaRPCError,
                .remoteFailure("membership-epoch-mismatch")
            )
        }
        do {
            _ = try await client.syncVector(for: fixture.group, membershipEpoch: 2)
            XCTFail("an old trust row must not authorize the new epoch")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaRPCError,
                .remoteFailure("peer-not-trusted")
            )
        }
    }

    func testReplicaRPCClientRejectsMismatchedResponseCorrelation() async throws {
        let client = MeshReplicaRPCClient(transport: MismatchedReplicaRPCTransport())
        do {
            _ = try await client.syncVector(
                for: MeshTrustGroupID(), membershipEpoch: 1
            )
            XCTFail("a response for another request ID must not be accepted")
        } catch {
            XCTAssertEqual(error as? MeshReplicaRPCError, .responseMismatch)
        }
    }

    func testStoreUsesWALAndPersistsVerifiedHashChainIdempotently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)

        let schemaVersion = try await store.schemaVersion()
        let journalMode = try await store.journalMode()
        XCTAssertEqual(schemaVersion, 7)
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

    func testCompactionDerivesPeersFromCurrentMembershipAndRejectsRevokedEpoch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let creator = MeshDeviceIdentity.generate()
        let creatorKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: creator.irohSecretKeyBytes()
        )
        let creatorPublicKey = try creator.signingPublicKeyBytes()
        let creatorEndpoint = try creator.endpointID()
        let firstPeer = MeshDeviceIdentity.generate()
        let secondPeer = MeshDeviceIdentity.generate()
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        try await pairDevice(
            firstPeer, roles: [.replica], invitedBy: creator,
            in: fixture.group, store: store
        )
        try await pairDevice(
            secondPeer, roles: [.controller], invitedBy: creator,
            in: fixture.group, store: store
        )

        let entity = MeshEntityReference(type: .issue, id: "membership-compaction")!
        let event = try signedFieldEvent(
            group: fixture.group, device: creator.deviceID, endpoint: creatorEndpoint,
            key: creatorKey, sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 100), entity: entity,
            mutation: MeshFieldMutation(field: "title", value: Data("one".utf8))
        )
        _ = try await store.insert(event, authorPublicKey: creatorPublicKey)
        let snapshot = try await store.createSnapshot(
            for: fixture.group, identity: creator,
            createdAt: .init(wallTimeMilliseconds: 200)
        )
        try await store.persistSnapshot(snapshot, creatorPublicKey: creatorPublicKey)
        let vector = try await store.syncVector(for: fixture.group)
        try await store.acknowledge(vector, from: firstPeer.deviceID)

        do {
            _ = try await store.compactEventsUsingCurrentMembership(
                using: snapshot.snapshot.id, creatorPublicKey: creatorPublicKey
            )
            XCTFail("every trusted installation in the current epoch must acknowledge")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .compactionNotAcknowledged(
                    peer: secondPeer.deviceID, author: creatorEndpoint,
                    required: 1, actual: 0
                )
            )
        }

        try await store.acknowledge(vector, from: secondPeer.deviceID)
        let removed = try await store.compactEventsUsingCurrentMembership(
            using: snapshot.snapshot.id, creatorPublicKey: creatorPublicKey
        )
        XCTAssertEqual(removed, 1)

        try await store.setMembershipEpoch(2, for: fixture.group)
        do {
            _ = try await store.compactEventsUsingCurrentMembership(
                using: snapshot.snapshot.id, creatorPublicKey: creatorPublicKey
            )
            XCTFail("an old-epoch snapshot must not authorize compaction")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .membershipEpochMismatch(expected: 2, actual: 1)
            )
        }
    }

    func testThreeReplicasConvergeAfterSeededPartitionsReorderingAndDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stores = try (0..<3).map { index in
            try DistributedMeshStore(
                databaseURL: fixture.directory.appendingPathComponent("sim-\(index).sqlite")
            )
        }
        for store in stores {
            try await store.setMembershipEpoch(1, for: fixture.group)
        }
        let identities = (0..<3).map { _ in MeshDeviceIdentity.generate() }
        var publicKeys: [MeshEndpointID: Data] = [:]
        for identity in identities {
            publicKeys[try identity.endpointID()] = try identity.signingPublicKeyBytes()
        }

        for authorIndex in identities.indices {
            let identity = identities[authorIndex]
            let endpoint = try identity.endpointID()
            let key = try Curve25519.Signing.PrivateKey(
                rawRepresentation: identity.irohSecretKeyBytes()
            )
            var previous: Data?
            for sequence in 1...8 {
                let entity = MeshEntityReference(
                    type: .issue, id: "simulation-\(sequence % 3)"
                )!
                let event = try signedFieldEvent(
                    group: fixture.group, device: identity.deviceID,
                    endpoint: endpoint, key: key, sequence: UInt64(sequence),
                    timestamp: .init(
                        wallTimeMilliseconds: Int64(authorIndex * 10_000 + sequence * 10)
                    ),
                    entity: entity,
                    mutation: MeshFieldMutation(
                        field: "author-\(authorIndex)",
                        value: Data("value-\(authorIndex)-\(sequence)".utf8)
                    ),
                    previousHash: previous
                )
                _ = try await stores[authorIndex].insert(
                    event, authorPublicKey: publicKeys[endpoint]!
                )
                previous = try DistributedMeshCrypto.digest(event)
            }
        }

        func pull(
            from source: DistributedMeshStore, into target: DistributedMeshStore,
            limit: Int
        ) async throws {
            let advertised = try await source.syncVector(for: fixture.group)
            let requests = try await target.missingRangeRequests(
                advertisedBy: advertised, limit: limit
            )
            for request in requests.reversed() {
                let batch = try await source.eventBatch(for: request)
                for event in batch {
                    let key = try XCTUnwrap(publicKeys[event.authorEndpointID])
                    _ = try await target.insert(event, authorPublicKey: key)
                    _ = try await target.insert(event, authorPublicKey: key)
                }
            }
        }

        var random = MeshSeededRandom(seed: 0x706861726f73)
        for _ in 0..<90 {
            let source = Int(random.next() % 3)
            var target = Int(random.next() % 3)
            if target == source { target = (target + 1) % 3 }
            guard random.next() % 4 != 0 else { continue } // deterministic partition
            try await pull(
                from: stores[source], into: stores[target],
                limit: Int(random.next() % 3) + 1
            )
        }

        // Heal every partition. Repeated bounded passes model reconnect and
        // reordered anti-entropy without relying on a live transport.
        for _ in 0..<12 {
            for source in stores.indices {
                for target in stores.indices where source != target {
                    try await pull(from: stores[source], into: stores[target], limit: 2)
                }
            }
        }

        var vectors: [MeshSyncVector] = []
        var states: [Data] = []
        for (index, store) in stores.enumerated() {
            vectors.append(try await store.syncVector(for: fixture.group))
            states.append(try await store.createSnapshot(
                for: fixture.group, identity: identities[index],
                createdAt: .init(wallTimeMilliseconds: 999_999)
            ).state.canonicalBytes())
        }
        XCTAssertEqual(vectors[0], vectors[1])
        XCTAssertEqual(vectors[1], vectors[2])
        XCTAssertEqual(states[0], states[1])
        XCTAssertEqual(states[1], states[2])
    }

    func testMigrationCutoverAndRollbackKeepExactlyOneWriteAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let digest = Data(repeating: 0x5a, count: 32)
        try await store.setMembershipEpoch(1, for: fixture.group)

        let shadow = try await store.prepareMigration(
            for: fixture.group, inventoryDigest: digest,
            at: .init(wallTimeMilliseconds: 100)
        )
        XCTAssertEqual(shadow.generation, 1)
        XCTAssertEqual(shadow.mode, .shadow)
        XCTAssertTrue(shadow.legacyMayWrite)
        XCTAssertFalse(shadow.distributedMayWrite)
        let firstEvent = try fixture.signedEvent(sequence: 1, payload: "cutover-write")
        do {
            _ = try await store.insert(firstEvent, authorPublicKey: fixture.publicKey)
            XCTFail("shadow mode must enforce a read-only distributed replica")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .distributedWritesDisabled(.shadow)
            )
        }
        let resumed = try await store.prepareMigration(
            for: fixture.group, inventoryDigest: digest,
            at: .init(wallTimeMilliseconds: 101)
        )
        XCTAssertEqual(resumed, shadow)
        let finalDigest = Data(repeating: 0x6b, count: 32)
        let refreshed = try await store.refreshMigrationInventory(
            for: fixture.group, inventoryDigest: finalDigest,
            expectedGeneration: shadow.generation,
            at: .init(wallTimeMilliseconds: 150)
        )
        XCTAssertEqual(refreshed.generation, 2)
        XCTAssertEqual(refreshed.mode, .shadow)
        XCTAssertEqual(refreshed.inventoryDigest, finalDigest)

        let distributed = try await store.cutOverMigration(
            for: fixture.group, inventoryDigest: finalDigest,
            expectedGeneration: refreshed.generation,
            at: .init(wallTimeMilliseconds: 200)
        )
        XCTAssertEqual(distributed.generation, 3)
        XCTAssertEqual(distributed.mode, .distributed)
        XCTAssertFalse(distributed.legacyMayWrite)
        XCTAssertTrue(distributed.distributedMayWrite)
        let inserted = try await store.insert(
            firstEvent, authorPublicKey: fixture.publicKey
        )
        XCTAssertEqual(inserted, .inserted)

        do {
            _ = try await store.rollBackMigration(
                for: fixture.group, inventoryDigest: finalDigest,
                expectedGeneration: 1,
                at: .init(wallTimeMilliseconds: 250)
            )
            XCTFail("a stale operator must not change write authority")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .migrationGenerationMismatch(expected: 3, actual: 1)
            )
        }

        let rolledBack = try await store.rollBackMigration(
            for: fixture.group, inventoryDigest: finalDigest,
            expectedGeneration: distributed.generation,
            at: .init(wallTimeMilliseconds: 300)
        )
        XCTAssertEqual(rolledBack.generation, 4)
        XCTAssertEqual(rolledBack.mode, .rolledBack)
        XCTAssertTrue(rolledBack.legacyMayWrite)
        XCTAssertFalse(rolledBack.distributedMayWrite)
        let secondEvent = try fixture.signedEvent(
            sequence: 2, payload: "must-not-write-after-rollback",
            previousHash: DistributedMeshCrypto.digest(firstEvent)
        )
        do {
            _ = try await store.insert(secondEvent, authorPublicKey: fixture.publicKey)
            XCTFail("rollback must enforce a read-only distributed replica")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .distributedWritesDisabled(.rolledBack)
            )
        }

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let persisted = try await reopened.migrationState(for: fixture.group)
        XCTAssertEqual(persisted, rolledBack)
        let recut = try await reopened.cutOverMigration(
            for: fixture.group, inventoryDigest: finalDigest,
            expectedGeneration: rolledBack.generation,
            at: .init(wallTimeMilliseconds: 400)
        )
        XCTAssertEqual(recut.mode, .distributed)
        XCTAssertEqual(recut.generation, 5)
    }

    func testLegacyMigrationBuildsDeterministicSignedGenesisAndVerifiedBlobs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("legacy", isDirectory: true)
        let mesh = source.appendingPathComponent("mesh", isDirectory: true)
        let attachmentID = "22222222-2222-4222-8222-222222222222"
        let attachmentDirectory = mesh.appendingPathComponent(
            "attachments/\(attachmentID)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: attachmentDirectory, withIntermediateDirectories: true
        )

        let projectID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let registry = try JSONSerialization.data(withJSONObject: [[
            "id": projectID.uuidString,
            "name": "Offline Migration Fixture",
            "issues": [[
                "id": "33333333-3333-4333-8333-333333333333",
                "number": 1, "title": "Verify cutover",
            ]],
        ]], options: [.sortedKeys])
        try registry.write(to: source.appendingPathComponent("projects.json"))

        let message = MeshMsg(
            id: "44444444-4444-7444-8444-444444444444",
            from: "agent", room: "migration-room", text: "offline fixture",
            ts: 123, to: ["human"]
        )
        var transcript = try JSONEncoder().encode(message)
        transcript.append(0x0a)
        try transcript.write(to: mesh.appendingPathComponent("migration-room.jsonl"))
        let messageObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
        let mailbox = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "rooms": [
                "migration-room": [
                    "members": ["agent": "member-1"],
                    "mailboxes": ["member-1": [messageObject]],
                ],
            ],
        ], options: [.sortedKeys])
        try mailbox.write(to: source.appendingPathComponent("mesh-mailboxes.json"))

        let attachmentBytes = Data("verified attachment".utf8)
        let attachmentDigest = Data(SHA256.hash(data: attachmentBytes))
            .map { String(format: "%02x", $0) }.joined()
        let attachment = MeshAttachment(
            id: attachmentID, name: "proof.txt", mimeType: "text/plain",
            byteSize: attachmentBytes.count, sha256: attachmentDigest
        )
        try JSONEncoder().encode(attachment).write(
            to: attachmentDirectory.appendingPathComponent("metadata.json")
        )
        try attachmentBytes.write(to: attachmentDirectory.appendingPathComponent("data"))

        let identity = MeshDeviceIdentity.generate()
        let first = try LegacyMeshMigration.export(
            sourceRoot: source, trustGroupID: fixture.group,
            membershipEpoch: 1, identity: identity
        )
        let second = try LegacyMeshMigration.export(
            sourceRoot: source, trustGroupID: fixture.group,
            membershipEpoch: 1, identity: identity
        )
        XCTAssertEqual(first.inventory, second.inventory)
        XCTAssertEqual(first.genesis.state, second.genesis.state)
        XCTAssertEqual(
            try first.genesis.snapshot.canonicalSigningBytes(),
            try second.genesis.snapshot.canonicalSigningBytes()
        )
        XCTAssertEqual(first.blobs, second.blobs)
        XCTAssertEqual(first.inventory.counts.projects, 1)
        XCTAssertEqual(first.inventory.counts.issues, 1)
        XCTAssertEqual(first.inventory.counts.rooms, 1)
        XCTAssertEqual(first.inventory.counts.messages, 1)
        XCTAssertEqual(first.inventory.counts.memberships, 1)
        XCTAssertEqual(first.inventory.counts.unreadMessages, 1)
        XCTAssertEqual(first.inventory.counts.attachments, 1)
        try MeshReplicaSnapshotCrypto.verify(
            first.genesis, creatorPublicKey: identity.signingPublicKeyBytes()
        )
        try MeshReplicaSnapshotCrypto.verify(
            second.genesis, creatorPublicKey: identity.signingPublicKeyBytes()
        )

        let targetURL = fixture.directory.appendingPathComponent("migration-target.sqlite")
        let target = try DistributedMeshStore(databaseURL: targetURL)
        try await target.setMembershipEpoch(1, for: fixture.group)
        let firstShadow = try await LegacyMeshMigration.installForShadow(
            first, into: target,
            creatorPublicKey: identity.signingPublicKeyBytes(),
            expectedGeneration: nil
        )
        let repeatedShadow = try await LegacyMeshMigration.installForShadow(
            second, into: target,
            creatorPublicKey: identity.signingPublicKeyBytes(),
            expectedGeneration: firstShadow.generation
        )
        XCTAssertEqual(firstShadow, repeatedShadow)
        let project = MeshEntityReference(type: .project, id: projectID.uuidString)!
        let importedProject = try await target.materializedImmutableValue(
            for: project, in: fixture.group
        )
        XCTAssertNotNil(importedProject)
        let importedBlob = try await target.blobData(
            for: first.blobs[0].manifest.digest
        )
        XCTAssertEqual(importedBlob, attachmentBytes)
        XCTAssertEqual(firstShadow.mode, .shadow)
    }

    func testAuthenticatedHostCommandIsDurableExactlyOnceGateAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let host = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 1))
        let sender = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 2))
        try await store.setMembershipEpoch(1, for: fixture.group)
        try await pairController(
            sender, invitedBy: host, in: fixture.group, store: store
        )
        let resource = try XCTUnwrap(MeshResourceID(rawValue: "tmux/session"))
        let registered = try await store.registerHostResource(
            in: fixture.group, on: host, resourceID: resource,
            allowedActions: [.stop, .attach],
            at: .init(wallTimeMilliseconds: 90)
        )
        XCTAssertEqual(registered.generation, 1)
        XCTAssertEqual(registered.state, .active)

        let command = MeshHostCommand(
            trustGroupID: fixture.group, senderDeviceID: sender.deviceID,
            targetHostDeviceID: host.deviceID, targetHostEndpointID: try host.endpointID(),
            resourceID: resource, expectedResourceGeneration: 1, action: .stop,
            idempotencyKey: "stop/tmux-session/generation-1",
            createdAt: .init(wallTimeMilliseconds: 100), deadlineMilliseconds: 1_000
        )
        let signed = try MeshHostCommandCrypto.sign(command, membershipEpoch: 1, with: sender)
        let accepted = try await store.accept(
            signed, on: host, receivedAt: .init(wallTimeMilliseconds: 110)
        )
        XCTAssertEqual(accepted.receipt.state, .accepted)
        try MeshHostCommandCrypto.verify(
            accepted, hostPublicKey: try host.signingPublicKeyBytes()
        )

        var retry = command
        retry.id = MeshCommandID()
        let signedRetry = try MeshHostCommandCrypto.sign(
            retry, membershipEpoch: 1, with: sender
        )
        let replay = try await store.accept(
            signedRetry, on: host, receivedAt: .init(wallTimeMilliseconds: 900)
        )
        XCTAssertEqual(replay, accepted)

        var collision = retry
        collision.action = .spawn
        let signedCollision = try MeshHostCommandCrypto.sign(
            collision, membershipEpoch: 1, with: sender
        )
        do {
            _ = try await store.accept(
                signedCollision, on: host,
                receivedAt: .init(wallTimeMilliseconds: 115)
            )
            XCTFail("same idempotency key must not alias different work")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .idempotencyCollision)
        }

        let contenders = try (0..<8).map { _ in
            try DistributedMeshStore(databaseURL: fixture.databaseURL)
        }
        let claims = try await withThrowingTaskGroup(
            of: MeshCommandExecutionClaim.self, returning: [MeshCommandExecutionClaim].self
        ) { group in
            for contender in contenders {
                group.addTask {
                    try await contender.claimExecution(
                        commandID: command.id, on: host,
                        at: .init(wallTimeMilliseconds: 120)
                    )
                }
            }
            var values: [MeshCommandExecutionClaim] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(claims.filter(\.shouldExecute).count, 1)
        let firstClaim = try XCTUnwrap(claims.first(where: { $0.shouldExecute }))
        XCTAssertTrue(firstClaim.shouldExecute)
        XCTAssertEqual(firstClaim.receipt.receipt.state, .executing)

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let reopenedSchemaVersion = try await reopened.schemaVersion()
        XCTAssertEqual(reopenedSchemaVersion, 7)
        let crashReplay = try await reopened.claimExecution(
            commandID: command.id, on: host,
            at: .init(wallTimeMilliseconds: 130)
        )
        XCTAssertFalse(crashReplay.shouldExecute)
        XCTAssertEqual(crashReplay.receipt, firstClaim.receipt)
        let unfinished = try await reopened.unfinishedCommandReceipts(on: host)
        XCTAssertEqual(unfinished, [firstClaim.receipt])

        let executed = try await reopened.finishExecution(
            commandID: command.id, on: host, outcome: .executed,
            at: .init(wallTimeMilliseconds: 140), result: Data("ok".utf8)
        )
        XCTAssertEqual(executed.receipt.state, .executed)
        let terminalReplay = try await reopened.claimExecution(
            commandID: command.id, on: host,
            at: .init(wallTimeMilliseconds: 150)
        )
        XCTAssertFalse(terminalReplay.shouldExecute)
        XCTAssertEqual(terminalReplay.receipt, executed)

        let replacement = try await reopened.replaceHostResource(
            in: fixture.group, on: host, resourceID: resource,
            allowedActions: [.stop, .attach],
            at: .init(wallTimeMilliseconds: 160)
        )
        XCTAssertEqual(replacement.generation, 2)

        var staleNewCommand = command
        staleNewCommand.id = MeshCommandID()
        staleNewCommand.idempotencyKey = "stop/tmux-session/new-command"
        let stale = try await reopened.accept(
            MeshHostCommandCrypto.sign(
                staleNewCommand, membershipEpoch: 1, with: sender
            ),
            on: host, receivedAt: .init(wallTimeMilliseconds: 170)
        )
        XCTAssertEqual(stale.receipt.state, .rejected)
        XCTAssertEqual(stale.receipt.failureCode, "stale-resource-generation")

        var disallowed = command
        disallowed.id = MeshCommandID()
        disallowed.expectedResourceGeneration = 2
        disallowed.action = .spawn
        disallowed.idempotencyKey = "spawn/tmux-session/generation-2"
        let rejected = try await reopened.accept(
            MeshHostCommandCrypto.sign(disallowed, membershipEpoch: 1, with: sender),
            on: host, receivedAt: .init(wallTimeMilliseconds: 180)
        )
        XCTAssertEqual(rejected.receipt.state, .rejected)
        XCTAssertEqual(rejected.receipt.failureCode, "action-not-allowed")

        var expiredCommand = command
        expiredCommand.id = MeshCommandID()
        expiredCommand.expectedResourceGeneration = 2
        expiredCommand.idempotencyKey = "stop/tmux-session/expired"
        expiredCommand.deadlineMilliseconds = 190
        let expired = try await reopened.accept(
            MeshHostCommandCrypto.sign(expiredCommand, membershipEpoch: 1, with: sender),
            on: host, receivedAt: .init(wallTimeMilliseconds: 190)
        )
        XCTAssertEqual(expired.receipt.state, .expired)
        XCTAssertEqual(expired.receipt.failureCode, "deadline-expired")

        try await reopened.setMembershipEpoch(2, for: fixture.group)
        let historicalReplay = try await reopened.accept(
            signed, on: host, receivedAt: .init(wallTimeMilliseconds: 200)
        )
        XCTAssertEqual(historicalReplay, executed)

        try executeSQLite(
            at: fixture.databaseURL,
            sql: "UPDATE command_receipts_v2 SET state='failed' " +
                 "WHERE command_id='\(command.id.rawValue.uuidString)';"
        )
        do {
            _ = try await reopened.commandReceipt(id: command.id)
            XCTFail("row columns must not diverge from the signed receipt envelope")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .corruptStoredValue)
        }
    }

    func testHostCommandRejectsTamperingUnknownSendersWrongEndpointAndRevokedEpoch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let host = MeshDeviceIdentity.generate()
        let sender = MeshDeviceIdentity.generate()
        try await store.setMembershipEpoch(1, for: fixture.group)
        try await pairController(sender, invitedBy: host, in: fixture.group, store: store)
        let resource = try XCTUnwrap(MeshResourceID(rawValue: "agent/session"))
        _ = try await store.registerHostResource(
            in: fixture.group, on: host, resourceID: resource,
            allowedActions: [.poke], at: .init(wallTimeMilliseconds: 1)
        )
        let command = MeshHostCommand(
            trustGroupID: fixture.group, senderDeviceID: sender.deviceID,
            targetHostDeviceID: host.deviceID, targetHostEndpointID: try host.endpointID(),
            resourceID: resource, expectedResourceGeneration: 1, action: .poke,
            idempotencyKey: "poke/agent-session/one",
            createdAt: .init(wallTimeMilliseconds: 10), deadlineMilliseconds: 100
        )

        var tampered = try MeshHostCommandCrypto.sign(
            command, membershipEpoch: 1, with: sender
        )
        tampered.command.payload = Data("changed-after-signing".utf8)
        do {
            _ = try await store.accept(
                tampered, on: host, receivedAt: .init(wallTimeMilliseconds: 20)
            )
            XCTFail("tampered commands must not reach the receipt journal")
        } catch {
            XCTAssertEqual(error as? MeshHostCommandCryptoError, .invalidSignature)
        }

        let stranger = MeshDeviceIdentity.generate()
        var unknown = command
        unknown.id = MeshCommandID()
        unknown.senderDeviceID = stranger.deviceID
        unknown.idempotencyKey = "poke/agent-session/unknown"
        do {
            _ = try await store.accept(
                MeshHostCommandCrypto.sign(unknown, membershipEpoch: 1, with: stranger),
                on: host, receivedAt: .init(wallTimeMilliseconds: 20)
            )
            XCTFail("an unpaired sender must not issue Host commands")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .commandSenderNotTrusted)
        }

        var wrongEndpoint = command
        wrongEndpoint.id = MeshCommandID()
        wrongEndpoint.idempotencyKey = "poke/agent-session/wrong-endpoint"
        wrongEndpoint.targetHostEndpointID = try XCTUnwrap(
            MeshEndpointID(rawValue: "not-the-host")
        )
        do {
            _ = try await store.accept(
                MeshHostCommandCrypto.sign(wrongEndpoint, membershipEpoch: 1, with: sender),
                on: host, receivedAt: .init(wallTimeMilliseconds: 20)
            )
            XCTFail("commands are directed to one immutable Host Endpoint ID")
        } catch {
            XCTAssertEqual(error as? DistributedMeshStoreError, .wrongCommandEndpoint)
        }

        try await store.setMembershipEpoch(2, for: fixture.group)
        do {
            _ = try await store.accept(
                MeshHostCommandCrypto.sign(command, membershipEpoch: 1, with: sender),
                on: host, receivedAt: .init(wallTimeMilliseconds: 20)
            )
            XCTFail("an old membership epoch must revoke command authority")
        } catch {
            XCTAssertEqual(
                error as? DistributedMeshStoreError,
                .membershipEpochMismatch(expected: 2, actual: 1)
            )
        }
    }

    func testBlobTransferResumesAcrossConnectionsFinalizesIdempotentlyAndRefetchesAfterEviction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = Data("local-first blob payload".utf8)
        let manifest = blobManifest(for: data, chunkSize: 7)
        let chunks = try blobChunks(for: data, manifest: manifest)
        XCTAssertEqual(chunks.count, 4)

        let first = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let second = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await first.registerBlobManifest(manifest)
        let initialMissing = try await first.missingBlobChunkIndices(for: manifest.digest)
        XCTAssertEqual(initialMissing, [0, 1, 2, 3])
        let thirdInsertion = try await first.receiveBlobChunk(chunks[2])
        let firstInsertion = try await second.receiveBlobChunk(chunks[0])
        let duplicateInsertion = try await second.receiveBlobChunk(chunks[2])
        XCTAssertEqual(thirdInsertion, .inserted)
        XCTAssertEqual(firstInsertion, .inserted)
        XCTAssertEqual(duplicateInsertion, .duplicate)
        let remaining = try await first.missingBlobChunkIndices(for: manifest.digest)
        XCTAssertEqual(remaining, [1, 3])
        do {
            try await first.finalizeBlob(manifest.digest)
            XCTFail("an incomplete blob must not publish")
        } catch {
            XCTAssertEqual(error as? MeshBlobStoreError, .incomplete)
        }

        let fourthInsertion = try await first.receiveBlobChunk(chunks[3])
        let secondInsertion = try await second.receiveBlobChunk(chunks[1])
        XCTAssertEqual(fourthInsertion, .inserted)
        XCTAssertEqual(secondInsertion, .inserted)
        try await second.finalizeBlob(manifest.digest)
        let firstData = try await first.blobData(for: manifest.digest)
        let firstState = try await first.blobState(for: manifest.digest)
        XCTAssertEqual(firstData, data)
        XCTAssertEqual(firstState, .complete)

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await reopened.finalizeBlob(manifest.digest)
        let reopenedData = try await reopened.blobData(for: manifest.digest)
        XCTAssertEqual(reopenedData, data)
        do {
            _ = try await reopened.receiveBlobChunk(chunks[0])
            XCTFail("a complete blob must reject orphan chunks")
        } catch {
            XCTAssertEqual(error as? MeshBlobStoreError, .unavailable)
        }

        try await reopened.evictBlob(manifest.digest)
        let evictedState = try await reopened.blobState(for: manifest.digest)
        let evictedData = try await reopened.blobData(for: manifest.digest)
        let refetchMissing = try await reopened.missingBlobChunkIndices(for: manifest.digest)
        XCTAssertEqual(evictedState, .evicted)
        XCTAssertNil(evictedData)
        XCTAssertEqual(refetchMissing, [0, 1, 2, 3])
        for chunk in chunks.reversed() {
            _ = try await reopened.receiveBlobChunk(chunk)
        }
        try await reopened.finalizeBlob(manifest.digest)
        let refetchedData = try await reopened.blobData(for: manifest.digest)
        XCTAssertEqual(refetchedData, data)
    }

    func testBlobTransferRejectsChunkTamperingAndRecoversAfterWholeBlobMismatch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let expected = Data("expected-content".utf8)
        let manifest = blobManifest(for: expected, chunkSize: 8)
        let expectedChunks = try blobChunks(for: expected, manifest: manifest)
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.registerBlobManifest(manifest)

        var tampered = expectedChunks[0]
        tampered.data[0] ^= 0xff
        do {
            _ = try await store.receiveBlobChunk(tampered)
            XCTFail("a chunk with the wrong digest must be rejected")
        } catch {
            XCTAssertEqual(error as? MeshBlobValidationError, .chunkDigestMismatch)
        }

        let wrong = Data("different-bytes!".utf8)
        XCTAssertEqual(wrong.count, expected.count)
        let wrongChunks = try blobChunks(for: wrong, manifest: manifest)
        for chunk in wrongChunks { _ = try await store.receiveBlobChunk(chunk) }
        do {
            try await store.finalizeBlob(manifest.digest)
            XCTFail("a blob with the wrong content digest must not publish")
        } catch {
            XCTAssertEqual(error as? MeshBlobValidationError, .blobDigestMismatch)
        }
        let corruptState = try await store.blobState(for: manifest.digest)
        let corruptMissing = try await store.missingBlobChunkIndices(for: manifest.digest)
        XCTAssertEqual(corruptState, .corrupt)
        XCTAssertEqual(corruptMissing, Array(expectedChunks.indices))

        for chunk in expectedChunks { _ = try await store.receiveBlobChunk(chunk) }
        try await store.finalizeBlob(manifest.digest)
        let recovered = try await store.blobData(for: manifest.digest)
        XCTAssertEqual(recovered, expected)
    }

    func testBlobTransferDetectsDamagedChunkOnRestartAndRejectsSymlinkStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let data = Data("resume-after-crash".utf8)
        let manifest = blobManifest(for: data, chunkSize: 6)
        let chunks = try blobChunks(for: data, manifest: manifest)
        let blobRoot = fixture.directory.appendingPathComponent(
            fixture.databaseURL.lastPathComponent + ".blobs", isDirectory: true
        )
        let chunkDirectory = blobRoot.appendingPathComponent(
            manifest.digest.hex + ".chunks", isDirectory: true
        )
        do {
            let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            try await store.registerBlobManifest(manifest)
            _ = try await store.receiveBlobChunk(chunks[0])
        }
        let firstChunk = chunkDirectory.appendingPathComponent("0.chunk")
        try Data("damage".utf8).write(to: firstChunk, options: .atomic)

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let missingAfterDamage = try await reopened.missingBlobChunkIndices(
            for: manifest.digest
        )
        XCTAssertEqual(missingAfterDamage, Array(chunks.indices))

        try FileManager.default.removeItem(at: firstChunk)
        try FileManager.default.createSymbolicLink(
            at: firstChunk, withDestinationURL: fixture.databaseURL
        )
        do {
            _ = try await reopened.receiveBlobChunk(chunks[0])
            XCTFail("chunk storage must never follow a symbolic link")
        } catch {
            XCTAssertEqual(error as? MeshBlobStoreError, .unsafeStoragePath)
        }

        try FileManager.default.removeItem(at: firstChunk)
        for chunk in chunks { _ = try await reopened.receiveBlobChunk(chunk) }
        let finalBlob = blobRoot.appendingPathComponent(manifest.digest.hex + ".blob")
        try FileManager.default.createSymbolicLink(
            at: finalBlob, withDestinationURL: fixture.databaseURL
        )
        do {
            try await reopened.finalizeBlob(manifest.digest)
            XCTFail("published blob storage must never follow a symbolic link")
        } catch {
            XCTAssertEqual(error as? MeshBlobStoreError, .unsafeStoragePath)
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
        XCTAssertEqual(migratedVersion, 7)
        XCTAssertEqual(migratedEpoch, 9)

        let futureURL = fixture.directory.appendingPathComponent("future.sqlite")
        try executeSQLite(
            at: futureURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(8);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: futureURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsupportedSchemaVersion(8))
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
        XCTAssertEqual(schemaVersion, 7)
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

    private func pairController(
        _ controller: MeshDeviceIdentity, invitedBy host: MeshDeviceIdentity,
        in group: MeshTrustGroupID, store: DistributedMeshStore
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hostService = MeshTrustPairingService(
            identity: host, invitationStore: store
        )
        let invitation = try await hostService.issueInvitation(
            trustGroupID: group, membershipEpoch: 1,
            inviterAddressTicket: "isolated-host-ticket",
            requestedRoles: [.controller], now: now
        )
        let controllerService = MeshTrustPairingService(
            identity: controller, invitationStore: MeshMemoryInvitationUseStore()
        )
        let acceptance = try controllerService.createAcceptance(
            for: invitation, acceptingAddressTicket: "isolated-controller-ticket",
            displayName: "Test Controller", now: now
        )
        _ = try await hostService.redeem(acceptance, for: invitation, now: now)
    }

    private func pairDevice(
        _ device: MeshDeviceIdentity, roles: Set<MeshDeviceRole>,
        invitedBy inviter: MeshDeviceIdentity, in group: MeshTrustGroupID,
        store: DistributedMeshStore
    ) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let inviterService = MeshTrustPairingService(
            identity: inviter, invitationStore: store
        )
        let invitation = try await inviterService.issueInvitation(
            trustGroupID: group, membershipEpoch: 1,
            inviterAddressTicket: "isolated-inviter-ticket",
            requestedRoles: roles, now: now
        )
        let acceptance = try MeshTrustPairingService(
            identity: device, invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: invitation, acceptingAddressTicket: "isolated-device-ticket",
            displayName: "RPC Test Device", now: now
        )
        _ = try await inviterService.redeem(acceptance, for: invitation, now: now)
    }

    private func blobManifest(for data: Data, chunkSize: Int) -> MeshBlobManifest {
        MeshBlobManifest(
            digest: MeshBlobDigest(rawValue: Data(SHA256.hash(data: data)))!,
            byteSize: UInt64(data.count), mediaType: "application/octet-stream",
            chunkSize: chunkSize
        )
    }

    private func blobChunks(for data: Data,
                            manifest: MeshBlobManifest) throws -> [MeshBlobChunk] {
        try (0..<manifest.chunkCount).map { index in
            let start = index * manifest.chunkSize
            let end = start + (try manifest.expectedByteCount(forChunk: index))
            let bytes = data.subdata(in: start..<end)
            return MeshBlobChunk(
                blobDigest: manifest.digest, index: index, data: bytes,
                chunkDigest: MeshBlobDigest(
                    rawValue: Data(SHA256.hash(data: bytes))
                )!
            )
        }
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

private struct ReplicaRPCServerTransport: MeshTransport, Sendable {
    let server: MeshReplicaRPCServer
    let remoteEndpointID: MeshEndpointID

    var path: MeshTransportPath { get async { .local } }

    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try await server.handle(request, remoteEndpointID: remoteEndpointID)
    }
}

private struct MismatchedReplicaRPCTransport: MeshTransport, Sendable {
    var path: MeshTransportPath { get async { .local } }

    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        let requestHeader = try MeshReplicaRPCHeader.decode(request.header)
        let responseHeader = MeshReplicaRPCHeader(
            requestID: UUID(), operation: requestHeader.operation,
            trustGroupID: requestHeader.trustGroupID,
            membershipEpoch: requestHeader.membershipEpoch,
            disposition: .success
        )
        let vector = try MeshSyncVector(
            trustGroupID: requestHeader.trustGroupID,
            membershipEpoch: requestHeader.membershipEpoch, authors: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return MeshTransportResponse(
            header: try responseHeader.canonicalBytes(),
            body: try encoder.encode(vector)
        )
    }
}

private struct MeshSeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
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
