import Foundation
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

public struct DistributedAgentHostLocation: Equatable, Sendable {
    public var deviceID: MeshDeviceID
    public var endpointID: MeshEndpointID
    public var displayName: String
    public var resourceGeneration: UInt64
    public var allowedActions: [MeshHostAction]
    public var controlReadiness: DistributedAgentHostControlReadiness
    public var isLocal: Bool

    public init(
        deviceID: MeshDeviceID, endpointID: MeshEndpointID,
        displayName: String, resourceGeneration: UInt64,
        allowedActions: [MeshHostAction], isLocal: Bool = false
    ) {
        self.deviceID = deviceID
        self.endpointID = endpointID
        self.displayName = displayName
        self.resourceGeneration = resourceGeneration
        self.allowedActions = allowedActions
        self.isLocal = isLocal
        controlReadiness = allowedActions.contains(.stop) ? .managed : .unmanaged
    }

    public var canStop: Bool { allowedActions.contains(.stop) }
    public var canPoke: Bool { allowedActions.contains(.poke) }
}

public enum DistributedAgentHostControlReadiness: String, Equatable, Sendable {
    case managed
    case unmanaged
}

public enum DistributedHostController {
    public static func locateAgent(
        memberID: String, runtime: IrohEndpointRuntime,
        replica: MeshLocalReplica, group: MeshTrustGroupID
    ) async throws -> DistributedAgentHostLocation {
        guard let resourceID = MeshResourceID(rawValue: memberID) else {
            throw DistributedHostControllerError.invalidAgentResource
        }
        guard let epoch = try await replica.store.membershipEpoch(for: group) else {
            throw DistributedHostControllerError.noActiveTrustGroup
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        var matches: [DistributedAgentHostLocation] = []
        var incompleteHostLookup = false
        let localEndpointID = try replica.identity.endpointID()
        if let local = try await replica.store.hostResource(
            in: group, hostDeviceID: replica.identity.deviceID,
            resourceID: resourceID
        ), local.state == .active,
           local.hostEndpointID == localEndpointID {
            matches.append(DistributedAgentHostLocation(
                deviceID: replica.identity.deviceID,
                endpointID: localEndpointID,
                displayName: "This device",
                resourceGeneration: local.generation,
                allowedActions: local.allowedActions,
                isLocal: true
            ))
        }
        for peer in peers where peer.descriptor.roles.contains(.host) {
            guard peer.descriptor.id != replica.identity.deviceID else { continue }
            let client = MeshReplicaRPCClient(transport: IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            ))
            do {
                let resource = try await client.hostResource(
                    resourceID, group: group, membershipEpoch: epoch
                )
                guard resource.state == .active,
                      resource.hostDeviceID == peer.descriptor.id,
                      resource.hostEndpointID == peer.descriptor.endpointID else {
                    continue
                }
                matches.append(DistributedAgentHostLocation(
                    deviceID: peer.descriptor.id,
                    endpointID: peer.descriptor.endpointID,
                    displayName: peer.descriptor.displayName,
                    resourceGeneration: resource.generation,
                    allowedActions: resource.allowedActions
                ))
            } catch MeshReplicaRPCError.remoteFailure("resource-not-found") {
                // A reachable trusted Host authoritatively does not own it.
            } catch {
                // Without every Host answer we cannot distinguish an offline
                // owner from no owner, nor prove that a visible claim is unique.
                incompleteHostLookup = true
            }
        }
        guard matches.count <= 1 else {
            throw DistributedHostControllerError.resourceOwnershipConflict
        }
        guard !incompleteHostLookup else {
            throw DistributedHostControllerError.hostUnavailable
        }
        guard let location = matches.first else {
            throw DistributedHostControllerError.agentResourceNotFound
        }
        return location
    }

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
        var matches: [(MeshPairedDevice, MeshHostResource)] = []
        var incompleteHostLookup = false
        for peer in peers where peer.descriptor.roles.contains(.host) {
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
                } catch MeshReplicaRPCError.remoteFailure("resource-not-found") {
                    continue
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
                      resource.hostEndpointID == peer.descriptor.endpointID else {
                    continue
                }
                matches.append((peer, resource))
            } catch MeshReplicaRPCError.remoteFailure("resource-not-found") {
                // A reachable trusted Host authoritatively does not own it.
            } catch {
                incompleteHostLookup = true
            }
        }
        guard matches.count <= 1 else {
            throw DistributedHostControllerError.resourceOwnershipConflict
        }
        guard !incompleteHostLookup else {
            throw DistributedHostControllerError.hostUnavailable
        }
        guard let (peer, resource) = matches.first else {
            throw DistributedHostControllerError.agentResourceNotFound
        }
        guard resource.allowedActions.contains(.stop) else {
            throw DistributedHostControllerError.agentNotControllable
        }
        let client = MeshReplicaRPCClient(transport: IrohMeshTransport(
            runtime: runtime,
            remote: MeshIrohEndpointAddress(
                endpointID: peer.descriptor.endpointID,
                ticket: peer.addressTicket
            )
        ))
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
        do {
            let receipt = try await client.sendHostCommand(signed)
            guard receipt.receipt.state == .executed else {
                throw DistributedHostControllerError.commandFailed(
                    receipt.receipt.failureCode ?? receipt.receipt.state.rawValue
                )
            }
        } catch let error as DistributedHostControllerError {
            throw error
        } catch {
            throw DistributedHostControllerError.hostUnavailable
        }
    }
}

public enum DistributedHostControllerError: LocalizedError, Sendable {
    case invalidAgentResource
    case noActiveTrustGroup
    case agentResourceNotFound
    case agentNotControllable
    case hostUnavailable
    case resourceOwnershipConflict
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAgentResource:
            "This agent has an invalid Host resource identity."
        case .noActiveTrustGroup:
            "Pair this device with a trusted Pharos device first."
        case .agentResourceNotFound:
            "No trusted Host currently advertises this agent session."
        case .agentNotControllable:
            "This agent is running, but its Host has not verified a safe runtime binding yet."
        case .hostUnavailable:
            "The trusted Host that controls this agent is currently unavailable."
        case .resourceOwnershipConflict:
            "More than one Host claims control of this agent. Control is disabled until the conflict is reconciled."
        case .commandFailed(let reason):
            "The Host rejected the stop command: \(reason)"
        }
    }
}
