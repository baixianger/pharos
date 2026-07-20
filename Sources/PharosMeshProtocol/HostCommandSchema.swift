import Foundation

public struct MeshCommandID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { rawValue = UUID() }
}

public struct MeshResourceID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard MeshSchemaText.isSafeIdentifier(rawValue) else { return nil }
        self.rawValue = rawValue
    }
}

public struct MeshHostAction: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard MeshSchemaText.isSafeToken(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public static let poke = MeshHostAction(rawValue: "agent.poke.v1")!
    public static let stop = MeshHostAction(rawValue: "agent.stop.v1")!
    public static let spawn = MeshHostAction(rawValue: "agent.spawn.v1")!
    public static let attach = MeshHostAction(rawValue: "agent.attach.v1")!
}

/// Directed only to the device that owns the runtime resource. The expected
/// generation prevents a stale command from affecting a replacement session.
public struct MeshHostCommand: Codable, Equatable, Identifiable, Sendable {
    public var id: MeshCommandID
    public var trustGroupID: MeshTrustGroupID
    public var senderDeviceID: MeshDeviceID
    public var targetHostDeviceID: MeshDeviceID
    public var targetHostEndpointID: MeshEndpointID
    public var resourceID: MeshResourceID
    public var expectedResourceGeneration: UInt64
    public var action: MeshHostAction
    public var idempotencyKey: String
    public var createdAt: MeshHybridTimestamp
    public var deadlineMilliseconds: Int64
    public var payload: Data

    public init(id: MeshCommandID = MeshCommandID(), trustGroupID: MeshTrustGroupID,
                senderDeviceID: MeshDeviceID, targetHostDeviceID: MeshDeviceID,
                targetHostEndpointID: MeshEndpointID, resourceID: MeshResourceID,
                expectedResourceGeneration: UInt64, action: MeshHostAction,
                idempotencyKey: String, createdAt: MeshHybridTimestamp,
                deadlineMilliseconds: Int64, payload: Data = Data()) {
        self.id = id
        self.trustGroupID = trustGroupID
        self.senderDeviceID = senderDeviceID
        self.targetHostDeviceID = targetHostDeviceID
        self.targetHostEndpointID = targetHostEndpointID
        self.resourceID = resourceID
        self.expectedResourceGeneration = expectedResourceGeneration
        self.action = action
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.deadlineMilliseconds = deadlineMilliseconds
        self.payload = payload
    }

    public func validate() throws {
        guard expectedResourceGeneration > 0 else {
            throw MeshSchemaValidationError.invalidResourceGeneration
        }
        guard MeshSchemaText.isSafeIdentifier(idempotencyKey) else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
        guard deadlineMilliseconds > createdAt.wallTimeMilliseconds else {
            throw MeshSchemaValidationError.invalidDeadline
        }
        guard payload.count <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSchemaValidationError.payloadTooLarge
        }
    }

    public func canonicalBytes() throws -> Data { try MeshCanonicalJSON.encode(self) }

    /// Stable across retransmission with a replacement command ID. A reused
    /// idempotency key is valid only when these semantic bytes are identical.
    public func canonicalIdempotencyBytes() throws -> Data {
        try MeshCanonicalJSON.encode(IdempotencyContent(command: self))
    }

    private struct IdempotencyContent: Codable {
        var trustGroupID: MeshTrustGroupID
        var senderDeviceID: MeshDeviceID
        var targetHostDeviceID: MeshDeviceID
        var targetHostEndpointID: MeshEndpointID
        var resourceID: MeshResourceID
        var expectedResourceGeneration: UInt64
        var action: MeshHostAction
        var idempotencyKey: String
        var createdAt: MeshHybridTimestamp
        var deadlineMilliseconds: Int64
        var payload: Data

        init(command: MeshHostCommand) {
            trustGroupID = command.trustGroupID
            senderDeviceID = command.senderDeviceID
            targetHostDeviceID = command.targetHostDeviceID
            targetHostEndpointID = command.targetHostEndpointID
            resourceID = command.resourceID
            expectedResourceGeneration = command.expectedResourceGeneration
            action = command.action
            idempotencyKey = command.idempotencyKey
            createdAt = command.createdAt
            deadlineMilliseconds = command.deadlineMilliseconds
            payload = command.payload
        }
    }
}

public enum MeshCommandReceiptState: String, Codable, CaseIterable, Sendable {
    case accepted
    case executing
    case executed
    case failed
    case rejected
    case expired

    public var isTerminal: Bool {
        switch self {
        case .executed, .failed, .rejected, .expired: true
        case .accepted, .executing: false
        }
    }
}

/// Persisted before side effects begin. Re-delivery of a command ID or
/// idempotency key returns this same journal entry rather than executing again.
public struct MeshCommandReceipt: Codable, Equatable, Identifiable, Sendable {
    public var id: MeshCommandID { commandID }
    public var commandID: MeshCommandID
    public var idempotencyKey: String
    public var hostDeviceID: MeshDeviceID
    public var resourceID: MeshResourceID
    public var resourceGeneration: UInt64
    public var state: MeshCommandReceiptState
    public var acceptedAt: MeshHybridTimestamp
    public var updatedAt: MeshHybridTimestamp
    public var result: Data?
    public var failureCode: String?

    public init(commandID: MeshCommandID, idempotencyKey: String,
                hostDeviceID: MeshDeviceID, resourceID: MeshResourceID,
                resourceGeneration: UInt64, state: MeshCommandReceiptState,
                acceptedAt: MeshHybridTimestamp, updatedAt: MeshHybridTimestamp,
                result: Data? = nil, failureCode: String? = nil) {
        self.commandID = commandID
        self.idempotencyKey = idempotencyKey
        self.hostDeviceID = hostDeviceID
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.state = state
        self.acceptedAt = acceptedAt
        self.updatedAt = updatedAt
        self.result = result
        self.failureCode = failureCode
    }

    public func validateTransition(to next: MeshCommandReceiptState) throws {
        let permitted: Bool = switch (state, next) {
        case (.accepted, .executing), (.accepted, .rejected), (.accepted, .expired),
             (.executing, .executed), (.executing, .failed): true
        default: false
        }
        guard permitted else { throw MeshSchemaValidationError.invalidStateTransition }
    }
}
