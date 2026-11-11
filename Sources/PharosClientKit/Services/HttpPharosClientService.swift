import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP/WS implementation of `PharosClientService` against the S4 Rust API
/// (`pharos-api` CONTRACTS_VERSION 0.1.0, base URL `http://127.0.0.1:<port>/`).
///
/// Foundation-only — no MeshCore / Runtime imports (ArchitectureBoundary).
public actor HttpPharosClientService: PharosClientService, BackendHealthReporting {
    public let configuration: PharosAPIConfiguration
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Highest decoded attachment size accepted by the backend (10 MiB).
    static let maxAttachmentBytes = 10 * 1024 * 1024
    /// Extension -> content type allowlist, identical to `webui/transport.js`.
    static let attachmentContentTypes: [String: String] = [
        "txt": "text/plain",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "csv": "text/csv",
        "json": "application/json",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "pdf": "application/pdf",
    ]

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
        self.encoder = JSONEncoder()
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

    public func fetchSessionConfiguration(sessionId: String) async throws -> ClientSessionConfiguration? {
        let wire: APISessionConfig = try await getJSON(
            path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/config"
        )
        return wire.asClient()
    }

    public func setSessionConfiguration(
        sessionId: String,
        configId: String,
        value: String
    ) async throws -> ClientSessionConfiguration {
        guard configId == "model" || configId == "mode" else {
            throw PharosClientError.operationFailed(
                "Unsupported Session configuration field: \(configId)"
            )
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PharosClientError.operationFailed("Choose a \(configId) value first")
        }
        // The server owns value validation (400 invalidRequest) and honest
        // 502 unsupportedField pass-through; the field is never reported saved.
        let wire: APISessionConfig = try await patchJSON(
            path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/config",
            body: [configId: value]
        )
        return wire.asClient()
    }

    public func supportsSessionTextAttachments(sessionId: String) async -> Bool {
        do {
            let wire: APISessionConfig = try await getJSON(
                path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/config"
            )
            return wire.capabilities.attachments
        } catch {
            return false
        }
    }

    public func sendSessionMessage(sessionId: String, text: String, files: [SessionFileUpload], requestId: String) async throws -> CanonicalTurn {
        if files.isEmpty {
            let wire: APICanonicalTurn = try await postJSON(
                path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/messages",
                body: ["text": text, "requestId": requestId]
            )
            let turn = wire.asClient()
            if turn.status == .inProgress { broadcast(.turnStarted(turn)) }
            else { broadcast(.turnCompleted(turn)) }
            return turn
        }
        let encoded = Self.encodePathComponent(sessionId)
        // Capability first: never upload orphans the adapter cannot consume.
        let config: APISessionConfig = try await getJSON(path: "api/v1/sessions/\(encoded)/config")
        guard config.capabilities.attachments else {
            throw PharosClientError.operationFailed(
                "Attachments are unavailable for this Session: the adapter does not advertise attachment support"
            )
        }
        var attachmentIds: [String] = []
        for file in files {
            let contentType = try Self.attachmentContentType(forFilename: file.name)
            guard !file.data.isEmpty else {
                throw PharosClientError.operationFailed(
                    "Attachment \(file.name) is empty; the backend accepts 1 byte to \(Self.maxAttachmentBytes) bytes"
                )
            }
            guard file.data.count <= Self.maxAttachmentBytes else {
                throw PharosClientError.operationFailed(
                    "Attachment \(file.name) is \(file.data.count) bytes; the backend accepts at most \(Self.maxAttachmentBytes) bytes"
                )
            }
            let uploaded: APIAttachment = try await postJSON(
                path: "api/v1/sessions/\(encoded)/attachments",
                body: APIUploadAttachmentRequest(
                    filename: file.name,
                    contentType: contentType,
                    dataBase64: file.data.base64EncodedString()
                )
            )
            attachmentIds.append(uploaded.attachmentId)
        }
        let wire: APICanonicalTurn = try await postJSON(
            path: "api/v1/sessions/\(encoded)/messages",
            body: APISendSessionMessageWithAttachmentsRequest(
                text: text,
                requestId: requestId,
                attachmentIds: attachmentIds
            )
        )
        let turn = wire.asClient()
        if turn.status == .inProgress { broadcast(.turnStarted(turn)) }
        else { broadcast(.turnCompleted(turn)) }
        return turn
    }

    public func fetchSessionAttachments(sessionId: String) async throws -> [ClientAttachment] {
        let wire: APIAttachmentListResponse = try await getJSON(
            path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/attachments"
        )
        return wire.attachments.map { $0.asClient() }
    }

    public func fetchAttachment(attachmentId: String) async throws -> ClientAttachment {
        let wire: APIAttachment = try await getJSON(
            path: "api/v1/attachments/\(Self.encodePathComponent(attachmentId))"
        )
        return wire.asClient()
    }

    public func fetchAttachmentContent(attachmentId: String) async throws -> Data {
        let request = makeRequest(
            method: "GET",
            path: "api/v1/attachments/\(Self.encodePathComponent(attachmentId))/content"
        )
        return try await performRaw(request)
    }

    public func stopSession(sessionId: String) async throws {
        try await postLifecycle(path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/stop", sessionId: sessionId, action: "stopped")
    }

    public func reviveSession(sessionId: String) async throws {
        try await postLifecycle(path: "api/v1/sessions/\(Self.encodePathComponent(sessionId))/revive", sessionId: sessionId, action: "revived")
    }

    /// POST a lifecycle route. The body (`{ok,sessionId,status}`) is decoded
    /// opportunistically: a 2xx is success unless the body explicitly says
    /// `ok:false`; a 502 `unsupportedOperation` always throws (never faked).
    private func postLifecycle(path: String, sessionId: String, action: String) async throws {
        let data = try await performRaw(makeRequest(method: "POST", path: path))
        if let response = try? decoder.decode(APISessionLifecycleResponse.self, from: data),
           response.ok == false {
            throw PharosClientError.operationFailed(
                "The backend reported that Session \(sessionId) was not \(action)"
            )
        }
    }

    public func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] {
        let encoded = Self.encodePathComponent(threadId)
        let wire: [APIThreadMessage] = try await getJSON(path: "api/v1/threads/\(encoded)/messages")
        return wire.map { $0.asClient() }
    }

    // MARK: - Thread ↔ session bindings

    public func supportsThreadSessionBinding() async -> Bool {
        do {
            let threads = try await fetchThreads()
            // Binding routes 404 for an unknown Thread; probing the first known
            // Thread distinguishes "route exists" from "no threads to bind yet".
            guard let first = threads.first else { return false }
            let _: [String: JSONValue] = try await getJSON(
                path: "api/v1/threads/\(Self.encodePathComponent(first.threadId))/bindings"
            )
            return true
        } catch {
            return false
        }
    }

    public func threadSessionBindingCandidates() async -> [ClientSessionSummary] {
        (try? await fetchSessions()) ?? []
    }

    public func bindThreadSession(threadId: String, sessionId: String, nickname: String) async throws {
        let member = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !member.isEmpty, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PharosClientError.operationFailed("Choose a Session and a member name before binding")
        }
        let _: [String: JSONValue] = try await putJSON(
            path: "api/v1/threads/\(Self.encodePathComponent(threadId))/bindings/\(Self.encodePathComponent(member))",
            body: APIBindThreadSessionRequest(sessionId: sessionId)
        )
    }

    public func unbindThreadSession(threadId: String, member: String) async throws {
        guard !member.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PharosClientError.operationFailed("Choose a Thread member to unbind")
        }
        let _: [String: JSONValue] = try await deleteJSON(
            path: "api/v1/threads/\(Self.encodePathComponent(threadId))/bindings/\(Self.encodePathComponent(member))"
        )
    }

    public func fetchThreadMembers(threadId: String) async throws -> [ClientMemberDetail] {
        struct Response: Decodable { let members: [APIThreadMember] }
        let response: Response = try await getJSON(
            path: "api/v1/threads/\(Self.encodePathComponent(threadId))/members"
        )
        return response.members.map { $0.asClient() }
    }

    // MARK: - Member settings

    /// Settings view -> member detail.
    ///
    /// `GET /api/v1/members/{id}` intentionally exposes only settings (it is not
    /// a claim that the member exists and carries no live session state), so
    /// `agent`, `machine` and `status` are empty = unknown here. They are never
    /// invented; Thread members get them from `GET /threads/{id}/members`.
    public func fetchMemberDetail(name: String) async throws -> ClientMemberDetail {
        let settings: APIMemberSettingsView = try await getJSON(
            path: "api/v1/members/\(Self.encodePathComponent(name))"
        )
        let memberId = settings.memberId ?? name
        return ClientMemberDetail(
            name: memberId,
            agent: "",
            machine: "",
            model: settings.model ?? "",
            mode: settings.mode ?? "",
            status: "",
            tmuxSession: nil,
            avatarSeed: settings.displayName ?? memberId,
            displayName: settings.displayName,
            avatarShape: settings.avatarShape,
            avatarColor: settings.avatarColor
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

    // MARK: - Approvals

    public func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest? {
        let approvals = try await pendingApprovalSnapshot(sessionId: sessionId)
        return approvals.first?.asClient()
    }

    public func resolveSessionApproval(
        sessionId: String,
        approvalId: String,
        decision: ApprovalDecision
    ) async throws {
        let encoded = Self.encodePathComponent(sessionId)
        guard let apiDecision = decision.choice.apiDecisionValue else {
            throw PharosClientError.operationFailed("This approval choice is unavailable in the Rust API")
        }
        var answers: [APIQuestionnaireAnswer] = []
        if let rawAnswers = decision.answers, !rawAnswers.isEmpty {
            // Metadata is only needed to split selected values from free text.
            // A resolved/missing approval falls back to keeping every value in
            // `selected` (the server validates, nothing is silently dropped).
            let approval = try? await fetchSessionApproval(sessionId: sessionId)
            answers = Self.questionnaireAnswers(rawAnswers, approval: approval)
        }
        let body = APIResolveApprovalRequest(
            approvalId: approvalId,
            decision: apiDecision,
            questionnaireAnswers: answers.isEmpty ? nil : answers
        )
        let _: [String: JSONValue] = try await postJSON(
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

    // MARK: - Member administration

    public func setMemberMode(name: String, mode: String) async throws {
        let _: APIMemberSettingsView = try await patchJSON(
            path: "api/v1/members/\(Self.encodePathComponent(name))",
            body: ["mode": mode]
        )
    }

    public func setMemberModel(name: String, model: String) async throws {
        let _: APIMemberSettingsView = try await patchJSON(
            path: "api/v1/members/\(Self.encodePathComponent(name))",
            body: ["model": model]
        )
    }

    public func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws {
        let encoded = Self.encodePathComponent(name)
        var patch: [String: String] = [:]
        if let shape = avatar.shape { patch["avatarShape"] = shape }
        if let color = avatar.color { patch["avatarColor"] = color }
        if !patch.isEmpty {
            let _: APIMemberSettingsView = try await patchJSON(
                path: "api/v1/members/\(encoded)",
                body: patch
            )
            return
        }
        if let uri = avatar.customImageUri, let image = Self.parseImageDataURI(uri) {
            let _: APIMemberSettingsView = try await putJSON(
                path: "api/v1/members/\(encoded)/avatar",
                body: APIUploadAvatarRequest(contentType: image.contentType, dataBase64: image.dataBase64)
            )
            return
        }
        throw PharosClientError.operationFailed(
            "Avatar identity requires a shape/colour or a png/jpeg data URI"
        )
    }

    public func stopMember(name: String) async throws {
        let sessionId = try await resolveSessionId(named: name, operation: "stop")
        try await stopSession(sessionId: sessionId)
    }

    public func reviveMember(name: String) async throws {
        let sessionId = try await resolveSessionId(named: name, operation: "revive")
        try await reviveSession(sessionId: sessionId)
    }

    /// Resolve a human-entered member/session name to a session id: exact
    /// session id first, then a unique title. Never guesses on ambiguity.
    private func resolveSessionId(named name: String, operation: String) async throws -> String {
        let sessions = try await fetchSessions()
        if let exact = sessions.first(where: { $0.sessionId == name }) {
            return exact.sessionId
        }
        let byTitle = sessions.filter { $0.title == name }
        switch byTitle.count {
        case 0:
            throw PharosClientError.operationFailed("No Session named \(name) on this backend")
        case 1:
            return byTitle[0].sessionId
        default:
            throw PharosClientError.operationFailed(
                "Multiple Sessions are named \(name) on this backend; \(operation) the Session by id instead"
            )
        }
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

    public func probeBackend() async -> BackendHealthProbe {
        do {
            let health: APIHealthResponse = try await getJSON(path: "health")
            return .reachable(
                BackendHealth(
                    ok: health.ok,
                    contractsVersion: health.contractsVersion,
                    service: health.service
                )
            )
        } catch {
            return .unreachable(reason: Self.describe(error))
        }
    }

    // MARK: - Internals

    private func pendingApprovalSnapshot(sessionId: String) async throws -> [APIApprovalRequest] {
        var components = URLComponents(
            url: configuration.apiURL("api/v1/approvals"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "state", value: "pending"),
            URLQueryItem(name: "sessionId", value: sessionId),
        ]
        guard let url = components?.url else {
            throw PharosClientError.operationFailed("Could not build the pending-approvals URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response: APIApprovalListResponse = try await perform(request)
        return response.approvals
    }

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
            case "cancelled": choice = .cancelled
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
        try await perform(makeRequest(method: "GET", path: path))
    }

    private func postJSON<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        var request = makeRequest(method: "POST", path: path)
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func putJSON<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        var request = makeRequest(method: "PUT", path: path)
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func patchJSON<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        var request = makeRequest(method: "PATCH", path: path)
        request.httpBody = try encoder.encode(body)
        return try await perform(request)
    }

    private func deleteJSON<T: Decodable>(path: String) async throws -> T {
        try await perform(makeRequest(method: "DELETE", path: path))
    }

    private func makeRequest(method: String, path: String) -> URLRequest {
        var request = URLRequest(url: Self.apiURL(configuration: configuration, path: path))
        request.httpMethod = method
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Performs the request, maps transport/HTTP failures to `PharosClientError`
    /// (server error bodies preserve their message text) and returns the raw body.
    private func performRaw(_ request: URLRequest) async throws -> Data {
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
        return data
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await performRaw(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PharosClientError.operationFailed(
                "Decode failed for \(request.url?.path ?? "?"): \(error.localizedDescription)"
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        guard let clientError = error as? PharosClientError else {
            return error.localizedDescription
        }
        switch clientError {
        case .backendUnreachable(let backend, let reason):
            return "\(backend): \(reason)"
        case .sessionNotFound(let id):
            return "Session \(id) not found"
        case .threadNotFound(let id):
            return "Thread \(id) not found"
        case .approvalNotFound(let id):
            return "Approval \(id) not found"
        case .connectionFailed(let message):
            return message
        case .operationFailed(let message):
            return message
        }
    }

    /// Extension -> allowlisted content type, mirroring `webui/transport.js`.
    static func attachmentContentType(forFilename filename: String) throws -> String {
        let lowercased = filename.lowercased()
        guard lowercased.contains("."),
              let extensionName = lowercased.split(separator: ".").last.map(String.init),
              let contentType = attachmentContentTypes[extensionName] else {
            throw PharosClientError.operationFailed(
                "Unsupported attachment type for \(filename): supported extensions are txt, md, markdown, csv, json, png, jpg, jpeg, pdf"
            )
        }
        return contentType
    }

    /// `data:image/png;base64,...` / `data:image/jpeg;base64,...` -> (type, payload).
    static func parseImageDataURI(_ uri: String) -> (contentType: String, dataBase64: String)? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            ("data:image/png;base64,", "image/png"),
            ("data:image/jpeg;base64,", "image/jpeg"),
        ]
        for (prefix, contentType) in prefixes where trimmed.lowercased().hasPrefix(prefix) {
            let payload = String(trimmed.dropFirst(prefix.count))
            guard !payload.isEmpty else { return nil }
            return (contentType, payload)
        }
        return nil
    }

    /// Split questionnaire answers into the contract's `{questionId, selected, text?}`.
    ///
    /// Uses the approval's own question metadata when available. Without
    /// metadata (e.g. the approval was already resolved) every non-empty value
    /// is kept in `selected`; the server validates it — nothing is dropped.
    static func questionnaireAnswers(
        _ answers: [String: [String]],
        approval: CanonicalApprovalRequest?
    ) -> [APIQuestionnaireAnswer] {
        let questions: [CanonicalQuestionOption] = {
            guard let approval, case let .structuredQuestionnaire(_, questions) = approval.kind else {
                return []
            }
            return questions
        }()
        var questionIds = questions.map(\.id).filter { answers[$0] != nil }
        questionIds += answers.keys.filter { !questionIds.contains($0) }.sorted()
        return questionIds.compactMap { questionId in
            guard let values = answers[questionId] else { return nil }
            let nonEmpty = values.filter { !$0.isEmpty }
            guard let question = questions.first(where: { $0.id == questionId }) else {
                return APIQuestionnaireAnswer(questionId: questionId, selected: nonEmpty, text: nil)
            }
            if question.options.isEmpty {
                return APIQuestionnaireAnswer(questionId: questionId, selected: [], text: nonEmpty.last)
            }
            // Values outside the options are kept: the server rejects them
            // explicitly instead of the client silently dropping input.
            return APIQuestionnaireAnswer(questionId: questionId, selected: nonEmpty, text: nil)
        }
    }

    private static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    /// Joins a path whose dynamic components are already percent-encoded
    /// without re-encoding them (`appendingPathComponent` would turn `%20`
    /// into `%2520`).
    static func apiURL(configuration: PharosAPIConfiguration, path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let base = configuration.baseURL.absoluteString
        let separator = base.hasSuffix("/") ? "" : "/"
        return URL(string: base + separator + trimmed) ?? configuration.apiURL(path)
    }
}

/// `POST /api/v1/sessions/{id}/approval` extended body.
private struct APIResolveApprovalRequest: Encodable, Sendable {
    let approvalId: String
    let decision: String
    let questionnaireAnswers: [APIQuestionnaireAnswer]?
}
