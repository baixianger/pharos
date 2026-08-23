import Foundation

public enum AgentRuntimeProtocol {
    public static let version = 1
    public static let service = "me.pai.pharos.agent-runtime"
}

public enum AgentRuntimeOwnership: String, Codable, Sendable {
    case managed
    case attached
    case external
}

public enum AgentRuntimeDeliveryState: String, Codable, Sendable {
    case queued
    case accepted
    case injected
    case consumed
    case completed
    case failed
}

public enum AgentSessionPresence: String, Codable, Sendable {
    case connecting, online, offline, stale
}

public enum AgentSessionActivity: String, Codable, Sendable {
    case unknown, idle, running, stopping
}

public enum AgentSessionAttention: String, Codable, Sendable {
    case none, waitingForInput, waitingForApproval, failed
}

public enum AgentSessionPersistence: String, Codable, Sendable {
    case ephemeral, persistent, archived
}

public enum AgentSessionStateSource: String, Codable, Sendable {
    case nativeProtocol, structuredHook, heartbeat, inferred

    public var precedence: Int {
        switch self {
        case .nativeProtocol: 4
        case .structuredHook: 3
        case .heartbeat: 2
        case .inferred: 1
        }
    }
}

public struct AgentSessionState: Codable, Equatable, Sendable {
    public var presence: AgentSessionPresence
    public var activity: AgentSessionActivity
    public var attention: AgentSessionAttention
    public var persistence: AgentSessionPersistence
    public var source: AgentSessionStateSource
    public var sourceEpoch: String?
    public var sequence: UInt64
    public var observedAt: Date
    public var reason: String?
    public var vendorRawState: String?

    public init(presence: AgentSessionPresence, activity: AgentSessionActivity,
                attention: AgentSessionAttention = .none,
                persistence: AgentSessionPersistence = .persistent,
                source: AgentSessionStateSource, sourceEpoch: String? = nil,
                sequence: UInt64 = 0, observedAt: Date = Date(), reason: String? = nil,
                vendorRawState: String? = nil) {
        self.presence = presence
        self.activity = activity
        self.attention = attention
        self.persistence = persistence
        self.source = source
        self.sourceEpoch = sourceEpoch
        self.sequence = sequence
        self.observedAt = observedAt
        self.reason = reason
        self.vendorRawState = vendorRawState
    }
}

public enum AgentSessionAction: String, Codable, CaseIterable, Sendable {
    case view
    case attach
    case resume
    case relaunch
    case fork
    case archive
}

public enum AgentActionAvailabilityState: String, Codable, Sendable {
    case available
    case unavailable
    case unsupported
    case fallback
}

public struct AgentActionAvailability: Codable, Equatable, Sendable {
    public var action: AgentSessionAction
    public var state: AgentActionAvailabilityState
    public var reason: String?
    public var suggestedAction: AgentSessionAction?

    public init(
        action: AgentSessionAction,
        state: AgentActionAvailabilityState,
        reason: String? = nil,
        suggestedAction: AgentSessionAction? = nil
    ) {
        self.action = action
        self.state = state
        self.reason = reason
        self.suggestedAction = suggestedAction
    }
}

public struct AgentAdapterManifest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var agentKind: String
    public var version: String
    public var preferredDriver: String
    public var capabilities: [String]

    public init(
        id: String,
        agentKind: String,
        version: String,
        preferredDriver: String,
        capabilities: [String]
    ) {
        self.id = id
        self.agentKind = agentKind
        self.version = version
        self.preferredDriver = preferredDriver
        self.capabilities = capabilities
    }
}

public struct AgentSurfaceDescriptor: Codable, Equatable, Sendable {
    public var kind: String
    public var preferred: Bool
    public var command: String?
    public var arguments: [String]
    public var detail: String?

    public init(
        kind: String,
        preferred: Bool,
        command: String? = nil,
        arguments: [String] = [],
        detail: String? = nil
    ) {
        self.kind = kind
        self.preferred = preferred
        self.command = command
        self.arguments = arguments
        self.detail = detail
    }
}

public struct AgentRuntimeDriverRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var version: String?
    public var capabilities: [String]
    public var processID: Int32?
    public var connectedAt: Date
    public var lastSeenAt: Date

    public init(id: String, kind: String, version: String?, capabilities: [String],
                processID: Int32?, connectedAt: Date, lastSeenAt: Date) {
        self.id = id
        self.kind = kind
        self.version = version
        self.capabilities = capabilities
        self.processID = processID
        self.connectedAt = connectedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct AgentConversationRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var driverID: String
    public var vendorSessionID: String
    public var kind: String
    public var title: String?
    public var projectPath: String?
    public var memberID: String?
    public var ownership: AgentRuntimeOwnership
    public var state: AgentSessionState?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, driverID: String, vendorSessionID: String, kind: String,
                title: String?, projectPath: String?, memberID: String?,
                ownership: AgentRuntimeOwnership, createdAt: Date, updatedAt: Date,
                state: AgentSessionState? = nil) {
        self.id = id
        self.driverID = driverID
        self.vendorSessionID = vendorSessionID
        self.kind = kind
        self.title = title
        self.projectPath = projectPath
        self.memberID = memberID
        self.ownership = ownership
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct AgentSurfaceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var driverID: String
    public var kind: String
    public var client: String?
    public var attachedAt: Date
    public var lastSeenAt: Date

    public init(id: String, conversationID: String, driverID: String, kind: String,
                client: String?, attachedAt: Date, lastSeenAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.driverID = driverID
        self.kind = kind
        self.client = client
        self.attachedAt = attachedAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct AgentDeliveryRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var idempotencyKey: String
    public var payload: String
    public var state: AgentRuntimeDeliveryState
    public var createdAt: Date
    public var updatedAt: Date
    public var detail: String?

    public init(id: String, conversationID: String, idempotencyKey: String,
                payload: String, state: AgentRuntimeDeliveryState, createdAt: Date,
                updatedAt: Date, detail: String?) {
        self.id = id
        self.conversationID = conversationID
        self.idempotencyKey = idempotencyKey
        self.payload = payload
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.detail = detail
    }
}

public struct AgentRuntimeSnapshot: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var drivers: [AgentRuntimeDriverRecord]
    public var conversations: [AgentConversationRecord]
    public var surfaces: [AgentSurfaceRecord]
    public var deliveries: [AgentDeliveryRecord]

    public init(
        protocolVersion: Int = AgentRuntimeProtocol.version,
        drivers: [AgentRuntimeDriverRecord] = [],
        conversations: [AgentConversationRecord] = [],
        surfaces: [AgentSurfaceRecord] = [],
        deliveries: [AgentDeliveryRecord] = []
    ) {
        self.protocolVersion = protocolVersion
        self.drivers = drivers
        self.conversations = conversations
        self.surfaces = surfaces
        self.deliveries = deliveries
    }
}
