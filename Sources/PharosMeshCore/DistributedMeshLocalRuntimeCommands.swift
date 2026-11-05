import Foundation
import PharosMeshControl
import PharosMeshIroh
import PharosMeshLifecycle
import PharosMeshProtocol
import PharosMeshReplica

/// Executes bounded network-required operations inside the sole process that
/// owns the local device's Iroh endpoint.
public struct DistributedMeshLocalRuntimeCommands: Sendable {
    public let replica: MeshLocalReplica
    public let runtime: IrohEndpointRuntime
    public let localAddress: MeshIrohEndpointAddress
    public let group: MeshTrustGroupID

    public init(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        localAddress: MeshIrohEndpointAddress, group: MeshTrustGroupID
    ) {
        self.replica = replica
        self.runtime = runtime
        self.localAddress = localAddress
        self.group = group
    }

    public func response(
        to request: DistributedMeshLocalServiceRequest
    ) async -> DistributedMeshLocalServiceResponse {
        do {
            switch request.operation {
            case .locateAgent:
                let memberID = try decodeMemberID(request.payload)
                let location = try await DistributedHostController.locateAgent(
                    memberID: memberID, runtime: runtime,
                    replica: replica, group: group
                )
                return .init(
                    requestID: request.requestID,
                    payload: try JSONEncoder().encode(location)
                )
            case .stopAgent:
                let memberID = try decodeMemberID(request.payload)
                try await stopAgent(memberID: memberID)
                return .init(requestID: request.requestID)
            case .issueInvitation:
                let value = try decode(
                    DistributedMeshInvitationRequest.self,
                    from: request.payload
                )
                guard let epoch = try await replica.store.membershipEpoch(
                    for: group
                ) else {
                    throw DistributedMeshLocalRuntimeCommandError
                        .missingMembership
                }
                guard try replica.activeRoles().contains(.controller) else {
                    throw DistributedMeshLocalRuntimeCommandError
                        .administratorRequired
                }
                let invitation = try await MeshTrustPairingService(
                    identity: replica.identity,
                    invitationStore: replica.store
                ).issueInvitation(
                    trustGroupID: group, membershipEpoch: epoch,
                    inviterAddressTicket: localAddress.ticket,
                    inviterRoles: try replica.activeRoles(),
                    requestedRoles: value.requestedRoles
                )
                let link = try MeshTrustInvitationLink.encode(invitation)
                return .init(
                    requestID: request.requestID,
                    payload: try JSONEncoder().encode(link.absoluteString)
                )
            case .revokeDevice:
                let value = try decode(
                    DistributedMeshRevokeDeviceRequest.self,
                    from: request.payload
                )
                let epoch = try await revokeDevice(value)
                return .init(
                    requestID: request.requestID,
                    payload: try JSONEncoder().encode(epoch)
                )
            case .fetchAttachment:
                let attachment = try decode(
                    MeshAttachment.self, from: request.payload
                )
                try await fetchAttachment(attachment)
                return .init(requestID: request.requestID)
            case .health, .status, .syncNow:
                return .init(
                    requestID: request.requestID, accepted: false,
                    error: "operation-owned-by-service-control"
                )
            }
        } catch {
            return .init(
                requestID: request.requestID, accepted: false,
                error: error.localizedDescription
            )
        }
    }

    private func decodeMemberID(_ payload: Data?) throws -> String {
        guard let payload,
              let value = try? JSONDecoder().decode(String.self, from: payload),
              !value.isEmpty, value.utf8.count <= 512
        else {
            throw DistributedMeshLocalRuntimeCommandError.invalidPayload
        }
        return value
    }

    private func decode<T: Decodable>(
        _ type: T.Type, from payload: Data?
    ) throws -> T {
        guard let payload,
              let value = try? JSONDecoder().decode(type, from: payload)
        else {
            throw DistributedMeshLocalRuntimeCommandError.invalidPayload
        }
        return value
    }

    private func revokeDevice(
        _ request: DistributedMeshRevokeDeviceRequest
    ) async throws -> UInt64 {
        guard try replica.activeRoles().contains(.controller) else {
            throw DistributedMeshLocalRuntimeCommandError
                .administratorRequired
        }
        guard let epoch = try await replica.store.membershipEpoch(
            for: group
        ) else {
            throw DistributedMeshLocalRuntimeCommandError.missingMembership
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        guard peers.contains(where: {
            $0.descriptor.id == request.deviceID
        }) else {
            throw DistributedMeshLocalRuntimeCommandError.deviceNotFound
        }
        let localMember = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID(),
                displayName: request.localDisplayName,
                roles: try replica.activeRoles()
            ),
            signingPublicKey: try replica.identity.signingPublicKeyBytes(),
            addressTicket: localAddress.ticket
        )
        let survivors = peers.filter {
            $0.descriptor.id != request.deviceID
        }
        let transition = try await MeshTrustGroupLifecycle
            .certifyMembershipTransition(
                replica: replica, runtime: runtime, group: group,
                previousEpoch: epoch, roster: survivors + [localMember]
            )
        for peer in survivors {
            let transport = IrohMeshTransport(
                runtime: runtime,
                remote: MeshIrohEndpointAddress(
                    endpointID: peer.descriptor.endpointID,
                    ticket: peer.addressTicket
                )
            )
            try? await MeshReplicaRPCClient(transport: transport)
                .applyMembershipTransition(transition)
        }
        try await replica.store.applyMembershipTransition(
            transition, localIdentity: replica.identity,
            localAuthorRoles: try replica.activeRoles()
        )
        return transition.nextEpoch
    }

    private func fetchAttachment(
        _ attachment: MeshAttachment
    ) async throws {
        let registry = DistributedAttachmentRegistry(
            replica: replica, group: group
        )
        guard try await registry.metadata(id: attachment.id) != nil else {
            throw DistributedMeshLocalRuntimeCommandError
                .attachmentNotFound
        }
        if try await registry.localData(for: attachment) != nil {
            return
        }
        guard let epoch = try await replica.store.membershipEpoch(
            for: group
        ) else {
            throw DistributedMeshLocalRuntimeCommandError.missingMembership
        }
        let digest = try DistributedAttachmentRegistry.digest(
            for: attachment
        )
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        for peer in peers {
            do {
                let transport = IrohMeshTransport(
                    runtime: runtime,
                    remote: MeshIrohEndpointAddress(
                        endpointID: peer.descriptor.endpointID,
                        ticket: peer.addressTicket
                    )
                )
                _ = try await MeshBlobFetchSession(
                    store: replica.store,
                    client: MeshReplicaRPCClient(transport: transport)
                ).fetch(
                    digest, group: group, membershipEpoch: epoch
                )
                return
            } catch {
                continue
            }
        }
        throw DistributedMeshLocalRuntimeCommandError
            .attachmentUnavailable
    }

    private func stopAgent(memberID: String) async throws {
        let location = try await DistributedHostController.locateAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
        if !location.isLocal {
            try await DistributedHostController.stopAgent(
                memberID: memberID, runtime: runtime,
                replica: replica, group: group
            )
            return
        }
        guard location.canStop,
              let resourceID = MeshResourceID(rawValue: memberID) else {
            throw DistributedHostControllerError.agentNotControllable
        }
        let now = MeshHybridTimestamp(
            wallTimeMilliseconds:
                Int64(Date().timeIntervalSince1970 * 1_000)
        )
        let bindings = DistributedHostResourceBindings(
            dataDirectory: replica.rootURL
        )
        let command = MeshHostCommand(
            trustGroupID: group,
            senderDeviceID: replica.identity.deviceID,
            targetHostDeviceID: location.deviceID,
            targetHostEndpointID: location.endpointID,
            resourceID: resourceID,
            expectedResourceGeneration: location.resourceGeneration,
            action: .stop,
            idempotencyKey: "local-service-stop-\(UUID().uuidString)",
            createdAt: now,
            deadlineMilliseconds: now.wallTimeMilliseconds + 30_000
        )
        switch await DistributedHostCommandExecutor(
            bindings: bindings
        ).execute(command) {
        case .executed:
            try await DistributedAgentTerminationFinalizer.finalize(
                resourceID: resourceID, replica: replica,
                group: group, bindings: bindings
            )
        case .failed(let code):
            throw DistributedHostControllerError.commandFailed(code)
        }
    }
}

public enum DistributedMeshLocalRuntimeCommandError:
    LocalizedError, Equatable, Sendable
{
    case invalidPayload
    case missingMembership
    case administratorRequired
    case deviceNotFound
    case attachmentNotFound
    case attachmentUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "The local Mesh service command payload is invalid."
        case .missingMembership:
            "This device does not have an active Mesh membership epoch."
        case .administratorRequired:
            "This operation requires a Mesh Admin device."
        case .deviceNotFound:
            "The selected trusted device no longer exists."
        case .attachmentNotFound:
            "The attachment metadata no longer exists."
        case .attachmentUnavailable:
            "No trusted online device currently has this attachment."
        }
    }
}
