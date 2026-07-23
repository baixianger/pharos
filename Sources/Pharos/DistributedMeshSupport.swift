import Foundation
import Observation
import PharosMeshControl
import PharosMeshCore
import PharosMeshLifecycle

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
    private(set) var membershipAudit: [MeshMembershipAuditEntry] = []
    private(set) var lastSyncError: String?
    private(set) var presenceDiagnostics: [MeshDeviceID: String] = [:]
    /// Ephemeral presence is deliberately not part of the durable registry,
    /// so views use this generation to refresh visible agent rows immediately.
    private(set) var presenceRevision: UInt64 = 0

    var isLocalMeshAdmin: Bool {
        guard let localReplica else { return false }
        return (try? localReplica.activeRoles().contains(.controller)) == true
    }

    var meshAdminCount: Int {
        trustedDevices.filter { $0.descriptor.roles.contains(.controller) }.count +
            (isLocalMeshAdmin ? 1 : 0)
    }
    @ObservationIgnored private var runtime: IrohEndpointRuntime?
    @ObservationIgnored private var chatRegistry: DistributedChatRegistry?
    @ObservationIgnored private var attachmentRegistry: DistributedAttachmentRegistry?
    /// The distributed endpoint belongs to the application, not to any one
    /// SwiftUI window. macOS can restore Pharos with only its menu-bar item;
    /// tying this task to the main WindowGroup made the device silently stop
    /// serving presence until a window was reopened.
    @ObservationIgnored private var applicationRuntimeTask: Task<Void, Never>?
    @ObservationIgnored private var membershipCatchUpTask: Task<Void, Never>?
    @ObservationIgnored private var synchronizationTasksInFlight = 0
    @ObservationIgnored private let peerSynchronizationGate =
        MacPeerSynchronizationGate()
    @ObservationIgnored private var lastAgentWakeMessageIDs: [String: String] = [:]
    @ObservationIgnored private var remotePresenceByHost:
        [MeshDeviceID: [String: CachedAgentPresence]] = [:]
    /// Concurrent anti-entropy rounds may finish out of order. Never let an
    /// older Host lease replace a newer one merely because a different peer
    /// kept that round alive longer.
    @ObservationIgnored private var remotePresenceGenerationByHost:
        [MeshDeviceID: Int64] = [:]
    @ObservationIgnored private var remotePresenceExpirationByHost:
        [MeshDeviceID: Int64] = [:]

    var isProductModeEnabled: Bool {
        PharosMeshRuntimeMode.usesDistributedMesh
    }

    /// Starts the one application-wide distributed runtime and convergence
    /// loop. Calls from multiple SwiftUI scenes are intentionally idempotent.
    func ensureApplicationRuntime(store: ProjectStore) {
        guard isProductModeEnabled, applicationRuntimeTask == nil else { return }
        applicationRuntimeTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            await self.start()
            await self.startNetwork()
            var activatedGroup: MeshTrustGroupID?
            while !Task.isCancelled {
                // A transient bind/bootstrap failure must not strand the app
                // offline for the rest of its process lifetime. `startNetwork`
                // is idempotent once a runtime exists.
                await self.startNetwork()
                if let replica = self.localReplica,
                   let group = self.activeTrustGroupID {
                    if group != activatedGroup {
                        await store.activateDistributedRegistry(
                            replica: replica, group: group,
                            meshSupport: self
                        )
                        activatedGroup = group
                    }
                    self.scheduleSynchronization()
                    // CLI and GUI are independent writers to the same local
                    // replica. Refresh even without a remote event.
                    store.syncRegistryNow()
                } else {
                    activatedGroup = nil
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
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
                activeTrustGroupID = try replica.activeTrustGroup()
                if let group = activeTrustGroupID {
                    configureRegistries(replica: replica, group: group)
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
              let replica = localReplica else { return }
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
            if let group = activeTrustGroupID {
                await DistributedHostCommandRecovery.recover(
                    replica: replica, group: group, executor: executor
                )
            }
            let hostEndpointID = try replica.identity.endpointID()
            let router = MeshReplicaRPCServer(
                store: replica.store, hostIdentity: replica.identity,
                localAuthorRoles: try replica.activeRoles(),
                allowedTrustGroupID: activeTrustGroupID,
                restrictToAllowedTrustGroup: true,
                membershipTransitionObserver: { transition in
                    try? replica.reconcileActiveMembership(after: transition)
                },
                hostPresenceProvider: {
                    guard let group = try? replica.activeTrustGroup() else {
                        let now = Int64(Date().timeIntervalSince1970 * 1_000)
                        return MeshAgentPresenceSnapshot(
                            hostDeviceID: replica.identity.deviceID,
                            hostEndpointID: hostEndpointID,
                            generatedAtMilliseconds: now,
                            expiresAtMilliseconds: now + 1_000,
                            records: []
                        )
                    }
                    return (try? await DistributedHookCLI.hostPresenceSnapshot(
                        replica: replica, group: group
                    )) ?? {
                        let now = Int64(Date().timeIntervalSince1970 * 1_000)
                        return MeshAgentPresenceSnapshot(
                            hostDeviceID: replica.identity.deviceID,
                            hostEndpointID: hostEndpointID,
                            generatedAtMilliseconds: now,
                            expiresAtMilliseconds: now + 1_000,
                            records: []
                        )
                    }()
                },
                hostCommandHandler: { command in
                    let outcome = await executor.execute(command)
                    if command.action == .stop,
                       case .executed = outcome {
                        try? await DistributedAgentTerminationFinalizer.finalize(
                            resourceID: command.resourceID,
                            replica: replica,
                            group: command.trustGroupID,
                            bindings: executor.bindings
                        )
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
                    let certified = try await MeshTrustGroupLifecycle
                        .certifyJoiningDevice(
                            invitation: pairing.invitation,
                            acceptance: pairing.acceptance,
                            replica: replica,
                            runtime: endpoint,
                            localAddress: address,
                            displayName: Host.current().localizedName ?? "This Mac"
                        )
                    return MeshTransportResponse(
                        header: try MeshTrustPairingRPCResponse(
                            acceptedDeviceID: certified.pairedDevice.descriptor.id
                        ).encoded(),
                        body: try certified.transition.canonicalBytes()
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

    func createPersonalMesh() async throws -> MeshTrustGroupID {
        guard let replica = localReplica else {
            throw DistributedMeshSupportError.networkNotReady
        }
        let group = try await MeshTrustGroupLifecycle.createPersonalMesh(
            replica: replica
        )
        activeTrustGroupID = group
        configureRegistries(replica: replica, group: group)
        try await refreshTrustedDevices()
        await restartNetwork()
        return group
    }

    func accept(
        _ invitation: MeshTrustInvitation,
        displayName: String,
        existingGroupDisposition: MeshExistingGroupDisposition
    ) async throws {
        await startNetwork()
        guard let replica = localReplica, let runtime, let localAddress else {
            throw DistributedMeshSupportError.networkNotReady
        }
        let current = try replica.activeTrustGroup()
        if let current, current != invitation.trustGroupID,
           existingGroupDisposition == .leave {
            _ = try await MeshTrustGroupLifecycle.leaveCurrentMesh(
                replica: replica,
                runtime: runtime,
                localAddress: localAddress,
                displayName: displayName
            )
            activeTrustGroupID = nil
            clearActiveGroupState()
        }
        let group = try await MeshTrustGroupLifecycle.join(
            invitation,
            replica: replica,
            runtime: runtime,
            localAddress: localAddress,
            displayName: displayName,
            inviterDisplayName: "Inviting device",
            replacingExisting: current != nil
        )
        activeTrustGroupID = group
        configureRegistries(replica: replica, group: group)
        try await refreshTrustedDevices()
        await restartNetwork()
        _ = await synchronizeOnce()
    }

    @discardableResult
    func archiveCurrentMesh() async throws -> MeshTrustGroupID {
        guard let replica = localReplica else {
            throw DistributedMeshSupportError.networkNotReady
        }
        let group = try MeshTrustGroupLifecycle.archiveCurrentMesh(
            replica: replica
        )
        activeTrustGroupID = nil
        clearActiveGroupState()
        await stopNetwork()
        await startNetwork()
        return group
    }

    @discardableResult
    func leaveCurrentMesh(displayName: String) async throws
        -> MeshTrustGroupLeaveResult {
        guard let replica = localReplica else {
            throw DistributedMeshSupportError.networkNotReady
        }
        guard try replica.activeTrustGroup() != nil else {
            throw MeshTrustGroupLifecycleError.noActiveTrustGroup
        }
        await startNetwork()
        guard let runtime, let localAddress else {
            throw DistributedMeshSupportError.networkNotReady
        }
        let result = try await MeshTrustGroupLifecycle.leaveCurrentMesh(
            replica: replica,
            runtime: runtime,
            localAddress: localAddress,
            displayName: displayName
        )
        activeTrustGroupID = nil
        clearActiveGroupState()
        await stopNetwork()
        await startNetwork()
        return result
    }

    func issueInvitation() async throws -> URL {
        guard let replica = localReplica, let group = activeTrustGroupID,
              let address = localAddress,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw DistributedMeshSupportError.networkNotReady }
        guard try replica.activeRoles().contains(.controller) else {
            throw DistributedMeshSupportError.administratorRequired
        }
        let invitation = try await MeshTrustPairingService(
            identity: replica.identity, invitationStore: replica.store
        ).issueInvitation(
            trustGroupID: group, membershipEpoch: epoch,
            inviterAddressTicket: address.ticket,
            inviterRoles: try replica.activeRoles(),
            // A paired Mac may host coding agents even if it initially joins
            // only as a viewer. Grant Host capability up front so its signed
            // presence/resource ownership is discoverable on every peer.
            requestedRoles: [.controller, .host, .replica]
        )
        return try MeshTrustInvitationLink.encode(invitation)
    }

    private func configureRegistries(
        replica: MeshLocalReplica, group: MeshTrustGroupID
    ) {
        chatRegistry = DistributedChatRegistry(replica: replica, group: group)
        attachmentRegistry = DistributedAttachmentRegistry(
            replica: replica, group: group
        )
    }

    private func clearActiveGroupState() {
        membershipCatchUpTask?.cancel()
        membershipCatchUpTask = nil
        chatRegistry = nil
        attachmentRegistry = nil
        trustedDevices = []
        membershipAudit = []
        connections = [:]
        remotePresenceByHost = [:]
        remotePresenceGenerationByHost = [:]
        remotePresenceExpirationByHost = [:]
        presenceDiagnostics = [:]
        lastSyncError = nil
    }

    private func stopNetwork() async {
        membershipCatchUpTask?.cancel()
        membershipCatchUpTask = nil
        if let runtime { try? await runtime.close() }
        runtime = nil
        localAddress = nil
    }

    /// Gracefully releases the process-owned Iroh endpoint before macOS exits.
    ///
    /// A command-line invocation may immediately reuse this device's stable
    /// Endpoint ID for a bounded admin operation. Letting the GUI process die
    /// without closing QUIC left remote peers holding a half-open canonical
    /// connection, so the new CLI endpoint was rejected as a duplicate.
    func shutdownApplicationRuntime() async {
        applicationRuntimeTask?.cancel()
        applicationRuntimeTask = nil
        await stopNetwork()
    }

    private func restartNetwork() async {
        await stopNetwork()
        await startNetwork()
    }

    /// Refreshes the user-visible device roster from the current membership
    /// epoch. Old-epoch rows stay in the database for audit, but never appear
    /// as currently trusted devices.
    func refreshTrustedDevices() async throws {
        guard let replica = localReplica, let group = activeTrustGroupID,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else {
            trustedDevices = []
            membershipAudit = []
            return
        }
        trustedDevices = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        membershipAudit = try await replica.store.membershipAudit(for: group)
    }

    func revokeDevice(_ device: MeshPairedDevice) async throws {
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID, let address = localAddress,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw DistributedMeshSupportError.networkNotReady }
        guard try replica.activeRoles().contains(.controller) else {
            throw DistributedMeshSupportError.administratorRequired
        }
        let peers = try await replica.store.trustedDevices(
            in: group, membershipEpoch: epoch
        )
        guard peers.contains(where: { $0.descriptor.id == device.descriptor.id }) else {
            return
        }
        let localMember = MeshPairedDevice(
            descriptor: MeshDeviceDescriptor(
                id: replica.identity.deviceID,
                endpointID: try replica.identity.endpointID(),
                displayName: Host.current().localizedName ?? "This Mac",
                roles: try replica.activeRoles()
            ),
            signingPublicKey: try replica.identity.signingPublicKeyBytes(),
            addressTicket: address.ticket
        )
        let survivors = peers.filter { $0.descriptor.id != device.descriptor.id }
        let transition = try await MeshTrustGroupLifecycle.certifyMembershipTransition(
            replica: replica, runtime: runtime, group: group,
            previousEpoch: epoch, roster: survivors + [localMember]
        )
        // Best effort before the local CAS. Offline survivors receive the same
        // signed transition from the retry path in synchronizeOnce().
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
        connections.removeValue(forKey: device.descriptor.id)
        try await refreshTrustedDevices()
    }

    func chatRooms() async throws -> [MeshRoomInfo] {
        try await requireChatRegistry().rooms()
    }

    func chatMembers(in room: MeshRoomInfo) async throws -> [DistributedChatMember] {
        try await requireChatRegistry().members(in: room)
    }

    /// Combines replicated room membership with this Host's structured hook
    /// observations. Missing local presence means "unknown", not "offline": a
    /// member may be running on another trusted peer.
    func chatMemberInfos(in room: MeshRoomInfo) async throws -> [MeshMemberInfo] {
        let members = try await chatMembers(in: room)
        let localPresence = localReplica.map {
            DistributedHookCLI.verifiedLocalAgentPresence(rootURL: $0.rootURL)
        } ?? [:]
        pruneExpiredRemotePresence()
        let remotePresence = effectiveRemotePresence()
        return members.map { member in
            let local = localPresence[member.id]
            let remote = local == nil ? remotePresence[member.id] : nil
            var effectiveState = local?.state
            // Codex does not emit SessionEnd. For a Pharos-owned tmux seat,
            // exact socket+pane disappearance is therefore the authoritative
            // local exit signal; do not expire quiet idle sessions by time.
            if let pane = local?.tmuxPane, let socket = local?.tmuxSocket,
               RemoteLaunch.sessionName(
                pane: pane, host: nil, socket: socket
               ) == nil {
                effectiveState = MeshSessionState.gone.rawValue
            }
            if effectiveState == nil { effectiveState = remote?.record.state.rawValue }
            return MeshMemberInfo(
                id: member.id, nick: member.nick,
                project: local?.cwd, session: member.id,
                host: remote?.hostDisplayName,
                tmuxPane: local?.tmuxPane, tmuxSocket: local?.tmuxSocket,
                state: effectiveState,
                stateTs: local?.updatedAt ?? remote.map {
                    Double($0.record.observedAtMilliseconds) / 1_000
                },
                stateReason: effectiveState == MeshSessionState.gone.rawValue
                    ? nil : (local?.reason ?? remote?.record.stateReason),
                kind: local?.kind ?? remote?.record.kind,
                rooms: [room.name],
                lastSeen: local?.updatedAt ?? remote.map {
                    Double($0.record.observedAtMilliseconds) / 1_000
                } ?? 0,
                nodeOnline: local != nil
                    ? effectiveState != MeshSessionState.gone.rawValue
                    : remote.map { $0.record.state != .gone }
            )
        }
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
        let registry = try requireChatRegistry()
        let author = try await registry.localHumanMember(in: room)
        let targetMemberIDs = try await registry.memberIDs(in: room, matching: to)
        return try await registry.send(
            room: room, fromMemberID: author.id, text: text,
            toMemberIDs: targetMemberIDs,
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
        let location = try await DistributedHostController.locateAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
        if location.isLocal {
            guard location.canStop,
                  let resourceID = MeshResourceID(rawValue: memberID) else {
                throw DistributedHostControllerError.agentNotControllable
            }
            let now = MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
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
                idempotencyKey: "local-stop-\(UUID().uuidString)",
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
                return
            case .failed(let code):
                throw DistributedHostControllerError.commandFailed(code)
            }
        }
        try await DistributedHostController.stopAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
    }

    func locateAgentHost(memberID: String) async throws -> DistributedAgentHostLocation {
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID else {
            throw DistributedMeshSupportError.networkNotReady
        }
        return try await DistributedHostController.locateAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
    }

    /// Re-runs Host-local proof for a legacy session. It can upgrade only an
    /// exact structured hook observation whose tmux socket and pane resolve to
    /// one live seat on this Mac.
    func repairLocalAgentBinding(
        memberID: String
    ) async throws -> DistributedAgentHostLocation {
        guard let replica = localReplica, let group = activeTrustGroupID,
              let presence = DistributedHookCLI.verifiedLocalAgentPresence(
                rootURL: replica.rootURL
              )[memberID] else {
            throw DistributedHostControllerError.agentNotControllable
        }
        let allPresence = DistributedHookCLI.verifiedLocalAgentPresence(
            rootURL: replica.rootURL
        )
        let matchingSeatClaims: Int
        if let pane = presence.tmuxPane, let socket = presence.tmuxSocket {
            matchingSeatClaims = allPresence.values.filter {
                $0.tmuxPane == pane && $0.tmuxSocket == socket
            }.count
        } else {
            matchingSeatClaims = 0
        }
        let result = try await DistributedAgentResourceReconciler(
            dataDirectory: replica.rootURL
        ).reconcile(
            memberID: memberID, presence: presence,
            seatIsConflicted: matchingSeatClaims > 1,
            replica: replica, group: group,
            now: MeshHybridTimestamp(
                wallTimeMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
        )
        guard result.readiness == .managed else {
            if result.readiness == .conflicted {
                throw DistributedHostControllerError.resourceOwnershipConflict
            }
            throw DistributedHostControllerError.agentNotControllable
        }
        return DistributedAgentHostLocation(
            deviceID: replica.identity.deviceID,
            endpointID: try replica.identity.endpointID(),
            displayName: Host.current().localizedName ?? "This Mac",
            resourceGeneration: result.resource.generation,
            allowedActions: result.resource.allowedActions
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
              let group = activeTrustGroupID
        else { return 0 }
        guard (try? replica.activeTrustGroup()) == group else {
            activeTrustGroupID = nil
            clearActiveGroupState()
            return 0
        }
        scheduleMembershipCatchUp(
            replica: replica, runtime: runtime, expectedGroup: group
        )
        guard let epoch = try? await replica.store.membershipEpoch(for: group)
        else { return 0 }
        // Local CLI/UI writes must wake a local idle agent immediately. Never
        // make that Host-local action wait behind an offline phone or peer RPC.
        await wakeIdleLocalAgents()
        do {
            let peers = try await replica.store.trustedDevices(
                in: group, membershipEpoch: epoch
            )
            trustedDevices = peers
            let pendingTransition = try await replica.store.latestMembershipTransition(
                for: group
            )
            let syncGate = peerSynchronizationGate
            var received = 0
            var failedPeers: [String] = []
            var presenceFailures: [String] = []
            await withTaskGroup(
                of: MeshPeerSynchronizationResult?.self
            ) { tasks in
                for peer in peers {
                    tasks.addTask {
                        guard await syncGate.acquire(peer.descriptor.id) else {
                            return nil
                        }
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
                                requestTimeoutMilliseconds: MeshReplicaRPCClient
                                    .backgroundRequestTimeoutMilliseconds
                            ).applyMembershipTransition(pendingTransition)
                        }
                        let client = MeshReplicaRPCClient(
                            transport: transport,
                            requestTimeoutMilliseconds: MeshReplicaRPCClient
                                .backgroundRequestTimeoutMilliseconds
                        )
                        let presenceFetcher:
                            (@Sendable () async throws -> MeshAgentPresenceSnapshot)?
                        // Presence is safe to probe on every authenticated
                        // replica: the response must still match the peer's
                        // Endpoint identity and every record must have an
                        // active Host resource owned by that same device.
                        // Older pairings omitted the Host role even on Macs;
                        // role-gating here stranded their live agents as
                        // Unknown forever. Devices that host no agents simply
                        // return an empty, short-lived snapshot.
                        presenceFetcher = {
                            try await MeshVerifiedHostPresence.fetch(
                                client: client, peer: peer, group: group,
                                membershipEpoch: epoch
                            )
                        }
                        let outcome = await MeshPeerSyncPresenceCoordinator.run(
                            synchronize: {
                                let report = try await MeshReplicaSyncSession(
                                    store: replica.store, client: client,
                                    remoteEndpointID: peer.descriptor.endpointID
                                ).synchronize(group: group, membershipEpoch: epoch)
                                return report.eventCount + report.snapshotCount
                            },
                            fetchPresence: presenceFetcher
                        )
                        let result = MeshPeerSynchronizationResult(
                            deviceID: peer.descriptor.id,
                            displayName: peer.descriptor.displayName,
                            received: outcome.received,
                            path: outcome.isReachable
                                ? await transport.path : .unavailable,
                            connected: outcome.isReachable,
                            synchronizationError: outcome.synchronizationError,
                            presence: outcome.presence,
                            presenceError: outcome.presenceError
                        )
                        await syncGate.release(peer.descriptor.id)
                        return result
                    }
                }
                for await result in tasks {
                    guard let result else { continue }
                    // Commit each peer as soon as it responds. Waiting for the
                    // whole task group made one offline phone/ghost hold an
                    // online Mac's 15-second presence lease behind a barrier.
                    let oldPresence = effectiveRemotePresence()
                    received += result.received
                    if result.synchronizationError != nil {
                        failedPeers.append(result.displayName)
                    }
                    if let error = result.presenceError {
                        presenceDiagnostics[result.deviceID] = error
                        presenceFailures.append("\(result.displayName): \(error)")
                    } else {
                        presenceDiagnostics[result.deviceID] = nil
                    }
                    connections[result.deviceID] = MeshConnectionSnapshot(
                        peer: result.deviceID, path: result.path,
                        connected: result.connected, lastChange: Date()
                    )
                    let now = Int64(Date().timeIntervalSince1970 * 1_000)
                    let priorLeaseExpired =
                        (remotePresenceExpirationByHost[result.deviceID] ?? .min) <= now
                    if let snapshot = result.presence,
                       priorLeaseExpired || snapshot.generatedAtMilliseconds >=
                        (remotePresenceGenerationByHost[result.deviceID] ?? .min) {
                        remotePresenceGenerationByHost[result.deviceID] =
                            snapshot.generatedAtMilliseconds
                        remotePresenceExpirationByHost[result.deviceID] =
                            snapshot.expiresAtMilliseconds
                        remotePresenceByHost[result.deviceID] = Dictionary(
                            uniqueKeysWithValues: snapshot.records.map {
                                ($0.resourceID.rawValue, CachedAgentPresence(
                                    record: $0, hostDeviceID: result.deviceID,
                                    hostDisplayName: result.displayName,
                                    expiresAtMilliseconds: snapshot.expiresAtMilliseconds
                                ))
                            }
                        )
                    }
                    pruneExpiredRemotePresence()
                    if effectiveRemotePresence() != oldPresence {
                        // Presence is ephemeral and intentionally excluded
                        // from the replicated registry. Explicitly invalidate
                        // already-visible Agents/Chat rows when a fresh Host
                        // lease arrives or expires.
                        presenceRevision &+= 1
                    }
                }
            }
            pruneExpiredRemotePresence()
            lastSyncError = MeshSyncFailurePresentation.message(
                peerNames: failedPeers
            )
            if lastSyncError == nil,
               let diagnostic = presenceFailures.sorted().first {
                lastSyncError = "Live agent state unavailable — \(diagnostic)"
            }
            // A peer pull may have introduced a newly directed message.
            await wakeIdleLocalAgents()
            return received
        } catch {
            lastSyncError = "Could not read trusted devices: \(error)"
            return 0
        }
    }

    /// Keep a one-second launch cadence even when one offline peer consumes
    /// the full bounded timeout. Two overlapping anti-entropy rounds are safe:
    /// events are immutable/idempotent and the store serializes writes. The
    /// cap prevents an unreachable fleet from creating an unbounded task pile.
    func scheduleSynchronization() {
        guard synchronizationTasksInFlight < 2 else { return }
        synchronizationTasksInFlight += 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.synchronizationTasksInFlight -= 1 }
            _ = await self.synchronizeOnce()
        }
    }

    /// Membership recovery must remain active, but an offline phone must not
    /// sit in front of the high-frequency chat/presence loop. Only one signed
    /// epoch walk runs at a time; ordinary replica pulls continue meanwhile.
    private func scheduleMembershipCatchUp(
        replica: MeshLocalReplica, runtime: IrohEndpointRuntime,
        expectedGroup: MeshTrustGroupID
    ) {
        guard membershipCatchUpTask == nil else { return }
        membershipCatchUpTask = Task { [weak self] in
            guard let self else { return }
            defer { self.membershipCatchUpTask = nil }
            let advanced = try? await MeshTrustGroupLifecycle.catchUpMembership(
                replica: replica, runtime: runtime
            )
            guard !Task.isCancelled,
                  self.activeTrustGroupID == expectedGroup else { return }
            guard (try? replica.activeTrustGroup()) == expectedGroup else {
                self.activeTrustGroupID = nil
                self.clearActiveGroupState()
                return
            }
            if (advanced ?? 0) > 0 {
                try? await self.refreshTrustedDevices()
            }
        }
    }

    /// A decentralized replica has no Broker process to inject idle-agent
    /// notifications. The owning Mac therefore wakes only its own exact tmux
    /// resources, only while structured hooks say the composer is safe, and
    /// types a fixed prompt that never contains untrusted message content.
    private func wakeIdleLocalAgents() async {
        guard let replica = localReplica, let group = activeTrustGroupID else { return }
        let presence = DistributedHookCLI.verifiedLocalAgentPresence(
            rootURL: replica.rootURL
        )
        let chat = DistributedAgentChat(replica: replica, group: group)
        let executor = DistributedHostCommandExecutor(
            bindings: DistributedHostResourceBindings(dataDirectory: replica.rootURL)
        )
        for (memberID, observation) in presence {
            guard observation.state == "idle" || observation.state == "stopped",
                  let resourceID = MeshResourceID(rawValue: memberID),
                  let messages = try? await chat.peek(memberID: memberID),
                  let newest = messages.last, !messages.isEmpty,
                  lastAgentWakeMessageIDs[memberID] != newest.stableID
            else { continue }
            let rooms = Array(Set(messages.map(\.room))).sorted().joined(separator: ", ")
            let prompt = "You have new Pharos mesh messages in \(rooms). " +
                "Run `pharos mesh recv --member \(memberID)` now, reply where needed, " +
                "then return to the idle composer."
            let outcome = await executor.pokeLocal(resourceID: resourceID, text: prompt)
            if case .executed = outcome {
                lastAgentWakeMessageIDs[memberID] = newest.stableID
            }
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

    private func pruneExpiredRemotePresence() {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        remotePresenceByHost = remotePresenceByHost.reduce(into: [:]) { result, entry in
            let live = entry.value.filter { $0.value.expiresAtMilliseconds > now }
            if !live.isEmpty { result[entry.key] = live }
        }
    }

    /// A stable resource ID may have exactly one owning Host. Conflicting
    /// simultaneous claims resolve to unknown until resource ownership
    /// converges; arrival order never decides authority.
    private func effectiveRemotePresence() -> [String: CachedAgentPresence] {
        var claims: [String: [CachedAgentPresence]] = [:]
        for host in remotePresenceByHost.values {
            for (resourceID, presence) in host {
                claims[resourceID, default: []].append(presence)
            }
        }
        return claims.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }
}

private struct MeshPeerSynchronizationResult: Sendable {
    let deviceID: MeshDeviceID
    let displayName: String
    let received: Int
    let path: MeshTransportPath
    let connected: Bool
    let synchronizationError: String?
    let presence: MeshAgentPresenceSnapshot?
    let presenceError: String?
}

private struct CachedAgentPresence: Equatable, Sendable {
    let record: MeshAgentPresenceRecord
    let hostDeviceID: MeshDeviceID
    let hostDisplayName: String
    let expiresAtMilliseconds: Int64
}

private actor MacPeerSynchronizationGate {
    private var active: Set<MeshDeviceID> = []

    func acquire(_ peer: MeshDeviceID) -> Bool {
        active.insert(peer).inserted
    }

    func release(_ peer: MeshDeviceID) {
        active.remove(peer)
    }
}

private enum DistributedMeshSupportError: LocalizedError {
    case networkNotReady
    case noActiveTrustGroup
    case attachmentNotFound
    case attachmentUnavailable
    case administratorRequired

    var errorDescription: String? {
        switch self {
        case .networkNotReady: "The private Mesh endpoint is still starting."
        case .noActiveTrustGroup: "Pair this device with a trusted Pharos device first."
        case .attachmentNotFound: "Attachment metadata is missing from this replica."
        case .attachmentUnavailable: "No trusted online device currently has this attachment."
        case .administratorRequired:
            "Only a current Mesh Admin device can invite or remove devices."
        }
    }
}
