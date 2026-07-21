import Foundation
import PharosMeshCore

/// Project/issue CLI backed by the same field-level replica as the GUI.
/// Host execution commands remain in `PharosCore`, but their cache is refreshed
/// here so they resolve the same project UUIDs and device-local paths.
enum DistributedRegistryCLI {
    static let commands: Set<String> = [
        "list", "projects", "groups", "add", "remove", "rename", "describe",
        "group", "trash", "issue", "milestone", "update", "search", "overview",
        "yolo", "tmux", "attach",
    ]

    static func handles(_ command: String, parsed: CLI.Parsed) -> Bool {
        guard commands.contains(command) else { return false }
        // Starting an agent is Host execution. Refreshing the distributed cache
        // happens in CLI.run before the existing launcher takes over.
        return !(command == "issue" && parsed.arg(0) == "start")
    }

    static func refreshLocalCache() async {
        guard let context = try? await context() else { return }
        try? writeCache(try await context.projection.materializedStore())
    }

    static func run(_ command: String, parsed p: CLI.Parsed) async -> Int32 {
        do {
            let context = try await context()
            var store = try await context.projection.materializedStore()
            HostLocalProjectPaths.apply(to: &store)
            var changed = false
            switch command {
            case "list", "projects":
                emitProjects(store.projects, json: p.has("json"))
            case "groups":
                if p.has("json") { emitJSON(store.groups) }
                else if store.groups.isEmpty { print("(no groups)") }
                else { for group in store.groups { print("\(group)\t\(store.projects.filter { $0.tags.contains(group) }.count)") } }
            case "add":
                let name = try required(p.arg(0), "add <name>")
                guard !store.projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                else { throw DistributedRegistryCLIError.duplicateProject(name) }
                let project = Project(
                    name: name, githubRemote: p.opt("remote"), tags: p.all("tag"),
                    notes: p.opt("notes") ?? ""
                )
                store.projects.append(project)
                if let path = p.opt("path") { HostLocalProjectPaths.set(path, for: project.id) }
                store.ensureGroupsForTags(); changed = true
                print("Added \(name)")
            case "remove":
                let index = try projectIndex(p.arg(0), in: store)
                let name = store.projects[index].name
                _ = store.softDeleteProject(id: store.projects[index].id)
                changed = true; print("Removed \(name) (recoverable from Trash)")
            case "rename":
                let index = try projectIndex(p.arg(0), in: store)
                let newName = try required(p.arg(1), "rename <project> <new-name>")
                store.projects[index].name = newName; changed = true
                print("Renamed project to \(newName)")
            case "describe":
                let index = try projectIndex(p.arg(0), in: store)
                store.projects[index].notes = p.positional.dropFirst().joined(separator: " ")
                changed = true; print("Updated \(store.projects[index].name)")
            case "yolo", "tmux":
                let index = try projectIndex(p.arg(0), in: store)
                let enabled = try boolean(p.arg(1))
                if command == "yolo" { store.projects[index].yolo = enabled }
                else { store.projects[index].tmux = enabled }
                changed = true; print("\(command) \(enabled ? "on" : "off") for \(store.projects[index].name)")
            case "group":
                changed = try runGroup(p, store: &store)
            case "trash":
                changed = try runTrash(p, store: &store)
            case "issue":
                changed = try await runIssue(p, store: &store, context: context)
            case "milestone":
                changed = try runMilestone(p, store: &store)
            case "update":
                changed = try runUpdate(p, store: &store)
            case "attach":
                changed = try await runAttachment(p, store: &store, context: context)
            case "search":
                let query = try required(p.arg(0), "search <query>").lowercased()
                let results = store.projects.flatMap { project in
                    project.issues.filter {
                        $0.title.lowercased().contains(query) || $0.body.lowercased().contains(query) ||
                        $0.labels.contains { $0.lowercased().contains(query) }
                    }.map { "\(project.name)#\($0.number) [\($0.status.rawValue)] \($0.title)" }
                }
                print(results.isEmpty ? "(no matches)" : results.joined(separator: "\n"))
            case "overview":
                let open = store.openIssueCount
                print("\(store.projects.count) projects · \(open) open issues · \(store.trash.count) recoverable items")
            default:
                return 2
            }
            if changed {
                var portable = store
                HostLocalProjectPaths.captureAndStrip(&portable)
                try await context.projection.publish(store: portable)
                store = try await context.projection.materializedStore()
            }
            try writeCache(store)
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return error is DistributedRegistryCLIUsageError ? 2 : 1
        }
    }

    private static func runGroup(_ p: CLI.Parsed, store: inout StoreData) throws -> Bool {
        let action = try required(p.arg(0), "group create|delete|add|remove …")
        switch action {
        case "create":
            let name = try required(p.arg(1), "group create <name>")
            if !store.groups.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                store.groups.append(name)
            }
            print("Created group \(name)")
        case "delete":
            let name = try required(p.arg(1), "group delete <name>")
            _ = store.softDeleteGroup(name); print("Deleted group \(name) (recoverable from Trash)")
        case "add", "remove":
            let index = try projectIndex(p.arg(1), in: store)
            let name = try required(p.arg(2), "group \(action) <project> <group>")
            if action == "add" {
                if !store.groups.contains(name) { store.groups.append(name) }
                if !store.projects[index].tags.contains(name) { store.projects[index].tags.append(name) }
            } else { store.projects[index].tags.removeAll { $0 == name } }
            print("Updated groups for \(store.projects[index].name)")
        default: throw DistributedRegistryCLIUsageError.message("group create|delete|add|remove …")
        }
        store.groups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return true
    }

    private static func runTrash(_ p: CLI.Parsed, store: inout StoreData) throws -> Bool {
        switch p.arg(0) ?? "list" {
        case "list":
            if p.has("json") { emitJSON(store.trash) }
            else if store.trash.isEmpty { print("(trash is empty)") }
            else { for item in store.trash { print("\(item.id.uuidString)\t\(item.kindLabel)\t\(item.title)") } }
            return false
        case "restore":
            guard let id = p.arg(1).flatMap(UUID.init(uuidString:)) else {
                throw DistributedRegistryCLIUsageError.message("trash restore <id>")
            }
            store.restoreTrash(id); print("Restored \(id.uuidString)"); return true
        case "empty":
            store.trash.removeAll(); print("Emptied Trash"); return true
        default: throw DistributedRegistryCLIUsageError.message("trash list|restore|empty")
        }
    }

    private static func runIssue(
        _ p: CLI.Parsed, store: inout StoreData, context: Context
    ) async throws -> Bool {
        let action = p.arg(0) ?? "list"
        if action == "list" {
            let pi = try projectIndex(p.arg(1), in: store)
            var issues = store.projects[pi].issues
            if !p.has("all") { issues = issues.filter { $0.status.isOpen } }
            if let value = p.opt("status"), let status = IssueStatus(rawValue: value) { issues = issues.filter { $0.status == status } }
            if let value = p.opt("priority"), let priority = IssuePriority(rawValue: value) { issues = issues.filter { $0.priority == priority } }
            if let label = p.opt("label") { issues = issues.filter { $0.labels.contains(label) } }
            if p.has("json") { emitJSON(issues) }
            else if issues.isEmpty { print("(no issues)") }
            else { for issue in issues.sorted(by: { $0.number < $1.number }) { print("#\(issue.number) [\(issue.status.rawValue)] [\(issue.priority.rawValue)] \(issue.title)") } }
            return false
        }
        if action == "add" {
            let pi = try projectIndex(p.arg(1), in: store)
            let title = try required(p.arg(2), "issue add <project> <title>")
            let priority = IssuePriority(rawValue: p.opt("priority") ?? "none") ?? .none
            let issue = store.addIssue(
                projectID: store.projects[pi].id, title: title, priority: priority,
                body: p.opt("body") ?? "", labels: p.all("label")
            )
            print("Added #\(issue?.number ?? 0) \(title)"); return true
        }
        if action == "label" {
            let add = p.arg(1) == "add"
            let pi = try projectIndex(p.arg(2), in: store)
            let number = try issueNumber(p.arg(3)); let label = try required(p.arg(4), "issue label add|rm <project> <#> <label>")
            _ = store.updateIssue(projectID: store.projects[pi].id, number: number) {
                if add { if !$0.labels.contains(label) { $0.labels.append(label) } }
                else { $0.labels.removeAll { $0.caseInsensitiveCompare(label) == .orderedSame } }
            }
            print("Updated #\(number)"); return true
        }
        let pi = try projectIndex(p.arg(1), in: store)
        let projectID = store.projects[pi].id
        let number = try issueNumber(p.arg(2))
        switch action {
        case "status":
            guard let value = p.arg(3).flatMap(IssueStatus.init(rawValue:)) else { throw DistributedRegistryCLIUsageError.message("issue status <project> <#> <status>") }
            _ = store.setIssueStatus(projectID: projectID, number: number, status: value)
        case "priority":
            guard let value = p.arg(3).flatMap(IssuePriority.init(rawValue:)) else { throw DistributedRegistryCLIUsageError.message("issue priority <project> <#> <priority>") }
            _ = store.setIssuePriority(projectID: projectID, number: number, priority: value)
        case "rm", "remove": _ = store.softDeleteIssue(projectID: projectID, number: number)
        case "parent": _ = store.setIssueParent(projectID: projectID, number: number, parent: p.arg(3) == "none" ? nil : Int(p.arg(3) ?? ""))
        case "milestone":
            let name = try required(p.arg(3), "issue milestone <project> <#> <name|none>")
            let milestone = name == "none" ? nil : store.addMilestone(projectID: projectID, name: name, due: nil)
            _ = store.updateIssue(projectID: projectID, number: number) { $0.milestoneID = milestone?.id }
        case "link", "unlink":
            let kindText = (p.arg(3) ?? "").replacingOccurrences(of: "-", with: "_")
            guard let kind = RelationKind(rawValue: kindText), let target = p.arg(4).flatMap(Int.init) else { throw DistributedRegistryCLIUsageError.message("issue link|unlink <project> <#> <kind> <#>") }
            if action == "link" { _ = store.addRelation(projectID: projectID, from: number, kind: kind, to: target) }
            else { _ = store.removeRelation(projectID: projectID, from: number, kind: kind, to: target) }
        default: throw DistributedRegistryCLIUsageError.message("issue list|add|status|priority|label|milestone|parent|link|unlink|rm")
        }
        print("Updated #\(number)"); return true
    }

    private static func runMilestone(_ p: CLI.Parsed, store: inout StoreData) throws -> Bool {
        let action = p.arg(0) ?? "list"; let pi = try projectIndex(p.arg(1), in: store)
        if action == "list" { emitJSON(store.projects[pi].milestones); return false }
        let name = try required(p.arg(2), "milestone add|rm <project> <name>")
        if action == "add" {
            let due = p.opt("due").flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
            _ = store.addMilestone(projectID: store.projects[pi].id, name: name, due: due)
        } else if action == "rm" || action == "remove" {
            guard let id = store.projects[pi].milestones.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.id else { throw DistributedRegistryCLIError.notFound(name) }
            _ = store.removeMilestone(projectID: store.projects[pi].id, milestoneID: id)
        } else { throw DistributedRegistryCLIUsageError.message("milestone list|add|rm") }
        print("Updated milestones for \(store.projects[pi].name)"); return true
    }

    private static func runUpdate(_ p: CLI.Parsed, store: inout StoreData) throws -> Bool {
        let action = p.arg(0) ?? "list"; let pi = try projectIndex(p.arg(1), in: store)
        if action == "list" { emitJSON(store.projects[pi].updates); return false }
        guard action == "add" else { throw DistributedRegistryCLIUsageError.message("update list|add") }
        let text = p.positional.dropFirst(2).joined(separator: " ")
        _ = store.addUpdate(projectID: store.projects[pi].id, body: text, issueNumber: p.opt("issue").flatMap(Int.init))
        print("Added project update"); return true
    }

    private static func runAttachment(
        _ p: CLI.Parsed, store: inout StoreData, context: Context
    ) async throws -> Bool {
        let action = p.arg(0) ?? "list"; let pi = try projectIndex(p.arg(1), in: store)
        let number = try issueNumber(p.arg(2))
        guard let ii = store.projects[pi].issues.firstIndex(where: { $0.number == number }) else { throw DistributedRegistryCLIError.notFound("issue #\(number)") }
        if action == "list" { emitJSON(store.projects[pi].issues[ii].attachments); return false }
        if action == "add" {
            let files = Array(p.positional.dropFirst(3)) + p.all("file")
            for path in files {
                let file = URL(fileURLWithPath: path).standardizedFileURL
                let data = try Data(contentsOf: file, options: [.mappedIfSafe])
                let ref = try await DistributedAttachmentRegistry(replica: context.replica, group: context.group).put(
                    data: data, name: file.lastPathComponent, mediaType: "application/octet-stream"
                )
                let attachment = try AttachmentStore.add(fileAt: file, toIssue: store.projects[pi].issues[ii].id, distributedReference: ref)
                store.projects[pi].issues[ii].attachments.append(attachment)
            }
            print("Attached \(files.count) file(s)"); return true
        }
        if action == "rm" || action == "remove" {
            let ref = try required(p.arg(3), "attach rm <project> <#> <index|name>")
            if let index = Int(ref), store.projects[pi].issues[ii].attachments.indices.contains(index) { store.projects[pi].issues[ii].attachments.remove(at: index) }
            else { store.projects[pi].issues[ii].attachments.removeAll { $0.originalName == ref || $0.id.uuidString == ref } }
            print("Removed attachment"); return true
        }
        throw DistributedRegistryCLIUsageError.message("attach add|list|rm")
    }

    private struct Context { let replica: MeshLocalReplica; let group: MeshTrustGroupID; let projection: DistributedProjectIssueProjection }
    private static func context() async throws -> Context {
        let replica: MeshLocalReplica
        if let path = ProcessInfo.processInfo.environment["PHAROS_DISTRIBUTED_DATA_DIR"] {
            replica = try MeshLocalReplica.openIsolated(rootURL: URL(fileURLWithPath: path, isDirectory: true))
        } else { replica = try MeshLocalReplica.openDefault() }
        let group = try await replica.ensureActiveTrustGroup()
        return Context(replica: replica, group: group, projection: .init(replica: replica, group: group))
    }

    private static func projectIndex(_ name: String?, in store: StoreData) throws -> Int {
        let name = try required(name, "project name")
        guard let index = store.projects.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name }) else { throw DistributedRegistryCLIError.notFound(name) }
        return index
    }
    private static func issueNumber(_ value: String?) throws -> Int { guard let number = value.flatMap(Int.init) else { throw DistributedRegistryCLIUsageError.message("issue number") }; return number }
    private static func required(_ value: String?, _ usage: String) throws -> String { guard let value, !value.isEmpty else { throw DistributedRegistryCLIUsageError.message(usage) }; return value }
    private static func boolean(_ value: String?) throws -> Bool { switch value?.lowercased() { case "on", "true", "1", "yes": true; case "off", "false", "0", "no": false; default: throw DistributedRegistryCLIUsageError.message("expected on|off") } }
    private static func emitProjects(_ projects: [Project], json: Bool) { if json { emitJSON(projects) } else if projects.isEmpty { print("(no projects)") } else { for project in projects { print("\(project.name)\t\(project.githubRemote ?? project.localPath ?? "—")\t\(project.issues.count) issues") } } }
    private static func emitJSON<T: Encodable>(_ value: T) { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601; if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) } }
    private static func writeCache(_ store: StoreData) throws { var local = store; HostLocalProjectPaths.apply(to: &local); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let url = DataLocation.current.appendingPathComponent("distributed-project-cache.json"); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try encoder.encode(local).write(to: url, options: .atomic) }
}

private enum DistributedRegistryCLIError: LocalizedError { case duplicateProject(String), notFound(String); var errorDescription: String? { switch self { case .duplicateProject(let value): "A project named \(value) already exists."; case .notFound(let value): "Not found: \(value)." } } }
private enum DistributedRegistryCLIUsageError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return "usage: pharos \(value)" }; return nil } }
