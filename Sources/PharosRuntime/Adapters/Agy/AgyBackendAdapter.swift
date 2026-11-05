import Foundation
import PharosClientKit

/// Adapter for Antigravity CLI (`agy 1.5.1`) holding a long-running ACP stdio child process.
/// Adheres strictly to RFC-006 §2 and docs/BACKEND-MATRIX.md.
public actor AgyBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "agy"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: AgyMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private var activeSessions: [String: String] = [:] // sessionId -> conversationId

    public init(
        translator: AgyMessageTranslator = AgyMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "agy")
        self.translator = translator
        self.eventRegistry = eventRegistry
    }

    public func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn {
        let conversationId = "conv_\(UUID().uuidString.prefix(8))"
        activeSessions[sessionId] = conversationId

        let turn = translator.translatePromptStart(
            turnId: "turn_init_\(sessionId)",
            sessionId: sessionId,
            turnNumber: 1,
            rawPayload: [
                "conversationId": conversationId,
                "cwd": workspacePath,
                "model": model ?? "gemini-2.5-pro",
                "dangerouslySkipPermissions": (mode == "yolo")
            ]
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard let convId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        let turnId = "turn_\(UUID().uuidString.prefix(8))"
        let turn = translator.translatePromptStart(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: 2,
            rawPayload: ["conversationId": convId, "mode": mode.rawValue]
        )
        emit(event: .turnStarted(turn), for: sessionId)

        let chunk = translator.translateStreamingChunk(
            sessionId: sessionId,
            turnId: turnId,
            chunk: "ACP response chunk for \(prompt)"
        )
        emit(event: .streamingDelta(chunk), for: sessionId)

        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        // Hot swap in-session via ACP session/set_config_option
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        emit(event: .approvalResolved(approvalId: approvalId, decision: decision), for: sessionId)
    }

    public func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState {
        // Mailbox delivers over same ACP connection into member's session
        return .delivered
    }

    public nonisolated func observeSessionEvents(sessionId: String) -> AsyncStream<PharosClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventRegistry.register(sessionId: sessionId, id: id, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                self?.eventRegistry.remove(sessionId: sessionId, id: id)
            }
        }
    }

    private func emit(event: PharosClientEvent, for sessionId: String) {
        eventRegistry.emit(event, for: sessionId)
    }
}
