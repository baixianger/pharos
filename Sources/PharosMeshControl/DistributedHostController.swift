import Foundation
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

public enum DistributedHostController {
    public static func stopAgent(
        memberID: String, runtime: IrohEndpointRuntime,
        replica: MeshLocalReplica, group: MeshTrustGroupID
    ) async throws {
        guard let resourceID = MeshResourceID(rawValue: memberID) else {
            throw DistributedHostControllerError.invalidAgentResource
        }
        guard let epoch = try await replica.store.membershipEpoch(for: group) else {
            throw DistributedHostControllerError.noActiveTrustGroup
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        var foundResource = false
        for peer in peers {
            let transport = IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            )
            let client = MeshReplicaRPCClient(transport: transport)
            do {
                let resource: MeshHostResource
                do {
                    resource = try await client.hostResource(
                        resourceID, group: group, membershipEpoch: epoch
                    )
                } catch {
                    // A Host may have restarted since its last replicated
                    // address ticket. One bounded sync refreshes both peers'
                    // current tickets and retries the resource lookup; users
                    // must never need to run `distributed sync` manually
                    // before a lifecycle command.
                    _ = try await MeshReplicaSyncSession(
                        store: replica.store, client: client,
                        remoteEndpointID: peer.descriptor.endpointID
                    ).synchronize(group: group, membershipEpoch: epoch)
                    resource = try await client.hostResource(
                        resourceID, group: group, membershipEpoch: epoch
                    )
                }
                guard resource.hostDeviceID == peer.descriptor.id,
                      resource.hostEndpointID == peer.descriptor.endpointID,
                      resource.allowedActions.contains(.stop) else { continue }
                foundResource = true
                let now = MeshHybridTimestamp(
                    wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                let command = MeshHostCommand(
                    trustGroupID: group,
                    senderDeviceID: replica.identity.deviceID,
                    targetHostDeviceID: resource.hostDeviceID,
                    targetHostEndpointID: resource.hostEndpointID,
                    resourceID: resource.resourceID,
                    expectedResourceGeneration: resource.generation,
                    action: .stop,
                    idempotencyKey: "stop-\(UUID().uuidString)",
                    createdAt: now,
                    deadlineMilliseconds: now.wallTimeMilliseconds + 30_000
                )
                let signed = try MeshHostCommandCrypto.sign(
                    command, membershipEpoch: epoch, with: replica.identity
                )
                let receipt = try await client.sendHostCommand(signed)
                guard receipt.receipt.state == .executed else {
                    throw DistributedHostControllerError.commandFailed(
                        receipt.receipt.failureCode ?? receipt.receipt.state.rawValue
                    )
                }
                return
            } catch let error as DistributedHostControllerError {
                throw error
            } catch {
                continue
            }
        }
        throw foundResource
            ? DistributedHostControllerError.commandFailed("Host unavailable")
            : DistributedHostControllerError.agentResourceNotFound
    }
}

public enum DistributedHostControllerError: LocalizedError, Sendable {
    case invalidAgentResource
    case noActiveTrustGroup
    case agentResourceNotFound
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAgentResource:
            "This agent has an invalid Host resource identity."
        case .noActiveTrustGroup:
            "Pair this device with a trusted Pharos device first."
        case .agentResourceNotFound:
            "No trusted Host currently advertises this agent session."
        case .commandFailed(let reason):
            "The Host rejected the stop command: \(reason)"
        }
    }
}
