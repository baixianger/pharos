import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP/WS implementation of `PharosClientService` against the S4 Rust API
/// (`pharos-api` CONTRACTS_VERSION 0.1.0, base URL `http://127.0.0.1:<port>/`).
///
/// Foundation-only — no MeshCore / Runtime imports (ArchitectureBoundary).
public actor HttpPharosClientService: PharosClientService {
    public let configuration: PharosAPIConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder

    private var eventContinuations: [UUID: AsyncStream<PharosClientEvent>.Continuation] = [:]
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketPump: Task<Void, Never>?

    public init(
        configuration: PharosAPIConfiguration = .resolve(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.decoder = JSONDecoder()
    }

    deinit {
        webSocketPump?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - PharosClientService

    public func fetchSessions() async throws -> [ClientSessionSummary] {
        let wire: [APISessionSummary] = try await getJSON(path: "api/v1/sessions")
        return wire.map { $0.asClient() }
    }

    public func fetchThreads() async throws -> [ClientThreadSummary] {
        let wire: [APIThreadSummary] = try await getJSON(path: "api/v1/threads")
        return wire.map { $0.asClient() }
    }

    public func fetchProjects() async throws -> [ClientProjectSummary] {
        let wire: [APIProjectSummary] = try await getJSON(path: "api/v1/projects")
        return wire.map { $0.asClient() }
    }

    public func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
        let encoded = Self.encodePathComponent(sessionId)
        let wire: [APICanonicalTurn] = try await getJSON(path: "api/v1/sessions/\(encoded)/history")
        return wire.map { $0.asClient() }
    }

    public func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress? {
        try await getJSON(path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/progress")
    }

    public func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn {
        guard files.isEmpty else { throw PharosClientError.operationFailed("Session attachments are unavailable in the Rust API") }
        let wire: APICanonicalTurn = try await postJSON(
            path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/messages",
            body: ["text": text, "requestId": requestId]
        )
        let turn = wire.asClient()
        if turn.status == .inProgress { broadcast(.turnStarted(turn)) }
        else { broadcast(.turnCompleted(turn)) }
        return turn
    }

    public func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] {
        let encoded = Self.encodePathComponent(threadId)
        let wire: [APIThreadMessage] = try await getJSON(path: "api/v1/threads/\(encoded)/messages")
        return wire.map { $0.asClient() }
    }

    public func fetchMemberDetail(name: String) async throws -> ClientMemberDetail {
        throw PharosClientError.operationFailed(
            "Member detail is not exposed on pharos-api 0.1.0 (\(name))"
        )
    }

    public func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
        let encoded = Self.encodePathComponent(sessionId)
        let body: [String: String] = ["text": text]
        let wire: APICanonicalTurn = try await postJSON(
            path: "api/v1/sessions/\(encoded)/messages",
            body: body
        )
        let turn = wire.asClient()
        if turn.status == .inProgress { broadcast(.turnStarted(turn)) }
        else { broadcast(.turnCompleted(turn)) }
        return turn
    }

    public func steerSession(sessionId: String, text: String) async throws {
        let encoded = Self.encodePathComponent(sessionId)
        let body: [String: String] = ["text": text]
        let _: [String: Bool] = try await postJSON(
            path: "api/v1/sessions/\(encoded)/steer",
            body: body
        )
    }

    public func resolveSessionApproval(
        sessionId: String,
        approvalId: String,
        decision: ApprovalDecision
    ) async throws {
        let encoded = Self.encodePathComponent(sessionId)
        guard decision.answers?.isEmpty != false else {
            throw PharosClientError.operationFailed("Questionnaire answers are unavailable in the Rust API")
        }
        guard let apiDecision = decision.choice.apiDecisionValue else {
            throw PharosClientError.operationFailed("This approval choice is unavailable in the Rust API")
        }
        let body: [String: String] = [
            "approvalId": approvalId,
            "decision": apiDecision,
        ]
        let _: [String: Bool] = try await postJSON(
            path: "api/v1/sessions/\(encoded)/approval",
            body: body
        )
        broadcast(.approvalResolved(approvalId: approvalId, decision: decision))
    }

    public func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage {
        let encoded = Self.encodePathComponent(threadId)
        let body: [String: String] = ["text": text]
        let wire: APIThreadMessage = try await postJSON(
            path: "api/v1/threads/\(encoded)/messages",
            body: body
        )
        let message = wire.asClient()
        broadcast(.threadMessageReceived(message))
        return message
    }

    public func setMemberMode(name: String, mode: String) async throws {
        throw PharosClientError.operationFailed(
            "setMemberMode not on pharos-api 0.1.0 (\(name)/\(mode))"
        )
    }

    public func setMemberModel(name: String, model: String) async throws {
        throw PharosClientError.operationFailed(
            "setMemberModel not on pharos-api 0.1.0 (\(name)/\(model))"
        )
    }

    public func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws {
        throw PharosClientError.operationFailed(
            "setMemberAvatar not on pharos-api 0.1.0 (\(name)/\(avatar.seed))"
        )
    }

    public func stopMember(name: String) async throws {
        throw PharosClientError.operationFailed(
            "stopMember not on pharos-api 0.1.0 (\(name))"
        )
    }

    public func reviveMember(name: String) async throws {
        throw PharosClientError.operationFailed(
            "reviveMember not on pharos-api 0.1.0 (\(name))"
        )
    }

    public nonisolated func events() -> AsyncStream<PharosClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { [weak self] in
                await self?.registerContinuation(id: id, continuation: continuation)
                await self?.ensureWebSocket()
            }
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    /// Probe `GET /health` (used by smoke / wiring checks).
    public func fetchHealth() async throws -> (ok: Bool, contractsVersion: String, service: String) {
        let health: APIHealthResponse = try await getJSON(path: "health")
        return (health.ok, health.contractsVersion, health.service)
    }

    // MARK: - Internals

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<PharosClientEvent>.Continuation
    ) {
        eventContinuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
        if eventContinuations.isEmpty {
            webSocketPump?.cancel()
            webSocketPump = nil
            webSocketTask?.cancel(with: .goingAway, reason: nil)
            webSocketTask = nil
        }
    }

    private func broadcast(_ event: PharosClientEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func ensureWebSocket() {
        guard webSocketTask == nil else { return }
        let task = session.webSocketTask(with: configuration.eventsWebSocketURL)
        webSocketTask = task
        task.resume()
        webSocketPump = Task { [weak self] in
            await self?.pumpWebSocket()
        }
    }

    private func pumpWebSocket() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else { return }
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handleWebSocketText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleWebSocketText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled {
                    broadcast(
                        .backendError(
                            .connectionFailed("WebSocket events closed: \(error.localizedDescription)")
                        )
                    )
                }
                return
            }
        }
    }

    private func handleWebSocketText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = object["eventType"] as? String
        else { return }

        // Ignore transport ready frames from FakeEventBus.
        if eventType == "ready" { return }

        if let event = mapWireEvent(eventType: eventType, data: data) {
            broadcast(event)
        }
    }

    func mapWireEvent(eventType: String, data: Data) -> PharosClientEvent? {
        switch eventType {
        case "sessionUpdated":
            struct Envelope: Decodable { let session: APISessionSummary }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .sessionUpdated(env.session.asClient())
        case "sessionConnectionRestored":
            struct Envelope: Decodable { let sessionId: String }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .sessionConnectionRestored(sessionId: env.sessionId)
        case "sessionGoalUpdated":
            struct Envelope: Decodable { let sessionId: String; let goal: CanonicalSessionGoal? }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .sessionGoalUpdated(sessionId: env.sessionId, goal: env.goal)
        case "sessionTodosUpdated":
            struct Envelope: Decodable { let sessionId: String; let todos: [CanonicalSessionTodo] }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .sessionTodosUpdated(sessionId: env.sessionId, todos: env.todos)
        case "turnStarted":
            struct Envelope: Decodable { let turn: APICanonicalTurn }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .turnStarted(env.turn.asClient())
        case "turnCompleted":
            struct Envelope: Decodable { let turn: APICanonicalTurn }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .turnCompleted(env.turn.asClient())
        case "approvalRequired", "approvalUpdated":
            struct Envelope: Decodable { let approval: APIApprovalRequest }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return eventType == "approvalUpdated" ? .approvalUpdated(env.approval.asClient()) : .approvalRequired(env.approval.asClient())
        case "approvalWithdrawn":
            struct Envelope: Decodable { let approvalId: String }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .approvalWithdrawn(approvalId: env.approvalId)
        case "approvalResolved":
            struct Envelope: Decodable {
                let approvalId: String
                let decision: String
            }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            let choice: ApprovalChoice
            switch env.decision {
            case "allowedAlways": choice = .allowedAlways
            case "rejected": choice = .rejected
            case "allowedOnce": choice = .allowedOnce
            default: return nil
            }
            return .approvalResolved(approvalId: env.approvalId, decision: ApprovalDecision(choice: choice))
        case "threadMessageReceived":
            struct Envelope: Decodable { let threadMessage: APIThreadMessage }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .threadMessageReceived(env.threadMessage.asClient())
        case "threadReceiptUpdated":
            struct Envelope: Decodable {
                let threadId: String
                let messageId: String
                let receipt: String
            }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .threadReceiptUpdated(
                threadId: env.threadId,
                messageId: env.messageId,
                receipt: DeliveryReceiptState(apiValue: env.receipt)
            )
        case "memberStatusChanged":
            struct Envelope: Decodable {
                let memberName: String
                let status: String
            }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .memberStatusChanged(name: env.memberName, status: env.status)
        case "backendError":
            struct Envelope: Decodable { let error: APIPharosError }
            guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
            return .backendError(env.error.asClientError(fallback: "backend error"))
        default:
            return nil
        }
    }

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        let request = URLRequest(url: configuration.apiURL(path))
        return try await perform(request)
    }

    private func postJSON<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        var request = URLRequest(url: configuration.apiURL(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PharosClientError.connectionFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PharosClientError.connectionFailed("Non-HTTP response from \(request.url?.absoluteString ?? "?")")
        }
        if !(200..<300).contains(http.statusCode) {
            if let errorBody = try? decoder.decode(APIErrorBody.self, from: data) {
                throw errorBody.error.asClientError(fallback: "HTTP \(http.statusCode)")
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            throw PharosClientError.operationFailed("HTTP \(http.statusCode): \(text)")
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PharosClientError.operationFailed(
                "Decode failed for \(request.url?.path ?? "?"): \(error.localizedDescription)"
            )
        }
    }

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
