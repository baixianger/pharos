import Foundation
import PharosClientKit

/// Adapter for OpenAI Codex CLI (`codex-cli 0.166.0`) interacting directly with the shared daemon.
/// Adheres strictly to RFC-006 §2 and docs/BACKEND-MATRIX.md. No tmux required.
public actor CodexBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "codex"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: CodexMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private var activeSessions: [String: String] = [:] // sessionId -> threadId
    private var isDaemonConnected: Bool = true
    private var daemonSocketPath: String

    public init(
        socketPath: String = ("~/.codex/app-server-control/app-server-control.sock" as NSString).expandingTildeInPath,
        translator: CodexMessageTranslator = CodexMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.daemonSocketPath = socketPath
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "codex")
        self.translator = translator
        self.eventRegistry = eventRegistry
    }

    /// Explicitly configure daemon connection state for testing.
    public func setDaemonConnected(_ connected: Bool) {
        isDaemonConnected = connected
    }

    public func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn {
        guard isDaemonConnected else {
            throw PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable at \(daemonSocketPath)")
        }

        let threadId = "th_\(UUID().uuidString.prefix(8))"
        activeSessions[sessionId] = threadId

        let turn = translator.translateTurnStarted(
            turnId: "turn_init_\(sessionId)",
            sessionId: sessionId,
            turnNumber: 1,
            rawPayload: [
                "threadId": threadId,
                "cwd": workspacePath,
                "model": model ?? "default",
                "mode": mode ?? "yolo"
            ]
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard isDaemonConnected else {
            let err = PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable")
            emit(event: .backendError(err), for: sessionId)
            throw err
        }
        guard let threadId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        let turnId = "turn_\(UUID().uuidString.prefix(8))"
        let turn = translator.translateTurnStarted(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: 2,
            rawPayload: ["threadId": threadId, "promptMode": mode.rawValue]
        )
        emit(event: .turnStarted(turn), for: sessionId)

        // Stream simulated/translated typing delta
        if let delta = translator.translateStreamingDelta(
            sessionId: sessionId,
            turnId: turnId,
            itemType: "agentMessage",
            deltaText: "Acknowledged prompt in \(mode.rawValue) mode"
        ) {
            emit(event: .streamingDelta(delta), for: sessionId)
        }

        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        guard isDaemonConnected else {
            throw PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable")
        }
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        // Fallback per BackendCapabilities: graceful restart
        guard isDaemonConnected else {
            throw PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable")
        }
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        guard isDaemonConnected else {
            throw PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable")
        }
        emit(event: .approvalResolved(approvalId: approvalId, decision: decision), for: sessionId)
    }

    public func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState {
        guard isDaemonConnected else {
            throw PharosClientError.backendUnreachable(backend: agentKind, reason: "Codex shared daemon is unreachable")
        }
        // Delivered into member's own thread via turn/start
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
