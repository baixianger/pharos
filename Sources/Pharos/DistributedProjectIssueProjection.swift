import Foundation
import PharosMeshCore

/// Field-level projection between the product models and replicated registers.
/// Host-local paths and live agent/session observations never enter this view.
struct DistributedProjectIssueProjection: Sendable {
    private static let deletedField = "_deleted"
    private let replica: MeshLocalReplica
    private let group: MeshTrustGroupID
    private let author: MeshLocalEventAuthor

    init(replica: MeshLocalReplica, group: MeshTrustGroupID,
         nowMilliseconds: @escaping @Sendable () -> Int64 = {
             Int64(Date().timeIntervalSince1970 * 1_000)
         }) {
        self.replica = replica
        self.group = group
        author = MeshLocalEventAuthor(
            replica: replica, trustGroupID: group,
            nowMilliseconds: nowMilliseconds
        )
    }

    func publish(projects: [Project]) async throws {
        try await publishProjects(
            projects, projectDeletionCandidates: nil,
            issueDeletionCandidates: nil
        )
    }

    private func publishProjects(
        _ projects: [Project], projectDeletionCandidates: Set<String>?,
        issueDeletionCandidates: Set<String>?
    ) async throws {
        let liveProjects = Set(projects.map { $0.id.uuidString })
        let liveIssues = Set(projects.flatMap { $0.issues }.map { $0.id.uuidString })

        for project in projects {
            let entity = MeshEntityReference(
                type: .project, id: project.id.uuidString
            )!
            try await publish(
                fields: try Self.projectFields(project), on: entity
            )
            for issue in project.issues {
                let issueEntity = MeshEntityReference(
                    type: .issue, id: issue.id.uuidString
                )!
                try await publish(
                    fields: try Self.issueFields(issue, projectID: project.id),
                    on: issueEntity
                )
            }
        }
        for entity in try await replica.store.materializedEntities(
            of: .project, in: group
        ) where projectDeletionCandidates?.contains(entity.id)
            ?? !liveProjects.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
        for entity in try await replica.store.materializedEntities(
            of: .issue, in: group
        ) where issueDeletionCandidates?.contains(entity.id)
            ?? !liveIssues.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
    }

    /// Publishes the complete portable registry. Projects/issues remain
    /// field-level registers; groups and recoverable trash are independent
    /// entities so unrelated edits do not contend on one registry JSON blob.
    func publish(store: StoreData) async throws {
        try await publish(projects: store.projects)
        try await publishGroups(store.groups)
        try await publishTrash(store.trash)
    }

    /// Publishes one writer's before/after delta. Entities absent from both
    /// snapshots may have been added concurrently by another process or
    /// device, so they must never be inferred as deletions.
    func publish(store: StoreData, replacing previous: StoreData) async throws {
        let desiredProjectIDs = Set(store.projects.map { $0.id.uuidString })
        let desiredIssueIDs = Set(store.projects.flatMap(\.issues).map {
            $0.id.uuidString
        })
        let priorProjectIDs = Set(previous.projects.map { $0.id.uuidString })
        let priorIssueIDs = Set(previous.projects.flatMap(\.issues).map {
            $0.id.uuidString
        })
        let priorProjects = Dictionary(uniqueKeysWithValues: previous.projects.map {
            ($0.id, $0)
        })
        let priorIssues = Dictionary(uniqueKeysWithValues: previous.projects
            .flatMap { project in project.issues.map { ($0.id, ($0, project.id)) } })
        for project in store.projects {
            let entity = MeshEntityReference(
                type: .project, id: project.id.uuidString
            )!
            try await publishChanges(
                fields: try Self.projectFields(project),
                replacing: try priorProjects[project.id].map(Self.projectFields),
                on: entity
            )
            for issue in project.issues {
                let issueEntity = MeshEntityReference(
                    type: .issue, id: issue.id.uuidString
                )!
                let oldFields = try priorIssues[issue.id].map {
                    try Self.issueFields($0.0, projectID: $0.1)
                }
                try await publishChanges(
                    fields: try Self.issueFields(issue, projectID: project.id),
                    replacing: oldFields, on: issueEntity
                )
            }
        }
        try await publishDeletions(
            of: .project,
            ids: priorProjectIDs.subtracting(desiredProjectIDs)
        )
        try await publishDeletions(
            of: .issue,
            ids: priorIssueIDs.subtracting(desiredIssueIDs)
        )
        try await publishGroups(
            store.groups,
            deletionCandidates: Set(previous.groups.map(Self.normalizedGroupName))
                .subtracting(store.groups.map(Self.normalizedGroupName))
        )
        try await publishTrash(
            store.trash,
            deletionCandidates: Set(previous.trash.map { $0.id.uuidString })
                .subtracting(store.trash.map { $0.id.uuidString })
        )
    }

    func materializedStore() async throws -> StoreData {
        var store = StoreData(
            projects: try await materializedProjects(),
            groups: try await materializedGroups(),
            trash: try await materializedTrash()
        )
        store.ensureGroupsForTags()
        store.purgeExpiredTrash()
        return store
    }

    func hasReplicatedRegistryMetadata() async throws -> Bool {
        let groups = try await replica.store.materializedEntities(
            of: .projectGroup, in: group
        )
        let trash = try await replica.store.materializedEntities(
            of: .trashItem, in: group
        )
        return !groups.isEmpty || !trash.isEmpty
    }

    func materializedProjects() async throws -> [Project] {
        var projectsByID: [UUID: Project] = [:]
        for entity in try await replica.store.materializedEntities(
            of: .project, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields),
                  let id = UUID(uuidString: entity.id),
                  let name: String = try Self.decode("name", from: fields),
                  let addedAt: Date = try Self.decode("addedAt", from: fields)
            else { continue }
            projectsByID[id] = Project(
                id: id, name: name,
                githubRemote: try Self.decode("githubRemote", from: fields),
                tags: try Self.decode("tags", from: fields) ?? [],
                yolo: try Self.decode("yolo", from: fields) ?? true,
                tmux: try Self.decode("tmux", from: fields) ?? false,
                addedAt: addedAt,
                playbooks: try Self.decode("playbooks", from: fields) ?? [],
                notes: try Self.decode("notes", from: fields) ?? "",
                updates: try Self.decode("updates", from: fields) ?? [],
                milestones: try Self.decode("milestones", from: fields) ?? []
            )
        }

        for entity in try await replica.store.materializedEntities(
            of: .issue, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields),
                  let id = UUID(uuidString: entity.id),
                  let projectID: UUID = try Self.decode("projectID", from: fields),
                  let number: Int = try Self.decode("number", from: fields),
                  let title: String = try Self.decode("title", from: fields),
                  let createdAt: Date = try Self.decode("createdAt", from: fields),
                  let updatedAt: Date = try Self.decode("updatedAt", from: fields),
                  var project = projectsByID[projectID]
            else { continue }
            project.issues.append(Issue(
                id: id, number: number, title: title,
                status: try Self.decode("status", from: fields) ?? .todo,
                priority: try Self.decode("priority", from: fields) ?? .none,
                body: try Self.decode("body", from: fields) ?? "",
                createdAt: createdAt, updatedAt: updatedAt,
                attachments: try Self.decode("attachments", from: fields) ?? [],
                labels: try Self.decode("labels", from: fields) ?? [],
                sortOrder: try Self.decode("sortOrder", from: fields) ?? 0,
                milestoneID: try Self.decode("milestoneID", from: fields),
                parent: try Self.decode("parent", from: fields),
                relations: try Self.decode("relations", from: fields) ?? []
            ))
            projectsByID[projectID] = project
        }
        return projectsByID.values.map { project in
            var sorted = project
            sorted.issues.sort { lhs, rhs in
                lhs.number == rhs.number
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.number < rhs.number
            }
            return sorted
        }.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func publishGroups(
        _ groups: [String], deletionCandidates: Set<String>? = nil
    ) async throws {
        let desired = Set(groups.map(Self.normalizedGroupName).filter { !$0.isEmpty })
        var activeByName: [String: [MeshEntityReference]] = [:]
        for entity in try await replica.store.materializedEntities(
            of: .projectGroup, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields),
                  let name: String = try Self.decode("name", from: fields)
            else { continue }
            activeByName[Self.normalizedGroupName(name), default: []].append(entity)
        }
        for name in desired where activeByName[name]?.isEmpty != false {
            guard let entity = MeshEntityReference(
                type: .projectGroup, id: UUID().uuidString
            ) else { continue }
            try await publish(fields: [
                Self.deletedField: try Self.encode(false),
                "name": try Self.encode(groups.first {
                    Self.normalizedGroupName($0) == name
                } ?? name),
            ], on: entity)
        }
        for (name, entities) in activeByName
        where deletionCandidates?.contains(name) ?? !desired.contains(name) {
            for entity in entities { try await publishDeletion(on: entity) }
        }
    }

    private func materializedGroups() async throws -> [String] {
        var byNormalizedName: [String: String] = [:]
        for entity in try await replica.store.materializedEntities(
            of: .projectGroup, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields),
                  let name: String = try Self.decode("name", from: fields),
                  !Self.normalizedGroupName(name).isEmpty else { continue }
            let key = Self.normalizedGroupName(name)
            if byNormalizedName[key] == nil { byNormalizedName[key] = name }
        }
        return byNormalizedName.values.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func publishTrash(
        _ trash: [TrashedItem], deletionCandidates: Set<String>? = nil
    ) async throws {
        let desired = Set(trash.map { $0.id.uuidString })
        for item in trash {
            guard let entity = MeshEntityReference(
                type: .trashItem, id: item.id.uuidString
            ) else { continue }
            try await publish(fields: [
                Self.deletedField: try Self.encode(false),
                "deletedAt": try Self.encode(item.deletedAt),
                "payload": try Self.encode(Self.portableTrashPayload(item.payload)),
            ], on: entity)
        }
        for entity in try await replica.store.materializedEntities(
            of: .trashItem, in: group
        ) where deletionCandidates?.contains(entity.id) ?? !desired.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
    }

    private func materializedTrash() async throws -> [TrashedItem] {
        var result: [TrashedItem] = []
        for entity in try await replica.store.materializedEntities(
            of: .trashItem, in: group
        ) {
            let fields = try await activeFields(for: entity)
            guard !Self.isDeleted(fields), let id = UUID(uuidString: entity.id),
                  let deletedAt: Date = try Self.decode("deletedAt", from: fields),
                  let payload: TrashPayload = try Self.decode("payload", from: fields)
            else { continue }
            result.append(TrashedItem(id: id, deletedAt: deletedAt, payload: payload))
        }
        return result.sorted {
            $0.deletedAt == $1.deletedAt
                ? $0.id.uuidString < $1.id.uuidString
                : $0.deletedAt > $1.deletedAt
        }
    }

    private func publish(
        fields desired: [String: Data], on entity: MeshEntityReference
    ) async throws {
        let current = Dictionary(
            uniqueKeysWithValues: try await replica.store.materializedFields(
                for: entity, in: group
            ).map { ($0.field, $0) }
        )
        for field in desired.keys.sorted() {
            guard let value = desired[field] else { continue }
            if current[field]?.isDeleted == false,
               current[field]?.value == value { continue }
            _ = try await author.setField(field, value: value, on: entity)
        }
        for field in current.keys.sorted()
        where field != Self.deletedField && desired[field] == nil &&
                current[field]?.isDeleted == false {
            _ = try await author.deleteField(field, on: entity)
        }
    }

    private func publishChanges(
        fields desired: [String: Data], replacing previous: [String: Data]?,
        on entity: MeshEntityReference
    ) async throws {
        guard let previous else {
            try await publish(fields: desired, on: entity)
            return
        }
        let current = Dictionary(
            uniqueKeysWithValues: try await replica.store.materializedFields(
                for: entity, in: group
            ).map { ($0.field, $0) }
        )
        for field in desired.keys.sorted()
        where desired[field] != previous[field] {
            guard let value = desired[field] else { continue }
            if current[field]?.isDeleted == false,
               current[field]?.value == value { continue }
            _ = try await author.setField(field, value: value, on: entity)
        }
        for field in previous.keys.sorted()
        where desired[field] == nil && current[field]?.isDeleted == false {
            _ = try await author.deleteField(field, on: entity)
        }
    }

    private func publishDeletions(
        of type: MeshEntityType, ids: Set<String>
    ) async throws {
        guard !ids.isEmpty else { return }
        for entity in try await replica.store.materializedEntities(
            of: type, in: group
        ) where ids.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
    }

    private func publishDeletion(on entity: MeshEntityReference) async throws {
        let fields = try await activeFields(for: entity)
        if let value = fields[Self.deletedField],
           (try? JSONDecoder().decode(Bool.self, from: value)) == true { return }
        _ = try await author.setField(
            Self.deletedField, value: try Self.encode(true), on: entity
        )
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

    private static func isDeleted(_ fields: [String: Data]) -> Bool {
        guard let value = fields[deletedField] else { return false }
        return (try? JSONDecoder().decode(Bool.self, from: value)) == true
    }

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func portableTrashPayload(_ payload: TrashPayload) -> TrashPayload {
        func portableIssue(_ value: Issue) -> Issue {
            var issue = value
            issue.activeSession = nil
            issue.activeSessionHost = nil
            issue.worktreePath = nil
            return issue
        }
        switch payload {
        case .project(var project):
            project.localPath = nil
            project.localPaths = [:]
            project.issues = project.issues.map(portableIssue)
            return .project(project)
        case .issue(let projectID, let projectName, let issue):
            return .issue(
                projectID: projectID, projectName: projectName,
                issue: portableIssue(issue)
            )
        case .group, .playbook:
            return payload
        }
    }

    private static func projectFields(_ project: Project) throws -> [String: Data] {
        var fields: [String: Data] = [
            deletedField: try encode(false),
            "name": try encode(project.name),
            "tags": try encode(project.tags),
            "yolo": try encode(project.yolo),
            "tmux": try encode(project.tmux),
            "addedAt": try encode(project.addedAt),
            "playbooks": try encode(project.playbooks),
            "notes": try encode(project.notes),
            "updates": try encode(project.updates),
            "milestones": try encode(project.milestones),
        ]
        if let remote = project.githubRemote {
            fields["githubRemote"] = try encode(remote)
        }
        return fields
    }

    private static func issueFields(
        _ issue: Issue, projectID: UUID
    ) throws -> [String: Data] {
        var fields: [String: Data] = [
            deletedField: try encode(false),
            "projectID": try encode(projectID),
            "number": try encode(issue.number),
            "title": try encode(issue.title),
            "status": try encode(issue.status),
            "priority": try encode(issue.priority),
            "body": try encode(issue.body),
            "createdAt": try encode(issue.createdAt),
            "updatedAt": try encode(issue.updatedAt),
            "attachments": try encode(issue.attachments),
            "labels": try encode(issue.labels),
            "sortOrder": try encode(issue.sortOrder),
            "relations": try encode(issue.relations),
        ]
        if let milestoneID = issue.milestoneID {
            fields["milestoneID"] = try encode(milestoneID)
        }
        if let parent = issue.parent {
            fields["parent"] = try encode(parent)
        }
        return fields
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(
        _ field: String, from fields: [String: Data]
    ) throws -> T? {
        guard let value = fields[field] else { return nil }
        return try JSONDecoder().decode(T.self, from: value)
    }
}
