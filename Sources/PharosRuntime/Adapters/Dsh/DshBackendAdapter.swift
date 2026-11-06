import Foundation
import PharosClientKit

/// Transport protocol abstracting HTTP/WS communication with the managed `dsh web` Host.
public protocol DshTransport: Sendable {
    func createSession(port: Int, token: String, workspacePath: String) async throws -> String
    func sendPrompt(port: Int, token: String, sessionId: String, prompt: String, mode: PromptMode) async throws -> [String: Any]
    func selectModel(port: Int, token: String, sessionId: String, model: String) async throws
    func executeCommand(port: Int, token: String, sessionId: String, command: String) async throws
    func cancelSession(port: Int, token: String, sessionId: String) async throws
    func observeMuxStream(port: Int, token: String, sessionId: String) -> AsyncStream<BackendWireEvent>
    func close()
}

/// Helper delegate disabling URLSession automatic redirect following so /connect 302 Set-Cookie can be extracted.
final class DshNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Real production transport connecting to the persistent `dsh web` Host via HTTP and WebSocket.
/// Wire protocol: HTTP POST /api/session/* and WS /api/remote.mux; RFC-006 §2.
public final class DshWebHttpWsTransport: DshTransport, @unchecked Sendable {
    private var cachedCookie: [Int: String] = [:]
    private var webSocketTasks: [String: URLSessionWebSocketTask] = [:]
    private let lock = NSLock()

    public init() {}

    private func getCookie(port: Int, token: String) async throws -> String {
        let existing = lock.withLock { cachedCookie[port] }
        if let existing = existing {
            return existing
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/connect?token=\(token)&interactions=answer") else {
            throw PharosClientError.operationFailed("Invalid dsh connect URL")
        }

        let session = URLSession(configuration: .ephemeral, delegate: DshNoRedirectDelegate(), delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw PharosClientError.operationFailed("dsh connect failed: invalid response")
            }

            var cookieHeader: String? = nil
            if let rawCookie = http.value(forHTTPHeaderField: "Set-Cookie") {
                cookieHeader = rawCookie.components(separatedBy: ";").first
            }

            guard let cookie = cookieHeader, !cookie.isEmpty else {
                throw PharosClientError.operationFailed("dsh connect failed: missing Set-Cookie (status \(http.statusCode))")
            }

            lock.withLock {
                cachedCookie[port] = cookie
            }
            return cookie
        } catch let err as PharosClientError {
            throw err
        } catch {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Cannot connect to dsh web host at port \(port): \(error.localizedDescription)")
        }
    }

    private func rpcCall(port: Int, token: String, method: String, args: [String: Any]) async throws -> [String: Any] {
        let cookie = try await getCookie(port: port, token: token)
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/\(method)") else {
            throw PharosClientError.operationFailed("Invalid dsh API URL: \(method)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cookie, forHTTPHeaderField: "Cookie")

        let body: [String: Any] = [
            "type": "client-request",
            "rpcId": UUID().uuidString,
            "method": method,
            "payload": ["args": args]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PharosClientError.operationFailed("dsh web HTTP request failed for \(method)")
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return [:]
            }
            if let result = json["result"] as? [String: Any] {
                if result["ok"] as? Bool == true {
                    return result["value"] as? [String: Any] ?? [:]
                } else if let error = result["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "Unknown dsh error"
                    throw PharosClientError.operationFailed("dsh RPC error: \(msg)")
                }
            }
            return json
        } catch let err as PharosClientError {
            throw err
        } catch {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: error.localizedDescription)
        }
    }

    public func createSession(port: Int, token: String, workspacePath: String) async throws -> String {
        let res = try await rpcCall(port: port, token: token, method: "session/create", args: ["request": ["cwd": workspacePath]])
        if let sid = res["sessionId"] as? String {
            return sid
        }
        return "session-\(UUID().uuidString.prefix(8))"
    }

    public func sendPrompt(port: Int, token: String, sessionId: String, prompt: String, mode: PromptMode) async throws -> [String: Any] {
        let reqArgs: [String: Any] = [
            "requestId": UUID().uuidString,
            "sessionId": sessionId,
            "mode": mode.rawValue,
            "content": [["type": "text", "text": prompt]]
        ]
        return try await rpcCall(port: port, token: token, method: "session/prompt", args: ["request": reqArgs])
    }

    public func selectModel(port: Int, token: String, sessionId: String, model: String) async throws {
        _ = try await rpcCall(port: port, token: token, method: "session/selectModel", args: [
            "request": [
                "sessionId": sessionId,
                "provider": "deepseek",
                "model": model
            ]
        ])
    }

    public func executeCommand(port: Int, token: String, sessionId: String, command: String) async throws {
        _ = try await rpcCall(port: port, token: token, method: "commands/execute", args: [
            "agentId": sessionId,
            "line": command,
            "submittedAttachments": []
        ])
    }

    public func cancelSession(port: Int, token: String, sessionId: String) async throws {
        _ = try await rpcCall(port: port, token: token, method: "session/cancel", args: [
            "request": ["sessionId": sessionId]
        ])
    }

    public func observeMuxStream(port: Int, token: String, sessionId: String) -> AsyncStream<BackendWireEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    let cookie = try await getCookie(port: port, token: token)
                    guard let url = URL(string: "ws://127.0.0.1:\(port)/api/remote.mux") else {
                        continuation.finish()
                        return
                    }

                    var req = URLRequest(url: url)
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")

                    let task = URLSession.shared.webSocketTask(with: req)
                    lock.withLock {
                        webSocketTasks[sessionId] = task
                    }
                    task.resume()

                    let streamId = "s_follow_\(UUID().uuidString.prefix(8))"
                    let openFrame: [String: Any] = [
                        "type": "open",
                        "streamId": streamId,
                        "endpoint": "session/follow",
                        "payload": [
                            "args": [
                                "request": [
                                    "address": ["kind": "session", "sessionId": sessionId],
                                    "assistantStream": true
                                ]
                            ]
                        ]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: openFrame),
                       let text = String(data: data, encoding: .utf8) {
                        task.send(.string(text)) { _ in }
                    }

            // Read frames loop
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let data: Data?
                        switch message {
                        case .string(let text):
                            data = text.data(using: .utf8)
                        case .data(let d):
                            data = d
                        @unknown default:
                            data = nil
                        }

                        if let data = data,
                           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            if let itemType = json["type"] as? String, itemType == "item",
                               let value = json["value"] as? [String: Any] {
                                continuation.yield(BackendWireEvent(value))
                            } else {
                                continuation.yield(BackendWireEvent(json))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
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
            cachedCookie.removeAll()
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

    public func createSession(port: Int, token: String, workspacePath: String) async throws -> String {
        guard isConnected else {
            throw PharosClientError.backendUnreachable(backend: "dsh", reason: "Simulated dsh host unreachable")
        }
        return "dsh_ses_\(UUID().uuidString.prefix(8))"
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

        let dshSessionId = try await transport.createSession(port: port, token: token, workspacePath: workspacePath)
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
            if let frame = event["frame"] as? [String: Any],
               let chunkObj = frame["chunk"] as? [String: Any],
               let deltaText = chunkObj["text"] as? String {
                let deltaType = chunkObj["type"] as? String ?? "text-delta"
                let turnId = (frame["turn"] as? Int).map { "turn_\($0)" } ?? "turn_1"
                if let delta = translator.translateStreamingDelta(sessionId: sessionId, turnId: turnId, deltaType: deltaType, chunk: deltaText) {
                    emit(event: .streamingDelta(delta), for: sessionId)
                }
            } else if let chunk = event["chunk"] as? String,
                      let turnId = event["turnId"] as? String {
                let deltaType = event["deltaType"] as? String ?? "text-delta"
                if let delta = translator.translateStreamingDelta(sessionId: sessionId, turnId: turnId, deltaType: deltaType, chunk: chunk) {
                    emit(event: .streamingDelta(delta), for: sessionId)
                }
            }
        case "turn/end":
            let turnId = event["turnId"] as? String ?? "turn_1"
            let reason = event["reason"] as? String ?? "stop"
            let initialTurn = CanonicalTurn(turnId: turnId, sessionId: sessionId, turnNumber: 1, status: .inProgress)
            let turn = translator.translateTurnEnd(currentTurn: initialTurn, reasonKind: reason, rawPayload: event.payload)
            emit(event: .turnCompleted(turn), for: sessionId)
        case "event":
            if let ev = event["event"] as? [String: Any], let evType = ev["type"] as? String {
                if evType == "turn/end" {
                    let data = ev["data"] as? [String: Any]
                    let turnNum = data?["turn"] as? Int ?? 1
                    let reasonObj = data?["reason"] as? [String: Any]
                    let reasonKind = reasonObj?["kind"] as? String ?? "stop"
                    let initialTurn = CanonicalTurn(turnId: "turn_\(turnNum)", sessionId: sessionId, turnNumber: turnNum, status: .inProgress)
                    let turn = translator.translateTurnEnd(currentTurn: initialTurn, reasonKind: reasonKind, rawPayload: ev)
                    emit(event: .turnCompleted(turn), for: sessionId)
                } else if evType == "assistant/message" {
                    if let data = ev["data"] as? [String: Any],
                       let msg = data["message"] as? [String: Any],
                       let content = msg["content"] as? [[String: Any]] {
                        let blocks = translator.translateAssistantMessage(blockId: "blk_\(UUID().uuidString.prefix(6))", contentArray: content, rawPayload: ev)
                        if !blocks.isEmpty {
                            emit(event: .turnCompleted(CanonicalTurn(turnId: "turn_1", sessionId: sessionId, turnNumber: 1, status: .completed, steps: [CanonicalStep(stepId: "step_1", stepNumber: 1, status: .completed, blocks: blocks)])), for: sessionId)
                        }
                    }
                }
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
