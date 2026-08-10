import Foundation
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

/// Connects an RPC router that may receive a hint during startup to the
/// bounded synchronizer created after the router begins serving. A pre-install
/// hint is retained per authenticated origin; hints never carry state and
/// merely prioritize the receiver's normal authenticated anti-entropy pull
/// from that exact Endpoint.
public actor DistributedMeshSyncHintRelay {
    private var pending: Set<MeshEndpointID> = []
    private var pendingFullSync = false
    private var handler:
        (@Sendable (MeshEndpointID?) async -> Void)?

    public init() {}

    public func receive(from endpointID: MeshEndpointID) async {
        guard let handler else {
            pending.insert(endpointID)
            return
        }
        await handler(endpointID)
    }

    public func receiveFullSync() async {
        guard let handler else {
            pendingFullSync = true
            return
        }
        await handler(nil)
    }

    public func install(
        _ handler:
            @escaping @Sendable (MeshEndpointID?) async -> Void
    ) async {
        self.handler = handler
        let endpoints = pending.sorted()
        pending.removeAll()
        if pendingFullSync {
            pendingFullSync = false
            await handler(nil)
        }
        for endpointID in endpoints {
            await handler(endpointID)
        }
    }
}

/// Continuously schedules bounded anti-entropy without letting one unreachable
/// peer delay healthy peer state or create an unbounded task backlog.
public actor DistributedMeshBackgroundSynchronizer {
    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let hostMode: Bool
    private let control: DistributedMeshLocalServiceControl
    private let wakeCoordinator: DistributedAgentWakeCoordinator
    private let hostPreparation: @Sendable (
        MeshLocalReplica, MeshTrustGroupID
    ) async throws -> Void
    private let peerRunner: @Sendable (
        MeshPairedDevice, UInt64, MeshMembershipTransition?, Bool
    ) async -> BackgroundPeerResult
    private var tasksInFlight = 0
    private var peersInFlight: Set<MeshDeviceID> = []
    private var connections: [MeshDeviceID: MeshConnectionSnapshot] = [:]
    private var presence: [MeshDeviceID: MeshAgentPresenceSnapshot] = [:]
    private var lastHintedVector: MeshSyncVector?
    private var pendingHintEndpoints: Set<MeshEndpointID> = []
    private var hintDrainInFlight = false

    public init(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        group: MeshTrustGroupID, hostMode: Bool,
        control: DistributedMeshLocalServiceControl,
        wakeCoordinator: DistributedAgentWakeCoordinator =
            DistributedAgentWakeCoordinator()
    ) {
        self.replica = replica
        self.group = group
        self.hostMode = hostMode
        self.control = control
        self.wakeCoordinator = wakeCoordinator
        hostPreparation = { replica, group in
            _ = try await DistributedHookCLI.hostPresenceSnapshot(
                replica: replica, group: group
            )
        }
        peerRunner = { peer, epoch, pendingTransition, shouldSendHint in
            let transport = IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            )
            if let pendingTransition,
               pendingTransition.nextEpoch == epoch {
                try? await MeshReplicaRPCClient(
                    transport: transport,
                    requestTimeoutMilliseconds:
                        MeshReplicaRPCClient
                        .backgroundRequestTimeoutMilliseconds
                ).applyMembershipTransition(pendingTransition)
            }
            let client = MeshReplicaRPCClient(
                transport: transport,
                requestTimeoutMilliseconds:
                    MeshReplicaRPCClient
                    .backgroundRequestTimeoutMilliseconds
            )
            if shouldSendHint {
                try? await client.sendSyncHint(
                    group: group, membershipEpoch: epoch
                )
            }
            let outcome = await MeshPeerSyncPresenceCoordinator.run(
                synchronize: {
                    let report = try await MeshReplicaSyncSession(
                        store: replica.store, client: client,
                        remoteEndpointID:
                            peer.descriptor.endpointID
                    ).synchronize(
                        group: group,
                        membershipEpoch: epoch
                    )
                    return report.eventCount + report.snapshotCount
                },
                fetchPresence: {
                    try await MeshVerifiedHostPresence.fetch(
                        client: client, peer: peer,
                        group: group,
                        membershipEpoch: epoch
                    )
                }
            )
            return BackgroundPeerResult(
                deviceID: peer.descriptor.id,
                snapshot: MeshConnectionSnapshot(
                    peer: peer.descriptor.id,
                    path: outcome.isReachable
                        ? await transport.path : .unavailable,
                    connected: outcome.isReachable,
                    lastChange: Date()
                ),
                presence: outcome.presence
            )
        }
    }

    init(
        replica: MeshLocalReplica, group: MeshTrustGroupID,
        hostMode: Bool, control: DistributedMeshLocalServiceControl,
        wakeCoordinator: DistributedAgentWakeCoordinator,
        hostPreparation: @escaping @Sendable (
            MeshLocalReplica, MeshTrustGroupID
        ) async throws -> Void = { _, _ in },
        peerRunner: @escaping @Sendable (
            MeshPairedDevice, UInt64, MeshMembershipTransition?, Bool
        ) async -> BackgroundPeerResult
    ) {
        self.replica = replica
        self.group = group
        self.hostMode = hostMode
        self.control = control
        self.wakeCoordinator = wakeCoordinator
        self.hostPreparation = hostPreparation
        self.peerRunner = peerRunner
    }

    /// Starts at most two overlapping rounds. Each peer participates in only
    /// one round at a time, so a cold relay timeout cannot build a task pile.
    public func schedule() {
        guard tasksInFlight < 2 else { return }
        tasksInFlight += 1
        Task {
            await runOnce()
            roundFinished()
        }
    }

    /// Prioritizes the authenticated peer that emitted a content-free hint.
    /// This path is independent of the two periodic rounds, so offline peers
    /// cannot consume the global cadence and discard a live invalidation.
    /// The per-peer gate still guarantees at most one RPC session per peer.
    public func scheduleHint(from endpointID: MeshEndpointID) {
        pendingHintEndpoints.insert(endpointID)
        startHintDrainIfPossible()
    }

    public func runOnce() async {
        guard (try? replica.activeTrustGroup()) == group,
              let epoch = try? await replica.store.membershipEpoch(for: group)
        else { return }
        if hostMode {
            do {
                try await hostPreparation(replica, group)
            } catch {
                control.update {
                    $0.lastError = "local-host-reconcile-failed"
                }
            }
            await wakeCoordinator.wakeEligibleAgents(
                replica: replica, group: group
            )
        }
        guard let peers = try? await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        ) else {
            control.update {
                $0.lastError = "trusted-device-read-failed"
            }
            return
        }
        let localVector = try? await replica.store.syncVector(for: group)
        let pendingEventCount = try? await replica.store.pendingEventCount(
            for: group, peers: peers.map(\.descriptor.id)
        )
        control.update {
            $0.pendingLocalEventCount = pendingEventCount
        }
        let shouldSendHint = localVector.map {
            $0 != lastHintedVector
        } ?? false
        if shouldSendHint {
            lastHintedVector = localVector
        }
        let pendingTransition = try? await replica.store
            .latestMembershipTransition(for: group)
        await withTaskGroup(
            of: BackgroundPeerResult?.self
        ) { tasks in
            for peer in peers {
                guard acquire(peer.descriptor.id) else { continue }
                tasks.addTask {
                    await self.peerRunner(
                        peer, epoch, pendingTransition, shouldSendHint
                    )
                }
            }
            for await result in tasks {
                guard let result else { continue }
                release(result.deviceID)
                connections[result.deviceID] = result.snapshot
                if let snapshot = result.presence {
                    let now = Int64(Date().timeIntervalSince1970 * 1_000)
                    if snapshot.isFresh(at: now) {
                        let prior = presence[result.deviceID]
                        if prior == nil ||
                            snapshot.generatedAtMilliseconds >=
                                prior!.generatedAtMilliseconds {
                            presence[result.deviceID] = snapshot
                        }
                    }
                }
                publish(epoch: epoch, successfulPeer: result.snapshot.connected)
            }
        }
        if peers.isEmpty {
            publish(epoch: epoch, successfulPeer: true)
        }
        if hostMode {
            await wakeCoordinator.wakeEligibleAgents(
                replica: replica, group: group
            )
        }
    }

    private func acquire(_ peer: MeshDeviceID) -> Bool {
        peersInFlight.insert(peer).inserted
    }

    private func release(_ peer: MeshDeviceID) {
        peersInFlight.remove(peer)
        startHintDrainIfPossible()
    }

    private func startHintDrainIfPossible() {
        guard !hintDrainInFlight, !pendingHintEndpoints.isEmpty else {
            return
        }
        hintDrainInFlight = true
        Task {
            await drainHintQueue()
        }
    }

    private func drainHintQueue() async {
        guard (try? replica.activeTrustGroup()) == group,
              let epoch = try? await replica.store.membershipEpoch(for: group),
              let peers = try? await replica.store.trustedDevices(
                  in: group, membershipEpoch: epoch
              )
        else {
            pendingHintEndpoints.removeAll()
            hintDrainInFlight = false
            return
        }
        let byEndpoint = Dictionary(
            uniqueKeysWithValues: peers.map {
                ($0.descriptor.endpointID, $0)
            }
        )
        let pendingTransition = try? await replica.store
            .latestMembershipTransition(for: group)
        for endpointID in pendingHintEndpoints.sorted() {
            guard let peer = byEndpoint[endpointID] else {
                pendingHintEndpoints.remove(endpointID)
                continue
            }
            guard acquire(peer.descriptor.id) else {
                // The current session will already observe the new vector, or
                // its release will restart this retained one-item hint.
                continue
            }
            pendingHintEndpoints.remove(endpointID)
            let result = await peerRunner(
                peer, epoch, pendingTransition, false
            )
            release(result.deviceID)
            connections[result.deviceID] = result.snapshot
            if let snapshot = result.presence {
                let now = Int64(Date().timeIntervalSince1970 * 1_000)
                if snapshot.isFresh(at: now) {
                    let prior = presence[result.deviceID]
                    if prior == nil ||
                        snapshot.generatedAtMilliseconds >=
                            prior!.generatedAtMilliseconds {
                        presence[result.deviceID] = snapshot
                    }
                }
            }
            publish(
                epoch: epoch,
                successfulPeer: result.snapshot.connected
            )
        }
        hintDrainInFlight = false
        let hasReadyHint = pendingHintEndpoints.contains {
            guard let peer = byEndpoint[$0] else { return false }
            return !peersInFlight.contains(peer.descriptor.id)
        }
        if hasReadyHint {
            startHintDrainIfPossible()
        }
        if hostMode {
            await wakeCoordinator.wakeEligibleAgents(
                replica: replica, group: group
            )
        }
    }

    private func roundFinished() {
        tasksInFlight = max(0, tasksInFlight - 1)
    }

    private func publish(epoch: UInt64, successfulPeer: Bool) {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        presence = presence.filter { $0.value.isFresh(at: now) }
        let connectionValues = connections.values.sorted {
            $0.peer < $1.peer
        }
        let presenceValues = presence.values.sorted {
            $0.hostDeviceID < $1.hostDeviceID
        }
        control.update {
            $0.membershipEpoch = epoch
            $0.connections = connectionValues
            $0.presence = presenceValues
            $0.networkState = .online
            if successfulPeer {
                $0.lastSuccessfulSyncMilliseconds = now
                $0.lastError = nil
            } else if !connectionValues.contains(where: \.connected) {
                $0.lastError = "all-peers-unreachable"
            }
        }
    }
}

struct BackgroundPeerResult: Sendable {
    let deviceID: MeshDeviceID
    let snapshot: MeshConnectionSnapshot
    let presence: MeshAgentPresenceSnapshot?
}
