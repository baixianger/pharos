import Foundation

/// Portable collection values embedded in project/issue field registers.
/// Keeping these wire shapes in the shared protocol target prevents macOS,
/// iOS, and headless clients from silently drifting while the product models
/// remain platform-specific.
public struct MeshProjectPlaybook: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var command: String

    public init(id: String, name: String, command: String) {
        self.id = id
        self.name = name
        self.command = command
    }
}

public struct MeshProjectMilestone: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var due: Date?
    public var createdAt: Date

    public init(id: String, name: String, due: Date?, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.due = due
        self.createdAt = createdAt
    }
}

public struct MeshIssueRelationValue: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(kind):\(target)" }
    public var kind: String
    public var target: Int

    public init(kind: String, target: Int) {
        self.kind = kind
        self.target = target
    }
}

public struct MeshIssueAttachmentValue: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public var storedName: String
    public var originalName: String
    public var isImage: Bool
    public var byteSize: Int
    public var meshAttachment: MeshAttachment?
    public var addedAt: Date

    public init(
        id: String, storedName: String, originalName: String,
        isImage: Bool, byteSize: Int, meshAttachment: MeshAttachment?,
        addedAt: Date
    ) {
        self.id = id
        self.storedName = storedName
        self.originalName = originalName
        self.isImage = isImage
        self.byteSize = byteSize
        self.meshAttachment = meshAttachment
        self.addedAt = addedAt
    }
}
