import Foundation
import Observation
import PharosMeshControl
import PharosMeshIdentity
import PharosMeshIroh
import PharosMeshProtocol
import PharosMeshReplica

/// PharosMobile opens its signed local replica by default. The old Broker path
/// remains available only for bounded migration diagnostics.
enum PharosMeshRuntimeMode {
    static var usesDistributedMesh: Bool {
        ProcessInfo.processInfo.environment["PHAROS_LEGACY_BROKER"] != "1"
    }
}

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
    private(set) var trustedDevices: [MeshPairedDevice] = []
    private(set) var lastSyncError: String?
    @ObservationIgnored private var runtime: IrohEndpointRuntime?
    @ObservationIgnored private var registry: MobileDistributedRegistry?
    @ObservationIgnored private var chatRegistry: DistributedChatRegistry?
    @ObservationIgnored private var attachmentRegistry: DistributedAttachmentRegistry?
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
            if let group = activeTrustGroupID {
                registry = MobileDistributedRegistry(replica: replica, group: group)
                chatRegistry = DistributedChatRegistry(replica: replica, group: group)
                attachmentRegistry = DistributedAttachmentRegistry(
                    replica: replica, group: group
                )
                try await refreshTrustedDevices()
            }
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
        try replica.adoptActiveTrustGroup(
            invitation.trustGroupID, replacingExisting: true
        )
        activeTrustGroupID = invitation.trustGroupID
        registry = MobileDistributedRegistry(
            replica: replica, group: invitation.trustGroupID
        )
        chatRegistry = DistributedChatRegistry(
            replica: replica, group: invitation.trustGroupID
        )
        attachmentRegistry = DistributedAttachmentRegistry(
            replica: replica, group: invitation.trustGroupID
        )
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
        try await refreshTrustedDevices()
        _ = await synchronizeOnce()
    }

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

    func projects() async throws -> [RemoteProject] {
        try await requireRegistry().projects()
    }

    func issues() async throws -> [RemoteIssue] {
        try await requireRegistry().issues()
    }

    func addProject(
        name: String, githubRemote: String?, notes: String, tags: [String],
        yolo: Bool, tmux: Bool, playbooks: [RemotePlaybook],
        milestones: [RemoteMilestone]
    ) async throws {
        try await requireRegistry().addProject(
            name: name, githubRemote: githubRemote, notes: notes, tags: tags,
            yolo: yolo, tmux: tmux, playbooks: playbooks,
            milestones: milestones
        )
    }

    func updateProject(
        _ project: RemoteProject, name: String, githubRemote: String?,
        notes: String, tags: [String], yolo: Bool, tmux: Bool,
        playbooks: [RemotePlaybook], milestones: [RemoteMilestone]
    ) async throws {
        try await requireRegistry().updateProject(
            project, name: name, githubRemote: githubRemote,
            notes: notes, tags: tags, yolo: yolo, tmux: tmux,
            playbooks: playbooks, milestones: milestones
        )
    }

    func deleteProject(_ project: RemoteProject) async throws {
        try await requireRegistry().deleteProject(project)
    }

    func addIssue(
        to projectName: String, title: String, body: String,
        status: String, priority: String, labels: [String],
        milestoneID: String?, parent: Int?,
        relations: [RemoteIssueRelation],
        pendingAttachments: [PendingRemoteAttachment]
    ) async throws {
        var attachments: [RemoteIssueAttachment] = []
        for pending in pendingAttachments {
            let mesh = try await uploadAttachment(
                data: pending.data, name: pending.name,
                mediaType: pending.mediaType
            )
            attachments.append(RemoteIssueAttachment(
                id: pending.id.uuidString, storedName: mesh.id,
                originalName: pending.name, isImage: pending.isImage,
                byteSize: pending.data.count, meshAttachment: mesh,
                addedAt: Date()
            ))
        }
        try await requireRegistry().addIssue(
            to: projectName, title: title, body: body,
            status: status, priority: priority, labels: labels,
            milestoneID: milestoneID, parent: parent,
            relations: relations, attachments: attachments
        )
    }

    func updateIssue(
        _ issue: RemoteIssue, title: String, body: String,
        status: String, priority: String, labels: [String],
        milestoneID: String?, parent: Int?,
        relations: [RemoteIssueRelation],
        attachments: [RemoteIssueAttachment],
        pendingAttachments: [PendingRemoteAttachment]
    ) async throws {
        var uploaded = attachments
        for pending in pendingAttachments {
            let mesh = try await uploadAttachment(
                data: pending.data, name: pending.name,
                mediaType: pending.mediaType
            )
            uploaded.append(RemoteIssueAttachment(
                id: pending.id.uuidString,
                storedName: mesh.id,
                originalName: pending.name,
                isImage: pending.isImage,
                byteSize: pending.data.count,
                meshAttachment: mesh,
                addedAt: Date()
            ))
        }
        try await requireRegistry().updateIssue(
            issue, title: title, body: body, status: status,
            priority: priority, labels: labels,
            milestoneID: milestoneID, parent: parent,
            relations: relations, attachments: uploaded
        )
    }

    func deleteIssue(_ issue: RemoteIssue) async throws {
        try await requireRegistry().deleteIssue(issue)
    }

    func addProjectUpdate(to projectName: String, body: String) async throws {
        try await requireRegistry().addProjectUpdate(
            to: projectName, body: body
        )
    }

    func rooms() async throws -> [MeshRoomInfo] {
        try await requireChatRegistry().rooms()
    }

    func messages(in room: MeshRoomInfo, limit: Int? = nil) async throws -> [MeshMsg] {
        try await requireChatRegistry().messages(in: room, limit: limit)
    }

    func members(in room: MeshRoomInfo) async throws -> [DistributedChatMember] {
        try await requireChatRegistry().members(in: room)
    }

    func createRoom(named name: String) async throws -> MeshRoomInfo {
        try await requireChatRegistry().createRoom(named: name)
    }

    func renameRoom(_ room: MeshRoomInfo, to name: String) async throws {
        try await requireChatRegistry().renameRoom(room, to: name)
    }

    func deleteRoom(_ room: MeshRoomInfo) async throws {
        try await requireChatRegistry().deleteRoom(room)
    }

    func send(
        _ text: String, in room: MeshRoomInfo, to: [String],
        replyTo: MeshReply? = nil, attachments: [MeshAttachment] = []
    ) async throws -> MeshMsg {
        try await requireChatRegistry().send(
            room: room, from: "human", text: text, to: to,
            replyTo: replyTo, attachments: attachments
        )
    }

    func removeMember(_ memberID: String, from room: MeshRoomInfo) async throws {
        try await requireChatRegistry().leave(room: room, memberID: memberID)
    }

    func removeMemberFromAllRooms(_ memberID: String) async throws {
        let registry = try requireChatRegistry()
        for room in try await registry.rooms() {
            if try await registry.members(in: room).contains(where: { $0.id == memberID }) {
                try await registry.leave(room: room, memberID: memberID)
            }
        }
    }

    func stopAgent(memberID: String) async throws {
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID
        else { throw MobileDistributedMeshError.networkNotReady }
        try await DistributedHostController.stopAgent(
            memberID: memberID, runtime: runtime,
            replica: replica, group: group
        )
    }

    func renameMember(
        _ memberID: String, in room: MeshRoomInfo, to nick: String
    ) async throws {
        try await requireChatRegistry().renameMember(
            room: room, memberID: memberID, to: nick
        )
    }

    func uploadAttachment(
        data: Data, name: String, mediaType: String
    ) async throws -> MeshAttachment {
        try await requireAttachmentRegistry().put(
            data: data, name: name, mediaType: mediaType
        )
    }

    func attachmentData(_ attachment: MeshAttachment) async throws -> Data {
        let registry = try requireAttachmentRegistry()
        guard try await registry.metadata(id: attachment.id) != nil else {
            throw MobileDistributedMeshError.attachmentNotFound
        }
        if let data = try await registry.localData(for: attachment) { return data }
        guard let runtime, let replica = localReplica,
              let group = activeTrustGroupID,
              let epoch = try await replica.store.membershipEpoch(for: group)
        else { throw MobileDistributedMeshError.networkNotReady }
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
        throw MobileDistributedMeshError.attachmentUnavailable
    }

    func issueAttachmentData(
        _ attachment: RemoteIssueAttachment
    ) async throws -> Data {
        guard let meshAttachment = attachment.meshAttachment else {
            throw MobileDistributedMeshError.attachmentUnavailable
        }
        return try await attachmentData(meshAttachment)
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
            trustedDevices = peers
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

    private func requireRegistry() throws -> MobileDistributedRegistry {
        guard let registry else {
            throw MobileDistributedMeshError.noActiveTrustGroup
        }
        return registry
    }

    private func requireChatRegistry() throws -> DistributedChatRegistry {
        guard let chatRegistry else {
            throw MobileDistributedMeshError.noActiveTrustGroup
        }
        return chatRegistry
    }

    private func requireAttachmentRegistry() throws -> DistributedAttachmentRegistry {
        guard let attachmentRegistry else {
            throw MobileDistributedMeshError.noActiveTrustGroup
        }
        return attachmentRegistry
    }
}

private enum MobileDistributedMeshError: LocalizedError {
    case networkNotReady
    case acceptanceMismatch
    case noActiveTrustGroup
    case attachmentNotFound
    case attachmentUnavailable

    var errorDescription: String? {
        switch self {
        case .networkNotReady:
            "The private mesh endpoint is still starting."
        case .acceptanceMismatch:
            "The pairing response did not match this device."
        case .noActiveTrustGroup:
            "Pair this device with a trusted Pharos device first."
        case .attachmentNotFound:
            "Attachment metadata is missing from this replica."
        case .attachmentUnavailable:
            "No trusted online device currently has this attachment."
        }
    }
}

/// iOS projection over the shared field-register schema. Entity UUIDs are the
/// durable identity; project names and issue numbers remain editable display
/// fields and therefore cannot collide destructively after offline edits.
actor MobileDistributedRegistry {
    private static let deletedField = "_deleted"
    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let author: MeshLocalEventAuthor

    init(replica: MeshLocalReplica, group: MeshTrustGroupID) {
        self.replica = replica
        self.group = group
        author = MeshLocalEventAuthor(replica: replica, trustGroupID: group)
    }

    func projects() async throws -> [RemoteProject] {
        var result: [UUID: RemoteProject] = [:]
        for entity in try await replica.store.materializedEntities(
            of: .project, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !isDeleted(fields),
                  let id = UUID(uuidString: entity.id),
                  let name: String = try decode("name", from: fields)
            else { continue }
            let updates: [MobileProjectUpdatePayload] =
                try decode("updates", from: fields) ?? []
            result[id] = RemoteProject(
                name: name,
                localPath: nil,
                githubRemote: try decode("githubRemote", from: fields),
                tags: try decode("tags", from: fields) ?? [],
                notes: try decode("notes", from: fields) ?? "",
                yolo: try decode("yolo", from: fields) ?? true,
                tmux: try decode("tmux", from: fields) ?? false,
                playbooks: try decode("playbooks", from: fields) ?? [],
                milestones: try decode("milestones", from: fields) ?? [],
                updates: updates.map {
                    RemoteProjectUpdate(
                        id: $0.id.uuidString, body: $0.body,
                        kind: $0.kind, issueNumber: $0.issueNumber
                    )
                },
                replicaID: entity.id
            )
        }

        for entity in try await replica.store.materializedEntities(
            of: .issue, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !isDeleted(fields),
                  let projectID: UUID = try decode("projectID", from: fields),
                  let number: Int = try decode("number", from: fields),
                  let title: String = try decode("title", from: fields),
                  var project = result[projectID]
            else { continue }
            project.issues.append(RemoteIssue(
                project: project.name,
                number: number,
                title: title,
                status: try decode("status", from: fields) ?? "todo",
                priority: try decode("priority", from: fields) ?? "none",
                labels: try decode("labels", from: fields) ?? [],
                body: try decode("body", from: fields) ?? "",
                sortOrder: try decode("sortOrder", from: fields),
                milestoneID: try decode("milestoneID", from: fields),
                parent: try decode("parent", from: fields),
                relations: try decode("relations", from: fields) ?? [],
                attachments: try decode("attachments", from: fields) ?? [],
                replicaID: entity.id
            ))
            result[projectID] = project
        }

        return result.values.map { project in
            var sorted = project
            sorted.issues.sort {
                $0.number == $1.number ? $0.id < $1.id : $0.number < $1.number
            }
            return sorted
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func issues() async throws -> [RemoteIssue] {
        try await projects().flatMap(\.issues)
    }

    func addProject(
        name: String, githubRemote: String?, notes: String, tags: [String],
        yolo: Bool, tmux: Bool, playbooks: [RemotePlaybook],
        milestones: [RemoteMilestone]
    ) async throws {
        guard !(try await projects()).contains(where: {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw MobileDistributedRegistryError.duplicateProject(name)
        }
        guard let entity = MeshEntityReference(
            type: .project, id: UUID().uuidString
        ) else { throw MobileDistributedRegistryError.invalidEntity }
        try await set([
            Self.deletedField: try encode(false),
            "name": try encode(name),
            "tags": try encode(tags),
            "yolo": try encode(yolo),
            "tmux": try encode(tmux),
            "addedAt": try encode(Date()),
            "playbooks": try encode(playbooks),
            "notes": try encode(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            "updates": try encode([MobileProjectUpdatePayload]()),
            "milestones": try encode(milestones),
        ], on: entity)
        if let remote = normalized(githubRemote) {
            _ = try await author.setField(
                "githubRemote", value: try encode(remote), on: entity
            )
        }
    }

    func updateProject(
        _ project: RemoteProject, name: String, githubRemote: String?,
        notes: String, tags: [String], yolo: Bool, tmux: Bool,
        playbooks: [RemotePlaybook], milestones: [RemoteMilestone]
    ) async throws {
        let entity = try await projectEntity(for: project)
        guard !(try await projects()).contains(where: {
            $0.id != project.id &&
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw MobileDistributedRegistryError.duplicateProject(name)
        }
        try await set([
            Self.deletedField: try encode(false),
            "name": try encode(name),
            "notes": try encode(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            "tags": try encode(tags),
            "yolo": try encode(yolo),
            "tmux": try encode(tmux),
            "playbooks": try encode(playbooks),
            "milestones": try encode(milestones),
        ], on: entity)
        let liveMilestones = Set(milestones.map(\.id))
        for issue in project.issues
        where issue.milestoneID.map({ !liveMilestones.contains($0) }) == true {
            _ = try await author.deleteField(
                "milestoneID", on: try await issueEntity(for: issue)
            )
        }
        if let remote = normalized(githubRemote) {
            _ = try await author.setField(
                "githubRemote", value: try encode(remote), on: entity
            )
        } else {
            _ = try await author.deleteField("githubRemote", on: entity)
        }
    }

    func deleteProject(_ project: RemoteProject) async throws {
        _ = try await author.setField(
            Self.deletedField, value: try encode(true),
            on: try await projectEntity(for: project)
        )
    }

    func addIssue(
        to projectName: String, title: String, body: String,
        status: String, priority: String, labels: [String],
        milestoneID: String?, parent: Int?,
        relations: [RemoteIssueRelation], attachments: [RemoteIssueAttachment]
    ) async throws {
        guard let project = try await projects().first(where: {
            $0.name.localizedCaseInsensitiveCompare(projectName) == .orderedSame
        }), let projectID = project.replicaID.flatMap(UUID.init(uuidString:))
        else { throw MobileDistributedRegistryError.projectNotFound }
        guard let entity = MeshEntityReference(
            type: .issue, id: UUID().uuidString
        ) else { throw MobileDistributedRegistryError.invalidEntity }
        let number = (project.issues.map(\.number).max() ?? 0) + 1
        if let milestoneID,
           !project.milestones.contains(where: { $0.id == milestoneID }) {
            throw MobileDistributedRegistryError.invalidRelationship
        }
        if let parent {
            guard project.issues.contains(where: { $0.number == parent })
            else { throw MobileDistributedRegistryError.invalidRelationship }
        }
        guard relations.allSatisfy({ relation in
            project.issues.contains(where: { $0.number == relation.target })
        }) else { throw MobileDistributedRegistryError.invalidRelationship }
        let now = Date()
        try await set([
            Self.deletedField: try encode(false),
            "projectID": try encode(projectID),
            "number": try encode(number),
            "title": try encode(title),
            "status": try encode(status),
            "priority": try encode(priority),
            "body": try encode(body),
            "createdAt": try encode(now),
            "updatedAt": try encode(now),
            "attachments": try encode(attachments),
            "labels": try encode(labels),
            "sortOrder": try encode(Double(project.issues.count)),
            "relations": try encode(relations),
        ], on: entity)
        if let milestoneID {
            _ = try await author.setField(
                "milestoneID", value: try encode(milestoneID), on: entity
            )
        }
        if let parent {
            _ = try await author.setField(
                "parent", value: try encode(parent), on: entity
            )
        }
        try await updateInverseRelations(
            source: number, removing: [], adding: Set(relations), in: project
        )
    }

    func updateIssue(
        _ issue: RemoteIssue, title: String, body: String,
        status: String, priority: String, labels: [String],
        milestoneID: String?, parent: Int?,
        relations: [RemoteIssueRelation], attachments: [RemoteIssueAttachment]
    ) async throws {
        let project = try await projects().first { project in
            project.issues.contains(where: { $0.id == issue.id }) ||
            project.name == issue.project
        }
        guard let project,
              let currentIssue = project.issues.first(where: {
                $0.id == issue.id || $0.number == issue.number
              })
        else { throw MobileDistributedRegistryError.issueNotFound }
        if let milestoneID,
           !project.milestones.contains(where: { $0.id == milestoneID }) {
            throw MobileDistributedRegistryError.invalidRelationship
        }
        if let parent {
            guard parent != currentIssue.number,
                  project.issues.contains(where: { $0.number == parent }),
                  !wouldCreateParentCycle(
                    issueNumber: currentIssue.number, parent: parent,
                    issues: project.issues
                  )
            else { throw MobileDistributedRegistryError.invalidRelationship }
        }
        guard relations.allSatisfy({ relation in
            relation.target != currentIssue.number &&
            project.issues.contains(where: { $0.number == relation.target })
        }) else { throw MobileDistributedRegistryError.invalidRelationship }
        let oldRelations = Set(currentIssue.relations)
        let newRelations = Set(relations)
        try await updateInverseRelations(
            source: currentIssue.number,
            removing: oldRelations.subtracting(newRelations),
            adding: newRelations.subtracting(oldRelations),
            in: project
        )
        let entity = try await issueEntity(for: currentIssue)
        try await set([
            Self.deletedField: try encode(false),
            "title": try encode(title),
            "body": try encode(body.trimmingCharacters(in: .whitespacesAndNewlines)),
            "status": try encode(status),
            "priority": try encode(priority),
            "labels": try encode(labels),
            "relations": try encode(relations),
            "attachments": try encode(attachments),
            "updatedAt": try encode(Date()),
        ], on: entity)
        if let milestoneID {
            _ = try await author.setField(
                "milestoneID", value: try encode(milestoneID), on: entity
            )
        } else {
            _ = try await author.deleteField("milestoneID", on: entity)
        }
        if let parent {
            _ = try await author.setField(
                "parent", value: try encode(parent), on: entity
            )
        } else {
            _ = try await author.deleteField("parent", on: entity)
        }
    }

    private func wouldCreateParentCycle(
        issueNumber: Int, parent: Int, issues: [RemoteIssue]
    ) -> Bool {
        var cursor: Int? = parent
        var visited = Set<Int>()
        while let number = cursor, visited.insert(number).inserted {
            if number == issueNumber { return true }
            cursor = issues.first(where: { $0.number == number })?.parent
        }
        return false
    }

    private func updateInverseRelations(
        source: Int, removing: Set<RemoteIssueRelation>,
        adding: Set<RemoteIssueRelation>, in project: RemoteProject
    ) async throws {
        let targetNumbers = Set(removing.map(\.target)).union(adding.map(\.target))
        for targetNumber in targetNumbers {
            guard let target = project.issues.first(where: {
                $0.number == targetNumber
            }) else { throw MobileDistributedRegistryError.issueNotFound }
            var targetRelations = target.relations
            for relation in removing where relation.target == targetNumber {
                let inverse = RemoteIssueRelation(
                    kind: inverseRelationKind(relation.kind), target: source
                )
                targetRelations.removeAll { $0 == inverse }
            }
            for relation in adding where relation.target == targetNumber {
                let inverse = RemoteIssueRelation(
                    kind: inverseRelationKind(relation.kind), target: source
                )
                if !targetRelations.contains(inverse) {
                    targetRelations.append(inverse)
                }
            }
            _ = try await author.setField(
                "relations", value: try encode(targetRelations),
                on: try await issueEntity(for: target)
            )
        }
    }

    private func inverseRelationKind(_ kind: String) -> String {
        switch kind {
        case "blocks": "blocked_by"
        case "blocked_by": "blocks"
        default: kind
        }
    }

    func deleteIssue(_ issue: RemoteIssue) async throws {
        _ = try await author.setField(
            Self.deletedField, value: try encode(true),
            on: try await issueEntity(for: issue)
        )
    }

    func addProjectUpdate(to projectName: String, body: String) async throws {
        guard let project = try await projects().first(where: {
            $0.name.localizedCaseInsensitiveCompare(projectName) == .orderedSame
        }) else { throw MobileDistributedRegistryError.projectNotFound }
        let entity = try await projectEntity(for: project)
        let fields = try await activeFields(for: entity)
        var updates: [MobileProjectUpdatePayload] =
            try decode("updates", from: fields) ?? []
        updates.insert(MobileProjectUpdatePayload(
            id: UUID(), createdAt: Date(), body: body,
            kind: "note", issueNumber: nil
        ), at: 0)
        _ = try await author.setField(
            "updates", value: try encode(updates), on: entity
        )
    }

    private func projectEntity(
        for project: RemoteProject
    ) async throws -> MeshEntityReference {
        if let id = project.replicaID,
           let entity = MeshEntityReference(type: .project, id: id) { return entity }
        guard let found = try await projects().first(where: {
            $0.name.localizedCaseInsensitiveCompare(project.name) == .orderedSame
        }), let id = found.replicaID,
              let entity = MeshEntityReference(type: .project, id: id)
        else { throw MobileDistributedRegistryError.projectNotFound }
        return entity
    }

    private func issueEntity(
        for issue: RemoteIssue
    ) async throws -> MeshEntityReference {
        if let id = issue.replicaID,
           let entity = MeshEntityReference(type: .issue, id: id) { return entity }
        guard let found = try await issues().first(where: {
            $0.project == issue.project && $0.number == issue.number
        }), let id = found.replicaID,
              let entity = MeshEntityReference(type: .issue, id: id)
        else { throw MobileDistributedRegistryError.issueNotFound }
        return entity
    }

    private func set(
        _ fields: [String: Data], on entity: MeshEntityReference
    ) async throws {
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            _ = try await author.setField(key, value: value, on: entity)
        }
    }

    private func activeFields(
        for entity: MeshEntityReference
    ) async throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try await replica.store.materializedFields(
            for: entity, in: group
        ).compactMap { field in
            guard !field.isDeleted, let value = field.value else { return nil }
            return (field.field, value)
        })
    }

    private func isDeleted(_ fields: [String: Data]) -> Bool {
        guard let value = fields[Self.deletedField] else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: value)) == true
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(
        _ field: String, from fields: [String: Data]
    ) throws -> T? {
        guard let value = fields[field] else { return nil }
        return try JSONDecoder().decode(T.self, from: value)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

private struct MobileProjectUpdatePayload: Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let body: String
    let kind: String
    let issueNumber: Int?
}

private enum MobileDistributedRegistryError: LocalizedError {
    case duplicateProject(String)
    case projectNotFound
    case issueNotFound
    case invalidEntity
    case invalidRelationship

    var errorDescription: String? {
        switch self {
        case .duplicateProject(let name):
            "A project named \(name) already exists."
        case .projectNotFound:
            "Project not found. Sync and try again."
        case .issueNotFound:
            "Issue not found. Sync and try again."
        case .invalidEntity:
            "Could not create a valid replicated entity."
        case .invalidRelationship:
            "That issue relationship would be invalid or create a cycle."
        }
    }
}
