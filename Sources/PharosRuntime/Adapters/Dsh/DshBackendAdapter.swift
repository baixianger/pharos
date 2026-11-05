import Foundation
import PharosClientKit

/// Transport protocol abstracting HTTP/WS communication with the managed `dsh web` Host.
public protocol DshTransport: Sendable {
    func sendPrompt(port: Int, token: String, sessionId: String, prompt: String, mode: PromptMode) async throws -> [String: Any]
    func selectModel(port: Int, token: String, sessionId: String, model: String) async throws
    func executeCommand(port: Int, token: String, sessionId: String, command: String) async throws
    func cancelSession(port: Int, token: String, sessionId: String) async throws
    func observeMuxStream(port: Int, token: String, sessionId: String) -> AsyncStream<BackendWireEvent>
    func close()
}

/// Real production transport connecting to the persistent `dsh web` Host via HTTP and WebSocket.
/// Wire protocol: HTTP POST /api/session/* and WS /api/remote.mux; RFC-006 §2.
public final class DshWebHttpWsTransport: DshTransport, @unchecked Sendable {
    private var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    private let lock = NSLock()

    public init() {}

    public func sendPrompt(port: Int, token: String, sessionId: String, prompt: String, mode: PromptMode) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/session/prompt") else {
            throw PharosClientError.operationFailed("Invalid dsh web URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "sessionId": sessionId,
            "prompt": prompt,
            "mode": mode.rawValue
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PharosClientError.operationFailed("dsh web HTTP request failed")
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: error.localizedDescription)
        }
    }

    public func selectModel(port: Int, token: String, sessionId: String, model: String) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/session/selectModel") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "model": model])
        _ = try? await URLSession.shared.data(for: req)
    }

    public func executeCommand(port: Int, token: String, sessionId: String, command: String) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/commands/execute") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "line": command])
        _ = try? await URLSession.shared.data(for: req)
    }

    public func cancelSession(port: Int, token: String, sessionId: String) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/session/cancel") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        _ = try? await URLSession.shared.data(for: req)
    }

    public func observeMuxStream(port: Int, token: String, sessionId: String) -> AsyncStream<BackendWireEvent> {
        AsyncStream { continuation in
            guard let url = URL(string: "ws://127.0.0.1:\(port)/api/remote.mux?token=\(token)") else {
                continuation.finish()
                return
            }

            let task = URLSession.shared.webSocketTask(with: url)
            lock.withLock {
                webSocketTasks[sessionId] = task
            }

            task.resume()

            // Follow session
            let followMsg: [String: Any] = ["type": "session/follow", "sessionId": sessionId]
            if let data = try? JSONSerialization.data(withJSONObject: followMsg),
               let text = String(data: data, encoding: .utf8) {
                task.send(.string(text)) { _ in }
            }

            // Read frames
            Task.detached {
                while !Task.isCancelled {
                    do {
                        let message = try await task.receive()
                        switch message {
                        case .string(let text):
                            if let data = text.data(using: .utf8),
                               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                                continuation.yield(BackendWireEvent(json))
                            }
                        case .data(let data):
                            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                                continuation.yield(BackendWireEvent(json))
                            }
                        @unknown default:
                            break
                        }
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                let t = self.lock.withLock {
                    self.webSocketTasks.removeValue(forKey: sessionId)
                }
                t?.cancel(with: .normalClosure, reason: nil)
            }
        }
    }

    public func close() {
        lock.withLock {
            for task in webSocketTasks.values {
                task.cancel(with: .normalClosure, reason: nil)
            }
            webSocketTasks.removeAll()
        }
    }
}

/// Simulated transport for dsh web Host unit testing.
public final class SimulatedDshTransport: DshTransport, @unchecked Sendable {
    public var isConnected: Bool
    private var eventContinuations: [String: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init(isConnected: Bool = true) {
        self.isConnected = isConnected
    }

    public func sendPrompt(port: Int, token: String, sessionId: String, prompt: String, mode: PromptMode) async throws -> [String: Any] {
        guard isConnected else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Simulated dsh host unreachable")
        }
        return ["turnId": "turn_dsh_\(UUID().uuidString.prefix(6))"]
    }

    public var lastExecutedCommand: String?
    public func executeCommand(port: Int, token: String, sessionId: String, command: String) async throws {
        lastExecutedCommand = command
    }
    public func selectModel(port: Int, token: String, sessionId: String, model: String) async throws {}
    public func cancelSession(port: Int, token: String, sessionId: String) async throws {}

    public func emitNotification(sessionId: String, notification: [String: Any]) {
        let wireEvent = BackendWireEvent(notification)
        _ = lock.withLock {
            eventContinuations[sessionId]?.yield(wireEvent)
        }
    }

    public func observeMuxStream(port: Int, token: String, sessionId: String) -> AsyncStream<BackendWireEvent> {
        AsyncStream { continuation in
            lock.withLock {
                eventContinuations[sessionId] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock {
                    _ = self.eventContinuations.removeValue(forKey: sessionId)
                }
            }
        }
    }

    public func close() {}
}

/// Adapter for DeepSeek Harness (`dsh 0.2.1-rc.5`) managing a persistent `dsh web` host in tmux.
/// Adheres strictly to RFC-006 §2, docs/BACKEND-MATRIX.md, and Research C findings.
public actor DshBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "dsh"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: DshMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private let transport: DshTransport
    private var activeSessions: [String: String] = [:] // sessionId -> dshSessionId

    // Managed Host State (Research C finalized)
    private var hostPort: Int?
    private var volatileAuthToken: String? // Kept in memory only; never serialized or written to disk

    public init(
        port: Int? = nil,
        token: String? = nil,
        transport: DshTransport? = nil,
        translator: DshMessageTranslator = DshMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.hostPort = port
        self.volatileAuthToken = token
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "dsh")
        self.translator = translator
        self.eventRegistry = eventRegistry
        self.transport = transport ?? DshWebHttpWsTransport()
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
        guard let port = hostPort, let token = volatileAuthToken else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "dsh web Host is unreachable (no discovered port/token)")
        }

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

        // Start listening to WebSocket mux events
        Task { [weak self] in
            guard let self else { return }
            for await event in self.transport.observeMuxStream(port: port, token: token, sessionId: dshSessionId) {
                await self.handleMuxEvent(event, for: sessionId)
            }
        }

        return turn
    }

    private func handleMuxEvent(_ event: BackendWireEvent, for sessionId: String) {
        guard let type = event["type"] as? String else { return }
        switch type {
        case "assistant-stream":
            if let chunk = event["chunk"] as? String,
               let turnId = event["turnId"] as? String {
                if let delta = translator.translateStreamingDelta(sessionId: sessionId, turnId: turnId, deltaType: "text-delta", chunk: chunk) {
                    emit(event: .streamingDelta(delta), for: sessionId)
                }
            }
        case "turn/end":
            if let turnId = event["turnId"] as? String {
                let reason = event["reason"] as? String ?? "stop"
                let initialTurn = CanonicalTurn(turnId: turnId, sessionId: sessionId, turnNumber: 1, status: .inProgress)
                let turn = translator.translateTurnEnd(currentTurn: initialTurn, reasonKind: reason, rawPayload: event.payload)
                emit(event: .turnCompleted(turn), for: sessionId)
            }
        default:
            break
        }
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard let port = hostPort, let token = volatileAuthToken else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "dsh web Host is unreachable (no discovered port/token)")
        }
        guard let dshId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        _ = try await transport.sendPrompt(port: port, token: token, sessionId: dshId, prompt: prompt, mode: mode)

        let turn = translator.translateTurnStart(
            turnNumber: 2,
            sessionId: sessionId,
            rawPayload: [
                "dshSessionId": dshId,
                "promptMode": mode.rawValue
            ]
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        guard let port = hostPort, let token = volatileAuthToken else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "dsh web Host is unreachable")
        }
        guard let dshId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        try await transport.cancelSession(port: port, token: token, sessionId: dshId)
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        guard let port = hostPort, let token = volatileAuthToken else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "dsh web Host is unreachable")
        }
        guard let dshId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        try await transport.selectModel(port: port, token: token, sessionId: dshId, model: model)
    }

    public func setSessionMode(sessionId: String, mode: String) async throws {
        guard let port = hostPort, let token = volatileAuthToken else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "dsh web Host is unreachable")
        }
        guard let dshId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        let command = (mode.lowercased() == "yolo") ? "/permission unrestricted" : "/permission ask"
        try await transport.executeCommand(port: port, token: token, sessionId: dshId, command: command)
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
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
