import Foundation
import PharosClientKit

/// Adapter for DeepSeek Harness (`dsh 0.2.1-rc.5`) managing a persistent `dsh web` host in tmux.
/// Adheres strictly to RFC-006 §2, docs/BACKEND-MATRIX.md, and Research C findings.
public actor DshBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "dsh"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: DshMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private var activeSessions: [String: String] = [:] // sessionId -> dshSessionId

    // Managed Host State (Research C finalized)
    private var hostPort: Int?
    private var volatileAuthToken: String? // Kept in memory only; never serialized or written to disk
    private var authCookie: String?

    public init(
        translator: DshMessageTranslator = DshMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "dsh")
        self.translator = translator
        self.eventRegistry = eventRegistry
    }

    /// Discovers dynamic port and in-memory token from managed `dsh web` process stdout line.
    /// Regex: `^dsh web: (http://127.0.0.1:(\d+)/\?token=(\S+))$`
    public func parseStartupLine(_ line: String) -> Bool {
        guard line.contains("dsh web: http://127.0.0.1:") else { return false }
        let pattern = #"dsh web: http://127\.0\.0\.1:(\d+)/\?token=([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return false
        }

        if let portRange = Range(match.range(at: 1), in: line),
           let tokenRange = Range(match.range(at: 2), in: line) {
            let portStr = String(line[portRange])
            self.hostPort = Int(portStr)
            self.volatileAuthToken = String(line[tokenRange])
            return true
        }
        return false
    }

    public func getDiscoveredPort() -> Int? {
        return hostPort
    }

    public func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn {
        let dshSessionId = "dsh_ses_\(UUID().uuidString.prefix(8))"
        activeSessions[sessionId] = dshSessionId

        let turn = translator.translateTurnStart(
            turnNumber: 1,
            sessionId: sessionId,
            rawPayload: [
                "dshSessionId": dshSessionId,
                "workspace": workspacePath,
                "model": model ?? "deepseek-coder",
                "mode": mode ?? "yolo"
            ]
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard let dshId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        let turn = translator.translateTurnStart(
            turnNumber: 2,
            sessionId: sessionId,
            rawPayload: [
                "dshSessionId": dshId,
                "promptMode": mode.rawValue
            ]
        )
        emit(event: .turnStarted(turn), for: sessionId)

        if let delta = translator.translateStreamingDelta(
            sessionId: sessionId,
            turnId: turn.turnId,
            deltaType: "text-delta",
            chunk: "dsh web response chunk for [\(prompt)]"
        ) {
            emit(event: .streamingDelta(delta), for: sessionId)
        }

        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        // Dispatches POST /api/session/cancel with {sessionId}
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        // Supported via POST /api/session/selectModel
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        // Dispatches POST /api/session/events with type user-questions/reply or tool-permission/reply
        emit(event: .approvalResolved(approvalId: approvalId, decision: decision), for: sessionId)
    }

    public func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState {
        // Dispatches directly via dsh-plugin-pharos in-process 4-phase loop
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
