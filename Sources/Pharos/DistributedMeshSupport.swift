import Foundation
import Observation
import PharosMeshCore

/// macOS owner of the local-first replica and its identity-addressed Iroh
/// endpoint. Distributed product mode never opens legacy Broker routing.
@Observable
@MainActor
final class DistributedMeshSupport {
    enum State: Equatable {
        case opening
        case ready(deviceID: MeshDeviceID, endpointID: MeshEndpointID)
        case failed(String)
    }

    private(set) var state: State = .opening
    private(set) var localReplica: MeshLocalReplica?
    private(set) var activeTrustGroupID: MeshTrustGroupID?
    private(set) var localAddress: MeshIrohEndpointAddress?
    private(set) var connections: [MeshDeviceID: MeshConnectionSnapshot] = [:]
    private(set) var lastSyncError: String?
    @ObservationIgnored private var runtime: IrohEndpointRuntime?

    var isProductModeEnabled: Bool {
        ProcessInfo.processInfo.environment["PHAROS_DISTRIBUTED"] == "1"
    }

    func start() async {
        guard localReplica == nil else { return }
        state = .opening
        do {
            let replica = try await Task.detached {
                try MeshLocalReplica.openDefault()
            }.value
            localReplica = replica
            if isProductModeEnabled {
                activeTrustGroupID = try await replica.ensureActiveTrustGroup()
            }
            state = .ready(
                deviceID: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID()
            )
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func startNetwork() async {
        guard isProductModeEnabled, runtime == nil,
              let replica = localReplica,
              activeTrustGroupID != nil else { return }
        do {
            let endpoint = try await IrohEndpointRuntime.bind(
                secretKey: replica.identity.irohSecretKeyBytes()
            )
            let address = try await endpoint.localAddress()
            let router = MeshReplicaRPCServer(
                store: replica.store, hostIdentity: replica.identity
            )
            await endpoint.startServing { request, remoteEndpointID in
                if let pairing = try? MeshTrustPairingRPCRequest.decode(
                    request.header
                ) {
                    guard pairing.acceptance.acceptingEndpointID == remoteEndpointID else {
                        throw MeshTrustPairingError.endpointKeyMismatch
                    }
                    let paired = try await MeshTrustPairingService(
                        identity: replica.identity,
                        invitationStore: replica.store
                    ).redeem(
                        pairing.acceptance, for: pairing.invitation
                    )
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
            lastSyncError = nil
        } catch {
            lastSyncError = "Could not start distributed Mesh: \(error)"
        }
    }

    func issueInvitation() async throws -> URL {
        guard let replica = localReplica, let group = activeTrustGroupID,
              let address = localAddress,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw DistributedMeshSupportError.networkNotReady }
        let invitation = try await MeshTrustPairingService(
            identity: replica.identity, invitationStore: replica.store
        ).issueInvitation(
            trustGroupID: group, membershipEpoch: epoch,
            inviterAddressTicket: address.ticket,
            requestedRoles: [.controller, .replica]
        )
        return try MeshTrustInvitationLink.encode(invitation)
    }

    /// One bounded pull from every trusted current-epoch peer. Every device
    /// runs the same loop, so synchronization stays decentralized and offline
    /// writers converge after either side reconnects.
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
}

private enum DistributedMeshSupportError: Error {
    case networkNotReady
}
