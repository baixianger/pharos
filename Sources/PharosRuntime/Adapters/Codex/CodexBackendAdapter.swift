import Foundation
import PharosClientKit

/// Transport protocol abstracting the communication with the Codex shared daemon.
public protocol CodexTransport: Sendable {
    func call(method: String, params: [String: Any]) async throws -> [String: Any]
    func observeEvents() -> AsyncStream<BackendWireEvent>
    func close()
}

/// Real production transport connecting to the Codex shared daemon via WebSocket over UDS.
/// Wire protocol: RFC-006 §2; app-server at `~/.codex/app-server-control/app-server-control.sock`.
public final class CodexDaemonUdsTransport: CodexTransport, @unchecked Sendable {
    private let client: CodexDaemonClient
    private var eventContinuations: [UUID: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private let lock = NSLock()
    private var pollingTask: Task<Void, Never>?

    public init(socketPath: String = CodexDaemonClient.socketPath()) {
        self.client = CodexDaemonClient(socketPath: socketPath)
        startEventLoop()
    }

    private func startEventLoop() {
        pollingTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    let events = try self.client.waitForEvents(timeout: 0.5)
                    self.lock.withLock {
                        for ev in events {
                            let wireEvent = BackendWireEvent(ev)
                            for cont in self.eventContinuations.values {
                                cont.yield(wireEvent)
                            }
                        }
                    }
                } catch {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    public func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        do {
            return try client.call(method, params)
        } catch let err as CodexDaemonError {
            switch err {
            case .unavailable(let reason):
                throw PharosClientError.backendUnreachable(backend: "codex", reason: "Codex daemon unreachable: \(reason)")
            case .rpc(let code, let msg):
                throw PharosClientError.operationFailed("Codex RPC error (\(code)): \(msg)")
            case .protocolError(let msg):
                throw PharosClientError.operationFailed("Codex protocol error: \(msg)")
            case .timeout:
                throw PharosClientError.connectionFailed("Codex daemon request timed out")
            }
        } catch {
            throw PharosClientError.backendUnreachable(backend: "codex", reason: error.localizedDescription)
        }
    }

    public func observeEvents() -> AsyncStream<BackendWireEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func close() {
        pollingTask?.cancel()
        client.close()
    }
}

/// Simulated transport used exclusively for deterministic unit testing.
public final class SimulatedCodexTransport: CodexTransport, @unchecked Sendable {
    public var isConnected: Bool
    public var calledMethods: [String] = []
    private var eventContinuations: [UUID: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init(isConnected: Bool = true) {
        self.isConnected = isConnected
    }

    public func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isConnected else {
            throw PharosClientError.backendUnreachable(backend: "codex", reason: "Simulated Codex daemon unreachable")
        }
        lock.withLock {
            calledMethods.append(method)
        }
        switch method {
        case "thread/start":
            return ["thread": ["id": "th_sim_\(UUID().uuidString.prefix(6))"]]
        case "turn/start", "turn/steer":
            return ["turn": ["id": "turn_sim_\(UUID().uuidString.prefix(6))"]]
        case "turn/interrupt":
            return [:]
        default:
            return [:]
        }
    }

    public func emitNotification(_ notification: [String: Any]) {
        let wireEvent = BackendWireEvent(notification)
        lock.withLock {
            for cont in eventContinuations.values {
                cont.yield(wireEvent)
            }
        }
    }

    public func observeEvents() -> AsyncStream<BackendWireEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock {
                eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func close() {}
}

/// Adapter for OpenAI Codex CLI (`codex-cli 0.166.0`) interacting directly with the shared daemon.
/// Adheres strictly to RFC-006 §2 and docs/BACKEND-MATRIX.md. No tmux required.
public actor CodexBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "codex"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: CodexMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private let transport: CodexTransport
    private var activeSessions: [String: String] = [:] // sessionId -> threadId
    private var activeTurnIds: [String: String] = [:] // sessionId -> activeTurnId
    private var notificationListenerTask: Task<Void, Never>?

    public init(
        socketPath: String = CodexDaemonClient.socketPath(),
        transport: CodexTransport? = nil,
        translator: CodexMessageTranslator = CodexMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "codex")
        self.translator = translator
        self.eventRegistry = eventRegistry
        self.transport = transport ?? CodexDaemonUdsTransport(socketPath: socketPath)
    }

    private func ensureNotificationObserverStarted() {
        guard notificationListenerTask == nil else { return }
        let stream = self.transport.observeEvents()
        notificationListenerTask = Task { [weak self] in
            guard let self else { return }
            for await rawEvent in stream {
                guard !Task.isCancelled else { break }
                await self.handleDaemonNotification(rawEvent)
            }
        }
    }

    private func handleDaemonNotification(_ event: BackendWireEvent) {
        guard let method = event["method"] as? String else { return }
        let params = event["params"] as? [String: Any]
        let threadId = params?["threadId"] as? String

        // Find associated session
        guard let (sessionId, _) = activeSessions.first(where: { threadId == nil || $0.value == threadId }) else {
            return
        }

        switch method {
        case "turn/started":
            if let turnObj = params?["turn"] as? [String: Any],
               let turnId = turnObj["id"] as? String {
                activeTurnIds[sessionId] = turnId
                let canonicalTurn = translator.translateTurnStarted(
                    turnId: turnId,
                    sessionId: sessionId,
                    turnNumber: 1,
                    rawPayload: turnObj
                )
                emit(event: .turnStarted(canonicalTurn), for: sessionId)
            }

        case "item/agentMessage/delta":
            if let deltaText = params?["delta"] as? String,
               let turnId = params?["turnId"] as? String {
                if let delta = translator.translateStreamingDelta(
                    sessionId: sessionId,
                    turnId: turnId,
                    itemType: "agentMessage",
                    deltaText: deltaText
                ) {
                    emit(event: .streamingDelta(delta), for: sessionId)
                }
            }

        case "item/reasoning/textDelta":
            if let deltaText = params?["delta"] as? String,
               let turnId = params?["turnId"] as? String {
                if let delta = translator.translateStreamingDelta(
                    sessionId: sessionId,
                    turnId: turnId,
                    itemType: "reasoning",
                    deltaText: deltaText
                ) {
                    emit(event: .streamingDelta(delta), for: sessionId)
                }
            }

        case "turn/completed":
            if let turnObj = params?["turn"] as? [String: Any],
               let turnId = turnObj["id"] as? String {
                activeTurnIds.removeValue(forKey: sessionId)
                let status = turnObj["status"] as? String ?? "completed"
                var steps: [CanonicalStep] = []
                if let items = turnObj["items"] as? [[String: Any]] {
                    for (idx, it) in items.enumerated() {
                        if it["type"] as? String == "agentMessage", let text = it["text"] as? String, !text.isEmpty {
                            let block = CanonicalBlock(blockId: it["id"] as? String ?? "blk_\(idx)", kind: .assistantText(text))
                            steps.append(CanonicalStep(stepId: it["id"] as? String ?? "step_\(idx)", stepNumber: idx + 1, status: .completed, blocks: [block]))
                        }
                    }
                }
                let initialTurn = CanonicalTurn(turnId: turnId, sessionId: sessionId, turnNumber: 1, status: .inProgress, steps: steps)
                let canonicalTurn = translator.translateTurnCompleted(
                    currentTurn: initialTurn,
                    status: status,
                    error: turnObj["error"] as? [String: Any],
                    rawPayload: turnObj
                )
                emit(event: .turnCompleted(canonicalTurn), for: sessionId)
            }

        case "item/completed":
            if let item = params?["item"] as? [String: Any],
               let itemType = item["type"] as? String, itemType == "agentMessage",
               let text = item["text"] as? String, !text.isEmpty {
                let turnId = (params?["turnId"] as? String) ?? activeTurnIds[sessionId] ?? "turn_1"
                let block = CanonicalBlock(blockId: item["id"] as? String ?? "blk_\(UUID().uuidString.prefix(6))", kind: .assistantText(text))
                let step = CanonicalStep(stepId: item["id"] as? String ?? "step_1", stepNumber: 1, status: .completed, blocks: [block])
                let canonicalTurn = CanonicalTurn(turnId: turnId, sessionId: sessionId, turnNumber: 1, status: .completed, steps: [step])
                emit(event: .turnCompleted(canonicalTurn), for: sessionId)
            }

        case "item/commandExecution/requestApproval":
            if let approvalId = (event["id"] as? String) ?? (params?["id"] as? String) {
                let approval = CanonicalApprovalRequest(
                    approvalId: approvalId,
                    sessionId: sessionId,
                    kind: .toolPermission(
                        toolName: (params?["command"] as? String) ?? "shell_command",
                        params: ["command": .string((params?["command"] as? String) ?? "")],
                        explanation: (params?["reason"] as? String) ?? "Codex command execution approval"
                    )
                )
                emit(event: .approvalRequired(approval), for: sessionId)
            }

        default:
            break
        }
    }

    public func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn {
        ensureNotificationObserverStarted()
        var params: [String: Any] = [
            "cwd": workspacePath,
            "approvalPolicy": (mode == "yolo") ? "never" : "on-request"
        ]
        if let model = model, !model.isEmpty, model != "default" {
            params["model"] = model
        }
        let res = try await transport.call(method: "thread/start", params: params)
        let threadObj = res["thread"] as? [String: Any]
        let threadId = (threadObj?["id"] as? String) ?? (res["id"] as? String) ?? "th_\(UUID().uuidString.prefix(8))"
        activeSessions[sessionId] = threadId

        var rawPayload: [String: Any] = [
            "threadId": threadId,
            "cwd": workspacePath,
            "mode": mode ?? "yolo"
        ]
        if let model = model, !model.isEmpty, model != "default" {
            rawPayload["model"] = model
        }
        let turn = translator.translateTurnStarted(
            turnId: "turn_init_\(sessionId)",
            sessionId: sessionId,
            turnNumber: 1,
            rawPayload: rawPayload
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard let threadId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        let method: String
        var params: [String: Any] = [
            "threadId": threadId,
            "input": [["type": "text", "text": prompt]]
        ]
        if mode == .steer {
            if let activeTurnId = activeTurnIds[sessionId] {
                method = "turn/steer"
                params["expectedTurnId"] = activeTurnId
            } else {
                method = "turn/start"
            }
        } else {
            method = "turn/start"
        }

        let res = try await transport.call(method: method, params: params)
        let turnObj = res["turn"] as? [String: Any]
        let turnId = (turnObj?["id"] as? String) ?? (res["id"] as? String) ?? (res["turnId"] as? String) ?? "turn_\(UUID().uuidString.prefix(8))"
        activeTurnIds[sessionId] = turnId

        let turn = translator.translateTurnStarted(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: 2,
            rawPayload: ["threadId": threadId, "promptMode": mode.rawValue, "rpcResult": res]
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        guard let threadId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        guard let turnId = activeTurnIds[sessionId] else {
            // No active turn to interrupt; safe no-op
            return
        }
        do {
            _ = try await transport.call(method: "turn/interrupt", params: ["threadId": threadId, "turnId": turnId])
        } catch let err as PharosClientError {
            // If the turn finished before interrupt arrived, treat "no active turn to interrupt" as a benign race completion
            if case .operationFailed(let msg) = err, msg.contains("no active turn to interrupt") {
                // Benign race condition: turn already completed
            } else {
                throw err
            }
        }
        activeTurnIds.removeValue(forKey: sessionId)
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        guard activeSessions[sessionId] != nil else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        // Fallback per BackendCapabilities: graceful restart
    }

    public func setSessionMode(sessionId: String, mode: String) async throws {
        guard let threadId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        // Mode toggle sets approval policy: 'never' for yolo, 'on-request' for safe
        // In accordance with PIT-CX-12 & CX-SES-12
        let policy = (mode.lowercased() == "yolo") ? "never" : "on-request"
        _ = try? await transport.call(method: "thread/setApprovalPolicy", params: ["threadId": threadId, "policy": policy])
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        let decisionStr = (decision.choice == .allowedOnce || decision.choice == .allowedAlways) ? "accept" : "decline"
        _ = try await transport.call(method: "item/commandExecution/replyApproval", params: [
            "id": approvalId,
            "decision": decisionStr
        ])
        emit(event: .approvalResolved(approvalId: approvalId, decision: decision), for: sessionId)
    }

    public func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState {
        let targets = threadId.contains(",")
            ? threadId.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            : [threadId]
        var deliveredCount = 0
        for target in targets {
            let actualThreadId = activeSessions[target] ?? target
            let text = "[\(message.senderName)] \(message.text)"
            let params: [String: Any] = [
                "threadId": actualThreadId,
                "input": [["type": "text", "text": text]]
            ]
            do {
                _ = try await transport.call(method: "turn/start", params: params)
                deliveredCount += 1
            } catch {
                // Individual delivery failure continues fan-out to remaining members
            }
        }
        return deliveredCount > 0 ? .delivered : .unverifiedFallback
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
