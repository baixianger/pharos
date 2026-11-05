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
    /// Presence-only ownership. A session discovered through hooks may prove
    /// which Host owns its live state without claiming tmux control.
    public static let presence = MeshHostAction(rawValue: "agent.presence.v1")!
}

public enum MeshHostResourceState: String, Codable, Sendable {
    case active
    case retired
}

/// Device-local authority record for a process, tmux session, or other runtime
/// handle. Replicas may display it, but only the owning Host advances its
/// generation or decides whether it is active.
public struct MeshHostResource: Codable, Equatable, Sendable {
    public var trustGroupID: MeshTrustGroupID
    public var hostDeviceID: MeshDeviceID
    public var hostEndpointID: MeshEndpointID
    public var resourceID: MeshResourceID
    public var generation: UInt64
    public var allowedActions: [MeshHostAction]
    public var state: MeshHostResourceState
    public var updatedAt: MeshHybridTimestamp

    public init(trustGroupID: MeshTrustGroupID, hostDeviceID: MeshDeviceID,
                hostEndpointID: MeshEndpointID, resourceID: MeshResourceID,
                generation: UInt64, allowedActions: Set<MeshHostAction>,
                state: MeshHostResourceState = .active,
                updatedAt: MeshHybridTimestamp) {
        self.trustGroupID = trustGroupID
        self.hostDeviceID = hostDeviceID
        self.hostEndpointID = hostEndpointID
        self.resourceID = resourceID
        self.generation = generation
        self.allowedActions = allowedActions.sorted { $0.rawValue < $1.rawValue }
        self.state = state
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        guard generation > 0, generation <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidResourceGeneration
        }
        let normalized = Set(allowedActions)
        guard !normalized.isEmpty, normalized.count == allowedActions.count,
              allowedActions == normalized.sorted(by: { $0.rawValue < $1.rawValue }) else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
    }
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
        guard expectedResourceGeneration > 0,
              expectedResourceGeneration <= UInt64(Int64.max) else {
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
    /// Optional only for decoding receipts written before Pharos 2.0 added
    /// crash recovery. New receipts always persist the accepted action.
    public var action: MeshHostAction?
    public var state: MeshCommandReceiptState
    public var acceptedAt: MeshHybridTimestamp
    public var updatedAt: MeshHybridTimestamp
    public var result: Data?
    public var failureCode: String?

    public init(commandID: MeshCommandID, idempotencyKey: String,
                hostDeviceID: MeshDeviceID, resourceID: MeshResourceID,
                resourceGeneration: UInt64, action: MeshHostAction? = nil,
                state: MeshCommandReceiptState,
                acceptedAt: MeshHybridTimestamp, updatedAt: MeshHybridTimestamp,
                result: Data? = nil, failureCode: String? = nil) {
        self.commandID = commandID
        self.idempotencyKey = idempotencyKey
        self.hostDeviceID = hostDeviceID
        self.resourceID = resourceID
        self.resourceGeneration = resourceGeneration
        self.action = action
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

    public func validate() throws {
        guard resourceGeneration > 0,
              resourceGeneration <= UInt64(Int64.max),
              updatedAt >= acceptedAt,
              (result?.count ?? 0) <= DistributedMeshProtocol.maximumHeaderBytes else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
        if let failureCode {
            guard !failureCode.isEmpty, failureCode.utf8.count <= 128,
                  !failureCode.unicodeScalars.contains(
                    where: CharacterSet.controlCharacters.contains
                  ) else { throw MeshSchemaValidationError.invalidStateTransition }
        }
        let fieldsAreConsistent: Bool = switch state {
        case .accepted, .executing:
            result == nil && failureCode == nil
        case .executed:
            failureCode == nil
        case .failed, .rejected, .expired:
            result == nil && failureCode != nil
        }
        guard fieldsAreConsistent else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
    }
}

/// Authentication wrapper for a directed command. The sender Endpoint ID is
/// part of the signed content and must match the trusted device membership at
/// the stated epoch before a Host may persist an acceptance receipt.
public struct MeshSignedHostCommand: Codable, Equatable, Sendable {
    public var command: MeshHostCommand
    public var membershipEpoch: UInt64
    public var senderEndpointID: MeshEndpointID
    public var signature: Data

    public init(command: MeshHostCommand, membershipEpoch: UInt64,
                senderEndpointID: MeshEndpointID, signature: Data = Data()) {
        self.command = command
        self.membershipEpoch = membershipEpoch
        self.senderEndpointID = senderEndpointID
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        try command.validate()
        guard membershipEpoch > 0, membershipEpoch <= UInt64(Int64.max) else {
            throw MeshSchemaValidationError.invalidMembershipEpoch
        }
        if requireSignature, signature.count != 64 {
            throw MeshSchemaValidationError.invalidStateTransition
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshCanonicalJSON.encode(UnsignedCommand(self))
    }

    public func canonicalBytes() throws -> Data { try MeshCanonicalJSON.encode(self) }

    private struct UnsignedCommand: Codable {
        var command: MeshHostCommand
        var membershipEpoch: UInt64
        var senderEndpointID: MeshEndpointID

        init(_ envelope: MeshSignedHostCommand) {
            command = envelope.command
            membershipEpoch = envelope.membershipEpoch
            senderEndpointID = envelope.senderEndpointID
        }
    }
}

/// Host-signed journal truth returned to controllers. `commandFingerprint`
/// binds the receipt to the semantic command even when a retry uses a new
/// command ID with the same idempotency key.
public struct MeshSignedCommandReceipt: Codable, Equatable, Sendable {
    public var receipt: MeshCommandReceipt
    public var trustGroupID: MeshTrustGroupID
    public var hostEndpointID: MeshEndpointID
    public var commandFingerprint: Data
    public var deadlineMilliseconds: Int64
    public var signature: Data

    public init(receipt: MeshCommandReceipt, trustGroupID: MeshTrustGroupID,
                hostEndpointID: MeshEndpointID, commandFingerprint: Data,
                deadlineMilliseconds: Int64, signature: Data = Data()) {
        self.receipt = receipt
        self.trustGroupID = trustGroupID
        self.hostEndpointID = hostEndpointID
        self.commandFingerprint = commandFingerprint
        self.deadlineMilliseconds = deadlineMilliseconds
        self.signature = signature
    }

    public func validateStructure(requireSignature: Bool = true) throws {
        try receipt.validate()
        guard commandFingerprint.count == 32 else {
            throw MeshSchemaValidationError.invalidStateTransition
        }
        if requireSignature, signature.count != 64 {
            throw MeshSchemaValidationError.invalidStateTransition
        }
    }

    public func canonicalSigningBytes() throws -> Data {
        try MeshCanonicalJSON.encode(UnsignedReceipt(self))
    }

    private struct UnsignedReceipt: Codable {
        var receipt: MeshCommandReceipt
        var trustGroupID: MeshTrustGroupID
        var hostEndpointID: MeshEndpointID
        var commandFingerprint: Data
        var deadlineMilliseconds: Int64

        init(_ envelope: MeshSignedCommandReceipt) {
            receipt = envelope.receipt
            trustGroupID = envelope.trustGroupID
            hostEndpointID = envelope.hostEndpointID
            commandFingerprint = envelope.commandFingerprint
            deadlineMilliseconds = envelope.deadlineMilliseconds
        }
    }
}

/// `shouldExecute` is true exactly once: for the transaction that changes an
/// accepted receipt to executing. Replays and crash recovery observe the same
/// signed receipt with `shouldExecute == false`, preventing duplicate effects.
public struct MeshCommandExecutionClaim: Equatable, Sendable {
    public var receipt: MeshSignedCommandReceipt
    public var shouldExecute: Bool

    public init(receipt: MeshSignedCommandReceipt, shouldExecute: Bool) {
        self.receipt = receipt
        self.shouldExecute = shouldExecute
    }
}
