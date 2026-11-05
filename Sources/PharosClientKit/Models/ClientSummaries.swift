import Foundation

/// Activity status of an agent session.
public enum SessionActivityStatus: String, Sendable, Codable, Equatable {
    case idle = "idle"
    case working = "working"
    case needsHuman = "needs_human"
    case stopped = "stopped"
}

/// Summary item representing an active 1:1 agent session in the Sessions tab.
public struct ClientSessionSummary: Sendable, Codable, Equatable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let machineId: String
    public let agentType: String
    public let workspacePath: String
    public let title: String
    public let status: SessionActivityStatus
    public let latestMessagePreview: String?
    public let updatedAt: Date
    public let avatarSeed: String
    public let rawVendorPayload: [String: JSONValue]?

    public init(
        sessionId: String,
        machineId: String,
        agentType: String,
        workspacePath: String,
        title: String,
        status: SessionActivityStatus,
        latestMessagePreview: String? = nil,
        updatedAt: Date = Date(),
        avatarSeed: String,
        rawVendorPayload: [String: JSONValue]? = nil
    ) {
        self.sessionId = sessionId
        self.machineId = machineId
        self.agentType = agentType
        self.workspacePath = workspacePath
        self.title = title
        self.status = status
        self.latestMessagePreview = latestMessagePreview
        self.updatedAt = updatedAt
        self.avatarSeed = avatarSeed
        self.rawVendorPayload = rawVendorPayload
    }
}

/// Summary item representing a multi-agent collaboration thread in the Threads tab.
public struct ClientThreadSummary: Sendable, Codable, Equatable, Identifiable {
    public var id: String { threadId }
    public let threadId: String
    public let title: String
    public let memberIds: [String]
    public let unreadCount: Int
    public let lastActivityAt: Date

    public init(
        threadId: String,
        title: String,
        memberIds: [String] = [],
        unreadCount: Int = 0,
        lastActivityAt: Date = Date()
    ) {
        self.threadId = threadId
        self.title = title
        self.memberIds = memberIds
        self.unreadCount = unreadCount
        self.lastActivityAt = lastActivityAt
    }
}

/// Summary item representing a registered workspace repository in the Projects tab.
public struct ClientProjectSummary: Sendable, Codable, Equatable, Identifiable {
    public var id: String { projectPath }
    public let projectPath: String
    public let name: String
    public let trackedDevices: [String]
    public let activeSessionsCount: Int

    public init(
        projectPath: String,
        name: String,
        trackedDevices: [String] = [],
        activeSessionsCount: Int = 0
    ) {
        self.projectPath = projectPath
        self.name = name
        self.trackedDevices = trackedDevices
        self.activeSessionsCount = activeSessionsCount
    }
}

/// Detailed operational attributes for a roster member.
public struct ClientMemberDetail: Sendable, Codable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let agent: String
    public let machine: String
    public let model: String
    public let mode: String
    public let status: String
    public let tmuxSession: String?
    public let avatarSeed: String

    public init(
        name: String,
        agent: String,
        machine: String,
        model: String,
        mode: String,
        status: String,
        tmuxSession: String? = nil,
        avatarSeed: String
    ) {
        self.name = name
        self.agent = agent
        self.machine = machine
        self.model = model
        self.mode = mode
        self.status = status
        self.tmuxSession = tmuxSession
        self.avatarSeed = avatarSeed
    }
}

/// Persistent identity and avatar customization attributes.
public struct ClientAvatarInfo: Sendable, Codable, Equatable {
    public let seed: String
    public let colorHex: String?
    public let customImageUri: String?

    public init(seed: String, colorHex: String? = nil, customImageUri: String? = nil) {
        self.seed = seed
        self.colorHex = colorHex
        self.customImageUri = customImageUri
    }
}
