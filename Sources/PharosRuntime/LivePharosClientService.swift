import Foundation
import PharosClientKit

/// Desktop service for sessions available through the local Codex App Server.
/// Other providers remain unavailable until their session ownership is wired.
public actor LivePharosClientService: PharosClientService {
    private struct PendingApproval {
        let requestID: CodexRequestID
        let method: String
        let turnID: String
        let request: CanonicalApprovalRequest
        let availableDecisions: [String]?
        let connectionGeneration: UInt64
    }
    private let transport: any CodexTransport
    private let translator = CodexMessageTranslator()
    private let machineID: String
    private let listeners = EventListeners()
    private var observer: Task<Void, Never>?
    private var activeTurns: [String: String] = [:]
    private var latestTurnIDs: [String: String] = [:]
    // A thread being loaded in the daemon does not mean this connection is
    // subscribed to it. Resume discovered threads before sending their first turn.
    private var discoveredSessions: Set<String> = []
    private var resumedSessions: [String: UInt64] = [:]
    private var liveItems: [String: [String: [[String: Any]]]] = [:]
    private var pendingFileChanges: [String: [String: (turnID: String, changes: JSONValue)]] = [:]
    private var ownedTurns: [String: String] = [:]
    private var ownedTurnGenerations: [String: UInt64] = [:]
    private var startingTurns: Set<String> = []
    private var deferredRequests: [String: [BackendWireEvent]] = [:]
    private var approvals: [String: [PendingApproval]] = [:]
    private var responsesInFlight: Set<String> = []
    private var pendingDecisions: [String: ApprovalDecision] = [:]
    private var confirmedApprovals: Set<String> = []
    private var resolutionWaiters: Set<String> = []
    private var progressBySession: [String: CanonicalSessionProgress] = [:]
    private var goalRevisions: [String: Int] = [:]

    public init(transport: (any CodexTransport)? = nil, machineID: String = ProcessInfo.processInfo.hostName) {
        self.transport = transport ?? CodexDaemonUdsTransport()
        self.machineID = machineID
    }

    deinit { observer?.cancel(); transport.close() }

    private func observe() {
        guard observer == nil else { return }
        let stream = transport.observeEvents()
        observer = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                await self.handle(event)
            }
        }
    }

    public func fetchSessions() async throws -> [ClientSessionSummary] {
        observe()
        var cursor: String?
        var sessions: [ClientSessionSummary] = []
        repeat {
            var params: [String: Any] = ["limit": 100, "archived": false]
            if let cursor { params["cursor"] = cursor }
            let response = try await transport.call(method: "thread/list", params: params)
            let threads = response["data"] as? [[String: Any]] ?? response["threads"] as? [[String: Any]] ?? []
            sessions += threads.compactMap { thread in
                guard let id = thread["id"] as? String, !id.isEmpty else { return nil }
                let state = (thread["status"] as? [String: Any])?["type"] as? String
                let flags = (thread["status"] as? [String: Any])?["activeFlags"] as? [String] ?? []
                let activity = Self.sessionStatus(type: state, flags: flags)
                let timestamp = (thread["updatedAt"] as? NSNumber)?.doubleValue
                return ClientSessionSummary(sessionId: id, machineId: machineID,
                    agentType: "codex", workspacePath: thread["cwd"] as? String ?? "",
                    title: thread["name"] as? String ?? "Codex", status: activity,
                    updatedAt: timestamp.map(Date.init(timeIntervalSince1970:)) ?? Date(), avatarSeed: id)
            }
            discoveredSessions.formUnion(threads.compactMap { $0["id"] as? String })
            let unloaded = threads.compactMap { thread -> String? in
                guard (thread["status"] as? [String: Any])?["type"] as? String == "notLoaded" else { return nil }
                return thread["id"] as? String
            }
            for id in unloaded { resumedSessions.removeValue(forKey: id) }
            let next = response["nextCursor"] as? String
            cursor = next?.isEmpty == false && next != cursor ? next : nil
        } while cursor != nil && sessions.count < 300
        return sessions
    }

    static func sessionStatus(type: String?, flags: [String]) -> SessionActivityStatus {
        if flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") { return .needsHuman }
        switch type {
        case "active": return .working
        case "idle": return .idle
        default: return .unknown
        }
    }

    public func fetchSessionHistory(sessionId: String) async throws -> [CanonicalTurn] {
        observe()
        let response = try await transport.call(method: "thread/read", params: ["threadId": sessionId, "includeTurns": true])
        guard let thread = response["thread"] as? [String: Any] else {
            throw PharosClientError.operationFailed("Codex returned no thread")
        }
        let history = (thread["turns"] as? [[String: Any]] ?? []).enumerated().map { index, turn in
            canonicalTurn(turn, sessionId: sessionId, number: index + 1)
        }
        if activeTurns[sessionId] == nil, let latest = history.last { latestTurnIDs[sessionId] = latest.turnId }
        if let active = history.last(where: { $0.status == .inProgress }) {
            activeTurns[sessionId] = active.turnId
        }
        return history
    }

    public func fetchSessionProgress(sessionId: String) async throws -> CanonicalSessionProgress? {
        observe()
        let revision = goalRevisions[sessionId, default: 0]
        do {
            let result = try await transport.call(method: "thread/goal/get", params: ["threadId": sessionId])
            if goalRevisions[sessionId, default: 0] == revision {
                let goal = SessionProgressMapping.goal(result["goal"] as? [String: Any])
                progressBySession[sessionId] = .init(goal: goal, todos: progressBySession[sessionId]?.todos ?? [])
            }
        } catch let error as PharosClientError {
            guard case .operationFailed(let message) = error else { throw error }
            let text = message.lowercased()
            guard text.contains("-32601") || text.contains("method not found") || text.contains("ephemeral")
                    || text.contains("goal feature is disabled") else { throw error }
        }
        return progressBySession[sessionId]
    }

    public func executeSessionCommand(sessionId: String, line: String) async throws -> SessionCommandResult? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text == "/goal" || text.hasPrefix("/goal ") || text.hasPrefix("/goal\n") || text.hasPrefix("/goal\t") else { return nil }
        let argument = String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        observe()
        let revision = goalRevisions[sessionId, default: 0]
        let result: [String: Any]
        if argument.isEmpty {
            result = try await transport.call(method: "thread/goal/get", params: ["threadId": sessionId])
            let goal = SessionProgressMapping.goal(result["goal"] as? [String: Any])
            if let rawGoal = result["goal"], !(rawGoal is NSNull), goal == nil {
                throw PharosClientError.operationFailed("Codex returned an invalid Goal")
            }
            applyGoalCommandSnapshot(goal, sessionId: sessionId, revision: revision)
            return SessionCommandResult(text: goal.map { "Goal (\($0.status)): \($0.objective)" } ?? "No goal")
        }
        if argument == "clear" {
            result = try await transport.call(method: "thread/goal/clear", params: ["threadId": sessionId, "origin": "user"])
            guard let cleared = result["cleared"] as? Bool else { throw PharosClientError.operationFailed("Codex returned an invalid Goal clear response") }
            applyGoalCommandSnapshot(nil, sessionId: sessionId, revision: revision)
            return SessionCommandResult(text: cleared ? "Goal cleared" : "No goal")
        }
        var params: [String: Any] = ["threadId": sessionId, "origin": "user"]
        if argument == "pause" || argument == "resume" {
            params["status"] = argument == "pause" ? "paused" : "active"
        } else {
            let current = try await transport.call(method: "thread/goal/get", params: ["threadId": sessionId])
            guard current["goal"] == nil || current["goal"] is NSNull else {
                throw PharosClientError.operationFailed("This Session already has a Goal; clear it before creating another")
            }
            params["objective"] = argument
            params["status"] = "active"
        }
        result = try await transport.call(method: "thread/goal/set", params: params)
        guard let goal = SessionProgressMapping.goal(result["goal"] as? [String: Any]),
              goal.status == params["status"] as? String,
              params["objective"] == nil || goal.objective == params["objective"] as? String else {
            throw PharosClientError.operationFailed("Codex returned an unexpected Goal state")
        }
        applyGoalCommandSnapshot(goal, sessionId: sessionId, revision: revision)
        return SessionCommandResult(text: "Goal (\(goal.status)): \(goal.objective)")
    }

    private func applyGoalCommandSnapshot(_ goal: CanonicalSessionGoal?, sessionId: String, revision: Int) {
        guard goalRevisions[sessionId, default: 0] == revision else { return }
        goalRevisions[sessionId, default: 0] += 1
        progressBySession[sessionId] = .init(goal: goal, todos: progressBySession[sessionId]?.todos ?? [])
        listeners.emit(.sessionGoalUpdated(sessionId: sessionId, goal: goal))
    }

    private func canonicalTurn(_ turn: [String: Any], sessionId: String, number: Int) -> CanonicalTurn {
        let id = turn["id"] as? String ?? UUID().uuidString
        let status: TurnStatus
        switch turn["status"] as? String {
        case "inProgress": status = .inProgress
        case "failed": status = .failed
        case "interrupted": status = .cancelled
        default: status = .completed
        }
        let blocks = (turn["items"] as? [[String: Any]] ?? []).enumerated().flatMap { index, item -> [CanonicalBlock] in
            guard let type = item["type"] as? String else { return [] }
            let itemID = item["id"] as? String ?? "\(id)-\(index)"
            if type == "userMessage", let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                return [CanonicalBlock(blockId: itemID, kind: .userText(text))]
            }
            if type == "fileChange", let changes = item["changes"] as? [[String: Any]] {
                return changes.enumerated().compactMap { index, change in
                    guard change["path"] as? String != nil else { return nil }
                    return translator.translateItemCompleted(itemId: "\(itemID)-change-\(index)", itemType: type,
                                                             itemDict: change, rawPayload: item)
                }
            }
            return translator.translateItemCompleted(itemId: itemID, itemType: type, itemDict: item).map { [$0] } ?? []
        }
        return CanonicalTurn(turnId: id, sessionId: sessionId, turnNumber: number, status: status,
                             steps: [.init(stepId: id, stepNumber: 1, status: status == .inProgress ? .running : .completed, blocks: blocks)])
    }

    public func sendSessionMessage(sessionId: String, text: String) async throws -> CanonicalTurn {
        observe()
        guard startingTurns.insert(sessionId).inserted else {
            throw PharosClientError.operationFailed("A Codex turn is already being started or is running")
        }
        defer { startingTurns.remove(sessionId) }
        if let previous = ownedTurns[sessionId], ownedTurnGenerations[sessionId] != transport.connectionGeneration {
            withdrawStaleApprovals(sessionId: sessionId)
            let history = try await fetchSessionHistory(sessionId: sessionId)
            guard let turn = history.first(where: { $0.turnId == previous }), turn.status != .inProgress else {
                throw PharosClientError.operationFailed("The previous Codex turn may still be running after the connection changed; refresh and try again")
            }
            ownedTurns.removeValue(forKey: sessionId)
            ownedTurnGenerations.removeValue(forKey: sessionId)
        }
        guard ownedTurns[sessionId] == nil else {
            throw PharosClientError.operationFailed("A Codex turn is already being started or is running")
        }
        if discoveredSessions.contains(sessionId), resumedSessions[sessionId] != transport.connectionGeneration {
            let resumed = try await transport.callWithGeneration(method: "thread/resume", params: ["threadId": sessionId], expectedGeneration: nil)
            resumedSessions[sessionId] = resumed.connectionGeneration
        }
        let started: CodexCallResult
        do { started = try await transport.callWithGeneration(method: "turn/start", params: ["threadId": sessionId, "input": [["type": "text", "text": text]]], expectedGeneration: discoveredSessions.contains(sessionId) ? resumedSessions[sessionId] : nil) }
        catch { deferredRequests.removeValue(forKey: sessionId); throw error }
        guard let turn = started.payload["turn"] as? [String: Any], let id = turn["id"] as? String else {
            throw PharosClientError.operationFailed("Codex returned no turn ID")
        }
        activeTurns[sessionId] = id
        ownedTurns[sessionId] = id
        ownedTurnGenerations[sessionId] = started.connectionGeneration
        let deferred = deferredRequests.removeValue(forKey: sessionId) ?? []
        for event in deferred { await handle(event) }
        return CanonicalTurn(turnId: id, sessionId: sessionId, turnNumber: 1, status: .inProgress,
            steps: [.init(stepId: id, stepNumber: 1, status: .running, blocks: [.init(blockId: "user-\(id)", kind: .userText(text))])])
    }

    public func steerSession(sessionId: String, text: String) async throws {
        guard let turn = activeTurns[sessionId] else { throw PharosClientError.operationFailed("No active turn to steer") }
        _ = try await transport.call(method: "turn/steer", params: ["threadId": sessionId, "expectedTurnId": turn, "input": [["type": "text", "text": text]]])
    }

    private func handle(_ event: BackendWireEvent) async {
        if let generation = event.connectionGeneration, generation != transport.connectionGeneration { return }
        guard let method = event["method"] as? String, let params = event["params"] as? [String: Any],
              let session = params["threadId"] as? String else { return }
        if startingTurns.contains(session), ownedTurns[session] == nil {
            deferredRequests[session, default: []].append(event)
            return
        }
        if event["id"] != nil {
            await handleRequest(event, method: method, params: params, session: session)
            return
        }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            if latestTurnIDs[session] != id {
                latestTurnIDs[session] = id
                if let progress = progressBySession[session], !progress.todos.isEmpty {
                    progressBySession[session] = .init(goal: progress.goal, todos: [])
                    listeners.emit(.sessionTodosUpdated(sessionId: session, todos: []))
                }
            }
            activeTurns[session] = id
        case "item/agentMessage/delta", "item/plan/delta", "item/reasoning/textDelta":
            guard let id = params["turnId"] as? String, let text = params["delta"] as? String else { return }
            let delta: DeltaType = method == "item/reasoning/textDelta" ? .reasoningDelta(text) : .textDelta(text)
            listeners.emit(.streamingDelta(.init(sessionId: session, turnId: id, deltaType: delta)))
        case "item/started":
            if let turnID = params["turnId"] as? String, let item = params["item"] as? [String: Any],
               item["type"] as? String == "fileChange", let itemID = item["id"] as? String,
               let changes = item["changes"] as? [[String: Any]],
               let data = try? JSONSerialization.data(withJSONObject: changes),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                pendingFileChanges[session, default: [:]][itemID] = (turnID, value)
            }
        case "item/completed":
            guard let turnID = params["turnId"] as? String,
                  let item = params["item"] as? [String: Any] else { return }
            liveItems[session, default: [:]][turnID, default: []].append(item)
            if item["type"] as? String == "fileChange", let itemID = item["id"] as? String,
               pendingFileChanges[session]?[itemID]?.turnID == turnID {
                pendingFileChanges[session]?.removeValue(forKey: itemID)
            }
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            if ownedTurns[session] == id {
                ownedTurns.removeValue(forKey: session)
                ownedTurnGenerations.removeValue(forKey: session)
            }
            pendingFileChanges[session] = pendingFileChanges[session]?.filter { $0.value.turnID != id }
            withdrawApprovals(session: session, turnID: id)
            if activeTurns[session] == id { activeTurns.removeValue(forKey: session) }
            let items = liveItems[session]?.removeValue(forKey: id) ?? []
            if !items.isEmpty {
                var complete = turn
                complete["items"] = items
                listeners.emit(.turnCompleted(canonicalTurn(complete, sessionId: session, number: 1)))
                return
            }
            do {
                let history = try await fetchSessionHistory(sessionId: session)
                guard let completed = history.first(where: { $0.turnId == id }) else {
                    throw PharosClientError.operationFailed("Completed Codex turn was not found in history")
                }
                listeners.emit(.turnCompleted(completed))
            } catch {
                listeners.emit(.backendError(.operationFailed(error.localizedDescription)))
            }
        case "turn/plan/updated":
            guard let turnID = params["turnId"] as? String, !turnID.isEmpty,
                  latestTurnIDs[session] == nil || latestTurnIDs[session] == turnID else { return }
            latestTurnIDs[session] = turnID
            if let todos = SessionProgressMapping.todos(params["plan"], textKey: "step") {
                progressBySession[session] = .init(goal: progressBySession[session]?.goal, todos: todos)
                listeners.emit(.sessionTodosUpdated(sessionId: session, todos: todos))
            }
        case "thread/goal/updated":
            if let goal = SessionProgressMapping.goal(params["goal"] as? [String: Any]) {
                goalRevisions[session, default: 0] += 1
                progressBySession[session] = .init(goal: goal, todos: progressBySession[session]?.todos ?? [])
                listeners.emit(.sessionGoalUpdated(sessionId: session, goal: goal))
            }
        case "thread/goal/cleared":
            goalRevisions[session, default: 0] += 1
            progressBySession[session] = .init(goal: nil, todos: progressBySession[session]?.todos ?? [])
            listeners.emit(.sessionGoalUpdated(sessionId: session, goal: nil))
        case "serverRequest/resolved":
            if let raw = params["requestId"], let requestID = CodexRequestID(raw: raw) { resolvedRequest(session: session, requestID: requestID) }
        default: break
        }
    }

    private func handleRequest(_ event: BackendWireEvent, method: String, params: [String: Any], session: String) async {
        guard ["item/tool/requestUserInput", "item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method),
              let rawID = event["id"], let requestID = CodexRequestID(raw: rawID), let turnID = params["turnId"] as? String else { return }
        guard ownedTurns[session] == turnID, ownedTurnGenerations[session] == transport.connectionGeneration else {
            if startingTurns.contains(session) { deferredRequests[session, default: []].append(event) }
            return
        }
        let approvalID = session + ":approval:" + requestID.stableKey
        let kind: ApprovalKind
        if method == "item/tool/requestUserInput" {
            guard let raw = params["questions"] as? [[String: Any]], !raw.isEmpty else { return }
            let questions = raw.compactMap { item -> CanonicalQuestionOption? in
                guard let id = item["id"] as? String, let question = item["question"] as? String else { return nil }
                let options = (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                return CanonicalQuestionOption(id: id, question: question, options: options,
                    isMultiSelect: item["isMultiSelect"] as? Bool ?? false,
                    allowsFreeText: item["isOther"] as? Bool ?? false,
                    isSecret: item["isSecret"] as? Bool ?? false)
            }
            guard questions.count == raw.count else { return }
            kind = .structuredQuestionnaire(intent: "user-input", questions: questions)
        } else {
            var values: [String: JSONValue] = [:]
            if let command = params["command"] as? String { values["command"] = .string(command) }
            if let cwd = params["cwd"] as? String { values["cwd"] = .string(cwd) }
            if let root = params["grantRoot"] as? String { values["grantRoot"] = .string(root) }
            if method == "item/fileChange/requestApproval", let itemID = params["itemId"] as? String,
               let change = pendingFileChanges[session]?[itemID], change.turnID == turnID {
                values["changes"] = change.changes
            }
            kind = .toolPermission(toolName: method.contains("fileChange") ? "fileChange" : "commandExecution",
                                   params: values, explanation: params["reason"] as? String)
        }
        let offeredDecisions = (params["availableDecisions"] as? [Any])?.compactMap { $0 as? String }
        let choices: [ApprovalChoice]
        if method == "item/tool/requestUserInput" { choices = [.allowedOnce] }
        else if let decisions = offeredDecisions {
            choices = [(.rejected, "decline"), (.cancelled, "cancel"), (.allowedOnce, "accept"), (.allowedAlways, "acceptForSession")]
                .compactMap { choice, value in decisions.contains(value) ? choice : nil }
        } else { choices = [.rejected, .allowedOnce, .allowedAlways] }
        let request = CanonicalApprovalRequest(approvalId: approvalID, sessionId: session, kind: kind, availableChoices: choices)
        guard !(approvals[session] ?? []).contains(where: { $0.requestID == requestID }) else { return }
        approvals[session, default: []].append(.init(requestID: requestID, method: method, turnID: turnID, request: request,
                                                     availableDecisions: offeredDecisions, connectionGeneration: event.connectionGeneration ?? transport.connectionGeneration))
        if approvals[session]?.count == 1 { listeners.emit(.approvalRequired(request)) }
    }

    private func resolvedRequest(session: String, requestID: CodexRequestID) {
        guard let index = approvals[session]?.firstIndex(where: { $0.requestID == requestID }),
              let pending = approvals[session]?[index] else { return }
        approvals[session]?.remove(at: index)
        responsesInFlight.remove(pending.request.id)
        let decision = pendingDecisions.removeValue(forKey: pending.request.id)
        if index == 0 {
            if let decision {
                if resolutionWaiters.contains(pending.request.id) { confirmedApprovals.insert(pending.request.id) }
                listeners.emit(.approvalResolved(approvalId: pending.request.id, decision: decision))
            }
            else { listeners.emit(.approvalWithdrawn(approvalId: pending.request.id)) }
            if let next = approvals[session]?.first { listeners.emit(.approvalRequired(next.request)) }
        }
    }

    private func withdrawApprovals(session: String, turnID: String) {
        guard let queue = approvals[session] else { return }
        let removed = queue.filter { $0.turnID == turnID }
        let remaining = queue.filter { $0.turnID != turnID }
        approvals[session] = remaining
        for item in removed {
            responsesInFlight.remove(item.request.id)
            pendingDecisions.removeValue(forKey: item.request.id)
            listeners.emit(.approvalWithdrawn(approvalId: item.request.id))
        }
        if queue.first?.turnID == turnID, let next = remaining.first { listeners.emit(.approvalRequired(next.request)) }
    }

    public nonisolated func events() -> AsyncStream<PharosClientEvent> { listeners.stream() }
    public func publishExternalEvent(_ event: PharosClientEvent) { listeners.emit(event) }
    public func fetchThreads() async throws -> [ClientThreadSummary] { [] }
    public func fetchProjects() async throws -> [ClientProjectSummary] { [] }
    public func fetchThreadMessages(threadId: String) async throws -> [ClientThreadMessage] { throw PharosClientError.threadNotFound(threadId) }
    public func fetchMemberDetail(name: String) async throws -> ClientMemberDetail { throw PharosClientError.operationFailed("Member details unavailable") }
    private func withdrawStaleApprovals(sessionId: String) {
        guard let queue = approvals[sessionId] else { return }
        let generation = transport.connectionGeneration
        let stale = queue.filter { $0.connectionGeneration != generation }
        guard !stale.isEmpty else { return }
        approvals[sessionId] = queue.filter { $0.connectionGeneration == generation }
        for pending in stale {
            responsesInFlight.remove(pending.request.id)
            pendingDecisions.removeValue(forKey: pending.request.id)
            listeners.emit(.approvalWithdrawn(approvalId: pending.request.id))
        }
        if let first = queue.first, first.connectionGeneration != generation, let next = approvals[sessionId]?.first {
            listeners.emit(.approvalRequired(next.request))
        }
    }
    public func fetchSessionApproval(sessionId: String) async throws -> CanonicalApprovalRequest? {
        withdrawStaleApprovals(sessionId: sessionId)
        return approvals[sessionId]?.first?.request
    }
    public func resolveSessionApproval(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        withdrawStaleApprovals(sessionId: sessionId)
        guard let pending = approvals[sessionId]?.first, pending.request.id == approvalId,
              ownedTurns[sessionId] == pending.turnID, ownedTurnGenerations[sessionId] == pending.connectionGeneration,
              responsesInFlight.insert(approvalId).inserted else {
            throw PharosClientError.approvalNotFound(approvalId)
        }
        resolutionWaiters.insert(approvalId)
        defer { resolutionWaiters.remove(approvalId); confirmedApprovals.remove(approvalId) }
        var sent = false
        do {
            let result: [String: Any]
            switch pending.request.kind {
            case .structuredQuestionnaire(_, let questions):
                guard decision.choice == .allowedOnce, let supplied = decision.answers else {
                    throw PharosClientError.operationFailed("Codex question cancellation is not connected")
                }
                var answers: [String: [String: [String]]] = [:]
                for question in questions {
                    guard let value = supplied[question.id], !value.isEmpty else { throw PharosClientError.operationFailed("Every Codex question needs an answer") }
                    answers[question.id] = ["answers": value]
                }
                result = ["answers": answers]
            case .toolPermission:
                let value: String
                switch decision.choice {
                case .allowedOnce: value = "accept"
                case .allowedAlways: value = "acceptForSession"
                case .rejected: value = "decline"
                case .cancelled: value = "cancel"
                }
                if let available = pending.availableDecisions, !available.contains(value) {
                    throw PharosClientError.operationFailed("This Codex approval option is unavailable")
                }
                result = ["decision": value]
            }
            pendingDecisions[approvalId] = decision
            try await transport.respond(requestID: pending.requestID, result: result, expectedGeneration: pending.connectionGeneration)
            sent = true
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if confirmedApprovals.remove(approvalId) != nil { return }
                withdrawStaleApprovals(sessionId: sessionId)
                guard approvals[sessionId]?.contains(where: { $0.request.id == approvalId }) == true else {
                    throw PharosClientError.approvalNotFound(approvalId)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw PharosClientError.connectionFailed("Codex answer was sent but confirmation was not received")
        } catch {
            if !sent {
                responsesInFlight.remove(approvalId)
                pendingDecisions.removeValue(forKey: approvalId)
            }
            withdrawStaleApprovals(sessionId: sessionId)
            throw error
        }
    }
    public func sendThreadMessage(threadId: String, text: String) async throws -> ClientThreadMessage { throw PharosClientError.operationFailed("Thread transport unavailable") }
    public func setMemberMode(name: String, mode: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func setMemberModel(name: String, model: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func setMemberAvatar(name: String, avatar: ClientAvatarInfo) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func stopMember(name: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
    public func reviveMember(name: String) async throws { throw PharosClientError.operationFailed("Member controls unavailable") }
}

private final class EventListeners: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PharosClientEvent>.Continuation] = [:]
    func stream() -> AsyncStream<PharosClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in _ = self?.lock.withLock { self?.continuations.removeValue(forKey: id) } }
        }
    }
    func emit(_ event: PharosClientEvent) {
        let targets = lock.withLock { Array(continuations.values) }
        targets.forEach { $0.yield(event) }
    }
}
