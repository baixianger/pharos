import Foundation
import PharosMeshCore

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

public struct AgentRuntimeDriverRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: String
    public var version: String?
    public var capabilities: [String]
    public var processID: Int32?
    public var connectedAt: Date
    public var lastSeenAt: Date
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
    public var createdAt: Date
    public var updatedAt: Date
}

public struct AgentSurfaceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var conversationID: String
    public var driverID: String
    public var kind: String
    public var client: String?
    public var attachedAt: Date
    public var lastSeenAt: Date
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

public enum AgentRuntimePaths {
    public static var directory: URL {
        MeshPaths.supportDir.appendingPathComponent("Runtime", isDirectory: true)
    }

    public static var socket: URL {
        if let override = ProcessInfo.processInfo.environment["PHAROS_AGENT_RUNTIME_SOCKET"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return directory.appendingPathComponent("agent-runtime.sock")
    }

    public static var registry: URL {
        directory.appendingPathComponent("agent-runtime-registry.json")
    }
}
