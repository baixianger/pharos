import Foundation
import PharosClientKit

/// Transport protocol abstracting the communication with the Antigravity ACP stdio server.
public protocol AgyTransport: Sendable {
    func sendRequest(method: String, params: [String: Any]) async throws -> BackendWireEvent
    func observeEvents() -> AsyncStream<BackendWireEvent>
    func close()
}

/// Real production transport spawning and managing the `agy acp --stdio` child process.
/// Wire protocol: JSON-RPC 2.0 over stdio; RFC-006 §2.
public final class AgyAcpProcessTransport: AgyTransport, @unchecked Sendable {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<BackendWireEvent, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private let lock = NSLock()
    private var isInitialized: Bool = false

    public init() {
        startProcess()
    }

    private func startProcess() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/agy")
        if !FileManager.default.fileExists(atPath: proc.executableURL?.path ?? "") {
            proc.executableURL = URL(fileURLWithPath: "/usr/local/bin/agy")
        }
        proc.arguments = ["acp", "--stdio"]

        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        do {
            try proc.run()
            startReadingStdout(stdout)
        } catch {
            // Process launch failure handled gracefully on first sendRequest
        }
    }

    private func startReadingStdout(_ pipe: Pipe) {
        Task.detached { [weak self] in
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                guard let self else { break }
                buffer.append(chunk)
                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                    if let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                        self.handleIncomingJson(json)
                    }
                }
            }
        }
    }

    private func handleIncomingJson(_ json: [String: Any]) {
        lock.withLock {
            // Response with id
            if let id = json["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    let msg = error["message"] as? String ?? "ACP error"
                    continuation.resume(throwing: PharosClientError.operationFailed(msg))
                } else if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: BackendWireEvent(result))
                } else {
                    continuation.resume(returning: BackendWireEvent(json))
                }
                return
            }

            // Notification: broadcast to active continuations
            let wireEvent = BackendWireEvent(json)
            for cont in eventContinuations.values {
                cont.yield(wireEvent)
            }
        }
    }

    public func sendRequest(method: String, params: [String: Any]) async throws -> BackendWireEvent {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe else {
            throw PharosClientError.backendUnreachable(backend: "agy", reason: "agy acp --stdio child process is not running")
        }

        let reqId: Int = lock.withLock {
            let id = nextRequestId
            nextRequestId += 1
            return id
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqId,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: payload)
        var lineData = data
        lineData.append(contentsOf: [0x0A])

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pendingRequests[reqId] = continuation
            }

            do {
                try stdin.fileHandleForWriting.write(contentsOf: lineData)
            } catch {
                lock.withLock {
                    _ = pendingRequests.removeValue(forKey: reqId)
                }
                continuation.resume(throwing: PharosClientError.backendUnreachable(backend: "agy", reason: error.localizedDescription))
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

    public func close() {
        process?.terminate()
        process = nil
    }
}

/// Simulated transport for Antigravity ACP unit testing.
public final class SimulatedAgyTransport: AgyTransport, @unchecked Sendable {
    public var isConnected: Bool
    private var eventContinuations: [UUID: AsyncStream<BackendWireEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init(isConnected: Bool = true) {
        self.isConnected = isConnected
    }

    public func sendRequest(method: String, params: [String: Any]) async throws -> BackendWireEvent {
        guard isConnected else {
            throw PharosClientError.backendUnreachable(backend: "agy", reason: "Simulated agy process unreachable")
        }
        switch method {
        case "initialize":
            return BackendWireEvent(["protocolVersion": 1, "agentInfo": ["name": "Antigravity ACP Server", "version": "1.5.1"]])
        case "session/prompt":
            return BackendWireEvent(["turnId": "turn_agy_\(UUID().uuidString.prefix(6))"])
        case "session/set_config_option":
            return BackendWireEvent(["status": "ok"])
        default:
            return BackendWireEvent([:])
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

/// Adapter for Antigravity CLI (`agy 1.5.1`) holding a long-running ACP stdio child process.
/// Adheres strictly to RFC-006 §2 and docs/BACKEND-MATRIX.md.
public actor AgyBackendAdapter: PharosAgentBackendAdapter {
    public nonisolated let agentKind: String = "agy"
    public nonisolated let capabilities: BackendCapabilities
    public nonisolated let translator: AgyMessageTranslator
    public nonisolated let eventRegistry: SessionEventRegistry

    private let transport: AgyTransport
    private var activeSessions: [String: String] = [:] // sessionId -> conversationId
    private var notificationListenerTask: Task<Void, Never>?

    public init(
        transport: AgyTransport? = nil,
        translator: AgyMessageTranslator = AgyMessageTranslator(),
        eventRegistry: SessionEventRegistry = SessionEventRegistry()
    ) {
        self.capabilities = BackendCapabilityRegistry.shared.capabilities(for: "agy")
        self.translator = translator
        self.eventRegistry = eventRegistry
        self.transport = transport ?? AgyAcpProcessTransport()
    }

    private func ensureNotificationObserverStarted() {
        guard notificationListenerTask == nil else { return }
        let stream = self.transport.observeEvents()
        notificationListenerTask = Task { [weak self] in
            guard let self else { return }
            for await rawEvent in stream {
                guard !Task.isCancelled else { break }
                await self.handleAcpNotification(rawEvent)
            }
        }
    }

    private func handleAcpNotification(_ event: BackendWireEvent) {
        guard let method = event["method"] as? String else { return }
        let params = event["params"] as? [String: Any]
        let sessionId = params?["sessionId"] as? String ?? activeSessions.keys.first ?? "ses_default"

        switch method {
        case "session/update":
            if let chunk = params?["chunk"] as? String,
               let turnId = params?["turnId"] as? String {
                let delta = translator.translateStreamingChunk(sessionId: sessionId, turnId: turnId, chunk: chunk)
                emit(event: .streamingDelta(delta), for: sessionId)
            }

        case "session/request_permission":
            let approvalId = (event["id"] as? String) ?? (params?["id"] as? String) ?? "appr_\(UUID().uuidString.prefix(6))"
            let toolName = (params?["toolName"] as? String) ?? (params?["tool"] as? String) ?? "execute"
            let req = translator.translatePermissionRequest(
                approvalId: approvalId,
                sessionId: sessionId,
                toolName: toolName,
                params: ["command": toolName],
                rawPayload: params
            )
            emit(event: .approvalRequired(req), for: sessionId)

        default:
            break
        }
    }

    public func startSession(sessionId: String, workspacePath: String, model: String?, mode: String?) async throws -> CanonicalTurn {
        ensureNotificationObserverStarted()
        let conversationId = "conv_\(UUID().uuidString.prefix(8))"
        activeSessions[sessionId] = conversationId

        let params: [String: Any] = [
            "sessionId": conversationId,
            "cwd": workspacePath,
            "model": model ?? "gemini-2.5-pro",
            "dangerouslySkipPermissions": (mode == "yolo")
        ]
        _ = try await transport.sendRequest(method: "initialize", params: [:])

        let turn = translator.translatePromptStart(
            turnId: "turn_init_\(sessionId)",
            sessionId: sessionId,
            turnNumber: 1,
            rawPayload: params
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func sendSessionPrompt(sessionId: String, prompt: String, mode: PromptMode) async throws -> CanonicalTurn {
        guard let convId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }

        let params: [String: Any] = [
            "sessionId": convId,
            "prompt": [["type": "text", "text": prompt]],
            "mode": mode.rawValue
        ]
        let res = try await transport.sendRequest(method: "session/prompt", params: params)
        let turnId = (res["turnId"] as? String) ?? "turn_\(UUID().uuidString.prefix(8))"

        let turn = translator.translatePromptStart(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: 2,
            rawPayload: params
        )
        emit(event: .turnStarted(turn), for: sessionId)
        return turn
    }

    public func interruptSession(sessionId: String) async throws {
        guard let convId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        _ = try await transport.sendRequest(method: "session/cancel", params: ["sessionId": convId])
    }

    public func selectSessionModel(sessionId: String, model: String) async throws {
        guard let convId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        // Hot swap in-session via ACP session/set_config_option
        _ = try await transport.sendRequest(method: "session/set_config_option", params: [
            "sessionId": convId,
            "config": ["model": model]
        ])
    }

    public func resolveApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        guard let convId = activeSessions[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        let approved = (decision.choice == .allowedOnce || decision.choice == .allowedAlways)
        _ = try await transport.sendRequest(method: "session/request_permission/reply", params: [
            "sessionId": convId,
            "requestId": approvalId,
            "approved": approved
        ])
        emit(event: .approvalResolved(approvalId: approvalId, decision: decision), for: sessionId)
    }

    public func deliverThreadMessage(threadId: String, message: ClientThreadMessage) async throws -> DeliveryReceiptState {
        // Mailbox delivers over same ACP connection into member's session
        _ = try await transport.sendRequest(method: "session/prompt", params: [
            "sessionId": threadId,
            "prompt": [["type": "text", "text": message.text]]
        ])
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
