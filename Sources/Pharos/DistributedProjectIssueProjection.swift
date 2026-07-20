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
        ) where !liveProjects.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
        for entity in try await replica.store.materializedEntities(
            of: .issue, in: group
        ) where !liveIssues.contains(entity.id) {
            try await publishDeletion(on: entity)
        }
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
