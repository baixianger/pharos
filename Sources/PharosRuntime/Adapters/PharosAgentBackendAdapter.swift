import Foundation
import PharosClientKit

/// Injection mode for a session prompt.
public enum PromptMode: String, Sendable, Codable, Equatable {
    /// Queues a regular conversational turn.
    case queue = "queue"
    /// Injects a mid-turn steering prompt while the agent is currently thinking or executing.
    case steer = "steer"
}

/// An unchecked Sendable container wrapping raw dictionary payloads across concurrency isolation boundaries.
public struct BackendWireEvent: @unchecked Sendable {
    public var payload: [String: Any]

    public init(_ payload: [String: Any] = [:]) {
        self.payload = payload
    }

    public subscript(key: String) -> Any? {
        get { payload[key] }
        set { payload[key] = newValue }
    }
}

/// Unified protocol implemented by all vendor backend adapters (`Codex`, `Agy`, `Dsh`).
/// Adheres strictly to RFC-006: Unified Client and Backend Integration.
public protocol PharosAgentBackendAdapter: Sendable {
    var agentKind: String { get }
    var capabilities: BackendCapabilities { get }

    // 1:1 Session Operations
    func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn
    func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn
    func interruptSession(sessionId: String) async throws
    func selectSessionModel(sessionId: String, model: String) async throws
    func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws

    // Thread Roster Operations (plain text mailbox dispatch)
    func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState

    // Live Event Stream
    func observeSessionEvents(sessionId: String) -> AsyncStream<PharosClientEvent>
}

/// Thread-safe registry for managing per-session AsyncStream continuations synchronously.
public final class SessionEventRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [String: [UUID: AsyncStream<PharosClientEvent>.Continuation]] = [:]

    public init() {}

    public func register(sessionId: String, id: UUID, continuation: AsyncStream<PharosClientEvent>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        continuations[sessionId, default: [:]][id] = continuation
    }

    public func remove(sessionId: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        continuations[sessionId]?.removeValue(forKey: id)
    }

    public func emit(_ event: PharosClientEvent, for sessionId: String) {
        lock.lock()
        let targets: [AsyncStream<PharosClientEvent>.Continuation]
        if let map = continuations[sessionId] {
            targets = Array(map.values)
        } else {
            targets = []
        }
        lock.unlock()
        for c in targets {
            c.yield(event)
        }
    }
}
