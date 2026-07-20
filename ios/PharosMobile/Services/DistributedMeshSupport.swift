import Observation
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

/// The iOS target imports the same transport contracts as macOS and the Mesh
/// CLI and opens the exact same replica schema in its sandbox. Demo mode never
/// opens storage or networking; the real app binds only identity-addressed Iroh
/// and never dials a legacy Broker.
@Observable
@MainActor
final class DistributedMeshSupport {
    enum State: Equatable {
        case disabled
        case opening
        case ready(deviceID: MeshDeviceID, endpointID: MeshEndpointID)
        case failed(String)
    }

    static let protocolVersion = DistributedMeshProtocol.version
    static let alpn = DistributedMeshProtocol.alpn

    private(set) var state: State
    private(set) var localReplica: MeshLocalReplica?
    private(set) var activeTrustGroupID: MeshTrustGroupID?
    private(set) var localAddress: MeshIrohEndpointAddress?
    private(set) var connections: [MeshDeviceID: MeshConnectionSnapshot] = [:]
    private(set) var lastSyncError: String?
    @ObservationIgnored private var runtime: IrohEndpointRuntime?
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        state = demo ? .disabled : .opening
    }

    func start() async {
        guard !isDemo, localReplica == nil else { return }
        state = .opening
        do {
            let replica = try await Task.detached {
                try MeshLocalReplica.openDefault()
            }.value
            localReplica = replica
            activeTrustGroupID = try replica.activeTrustGroup()
            try await startNetwork(replica: replica)
            state = .ready(
                deviceID: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID()
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func accept(
        _ invitation: MeshTrustInvitation, displayName: String
    ) async throws {
        guard let replica = localReplica, let runtime,
              let localAddress else {
            throw MobileDistributedMeshError.networkNotReady
        }
        let service = MeshTrustPairingService(
            identity: replica.identity, invitationStore: replica.store
        )
        let acceptance = try await service.acceptAndTrustInviter(
            invitation,
            acceptingAddressTicket: localAddress.ticket,
            displayName: displayName,
            inviterDisplayName: "Pharos Mac"
        )
        try replica.adoptActiveTrustGroup(invitation.trustGroupID)
        activeTrustGroupID = invitation.trustGroupID
        let transport = IrohMeshTransport(
            runtime: runtime,
            remote: MeshIrohEndpointAddress(
                endpointID: invitation.inviterEndpointID,
                ticket: invitation.inviterAddressTicket
            )
        )
        let request = MeshTrustPairingRPCRequest(
            invitation: invitation, acceptance: acceptance
        )
        let response = try await transport.exchange(
            MeshTransportRequest(
                header: try request.encoded(), timeoutMilliseconds: 15_000
            )
        )
        let confirmation = try MeshTrustPairingRPCResponse.decode(response.header)
        guard confirmation.acceptedDeviceID == replica.identity.deviceID else {
            throw MobileDistributedMeshError.acceptanceMismatch
        }
        _ = await synchronizeOnce()
    }

    @discardableResult
    func synchronizeOnce() async -> Int {
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID,
              let epoch = try? await replica.store.membershipEpoch(for: group)
        else { return 0 }
        do {
            let peers = try await replica.store.trustedDevices(
                in: group, membershipEpoch: epoch
            )
            var received = 0
            var failures: [String] = []
            for peer in peers {
                let transport = IrohMeshTransport(
                    runtime: runtime,
                    remote: MeshIrohEndpointAddress(
                        endpointID: peer.descriptor.endpointID,
                        ticket: peer.addressTicket
                    )
                )
                do {
                    let report = try await MeshReplicaSyncSession(
                        store: replica.store,
                        client: MeshReplicaRPCClient(transport: transport)
                    ).synchronize(group: group, membershipEpoch: epoch)
                    received += report.eventCount + report.snapshotCount
                    connections[peer.descriptor.id] = MeshConnectionSnapshot(
                        peer: peer.descriptor.id, path: await transport.path,
                        connected: true, lastChange: Date()
                    )
                } catch {
                    failures.append("\(peer.descriptor.displayName): \(error)")
                    connections[peer.descriptor.id] = MeshConnectionSnapshot(
                        peer: peer.descriptor.id, path: .unavailable,
                        connected: false, lastChange: Date()
                    )
                }
            }
            lastSyncError = failures.isEmpty ? nil : failures.joined(separator: " · ")
            return received
        } catch {
            lastSyncError = "Could not read trusted devices: \(error)"
            return 0
        }
    }

    private func startNetwork(replica: MeshLocalReplica) async throws {
        guard runtime == nil else { return }
        let endpoint = try await IrohEndpointRuntime.bind(
            secretKey: replica.identity.irohSecretKeyBytes()
        )
        let address = try await endpoint.localAddress()
        let router = MeshReplicaRPCServer(store: replica.store)
        await endpoint.startServing { request, remoteEndpointID in
            if let pairing = try? MeshTrustPairingRPCRequest.decode(request.header) {
                guard pairing.acceptance.acceptingEndpointID == remoteEndpointID else {
                    throw MeshTrustPairingError.endpointKeyMismatch
                }
                let paired = try await MeshTrustPairingService(
                    identity: replica.identity, invitationStore: replica.store
                ).redeem(pairing.acceptance, for: pairing.invitation)
                return MeshTransportResponse(
                    header: try MeshTrustPairingRPCResponse(
                        acceptedDeviceID: paired.descriptor.id
                    ).encoded()
                )
            }
            return try await router.handle(
                request, remoteEndpointID: remoteEndpointID
            )
        }
        runtime = endpoint
        localAddress = address
    }
}

private enum MobileDistributedMeshError: Error {
    case networkNotReady
    case acceptanceMismatch
}
