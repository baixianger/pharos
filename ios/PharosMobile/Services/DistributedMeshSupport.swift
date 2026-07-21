import Foundation
import Observation
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
        name: String, githubRemote: String?, notes: String, tags: [String]
    ) async throws {
        try await requireRegistry().addProject(
            name: name, githubRemote: githubRemote, notes: notes, tags: tags
        )
    }

    func updateProject(
        _ project: RemoteProject, name: String, githubRemote: String?,
        notes: String, tags: [String]
    ) async throws {
        try await requireRegistry().updateProject(
            project, name: name, githubRemote: githubRemote,
            notes: notes, tags: tags
        )
    }

    func deleteProject(_ project: RemoteProject) async throws {
        try await requireRegistry().deleteProject(project)
    }

    func addIssue(to projectName: String, title: String) async throws {
        try await requireRegistry().addIssue(to: projectName, title: title)
    }

    func updateIssue(
        _ issue: RemoteIssue, title: String, body: String,
        status: String, priority: String, labels: [String]
    ) async throws {
        try await requireRegistry().updateIssue(
            issue, title: title, body: body, status: status,
            priority: priority, labels: labels
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
private actor MobileDistributedRegistry {
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
        name: String, githubRemote: String?, notes: String, tags: [String]
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
            "yolo": try encode(true),
            "tmux": try encode(false),
            "addedAt": try encode(Date()),
            "playbooks": try encode([String]()),
            "notes": try encode(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            "updates": try encode([MobileProjectUpdatePayload]()),
            "milestones": try encode([String]()),
        ], on: entity)
        if let remote = normalized(githubRemote) {
            _ = try await author.setField(
                "githubRemote", value: try encode(remote), on: entity
            )
        }
    }

    func updateProject(
        _ project: RemoteProject, name: String, githubRemote: String?,
        notes: String, tags: [String]
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
        ], on: entity)
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

    func addIssue(to projectName: String, title: String) async throws {
        guard let project = try await projects().first(where: {
            $0.name.localizedCaseInsensitiveCompare(projectName) == .orderedSame
        }), let projectID = project.replicaID.flatMap(UUID.init(uuidString:))
        else { throw MobileDistributedRegistryError.projectNotFound }
        guard let entity = MeshEntityReference(
            type: .issue, id: UUID().uuidString
        ) else { throw MobileDistributedRegistryError.invalidEntity }
        let number = (project.issues.map(\.number).max() ?? 0) + 1
        let now = Date()
        try await set([
            Self.deletedField: try encode(false),
            "projectID": try encode(projectID),
            "number": try encode(number),
            "title": try encode(title),
            "status": try encode("todo"),
            "priority": try encode("none"),
            "body": try encode(""),
            "createdAt": try encode(now),
            "updatedAt": try encode(now),
            "attachments": try encode([String]()),
            "labels": try encode([String]()),
            "sortOrder": try encode(Double(project.issues.count)),
            "relations": try encode([String]()),
        ], on: entity)
    }

    func updateIssue(
        _ issue: RemoteIssue, title: String, body: String,
        status: String, priority: String, labels: [String]
    ) async throws {
        try await set([
            Self.deletedField: try encode(false),
            "title": try encode(title),
            "body": try encode(body.trimmingCharacters(in: .whitespacesAndNewlines)),
            "status": try encode(status),
            "priority": try encode(priority),
            "labels": try encode(labels),
            "updatedAt": try encode(Date()),
        ], on: try await issueEntity(for: issue))
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
        }
    }
}
