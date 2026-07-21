import Foundation
import Observation
import PharosMeshControl
import PharosMeshCore

/// Product builds use the signed, device-to-device replica by default. The
/// legacy Broker path is retained only as an explicit migration diagnostic;
/// normal launches never need an environment flag to enable the new mesh.
enum PharosMeshRuntimeMode {
    static var usesDistributedMesh: Bool {
        ProcessInfo.processInfo.environment["PHAROS_LEGACY_BROKER"] != "1"
    }
}

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
    private(set) var trustedDevices: [MeshPairedDevice] = []
    private(set) var lastSyncError: String?
    @ObservationIgnored private var runtime: IrohEndpointRuntime?
    @ObservationIgnored private var chatRegistry: DistributedChatRegistry?
    @ObservationIgnored private var attachmentRegistry: DistributedAttachmentRegistry?

    var isProductModeEnabled: Bool {
        PharosMeshRuntimeMode.usesDistributedMesh
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
                if let group = activeTrustGroupID {
                    chatRegistry = DistributedChatRegistry(
                        replica: replica, group: group
                    )
                    attachmentRegistry = DistributedAttachmentRegistry(
                        replica: replica, group: group
                    )
                    try await refreshTrustedDevices()
                }
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
                secretKey: replica.identity.irohSecretKeyBytes(),
                expectedEndpointID: try replica.identity.endpointID()
            )
            let address = try await endpoint.localAddress()
            let executor = DistributedHostCommandExecutor(
                bindings: DistributedHostResourceBindings(
                    dataDirectory: replica.rootURL
                )
            )
            let router = MeshReplicaRPCServer(
                store: replica.store, hostIdentity: replica.identity,
                hostCommandHandler: { command in
                    let outcome = await executor.execute(command)
                    if command.action == .stop,
                       case .executed = outcome {
                        _ = try? await replica.store.retireHostResource(
                            in: command.trustGroupID,
                            on: replica.identity,
                            resourceID: command.resourceID,
                            at: MeshHybridTimestamp(
                                wallTimeMilliseconds: Int64(
                                    Date().timeIntervalSince1970 * 1_000
                                )
                            )
                        )
                        try? executor.bindings.remove(command.resourceID)
                    }
                    return outcome
                }
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
            Task { [weak self] in
                await endpoint.waitUntilOnline()
                guard let refreshed = try? await endpoint.localAddress() else { return }
                self?.localAddress = refreshed
            }
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

    /// Refreshes the user-visible device roster from the current membership
    /// epoch. Old-epoch rows stay in the database for audit, but never appear
    /// as currently trusted devices.
    func refreshTrustedDevices() async throws {
        guard let replica = localReplica, let group = activeTrustGroupID,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else {
            trustedDevices = []
            return
        }
        trustedDevices = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
    }

    func chatRooms() async throws -> [MeshRoomInfo] {
        try await requireChatRegistry().rooms()
    }

    func chatMembers(in room: MeshRoomInfo) async throws -> [DistributedChatMember] {
        try await requireChatRegistry().members(in: room)
    }

    func chatMessages(in room: MeshRoomInfo, limit: Int? = nil) async throws -> [MeshMsg] {
        try await requireChatRegistry().messages(in: room, limit: limit)
    }

    func createChatRoom(named name: String) async throws -> MeshRoomInfo {
        try await requireChatRegistry().createRoom(named: name)
    }

    func renameChatRoom(_ room: MeshRoomInfo, to name: String) async throws {
        try await requireChatRegistry().renameRoom(room, to: name)
    }

    func deleteChatRoom(_ room: MeshRoomInfo) async throws {
        try await requireChatRegistry().deleteRoom(room)
    }

    func sendChatMessage(
        _ text: String, in room: MeshRoomInfo, to: [String],
        replyTo: MeshReply? = nil, attachments: [MeshAttachment] = []
    ) async throws -> MeshMsg {
        try await requireChatRegistry().send(
            room: room, from: "human", text: text, to: to,
            replyTo: replyTo, attachments: attachments
        )
    }

    func renameChatMember(
        _ memberID: String, in room: MeshRoomInfo, to nick: String
    ) async throws {
        try await requireChatRegistry().renameMember(
            room: room, memberID: memberID, to: nick
        )
    }

    func stopAgent(memberID: String) async throws {
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID else {
            throw DistributedMeshSupportError.networkNotReady
        }
        try await DistributedHostController.stopAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
    }

    func removeChatMember(_ memberID: String, from room: MeshRoomInfo) async throws {
        try await requireChatRegistry().leave(room: room, memberID: memberID)
    }

    func removeChatMemberFromAllRooms(_ memberID: String) async throws {
        let registry = try requireChatRegistry()
        for room in try await registry.rooms() {
            if try await registry.members(in: room).contains(where: { $0.id == memberID }) {
                try await registry.leave(room: room, memberID: memberID)
            }
        }
    }

    func uploadChatAttachment(
        data: Data, name: String, mediaType: String
    ) async throws -> MeshAttachment {
        try await requireAttachmentRegistry().put(
            data: data, name: name, mediaType: mediaType
        )
    }

    func chatAttachmentData(_ attachment: MeshAttachment) async throws -> Data {
        let registry = try requireAttachmentRegistry()
        guard try await registry.metadata(id: attachment.id) != nil else {
            throw DistributedMeshSupportError.attachmentNotFound
        }
        if let data = try await registry.localData(for: attachment) { return data }
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw DistributedMeshSupportError.networkNotReady }
        let digest = try DistributedAttachmentRegistry.digest(for: attachment)
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
                return try await MeshBlobFetchSession(
                    store: replica.store,
                    client: MeshReplicaRPCClient(transport: transport)
                ).fetch(digest, group: group, membershipEpoch: epoch)
            } catch { continue }
        }
        throw DistributedMeshSupportError.attachmentUnavailable
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
            trustedDevices = peers
            var received = 0
            var failedPeers: [String] = []
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
                        client: MeshReplicaRPCClient(transport: transport),
                        remoteEndpointID: peer.descriptor.endpointID
                    ).synchronize(group: group, membershipEpoch: epoch)
                    received += report.eventCount + report.snapshotCount
                    connections[peer.descriptor.id] = MeshConnectionSnapshot(
                        peer: peer.descriptor.id, path: await transport.path,
                        connected: true, lastChange: Date()
                    )
                } catch {
                    failedPeers.append(peer.descriptor.displayName)
                    connections[peer.descriptor.id] = MeshConnectionSnapshot(
                        peer: peer.descriptor.id, path: .unavailable,
                        connected: false, lastChange: Date()
                    )
                }
            }
            lastSyncError = MeshSyncFailurePresentation.message(
                peerNames: failedPeers
            )
            return received
        } catch {
            lastSyncError = "Could not read trusted devices: \(error)"
            return 0
        }
    }

    private func requireChatRegistry() throws -> DistributedChatRegistry {
        guard let chatRegistry else {
            throw DistributedMeshSupportError.noActiveTrustGroup
        }
        return chatRegistry
    }

    private func requireAttachmentRegistry() throws -> DistributedAttachmentRegistry {
        guard let attachmentRegistry else {
            throw DistributedMeshSupportError.noActiveTrustGroup
        }
        return attachmentRegistry
    }
}

private enum DistributedMeshSupportError: LocalizedError {
    case networkNotReady
    case noActiveTrustGroup
    case attachmentNotFound
    case attachmentUnavailable

    var errorDescription: String? {
        switch self {
        case .networkNotReady: "The private Mesh endpoint is still starting."
        case .noActiveTrustGroup: "Pair this device with a trusted Pharos device first."
        case .attachmentNotFound: "Attachment metadata is missing from this replica."
        case .attachmentUnavailable: "No trusted online device currently has this attachment."
        }
    }
}
