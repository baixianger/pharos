import Foundation

/// In-memory implementation of `PharosClientService` for deterministic UI testing and previews.
public actor MockPharosClientService: PharosClientService {
    public var sessions: [ClientSessionSummary]
    public var threads: [ClientThreadSummary]
    public var projects: [ClientProjectSummary]
    public var sessionHistories: [String: [CanonicalTurn]]
    public var threadMessages: [String: [ClientThreadMessage]]
    public var members: [String: ClientMemberDetail]

    private var eventContinuations: [UUID: AsyncStream<PharosClientEvent>.Continuation] = [:]
    private var backendFailureOverride: (backend: String, reason: String)?

    public init(
        sessions: [ClientSessionSummary] = [],
        threads: [ClientThreadSummary] = [],
        projects: [ClientProjectSummary] = [],
        sessionHistories: [String: [CanonicalTurn]] = [:],
        threadMessages: [String: [ClientThreadMessage]] = [:],
        members: [String: ClientMemberDetail] = [:]
    ) {
        self.sessions = sessions
        self.threads = threads
        self.projects = projects
        self.sessionHistories = sessionHistories
        self.threadMessages = threadMessages
        self.members = members
    }

    /// Set an explicit backend failure override to test daemon unreachable handling.
    public func setBackendFailure(backend: String?, reason: String?) {
        if let b = backend, let r = reason {
            backendFailureOverride = (b, r)
        } else {
            backendFailureOverride = nil
        }
    }

    public func emitEvent(_ event: PharosClientEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    public func fetchSessions() async throws -> [ClientSessionSummary] {
        if let failure = backendFailureOverride {
            throw PharosClientError.backendUnreachable(backend: failure.backend, reason: failure.reason)
        }
        return sessions
    }

    public func fetchThreads() async throws -> [ClientThreadSummary] {
        return threads
    }

    public func fetchProjects() async throws -> [ClientProjectSummary] {
        return projects
    }

    public func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
        if let failure = backendFailureOverride {
            throw PharosClientError.backendUnreachable(backend: failure.backend, reason: failure.reason)
        }
        guard let history = sessionHistories[sessionId] else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        return history
    }

    public func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] {
        return threadMessages[threadId] ?? []
    }

    public func fetchMemberDetail(name: String) async throws -> ClientMemberDetail {
        guard let member = members[name] else {
            throw PharosClientError.operationFailed("Member not found: \(name)")
        }
        return member
    }

    public func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
        if let failure = backendFailureOverride {
            let err = PharosClientError.backendUnreachable(backend: failure.backend, reason: failure.reason)
            emitEvent(.backendError(err))
            throw err
        }
        guard sessions.contains(where: { $0.sessionId == sessionId }) else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        let history = sessionHistories[sessionId] ?? []
        let newTurn = CanonicalTurn(
            turnId: "turn_\(UUID().uuidString.prefix(8))",
            sessionId: sessionId,
            turnNumber: history.count + 1,
            status: .inProgress,
            steps: [
                CanonicalStep(
                    stepId: "step_1",
                    stepNumber: 1,
                    status: .running,
                    blocks: [
                        CanonicalBlock(
                            blockId: "blk_user",
                            kind: .userText(text)
                        )
                    ]
                )
            ]
        )
        sessionHistories[sessionId, default: []].append(newTurn)
        emitEvent(.turnStarted(newTurn))
        return newTurn
    }

    public func steerSession(sessionId: String, text: String) async throws {
        if let failure = backendFailureOverride {
            throw PharosClientError.backendUnreachable(backend: failure.backend, reason: failure.reason)
        }
        guard sessions.contains(where: { $0.sessionId == sessionId }) else {
            throw PharosClientError.sessionNotFound(sessionId)
        }
        emitEvent(.streamingDelta(CanonicalStreamingDelta(
            sessionId: sessionId,
            turnId: "current",
            deltaType: .textDelta(" [Steered: \(text)]")
        )))
    }

    public func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        emitEvent(.approvalResolved(approvalId: approvalId, decision: decision))
    }

    public func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage {
        if let failure = backendFailureOverride {
            let err = PharosClientError.backendUnreachable(backend: failure.backend, reason: failure.reason)
            emitEvent(.backendError(err))
            throw err
        }
        let msg = ClientThreadMessage(
            id: "msg_\(UUID().uuidString.prefix(8))",
            threadId: threadId,
            senderId: "tester",
            senderName: "Human Operator",
            text: text,
            receipt: .delivered
        )
        threadMessages[threadId, default: []].append(msg)
        emitEvent(.threadMessageReceived(msg))
        return msg
    }

    public func setMemberMode(name: String, mode: String) async throws {
        if var member = members[name] {
            member = ClientMemberDetail(
                name: member.name,
                agent: member.agent,
                machine: member.machine,
                model: member.model,
                mode: mode,
                status: member.status,
                tmuxSession: member.tmuxSession,
                avatarSeed: member.avatarSeed
            )
            members[name] = member
            emitEvent(.memberStatusChanged(name: name, status: member.status))
        }
    }

    public func setMemberModel(name: String, model: String) async throws {
        if var member = members[name] {
            member = ClientMemberDetail(
                name: member.name,
                agent: member.agent,
                machine: member.machine,
                model: model,
                mode: member.mode,
                status: member.status,
                tmuxSession: member.tmuxSession,
                avatarSeed: member.avatarSeed
            )
            members[name] = member
        }
    }

    public func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws {
        if var member = members[name] {
            member = ClientMemberDetail(
                name: member.name,
                agent: member.agent,
                machine: member.machine,
                model: member.model,
                mode: member.mode,
                status: member.status,
                tmuxSession: member.tmuxSession,
                avatarSeed: avatar.seed
            )
            members[name] = member
        }
    }

    public func stopMember(name: String) async throws {
        if var member = members[name] {
            member = ClientMemberDetail(
                name: member.name,
                agent: member.agent,
                machine: member.machine,
                model: member.model,
                mode: member.mode,
                status: "stopped",
                tmuxSession: member.tmuxSession,
                avatarSeed: member.avatarSeed
            )
            members[name] = member
            emitEvent(.memberStatusChanged(name: name, status: "stopped"))
        }
    }

    public func reviveMember(name: String) async throws {
        if var member = members[name] {
            member = ClientMemberDetail(
                name: member.name,
                agent: member.agent,
                machine: member.machine,
                model: member.model,
                mode: member.mode,
                status: "active",
                tmuxSession: member.tmuxSession,
                avatarSeed: member.avatarSeed
            )
            members[name] = member
            emitEvent(.memberStatusChanged(name: name, status: "active"))
        }
    }

    public nonisolated func events() -> AsyncStream<PharosClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { [weak self, id] in
                await self?.registerContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { [weak self, id] _ in
                Task { [weak self, id] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func registerContinuation(id: UUID, continuation: AsyncStream<PharosClientEvent>.Continuation) {
        eventContinuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }
}
