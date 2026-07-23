import Crypto
import CSQLite
import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol

final class DistributedMeshStoreTests: XCTestCase {
    func testReplicaSyncAndPresenceStartConcurrently() async {
        let probe = ConcurrentOperationStartProbe()
        let task = Task {
            await MeshPeerSyncPresenceCoordinator.run(
                synchronize: {
                    await probe.arriveAndWait()
                    return 1
                },
                fetchPresence: {
                    await probe.arriveAndWait()
                    return "busy"
                }
            )
        }
        for _ in 0..<100 where await probe.count < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        let count = await probe.count
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(count, 2)
        XCTAssertEqual(outcome.received, 1)
        XCTAssertEqual(outcome.presence, "busy")
    }

    func testPresenceStillRefreshesWhenReplicaSynchronizationFails() async {
        let outcome = await MeshPeerSyncPresenceCoordinator.run(
            synchronize: {
                throw MeshReplicaRPCError.synchronizationLimitExceeded
            },
            fetchPresence: { "busy" }
        )

        XCTAssertEqual(outcome.received, 0)
        XCTAssertNotNil(outcome.synchronizationError)
        XCTAssertEqual(outcome.presence, "busy")
        XCTAssertNil(outcome.presenceError)
        XCTAssertTrue(outcome.isReachable)
    }

    func testRPCClientPropagatesConfiguredBackgroundTimeout() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let transport = TimeoutRecordingTransport()
        let client = MeshReplicaRPCClient(
            transport: transport, requestTimeoutMilliseconds: 1_500
        )

        do {
            _ = try await client.syncVector(
                for: fixture.group, membershipEpoch: 1
            )
            XCTFail("recording transport should terminate the request")
        } catch TimeoutRecordingTransport.Expected.failure {
            // Expected: only the outbound request contract is under test.
        }
        let recordedTimeout = await transport.recordedTimeout()
        XCTAssertEqual(recordedTimeout, 1_500)
    }

    func testBackgroundTimeoutCoversColdRelayConnectionBudget() {
        // Cross-network cold QUIC setup was measured at 3.36–4.45 seconds. A
        // simultaneous dial may then need one bounded reconnect, so keep room
        // for two handshakes plus the authenticated RPC.
        XCTAssertGreaterThanOrEqual(
            MeshReplicaRPCClient.defaultRequestTimeoutMilliseconds,
            10_000
        )
        XCTAssertGreaterThanOrEqual(
            MeshReplicaRPCClient.backgroundRequestTimeoutMilliseconds,
            10_000
        )
    }

    func testSyncFailurePresentationIsConciseStableAndRecoverable() {
        XCTAssertNil(MeshSyncFailurePresentation.message(peerNames: []))
        XCTAssertEqual(
            MeshSyncFailurePresentation.message(peerNames: ["Home Mac"]),
            "Couldn't sync with Home Mac. Changes remain saved locally " +
                "and will retry automatically."
        )
        XCTAssertEqual(
            MeshSyncFailurePresentation.message(
                peerNames: ["personal-dev", "Home Mac", "Home Mac"]
            ),
            "Couldn't sync with 2 devices (Home Mac, personal-dev). Changes " +
                "remain saved locally and will retry automatically."
        )
    }

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
        let controllerEntity = MeshEntityReference(
            type: .issue, id: "offline-controller-issue"
        )!
        let controllerEvent = try signedFieldEvent(
            group: fixture.group, device: controller.deviceID,
            endpoint: try controller.endpointID(),
            key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: controller.irohSecretKeyBytes()
            ),
            sequence: 1,
            timestamp: .init(wallTimeMilliseconds: 1_100),
            entity: controllerEntity,
            mutation: MeshFieldMutation(
                field: "title", value: Data("Offline Controller".utf8)
            )
        )
        _ = try await clientStore.insert(
            controllerEvent,
            authorPublicKey: try controller.signingPublicKeyBytes()
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

        let executionCounter = HostExecutionCounter()
        let server = MeshReplicaRPCServer(
            store: hostStore, hostIdentity: host,
            hostPresenceProvider: {
                MeshAgentPresenceSnapshot(
                    hostDeviceID: host.deviceID,
                    hostEndpointID: try! host.endpointID(),
                    generatedAtMilliseconds: 1_000,
                    expiresAtMilliseconds: 16_000,
                    records: [MeshAgentPresenceRecord(
                        resourceID: resourceID, state: .busy,
                        observedAtMilliseconds: 900,
                        stateReason: "tool", kind: "codex"
                    )]
                )
            },
            hostCommandHandler: { command in
                await executionCounter.record(command.id)
                return .executed(Data("poke-ok".utf8))
            },
            timestamp: { MeshHybridTimestamp(wallTimeMilliseconds: 2_000) }
        )
        let transport = ReplicaRPCServerTransport(
            server: server, remoteEndpointID: try controller.endpointID(),
            advertisedAddressTicket: "fresh-controller-address-ticket"
        )
        let client = MeshReplicaRPCClient(transport: transport)
        let report = try await MeshReplicaSyncSession(
            store: clientStore, client: client
        ).synchronize(group: fixture.group, membershipEpoch: 1, rangeLimit: 1)
        XCTAssertEqual(report, MeshReplicaSyncReport(eventCount: 1, rangeCount: 1))
        let refreshedController = try await hostStore.trustedDevice(
            in: fixture.group, id: controller.deviceID
        )
        XCTAssertEqual(
            refreshedController?.addressTicket,
            "fresh-controller-address-ticket"
        )
        let fields = try await clientStore.materializedFields(
            for: entity, in: fixture.group
        )
        XCTAssertEqual(fields.first?.value, mutation.value)
        let clientVector = try await clientStore.syncVector(for: fixture.group)
        let hostVector = try await hostStore.syncVector(for: fixture.group)
        XCTAssertEqual(clientVector, hostVector)
        let pushedFields = try await hostStore.materializedFields(
            for: controllerEntity, in: fixture.group
        )
        XCTAssertEqual(
            pushedFields.first?.value,
            Data("Offline Controller".utf8)
        )
        let acknowledged = try await hostStore.acknowledgementVector(
            for: fixture.group, peer: controller.deviceID
        )
        XCTAssertEqual(acknowledged, hostVector)

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

        let fetchedResource = try await client.hostResource(
            resourceID, group: fixture.group, membershipEpoch: 1
        )
        XCTAssertEqual(fetchedResource.resourceID, resourceID)
        XCTAssertEqual(fetchedResource.hostDeviceID, host.deviceID)
        XCTAssertEqual(fetchedResource.generation, 1)
        let presence = try await client.hostPresence(
            group: fixture.group, membershipEpoch: 1
        )
        XCTAssertEqual(presence.hostDeviceID, host.deviceID)
        XCTAssertEqual(presence.records.first?.resourceID, resourceID)
        XCTAssertEqual(presence.records.first?.state, .busy)
        let storedHostPeer = try await clientStore.trustedDevice(
            in: fixture.group, id: host.deviceID
        )
        let hostPeer = try XCTUnwrap(storedHostPeer)
        let verifiedPresence = try await MeshVerifiedHostPresence.fetch(
            client: client, peer: hostPeer, group: fixture.group,
            membershipEpoch: 1, nowMilliseconds: 2_000
        )
        XCTAssertEqual(verifiedPresence.records.map(\.resourceID), [resourceID])

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
        XCTAssertEqual(receipt.receipt.state, .executed)
        XCTAssertEqual(receipt.receipt.result, Data("poke-ok".utf8))
        try MeshHostCommandCrypto.verify(
            receipt, hostPublicKey: try host.signingPublicKeyBytes()
        )
        let replayedReceipt = try await client.sendHostCommand(signedCommand)
        XCTAssertEqual(replayedReceipt, receipt)
        let executionCount = await executionCounter.count
        XCTAssertEqual(executionCount, 1)

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

        let inactiveGroupClient = MeshReplicaRPCClient(
            transport: ReplicaRPCServerTransport(
                server: MeshReplicaRPCServer(
                    store: hostStore,
                    allowedTrustGroupID: MeshTrustGroupID(),
                    restrictToAllowedTrustGroup: true
                ),
                remoteEndpointID: try controller.endpointID()
            )
        )
        do {
            _ = try await inactiveGroupClient.syncVector(
                for: fixture.group, membershipEpoch: 1
            )
            XCTFail("an archived trust group must not remain remotely serviceable")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaRPCError,
                .remoteFailure("trust-group-inactive")
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

    func testControllerSyncBootstrapsCurrentEpochRosterBeforeHistoricalEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hostStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("roster-host.sqlite")
        )
        let joiningStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("roster-joining.sqlite")
        )
        try await hostStore.setMembershipEpoch(1, for: fixture.group)
        try await joiningStore.setMembershipEpoch(1, for: fixture.group)
        let host = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let joining = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        let historicalAuthor = MeshDeviceIdentity.generate(
            now: Date(timeIntervalSince1970: 30)
        )
        try await pairDevice(
            joining, roles: [.controller, .replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            historicalAuthor, roles: [.replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            host, roles: [.controller, .replica], invitedBy: joining,
            in: fixture.group, store: joiningStore
        )
        let storedAuthor = try await hostStore.trustedDevice(
            in: fixture.group, id: historicalAuthor.deviceID
        )
        var localAlias = try XCTUnwrap(storedAuthor)
        localAlias.descriptor.displayName = "Historical author on this device"
        localAlias.addressTicket = "stale-local-address-ticket"
        try await joiningStore.installVerifiedPeer(
            localAlias, in: fixture.group, membershipEpoch: 1
        )
        let entity = MeshEntityReference(type: .project, id: "roster-history")!
        let mutation = MeshFieldMutation(
            field: "title", value: Data("Roster History".utf8)
        )
        let event = try signedFieldEvent(
            group: fixture.group, device: historicalAuthor.deviceID,
            endpoint: try historicalAuthor.endpointID(),
            key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: historicalAuthor.irohSecretKeyBytes()
            ),
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 1_000),
            entity: entity, mutation: mutation
        )
        _ = try await hostStore.insert(
            event, authorPublicKey: try historicalAuthor.signingPublicKeyBytes()
        )
        let transport = ReplicaRPCServerTransport(
            server: MeshReplicaRPCServer(store: hostStore, hostIdentity: host),
            remoteEndpointID: try joining.endpointID()
        )
        let report = try await MeshReplicaSyncSession(
            store: joiningStore,
            client: MeshReplicaRPCClient(transport: transport),
            remoteEndpointID: try host.endpointID()
        ).synchronize(group: fixture.group, membershipEpoch: 1)

        let installedAuthor = try await joiningStore.trustedDevice(
            in: fixture.group, id: historicalAuthor.deviceID
        )
        let materialized = try await joiningStore.materializedFields(
            for: entity, in: fixture.group
        )
        XCTAssertEqual(report.eventCount, 1)
        XCTAssertEqual(
            installedAuthor?.signingPublicKey,
            try historicalAuthor.signingPublicKeyBytes()
        )
        XCTAssertEqual(
            installedAuthor?.descriptor.displayName,
            "Historical author on this device"
        )
        XCTAssertEqual(installedAuthor?.addressTicket, "isolated-device-ticket")
        XCTAssertEqual(materialized.first?.value, mutation.value)
    }

    func testControllerSyncCarriesHistoricalEventsAcrossMembershipEpochs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hostStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("epoch-host.sqlite")
        )
        let joiningStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("epoch-joining.sqlite")
        )
        try await hostStore.setMembershipEpoch(1, for: fixture.group)
        try await joiningStore.setMembershipEpoch(1, for: fixture.group)

        let host = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let joining = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        let removedAuthor = MeshDeviceIdentity.generate(
            now: Date(timeIntervalSince1970: 30)
        )
        try await pairDevice(
            joining, roles: [.controller, .replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            host, roles: [.controller, .replica], invitedBy: joining,
            in: fixture.group, store: joiningStore
        )
        try await pairDevice(
            removedAuthor, roles: [.replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )

        let entity = MeshEntityReference(type: .project, id: "epoch-history")!
        let mutation = MeshFieldMutation(
            field: "title", value: Data("Created before pairing changed".utf8)
        )
        let event = try signedFieldEvent(
            group: fixture.group, device: removedAuthor.deviceID,
            endpoint: try removedAuthor.endpointID(),
            key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: removedAuthor.irohSecretKeyBytes()
            ),
            sequence: 1, timestamp: .init(wallTimeMilliseconds: 1_000),
            entity: entity, mutation: mutation
        )
        _ = try await hostStore.insert(
            event, authorPublicKey: try removedAuthor.signingPublicKeyBytes()
        )

        let hostMember = try pairedDevice(
            host, name: "Host Controller", roles: [.controller, .replica]
        )
        let joiningMember = try pairedDevice(
            joining, name: "Joining Controller", roles: [.controller, .replica]
        )
        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: host, roster: [hostMember, joiningMember]
        )
        try await hostStore.applyMembershipTransition(
            transition, localIdentity: host,
            localAuthorRoles: [.controller, .replica]
        )
        try await joiningStore.applyMembershipTransition(
            transition, localIdentity: joining,
            localAuthorRoles: [.replica]
        )

        let transport = ReplicaRPCServerTransport(
            server: MeshReplicaRPCServer(store: hostStore, hostIdentity: host),
            remoteEndpointID: try joining.endpointID()
        )
        let report = try await MeshReplicaSyncSession(
            store: joiningStore,
            client: MeshReplicaRPCClient(transport: transport),
            remoteEndpointID: try host.endpointID()
        ).synchronize(group: fixture.group, membershipEpoch: 2)

        let materialized = try await joiningStore.materializedFields(
            for: entity, in: fixture.group
        )
        let retainedAuthor = try await joiningStore.retainedTrustedDevice(
            in: fixture.group, endpointID: try removedAuthor.endpointID()
        )
        let activePeers = try await joiningStore.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertEqual(report.eventCount, 1)
        XCTAssertEqual(
            retainedAuthor?.signingPublicKey,
            try removedAuthor.signingPublicKeyBytes()
        )
        XCTAssertFalse(activePeers.contains {
            $0.descriptor.id == removedAuthor.deviceID
        })
        XCTAssertEqual(materialized.first?.value, mutation.value)
    }

    func testControllerRosterRepairsPromotedHistoricalGhostWithoutDemotingActivePeer()
        async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hostStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent(
                "ghost-repair-host.sqlite"
            )
        )
        let joiningStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent(
                "ghost-repair-joining.sqlite"
            )
        )
        try await hostStore.setMembershipEpoch(1, for: fixture.group)
        try await joiningStore.setMembershipEpoch(1, for: fixture.group)

        let host = MeshDeviceIdentity.generate()
        let joining = MeshDeviceIdentity.generate()
        let removed = MeshDeviceIdentity.generate()
        try await pairDevice(
            joining, roles: [.controller, .replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            removed, roles: [.replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            host, roles: [.controller, .replica], invitedBy: joining,
            in: fixture.group, store: joiningStore
        )
        try await pairDevice(
            removed, roles: [.replica], invitedBy: joining,
            in: fixture.group, store: joiningStore
        )

        let hostMember = try pairedDevice(
            host, name: "Host", roles: [.controller, .replica]
        )
        let joiningMember = try pairedDevice(
            joining, name: "Joining", roles: [.controller, .replica]
        )
        let removedMember = try pairedDevice(
            removed, name: "Removed", roles: [.replica]
        )
        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: host, roster: [hostMember, joiningMember]
        )
        try await hostStore.applyMembershipTransition(
            transition, localIdentity: host,
            localAuthorRoles: [.controller, .replica]
        )
        try await joiningStore.applyMembershipTransition(
            transition, localIdentity: joining,
            localAuthorRoles: [.controller, .replica]
        )

        // Reproduce the pre-epoch-tag roster bug: an already retained binding
        // was accidentally promoted into the current live epoch.
        try await joiningStore.installVerifiedPeer(
            removedMember, in: fixture.group, membershipEpoch: 2
        )
        let pollutedActive = try await joiningStore.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertTrue(pollutedActive.contains {
            $0.descriptor.id == removed.deviceID
        })

        let transport = ReplicaRPCServerTransport(
            server: MeshReplicaRPCServer(store: hostStore, hostIdentity: host),
            remoteEndpointID: try joining.endpointID()
        )
        _ = try await MeshReplicaSyncSession(
            store: joiningStore,
            client: MeshReplicaRPCClient(transport: transport),
            remoteEndpointID: try host.endpointID()
        ).synchronize(group: fixture.group, membershipEpoch: 2)

        let active = try await joiningStore.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertFalse(active.contains {
            $0.descriptor.id == removed.deviceID
        })
        XCTAssertTrue(active.contains {
            $0.descriptor.id == host.deviceID
        })
        let retained = try await joiningStore.retainedTrustedDevices(
            in: fixture.group
        )
        XCTAssertEqual(
            retained.first {
                $0.device.descriptor.id == removed.deviceID
            }?.membershipEpoch,
            1
        )

        // Even an authenticated controller's historical entry cannot demote
        // a device that the signed current transition still includes.
        try await joiningStore.installRetainedVerifiedPeer(
            hostMember, in: fixture.group, membershipEpoch: 1
        )
        let stillActive = try await joiningStore.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertTrue(stillActive.contains {
            $0.descriptor.id == host.deviceID
        })
    }

    func testHistoricalSnapshotMergePreservesJoiningDeviceLocalEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let hostStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("snapshot-host.sqlite")
        )
        let joiningStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("snapshot-joining.sqlite")
        )
        try await hostStore.setMembershipEpoch(1, for: fixture.group)
        try await joiningStore.setMembershipEpoch(1, for: fixture.group)

        let host = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 10))
        let joining = MeshDeviceIdentity.generate(now: Date(timeIntervalSince1970: 20))
        try await pairDevice(
            joining, roles: [.controller, .replica], invitedBy: host,
            in: fixture.group, store: hostStore
        )
        try await pairDevice(
            host, roles: [.controller, .replica], invitedBy: joining,
            in: fixture.group, store: joiningStore
        )

        let hostEntity = MeshEntityReference(type: .project, id: "snapshot-host")!
        let hostMutation = MeshFieldMutation(
            field: "title", value: Data("Host before epoch change".utf8)
        )
        let hostEvent = try signedFieldEvent(
            group: fixture.group, device: host.deviceID,
            endpoint: try host.endpointID(),
            key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: host.irohSecretKeyBytes()
            ), sequence: 1, timestamp: .init(wallTimeMilliseconds: 1_000),
            entity: hostEntity, mutation: hostMutation
        )
        _ = try await hostStore.insert(
            hostEvent, authorPublicKey: try host.signingPublicKeyBytes()
        )
        let snapshot = try await hostStore.createSnapshot(
            for: fixture.group, identity: host,
            createdAt: .init(wallTimeMilliseconds: 1_100)
        )
        try await hostStore.persistSnapshot(
            snapshot, creatorPublicKey: try host.signingPublicKeyBytes()
        )
        _ = try await hostStore.compactEvents(
            using: snapshot.snapshot.id,
            creatorPublicKey: try host.signingPublicKeyBytes(),
            activePeers: []
        )

        let joiningEntity = MeshEntityReference(
            type: .project, id: "snapshot-joining"
        )!
        let joiningMutation = MeshFieldMutation(
            field: "title", value: Data("Joining device local history".utf8)
        )
        let joiningEvent = try signedFieldEvent(
            group: fixture.group, device: joining.deviceID,
            endpoint: try joining.endpointID(),
            key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: joining.irohSecretKeyBytes()
            ), sequence: 1, timestamp: .init(wallTimeMilliseconds: 1_200),
            entity: joiningEntity, mutation: joiningMutation
        )
        _ = try await joiningStore.insert(
            joiningEvent, authorPublicKey: try joining.signingPublicKeyBytes()
        )

        let hostMember = try pairedDevice(
            host, name: "Host Controller", roles: [.controller, .replica]
        )
        let joiningMember = try pairedDevice(
            joining, name: "Joining Controller", roles: [.controller, .replica]
        )
        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: host, roster: [hostMember, joiningMember]
        )
        try await hostStore.applyMembershipTransition(
            transition, localIdentity: host,
            localAuthorRoles: [.controller, .replica]
        )
        try await joiningStore.applyMembershipTransition(
            transition, localIdentity: joining,
            localAuthorRoles: [.replica]
        )

        let transport = ReplicaRPCServerTransport(
            server: MeshReplicaRPCServer(store: hostStore, hostIdentity: host),
            remoteEndpointID: try joining.endpointID()
        )
        let report = try await MeshReplicaSyncSession(
            store: joiningStore,
            client: MeshReplicaRPCClient(transport: transport),
            remoteEndpointID: try host.endpointID()
        ).synchronize(group: fixture.group, membershipEpoch: 2)

        let hostFields = try await joiningStore.materializedFields(
            for: hostEntity, in: fixture.group
        )
        let joiningFields = try await joiningStore.materializedFields(
            for: joiningEntity, in: fixture.group
        )
        let vector = try await joiningStore.syncVector(for: fixture.group)
        XCTAssertEqual(report.snapshotCount, 1)
        XCTAssertEqual(hostFields.first?.value, hostMutation.value)
        XCTAssertEqual(joiningFields.first?.value, joiningMutation.value)
        XCTAssertEqual(vector.sequence(for: try host.endpointID()), 1)
        XCTAssertEqual(vector.sequence(for: try joining.endpointID()), 1)
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
        XCTAssertEqual(schemaVersion, 10)
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
        let issueID = "33333333-3333-4333-8333-333333333333"
        let legacyIssueAttachmentID = "55555555-5555-4555-8555-555555555555"
        let legacyIssueAttachmentName = "legacy-proof.md"
        let legacyIssueAttachmentBytes = Data("legacy issue attachment".utf8)
        let legacyIssueAttachmentDirectory = source.appendingPathComponent(
            "attachments/\(issueID)", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyIssueAttachmentDirectory, withIntermediateDirectories: true
        )
        try legacyIssueAttachmentBytes.write(
            to: legacyIssueAttachmentDirectory.appendingPathComponent(
                legacyIssueAttachmentName
            )
        )
        let registry = try JSONSerialization.data(withJSONObject: [
            "groups": ["personal"],
            "projects": [[
                "id": projectID.uuidString,
                "name": "Offline Migration Fixture",
                "addedAt": 123.0,
                "issues": [[
                    "id": issueID,
                    "number": 1, "title": "Verify cutover",
                    "createdAt": 124.0, "updatedAt": 125.0,
                    "attachments": [[
                        "id": legacyIssueAttachmentID,
                        "storedName": legacyIssueAttachmentName,
                        "originalName": "proof.md",
                        "byteSize": legacyIssueAttachmentBytes.count,
                        "isImage": false,
                        "addedAt": 126.0,
                    ]],
                ]],
            ]],
            "trash": [],
        ], options: [.sortedKeys])
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
        XCTAssertEqual(first.inventory.counts.attachments, 2)
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
        let importedProject = try await target.materializedFields(
            for: project, in: fixture.group
        )
        XCTAssertEqual(
            importedProject.first { $0.field == "name" }?.value,
            Data("\"Offline Migration Fixture\"".utf8)
        )
        let issue = MeshEntityReference(
            type: .issue, id: issueID
        )!
        let importedIssue = try await target.materializedFields(
            for: issue, in: fixture.group
        )
        XCTAssertEqual(
            importedIssue.first { $0.field == "projectID" }?.value,
            Data("\"\(projectID.uuidString)\"".utf8)
        )
        let importedAttachments = try XCTUnwrap(
            importedIssue.first { $0.field == "attachments" }?.value
        )
        let attachmentObjects = try XCTUnwrap(
            JSONSerialization.jsonObject(with: importedAttachments)
                as? [[String: Any]]
        )
        XCTAssertEqual(
            (attachmentObjects.first?["meshAttachment"] as? [String: Any])?["id"]
                as? String,
            legacyIssueAttachmentID
        )
        let groups = try await target.materializedEntities(
            of: .projectGroup, in: fixture.group
        )
        XCTAssertEqual(groups.count, 1)
        let migrationVector = try await target.syncVector(for: fixture.group)
        XCTAssertEqual(migrationVector.authors.map(\.sequence), [1])
        let bootstrap = try await target.syncResponse(for: MeshEventRangeRequest(
            trustGroupID: fixture.group, membershipEpoch: 1,
            authorEndpointID: try identity.endpointID(), afterSequence: 0, limit: 256
        ))
        XCTAssertEqual(bootstrap.kind, .snapshot)
        XCTAssertEqual(bootstrap.snapshot, first.genesis)
        let importedLegacyBlob = try await target.blobData(
            for: MeshBlobDigest(
                rawValue: Data(SHA256.hash(data: legacyIssueAttachmentBytes))
            )!
        )
        XCTAssertEqual(importedLegacyBlob, legacyIssueAttachmentBytes)
        let importedMeshBlob = try await target.blobData(
            for: MeshBlobDigest(
                rawValue: Data(SHA256.hash(data: attachmentBytes))
            )!
        )
        XCTAssertEqual(importedMeshBlob, attachmentBytes)
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
        XCTAssertEqual(reopenedSchemaVersion, 10)
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

    func testExecutingStopRecoversRosterCleanupAfterHostCrash() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let replica = try MeshLocalReplica.open(
            rootURL: fixture.directory.appendingPathComponent(
                "stop-recovery", isDirectory: true
            ),
            identityStorage: MeshMemoryIdentityStorage()
        )
        let store = replica.store
        let host = replica.identity
        let sender = MeshDeviceIdentity.generate(
            now: Date(timeIntervalSince1970: 2)
        )
        try await store.setMembershipEpoch(1, for: fixture.group)
        try await pairController(
            sender, invitedBy: host, in: fixture.group, store: store
        )
        let registry = DistributedChatRegistry(
            replica: replica, group: fixture.group
        )
        _ = try await registry.createRoom(named: "stop-recovery")
        let chat = DistributedAgentChat(replica: replica, group: fixture.group)
        let memberID = "crashed-stop-agent"
        _ = try await chat.join(
            room: "stop-recovery", nick: "worker", memberID: memberID
        )
        let resourceID = try XCTUnwrap(MeshResourceID(rawValue: memberID))
        let bindings = DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        )
        try bindings.save(
            try DistributedHostResourceBinding(
                resourceID: resourceID,
                tmuxSession: "pharos-crashed-stop",
                tmuxSocket: "/tmp/tmux-crashed-stop",
                tmuxPane: "%9", tmuxSessionID: "$4",
                tmuxSessionCreatedAt: 10, panePID: 11
            ),
            for: resourceID
        )
        let base = Int64(Date().timeIntervalSince1970 * 1_000)
        let managed = try await store.replaceHostResource(
            in: fixture.group, on: host, resourceID: resourceID,
            allowedActions: [.presence, .poke, .stop],
            at: MeshHybridTimestamp(wallTimeMilliseconds: base)
        )
        let command = MeshHostCommand(
            trustGroupID: fixture.group,
            senderDeviceID: sender.deviceID,
            targetHostDeviceID: host.deviceID,
            targetHostEndpointID: try host.endpointID(),
            resourceID: resourceID,
            expectedResourceGeneration: managed.generation,
            action: .stop,
            idempotencyKey: "stop-recovery-after-crash",
            createdAt: MeshHybridTimestamp(wallTimeMilliseconds: base + 1),
            deadlineMilliseconds: base + 10_000
        )
        let accepted = try await store.accept(
            MeshHostCommandCrypto.sign(
                command, membershipEpoch: 1, with: sender
            ),
            on: host,
            receivedAt: MeshHybridTimestamp(wallTimeMilliseconds: base + 2)
        )
        XCTAssertEqual(accepted.receipt.action, .stop)
        let claim = try await store.claimExecution(
            commandID: command.id, on: host,
            at: MeshHybridTimestamp(wallTimeMilliseconds: base + 3)
        )
        XCTAssertTrue(claim.shouldExecute)

        await DistributedHostCommandRecovery.recover(
            replica: replica, group: fixture.group,
            executor: DistributedHostCommandExecutor(
                bindings: bindings,
                seatInspector: MissingTmuxSeatInspector()
            )
        )

        let storedReceipt = try await store.commandReceipt(id: command.id)
        let recovered = try XCTUnwrap(storedReceipt)
        XCTAssertEqual(recovered.receipt.state, .executed)
        let memberships = try await chat.memberships(memberID: memberID)
        XCTAssertTrue(memberships.isEmpty)
        let retired = try await store.hostResource(
            in: fixture.group, hostDeviceID: host.deviceID,
            resourceID: resourceID
        )
        XCTAssertEqual(retired?.state, .retired)
        XCTAssertThrowsError(try bindings.load(resourceID))
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
        XCTAssertEqual(migratedVersion, 10)
        XCTAssertEqual(migratedEpoch, 9)

        let futureURL = fixture.directory.appendingPathComponent("future.sqlite")
        try executeSQLite(
            at: futureURL,
            sql: "CREATE TABLE schema_metadata(version INTEGER NOT NULL); " +
                 "INSERT INTO schema_metadata VALUES(11);"
        )
        XCTAssertThrowsError(try DistributedMeshStore(databaseURL: futureURL)) {
            XCTAssertEqual($0 as? DistributedMeshStoreError, .unsupportedSchemaVersion(11))
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
        XCTAssertEqual(schemaVersion, 10)
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

    func testRepairPairingRefreshesSameIdentityButRejectsDeviceIDCollision() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let inviter = MeshDeviceIdentity.generate()
        let acceptor = MeshDeviceIdentity.generate()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = MeshTrustPairingService(
            identity: inviter, invitationStore: store
        )

        func invitation(at date: Date) async throws -> MeshTrustInvitation {
            try await service.issueInvitation(
                trustGroupID: fixture.group, membershipEpoch: 1,
                inviterAddressTicket: "inviter-\(date.timeIntervalSince1970)",
                requestedRoles: [.controller, .replica], now: date
            )
        }

        let first = try await invitation(at: now)
        let firstAcceptance = try MeshTrustPairingService(
            identity: acceptor,
            invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: first, acceptingAddressTicket: "old-address",
            displayName: "iPhone", now: now
        )
        _ = try await service.redeem(firstAcceptance, for: first, now: now)

        let repairNow = now.addingTimeInterval(1)
        let repair = try await invitation(at: repairNow)
        let repairAcceptance = try MeshTrustPairingService(
            identity: acceptor,
            invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: repair, acceptingAddressTicket: "refreshed-address",
            displayName: "Renamed iPhone", now: repairNow
        )
        _ = try await service.redeem(
            repairAcceptance, for: repair, now: repairNow
        )
        let refreshed = try await store.trustedDevice(
            in: fixture.group, id: acceptor.deviceID
        )
        XCTAssertEqual(refreshed?.descriptor.displayName, "Renamed iPhone")
        XCTAssertEqual(refreshed?.addressTicket, "refreshed-address")
        XCTAssertEqual(
            refreshed?.signingPublicKey, try acceptor.signingPublicKeyBytes()
        )

        let attackerSeed = MeshDeviceIdentity.generate()
        let attacker = try MeshDeviceIdentity(
            deviceID: acceptor.deviceID,
            secretKey: attackerSeed.irohSecretKeyBytes(),
            createdAtMilliseconds: attackerSeed.createdAtMilliseconds
        )
        let collisionNow = now.addingTimeInterval(2)
        let collisionInvitation = try await invitation(at: collisionNow)
        let collisionAcceptance = try MeshTrustPairingService(
            identity: attacker,
            invitationStore: MeshMemoryInvitationUseStore()
        ).createAcceptance(
            for: collisionInvitation,
            acceptingAddressTicket: "attacker-address",
            displayName: "Impostor", now: collisionNow
        )
        do {
            _ = try await service.redeem(
                collisionAcceptance, for: collisionInvitation,
                now: collisionNow
            )
            XCTFail("a reused device ID with another signing key must fail")
        } catch {
            XCTAssertEqual(
                error as? MeshTrustPairingError, .deviceAlreadyTrusted
            )
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

    func testSignedMembershipTransitionRevokesOnePeerRetainsOthersAndIsIdempotent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let controller = MeshDeviceIdentity.generate()
        let retained = MeshDeviceIdentity.generate()
        let revoked = MeshDeviceIdentity.generate()
        try await pairDevice(
            retained, roles: [.replica], invitedBy: controller,
            in: fixture.group, store: store
        )
        try await pairDevice(
            revoked, roles: [.controller, .replica], invitedBy: controller,
            in: fixture.group, store: store
        )

        let controllerMember = try pairedDevice(
            controller, name: "This Mac", roles: [.controller, .replica]
        )
        let storedRetained = try await store.trustedDevice(
            in: fixture.group, id: retained.deviceID
        )
        let retainedMember = try XCTUnwrap(storedRetained)

        let attackerKey = Curve25519.Signing.PrivateKey()
        let spoofedLocalIdentity = try MeshDeviceIdentity(
            deviceID: controller.deviceID,
            secretKey: attackerKey.rawRepresentation,
            createdAtMilliseconds: 99
        )
        let spoofedController = try pairedDevice(
            spoofedLocalIdentity, name: "Spoofed Controller",
            roles: [.controller, .replica]
        )
        let forgedTransition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: spoofedLocalIdentity,
            roster: [spoofedController, retainedMember]
        )
        do {
            try await store.applyMembershipTransition(
                forgedTransition, localIdentity: controller,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("matching only the local device UUID must not authorize a transition")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .authorNotController
            )
        }

        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: controller, roster: [controllerMember, retainedMember]
        )
        do {
            try await store.applyMembershipTransition(
                transition, localIdentity: controller,
                localAuthorRoles: [.replica]
            )
            XCTFail("a replica-only local device must not authorize a transition")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .authorNotController
            )
        }
        try await store.applyMembershipTransition(
            transition, localIdentity: controller,
            localAuthorRoles: [.controller, .replica]
        )
        let currentEpoch = try await store.membershipEpoch(for: fixture.group)
        XCTAssertEqual(currentEpoch, 2)
        let currentDevices = try await store.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertEqual(currentDevices.map(\.descriptor.id), [retained.deviceID])
        let revokedAuditRow = try await store.trustedDevice(
            in: fixture.group, id: revoked.deviceID
        )
        XCTAssertNotNil(
            revokedAuditRow,
            "the revoked row remains only as old-epoch audit evidence"
        )
        let auditTransitions = try await store.membershipTransitions(
            for: fixture.group
        )
        XCTAssertEqual(auditTransitions, [transition])
        let auditEntries = try await store.membershipAudit(for: fixture.group)
        XCTAssertEqual(auditEntries.count, 1)
        XCTAssertEqual(
            auditEntries[0].removedDevices.map(\.descriptor.id),
            [revoked.deviceID]
        )
        XCTAssertEqual(auditEntries[0].transitionSHA256.count, 64)

        let revokedMember = try pairedDevice(
            revoked, name: "Revoked Controller", roles: [.controller, .replica]
        )
        let revokedAuthorTransition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 2,
            identity: revoked, roster: [revokedMember, retainedMember]
        )
        do {
            try await store.applyMembershipTransition(
                revokedAuthorTransition, localIdentity: controller,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("an old-epoch controller audit row must not regain authority")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .authorNotController
            )
        }

        try await store.applyMembershipTransition(
            transition, localIdentity: controller,
            localAuthorRoles: [.controller, .replica]
        )
        let conflicting = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: controller, roster: [controllerMember]
        )
        do {
            try await store.applyMembershipTransition(
                conflicting, localIdentity: controller,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("a different transition for the committed epoch must fail closed")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .conflictingTransition
            )
        }
    }

    func testJoiningTransitionIsAnchoredToExactInviterIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let inviter = MeshDeviceIdentity.generate()
        let joiner = MeshDeviceIdentity.generate()
        let attacker = MeshDeviceIdentity.generate()
        let inviterMember = try pairedDevice(
            inviter, name: "Inviter", roles: [.controller, .replica]
        )
        let joinerMember = try pairedDevice(
            joiner, name: "Joiner", roles: [.controller, .replica]
        )
        try await store.installVerifiedPeer(
            inviterMember, in: fixture.group, membershipEpoch: 1
        )

        let attackerMember = try pairedDevice(
            attacker, name: "Attacker", roles: [.controller, .replica]
        )
        let attackerProposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: attacker,
            previousControllers: [MeshMembershipControllerIdentity(attackerMember)],
            roster: [attackerMember, joinerMember]
        )
        let attackerTransition = try MeshMembershipTransitionSigner.certify(
            attackerProposal, approvals: []
        )
        do {
            try await store.applyJoiningMembershipTransition(
                attackerTransition, trustedInviter: inviterMember,
                joiningDevice: joinerMember, localIdentity: joiner
            )
            XCTFail("a certified transition from a different inviter must fail")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .invalidRoster,
                "unexpected rejection: \(error)"
            )
        }

        let proposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: inviter,
            previousControllers: [MeshMembershipControllerIdentity(inviterMember)],
            roster: [inviterMember, joinerMember]
        )
        let transition = try MeshMembershipTransitionSigner.certify(
            proposal, approvals: []
        )
        try await store.applyJoiningMembershipTransition(
            transition, trustedInviter: inviterMember,
            joiningDevice: joinerMember, localIdentity: joiner
        )
        let joinedEpoch = try await store.membershipEpoch(for: fixture.group)
        let joinedPeers = try await store.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertEqual(joinedEpoch, 2)
        XCTAssertEqual(joinedPeers, [inviterMember])
    }

    func testQuorumVoteJournalPreventsConflictingCertificatesAndActivatesPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let a = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let c = MeshDeviceIdentity.generate()
        try await pairDevice(
            a, roles: [.controller, .replica], invitedBy: b,
            in: fixture.group, store: store
        )
        try await pairDevice(
            c, roles: [.controller, .replica], invitedBy: b,
            in: fixture.group, store: store
        )
        let storedA = try await store.trustedDevice(
            in: fixture.group, id: a.deviceID
        )
        let storedC = try await store.trustedDevice(
            in: fixture.group, id: c.deviceID
        )
        let aMember = try XCTUnwrap(storedA)
        let cMember = try XCTUnwrap(storedC)
        let bMember = try pairedDevice(
            b, name: "B", roles: [.controller, .replica]
        )
        let controllers = [aMember, bMember, cMember]
            .map(MeshMembershipControllerIdentity.init)

        let removeC = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1, identity: a,
            previousControllers: controllers,
            roster: [aMember, bMember]
        )
        let removeA = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1, identity: c,
            previousControllers: controllers,
            roster: [bMember, cMember]
        )
        let recordedApproval = try await store.recordMembershipVote(
            for: removeC, localIdentity: b,
            localAuthorRoles: [.controller, .replica]
        )
        let bApproval = try XCTUnwrap(recordedApproval)
        let replayedApproval = try await store.recordMembershipVote(
            for: removeC, localIdentity: b,
            localAuthorRoles: [.controller, .replica]
        )
        XCTAssertEqual(
            replayedApproval, bApproval,
            "same-proposal vote replay must return the durable approval"
        )
        do {
            _ = try await store.recordMembershipVote(
                for: removeA, localIdentity: b,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("one controller must never vote for two proposals in one epoch")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError,
                .conflictingTransition
            )
        }
        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        do {
            _ = try await reopened.recordMembershipVote(
                for: removeA, localIdentity: b,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("the one-vote rule must survive reopening the database")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError,
                .conflictingTransition
            )
        }
        let durableReplay = try await reopened.recordMembershipVote(
            for: removeC, localIdentity: b,
            localAuthorRoles: [.controller, .replica]
        )
        XCTAssertEqual(durableReplay, bApproval)

        let certified = try MeshMembershipTransitionSigner.certify(
            removeC, approvals: [bApproval]
        )
        try await store.applyMembershipTransition(
            certified, localIdentity: b,
            localAuthorRoles: [.controller, .replica]
        )
        let quorumEpoch = try await store.membershipQuorumRequiredFromEpoch(
            for: fixture.group
        )
        let currentEpoch = try await store.membershipEpoch(for: fixture.group)
        XCTAssertEqual(quorumEpoch, 2)
        XCTAssertEqual(currentEpoch, 2)

        let legacyNext = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 2,
            identity: b, roster: [aMember, bMember]
        )
        do {
            try await store.applyMembershipTransition(
                legacyNext, localIdentity: b,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("v1 must remain historical-only after quorum activation")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError, .quorumRequired
            )
        }
    }

    func testPendingAuthorProposalSurvivesRestartForExactRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let author = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let c = MeshDeviceIdentity.generate()
        let authorMember = try pairedDevice(
            author, name: "Author", roles: [.controller, .replica]
        )
        let bMember = try pairedDevice(
            b, name: "B", roles: [.controller, .replica]
        )
        let cMember = try pairedDevice(
            c, name: "C", roles: [.controller, .replica]
        )
        let proposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: author,
            previousControllers: [authorMember, bMember, cMember]
                .map(MeshMembershipControllerIdentity.init),
            roster: [authorMember, bMember]
        )

        do {
            let first = try DistributedMeshStore(databaseURL: fixture.databaseURL)
            try await first.setMembershipEpoch(1, for: fixture.group)
            try await first.installVerifiedPeer(
                bMember, in: fixture.group, membershipEpoch: 1
            )
            try await first.installVerifiedPeer(
                cMember, in: fixture.group, membershipEpoch: 1
            )
            let approval = try await first.recordMembershipVote(
                for: proposal, localIdentity: author,
                localAuthorRoles: [.controller, .replica]
            )
            XCTAssertNil(approval)
        }

        let reopened = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        let recovered = try await reopened.pendingMembershipProposal(
            for: fixture.group, previousEpoch: 1, authoredBy: author
        )
        XCTAssertEqual(recovered, proposal)
        let replay = try await reopened.recordMembershipVote(
            for: proposal, localIdentity: author,
            localAuthorRoles: [.controller, .replica]
        )
        XCTAssertNil(replay)
        let schemaVersion = try await reopened.schemaVersion()
        XCTAssertEqual(schemaVersion, 10)
    }

    func testQuorumCertificateRejectsFabricatedPreviousControllerSet() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let a = MeshDeviceIdentity.generate()
        let b = MeshDeviceIdentity.generate()
        let omitted = MeshDeviceIdentity.generate()
        try await pairDevice(
            a, roles: [.controller, .replica], invitedBy: b,
            in: fixture.group, store: store
        )
        try await pairDevice(
            omitted, roles: [.controller, .replica], invitedBy: b,
            in: fixture.group, store: store
        )
        let storedA = try await store.trustedDevice(
            in: fixture.group, id: a.deviceID
        )
        let aMember = try XCTUnwrap(storedA)
        let bMember = try pairedDevice(
            b, name: "B", roles: [.controller, .replica]
        )
        let fabricatedControllers = [aMember, bMember]
            .map(MeshMembershipControllerIdentity.init)
        let proposal = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1, identity: a,
            previousControllers: fabricatedControllers,
            roster: [aMember, bMember]
        )
        let approval = try MeshMembershipTransitionSigner.approve(
            proposal, with: b
        )
        let certified = try MeshMembershipTransitionSigner.certify(
            proposal, approvals: [approval]
        )

        do {
            try await store.applyMembershipTransition(
                certified, localIdentity: b,
                localAuthorRoles: [.controller, .replica]
            )
            XCTFail("a minority must not shrink the claimed controller universe")
        } catch {
            XCTAssertEqual(
                error as? MeshMembershipTransitionError,
                .previousControllerSetMismatch
            )
        }
    }

    func testMembershipVoteRPCReturnsOneDurableVoteAndRejectsCompetingProposal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let author = MeshDeviceIdentity.generate()
        let voter = MeshDeviceIdentity.generate()
        let third = MeshDeviceIdentity.generate()
        try await pairDevice(
            author, roles: [.controller, .replica], invitedBy: voter,
            in: fixture.group, store: store
        )
        try await pairDevice(
            third, roles: [.controller, .replica], invitedBy: voter,
            in: fixture.group, store: store
        )
        let storedAuthor = try await store.trustedDevice(
            in: fixture.group, id: author.deviceID
        )
        let storedThird = try await store.trustedDevice(
            in: fixture.group, id: third.deviceID
        )
        let authorMember = try XCTUnwrap(storedAuthor)
        let thirdMember = try XCTUnwrap(storedThird)
        let voterMember = try pairedDevice(
            voter, name: "Voter", roles: [.controller, .replica]
        )
        let controllers = [authorMember, voterMember, thirdMember]
            .map(MeshMembershipControllerIdentity.init)
        let first = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: author, previousControllers: controllers,
            roster: [authorMember, voterMember]
        )
        let competing = try MeshMembershipTransitionSigner.propose(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: author, previousControllers: controllers,
            roster: [authorMember, thirdMember]
        )
        let client = MeshReplicaRPCClient(
            transport: ReplicaRPCServerTransport(
                server: MeshReplicaRPCServer(
                    store: store, hostIdentity: voter,
                    localAuthorRoles: [.controller, .replica]
                ),
                remoteEndpointID: try author.endpointID()
            )
        )
        let receivedApproval = try await client.requestMembershipVote(for: first)
        let approval = try XCTUnwrap(receivedApproval)
        XCTAssertEqual(approval.deviceID, voter.deviceID)
        XCTAssertNoThrow(try MeshMembershipTransitionSigner.certify(
            first, approvals: [approval]
        ))

        do {
            _ = try await client.requestMembershipVote(for: competing)
            XCTFail("RPC must surface the durable one-vote conflict")
        } catch {
            XCTAssertEqual(
                error as? MeshReplicaRPCError,
                .remoteFailure("membership-vote-conflict")
            )
        }
    }

    func testMembershipTransitionRPCAdvancesOfflineSurvivorBeforeNormalSync() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controllerStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("controller.sqlite")
        )
        let survivorStore = try DistributedMeshStore(
            databaseURL: fixture.directory.appendingPathComponent("survivor.sqlite")
        )
        try await controllerStore.setMembershipEpoch(1, for: fixture.group)
        try await survivorStore.setMembershipEpoch(1, for: fixture.group)
        let controller = MeshDeviceIdentity.generate()
        let survivor = MeshDeviceIdentity.generate()
        try await pairDevice(
            survivor, roles: [.replica], invitedBy: controller,
            in: fixture.group, store: controllerStore
        )
        try await pairDevice(
            controller, roles: [.controller, .replica], invitedBy: survivor,
            in: fixture.group, store: survivorStore
        )
        let storedSurvivor = try await controllerStore.trustedDevice(
            in: fixture.group, id: survivor.deviceID
        )
        let survivorMember = try XCTUnwrap(storedSurvivor)
        let controllerMember = try pairedDevice(
            controller, name: "Controller", roles: [.controller, .replica]
        )
        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group, previousEpoch: 1,
            identity: controller, roster: [controllerMember, survivorMember]
        )
        let transport = ReplicaRPCServerTransport(
            server: MeshReplicaRPCServer(
                store: survivorStore, hostIdentity: survivor
            ),
            // A valid signed transition remains relayable if its author goes
            // offline after committing it on another survivor.
            remoteEndpointID: try survivor.endpointID()
        )
        try await MeshReplicaRPCClient(transport: transport)
            .applyMembershipTransition(transition)
        let survivorEpoch = try await survivorStore.membershipEpoch(for: fixture.group)
        XCTAssertEqual(survivorEpoch, 2)
        let survivorPeers = try await survivorStore.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertEqual(survivorPeers.map(\.descriptor.id), [controller.deviceID])
    }

    func testControllerCanSignOwnDepartureWhenAnotherControllerSurvives() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = try DistributedMeshStore(databaseURL: fixture.databaseURL)
        try await store.setMembershipEpoch(1, for: fixture.group)
        let departing = MeshDeviceIdentity.generate()
        let survivor = MeshDeviceIdentity.generate()
        try await pairDevice(
            departing, roles: [.controller, .replica], invitedBy: survivor,
            in: fixture.group, store: store
        )
        let departingMember = try pairedDevice(
            departing, name: "Departing Mac", roles: [.controller, .replica]
        )
        let survivorMember = try pairedDevice(
            survivor, name: "Surviving iPhone", roles: [.controller, .replica]
        )
        let transition = try MeshMembershipTransitionSigner.sign(
            trustGroupID: fixture.group,
            previousEpoch: 1,
            identity: departing,
            roster: [survivorMember],
            departingAuthor: departingMember
        )

        try await store.applyMembershipTransition(
            transition, localIdentity: survivor,
            localAuthorRoles: [.replica]
        )

        let currentEpoch = try await store.membershipEpoch(for: fixture.group)
        let currentPeers = try await store.trustedDevices(
            in: fixture.group, membershipEpoch: 2
        )
        XCTAssertEqual(currentEpoch, 2)
        XCTAssertTrue(
            currentPeers.isEmpty,
            "the local survivor is intentionally not stored as its own peer"
        )
        let auditRow = try await store.trustedDevice(
            in: fixture.group, id: departing.deviceID
        )
        XCTAssertNotNil(auditRow)
    }

    func testControllerCannotLeaveWithoutAnotherController() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let departing = MeshDeviceIdentity.generate()
        let replica = MeshDeviceIdentity.generate()
        let departingMember = try pairedDevice(
            departing, name: "Departing Mac", roles: [.controller, .replica]
        )
        let replicaMember = try pairedDevice(
            replica, name: "Replica only", roles: [.replica]
        )

        XCTAssertThrowsError(
            try MeshMembershipTransitionSigner.sign(
                trustGroupID: fixture.group,
                previousEpoch: 1,
                identity: departing,
                roster: [replicaMember],
                departingAuthor: departingMember
            )
        ) {
            XCTAssertEqual(
                $0 as? MeshMembershipTransitionError, .invalidRoster
            )
        }
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

    private func pairedDevice(
        _ identity: MeshDeviceIdentity, name: String,
        roles: Set<MeshDeviceRole>
    ) throws -> MeshPairedDevice {
        MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: identity.deviceID, endpointID: try identity.endpointID(),
                displayName: name, roles: roles
            ),
            signingPublicKey: try identity.signingPublicKeyBytes(),
            addressTicket: "isolated-\(identity.deviceID.rawValue.uuidString)-ticket"
        )
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

private struct MissingTmuxSeatInspector: DistributedTmuxSeatInspecting {
    func resolve(socket: String?, pane: String) throws -> DistributedTmuxSeat {
        throw DistributedHostExecutorError.runtimeSeatMismatch
    }
}

private struct ReplicaRPCServerTransport: MeshTransport, Sendable {
    let server: MeshReplicaRPCServer
    let remoteEndpointID: MeshEndpointID
    var advertisedAddressTicket: String? = nil

    var path: MeshTransportPath { get async { .local } }

    func localAddressTicket() async throws -> String? {
        advertisedAddressTicket
    }

    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        try await server.handle(request, remoteEndpointID: remoteEndpointID)
    }
}

private actor TimeoutRecordingTransport: MeshTransport {
    enum Expected: Error { case failure }

    private var timeout: Int?
    var path: MeshTransportPath { get async { .local } }

    func exchange(_ request: MeshTransportRequest) async throws -> MeshTransportResponse {
        timeout = request.timeoutMilliseconds
        throw Expected.failure
    }

    func recordedTimeout() -> Int? { timeout }
}

private actor ConcurrentOperationStartProbe {
    private var arrivals = 0
    var count: Int { arrivals }

    func arriveAndWait() async {
        arrivals += 1
        while arrivals < 2, !Task.isCancelled {
            await Task.yield()
        }
    }
}

private actor HostExecutionCounter {
    private(set) var count = 0
    private var commands: [MeshCommandID] = []

    func record(_ command: MeshCommandID) {
        count += 1
        commands.append(command)
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
