import Foundation
import XCTest
@testable import PharosMeshCore
import PharosMeshIdentity
import PharosMeshProtocol
import PharosMeshReplica

final class DistributedMeshBackgroundSynchronizerTests: XCTestCase {
    func testHostPreparationRunsBeforeWakeDelivery() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let memberID = UUID().uuidString
        let order = HostPreparationOrder()
        let synchronizer = DistributedMeshBackgroundSynchronizer(
            replica: fixture.replica,
            group: fixture.group,
            hostMode: true,
            control: DistributedMeshLocalServiceControl(
                status: fixture.status
            ),
            wakeCoordinator: DistributedAgentWakeCoordinator(
                presenceProvider: { _ in
                    [
                        memberID: DistributedHookCLI.LocalAgentPresence(
                            state: "idle", updatedAt: 1
                        )
                    ]
                },
                pendingMessageProvider: { _, _, _ in
                    [
                        .init(stableID: "message-1", room: "misc")
                    ]
                },
                pokeProvider: { _, _, _ in
                    await order.recordPoke()
                    return true
                }
            ),
            hostPreparation: { _, _ in
                await order.recordPreparation()
            },
            peerRunner: { peer, _, _, _ in
                BackgroundPeerResult(
                    deviceID: peer.descriptor.id,
                    snapshot: MeshConnectionSnapshot(
                        peer: peer.descriptor.id,
                        path: .irohDirect,
                        connected: true,
                        lastChange: Date()
                    ),
                    presence: nil
                )
            }
        )

        await synchronizer.runOnce()
        let events = await order.events

        XCTAssertEqual(
            events,
            ["prepare", "poke"]
        )
    }

    func testSlowOfflinePeerDoesNotDelayHealthyPeerPublication()
        async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let control = DistributedMeshLocalServiceControl(
            status: fixture.status
        )
        let synchronizer = DistributedMeshBackgroundSynchronizer(
            replica: fixture.replica,
            group: fixture.group,
            hostMode: false,
            control: control,
            wakeCoordinator: DistributedAgentWakeCoordinator(
                presenceProvider: { _ in [:] },
                pendingMessageProvider: { _, _, _ in [] },
                pokeProvider: { _, _, _ in false }
            ),
            peerRunner: { peer, _, _, _ in
                if peer.descriptor.id == fixture.slowPeerID {
                    try? await Task.sleep(for: .milliseconds(250))
                    return BackgroundPeerResult(
                        deviceID: peer.descriptor.id,
                        snapshot: MeshConnectionSnapshot(
                            peer: peer.descriptor.id,
                            path: .unavailable,
                            connected: false,
                            lastChange: Date()
                        ),
                        presence: nil
                    )
                }
                try? await Task.sleep(for: .milliseconds(10))
                return BackgroundPeerResult(
                    deviceID: peer.descriptor.id,
                    snapshot: MeshConnectionSnapshot(
                        peer: peer.descriptor.id,
                        path: .irohDirect,
                        connected: true,
                        lastChange: Date()
                    ),
                    presence: nil
                )
            }
        )

        let round = Task { await synchronizer.runOnce() }
        try await Task.sleep(for: .milliseconds(75))

        let early = control.snapshot()
        XCTAssertEqual(early.connections.count, 1)
        XCTAssertEqual(
            early.connections.first?.peer, fixture.healthyPeerID
        )
        XCTAssertEqual(early.connections.first?.connected, true)
        XCTAssertNotNil(early.lastSuccessfulSyncMilliseconds)

        await round.value
        let final = control.snapshot()
        XCTAssertEqual(final.connections.count, 2)
        XCTAssertTrue(final.connections.contains {
            $0.peer == fixture.healthyPeerID && $0.connected
        })
        XCTAssertTrue(final.connections.contains {
            $0.peer == fixture.slowPeerID && !$0.connected
        })
        XCTAssertNil(final.lastError)
    }

    func testSyncHintIsSentOnlyWhenTheLocalVectorChanges() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let control = DistributedMeshLocalServiceControl(
            status: fixture.status
        )
        let hints = SyncHintRecorder()
        let synchronizer = DistributedMeshBackgroundSynchronizer(
            replica: fixture.replica,
            group: fixture.group,
            hostMode: false,
            control: control,
            wakeCoordinator: DistributedAgentWakeCoordinator(
                presenceProvider: { _ in [:] },
                pendingMessageProvider: { _, _, _ in [] },
                pokeProvider: { _, _, _ in false }
            ),
            peerRunner: { peer, _, _, shouldSendHint in
                await hints.record(shouldSendHint)
                return BackgroundPeerResult(
                    deviceID: peer.descriptor.id,
                    snapshot: MeshConnectionSnapshot(
                        peer: peer.descriptor.id,
                        path: .irohDirect,
                        connected: true,
                        lastChange: Date()
                    ),
                    presence: nil
                )
            }
        )

        await synchronizer.runOnce()
        await synchronizer.runOnce()

        let values = await hints.values
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values.filter { $0 }.count, 2)
        XCTAssertEqual(values.filter { !$0 }.count, 2)
    }

    func testSyncHintRelayRetainsAStartupHintAndForwardsLaterHints()
        async throws {
        let relay = DistributedMeshSyncHintRelay()
        let counter = SyncHintInvocationCounter()
        let endpoint = try MeshDeviceIdentity.generate().endpointID()

        await relay.receive(from: endpoint)
        await relay.receive(from: endpoint)
        await relay.receiveFullSync()
        await relay.install { _ in
            await counter.record()
        }
        await relay.receive(from: endpoint)

        let count = await counter.value
        XCTAssertEqual(count, 3)
    }

    func testAuthenticatedHintPullsOnlyItsOriginPeer() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let control = DistributedMeshLocalServiceControl(
            status: fixture.status
        )
        let recorder = HintPeerRecorder()
        let synchronizer = DistributedMeshBackgroundSynchronizer(
            replica: fixture.replica,
            group: fixture.group,
            hostMode: false,
            control: control,
            wakeCoordinator: DistributedAgentWakeCoordinator(
                presenceProvider: { _ in [:] },
                pendingMessageProvider: { _, _, _ in [] },
                pokeProvider: { _, _, _ in false }
            ),
            peerRunner: { peer, _, _, _ in
                await recorder.record(peer.descriptor.id)
                return BackgroundPeerResult(
                    deviceID: peer.descriptor.id,
                    snapshot: MeshConnectionSnapshot(
                        peer: peer.descriptor.id,
                        path: .irohDirect,
                        connected: true,
                        lastChange: Date()
                    ),
                    presence: nil
                )
            }
        )

        await synchronizer.scheduleHint(
            from: fixture.healthyEndpointID
        )
        try await Task.sleep(for: .milliseconds(50))

        let peers = await recorder.peers
        XCTAssertEqual(peers, [fixture.healthyPeerID])
    }

    func testHintsDuringAnActivePeerPullCoalesceIntoOneFollowUp()
        async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let gate = HintFollowUpGate()
        let synchronizer = DistributedMeshBackgroundSynchronizer(
            replica: fixture.replica,
            group: fixture.group,
            hostMode: false,
            control: DistributedMeshLocalServiceControl(
                status: fixture.status
            ),
            wakeCoordinator: DistributedAgentWakeCoordinator(
                presenceProvider: { _ in [:] },
                pendingMessageProvider: { _, _, _ in [] },
                pokeProvider: { _, _, _ in false }
            ),
            peerRunner: { peer, _, _, _ in
                await gate.enter()
                return BackgroundPeerResult(
                    deviceID: peer.descriptor.id,
                    snapshot: MeshConnectionSnapshot(
                        peer: peer.descriptor.id,
                        path: .irohDirect,
                        connected: true,
                        lastChange: Date()
                    ),
                    presence: nil
                )
            }
        )

        await synchronizer.scheduleHint(
            from: fixture.healthyEndpointID
        )
        for _ in 0..<100 where await gate.count < 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        await synchronizer.scheduleHint(
            from: fixture.healthyEndpointID
        )
        await synchronizer.scheduleHint(
            from: fixture.healthyEndpointID
        )
        await synchronizer.scheduleHint(
            from: fixture.healthyEndpointID
        )
        await gate.releaseFirst()
        for _ in 0..<100 where await gate.count < 2 {
            try await Task.sleep(for: .milliseconds(1))
        }

        let count = await gate.count
        XCTAssertEqual(count, 2)
    }

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let replica: MeshLocalReplica
        let group: MeshTrustGroupID
        let slowPeerID: MeshDeviceID
        let healthyPeerID: MeshDeviceID
        let healthyEndpointID: MeshEndpointID
        let status: DistributedMeshLocalServiceStatus

        init() async throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "pharos-background-sync-\(UUID().uuidString)",
                    isDirectory: true
                )
            replica = try MeshLocalReplica.open(
                rootURL: root,
                identityStorage: MeshMemoryIdentityStorage()
            )
            group = try await replica.ensureActiveTrustGroup()
            let slow = MeshDeviceIdentity.generate()
            let healthy = MeshDeviceIdentity.generate()
            slowPeerID = slow.deviceID
            healthyPeerID = healthy.deviceID
            healthyEndpointID = try healthy.endpointID()
            try await replica.store.installVerifiedPeer(
                try Self.pairedDevice(slow, name: "Slow"),
                in: group,
                membershipEpoch: 1
            )
            try await replica.store.installVerifiedPeer(
                try Self.pairedDevice(healthy, name: "Healthy"),
                in: group,
                membershipEpoch: 1
            )
            status = DistributedMeshLocalServiceStatus(
                buildID: "test",
                deviceID: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID(),
                trustGroupID: group,
                membershipEpoch: 1,
                networkState: .starting
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func pairedDevice(
            _ identity: MeshDeviceIdentity, name: String
        ) throws -> MeshPairedDevice {
            MeshPairedDevice(
                descriptor: MeshDeviceDescriptor(
                    id: identity.deviceID,
                    endpointID: try identity.endpointID(),
                    displayName: name,
                    roles: [.replica]
                ),
                signingPublicKey:
                    try identity.signingPublicKeyBytes(),
                addressTicket: "test-\(name.lowercased())-ticket"
            )
        }
    }
}

private actor SyncHintRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

private actor SyncHintInvocationCounter {
    private(set) var value = 0

    func record() {
        value += 1
    }
}

private actor HintPeerRecorder {
    private(set) var peers: [MeshDeviceID] = []

    func record(_ peer: MeshDeviceID) {
        peers.append(peer)
    }
}

private actor HintFollowUpGate {
    private(set) var count = 0
    private var firstReleased = false

    func enter() async {
        count += 1
        guard count == 1 else { return }
        while !firstReleased {
            await Task.yield()
        }
    }

    func releaseFirst() {
        firstReleased = true
    }
}

private actor HostPreparationOrder {
    private(set) var events: [String] = []

    func recordPreparation() {
        events.append("prepare")
    }

    func recordPoke() {
        events.append("poke")
    }
}
