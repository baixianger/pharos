import Foundation
import PharosClientKit

/// Tracks turns started through the app-owned DSH Host using its durable journal.
public actor DshLiveSessionService {
    private struct PendingPermissionDetails {
        let clientID: String
        let sessionID: String
        let callID: String
        let toolName: String
        let original: [String: Any]
        var published = false
    }
    private let host: any DshSessionHosting
    private let interactionHost: any DshInteractionHosting
    private let sessionIDPrefix: String
    private let publish: @Sendable (PharosClientEvent) async -> Void
    private var active: [String: Task<Void, Never>] = [:]
    private var starting: Set<String> = []
    private var modelChanges: Set<String> = []
    private var modelSelections: [String: BackendWireEvent] = [:]
    private var modelRevisions: [String: Int] = [:]
    private var followers: [String: Task<Void, Never>] = [:]
    private var following: Set<String> = []
    private var followerRetries: [String: Task<Void, Never>] = [:]
    private var followerRetrySeconds: [String: Int] = [:]
    private var journalSequence: [String: Int] = [:]
    private var progressRevision: [String: Int] = [:]
    private var turnIDs: [String: String] = [:]
    private var turnBaselines: [String: Int] = [:]
    private var activeAttempts: [String: Set<String>] = [:]
    private var externalTurns: [String: (number: Int, id: String)] = [:]
    private var progressBySession: [String: CanonicalSessionProgress] = [:]
    private var interactionTask: Task<Void, Never>?
    private var interactionOpening: Task<(String, AsyncStream<BackendWireEvent>), Error>?
    private var interactionRetry: Task<Void, Never>?
    private var retrySeconds = 1
    private var interactionClientID: String?
    private var observedSessions: Set<String> = []
    private var questions: [String: [CanonicalApprovalRequest]] = [:]
    private var pendingPermissionDetails: [String: PendingPermissionDetails] = [:]
    private var resolving: Set<String> = []

    public init(host: any DshSessionHosting = DshWebHost(), interactionHost: (any DshInteractionHosting)? = nil,
                sessionIDPrefix: String = "dsh:",
                publish: @escaping @Sendable (PharosClientEvent) async -> Void) {
        self.host = host
        self.interactionHost = interactionHost ?? (host as? any DshInteractionHosting) ?? DshWebHost()
        self.sessionIDPrefix = sessionIDPrefix
        self.publish = publish
    }

    deinit {
        active.values.forEach { $0.cancel() }
        followers.values.forEach { $0.cancel() }
        followerRetries.values.forEach { $0.cancel() }
        interactionTask?.cancel()
        interactionOpening?.cancel()
        interactionRetry?.cancel()
    }

    /// Read the Host's provider-aware catalog and the exact Session's next selection.
    public func modelConfiguration(sessionId: String) async throws -> [JSONValue]? {
        guard let modelHost = host as? any DshModelHosting else { return nil }
        let result = try await modelHost.modelConfiguration(sessionId: sessionId)
        let session = modelSelections[sessionId].map { Self.withModelSelection($0, session: result.session) } ?? result.session
        return try Self.modelConfiguration(catalog: result.catalog, session: session)
    }

    private static func withModelSelection(_ selected: BackendWireEvent, session: BackendWireEvent) -> BackendWireEvent {
        var payload = session.payload
        var projections = payload["projections"] as? [String: Any] ?? [:]
        var values = projections["values"] as? [String: Any] ?? [:]
        var selection = values["modelSelection"] as? [String: Any] ?? [:]
        selection["next"] = selected.payload
        values["modelSelection"] = selection
        projections["values"] = values
        payload["projections"] = projections
        return BackendWireEvent(payload)
    }

    public func configuration(sessionId: String) async throws -> [JSONValue]? {
        guard var result = try await modelConfiguration(sessionId: sessionId) else { return nil }
        if let permissionHost = host as? any DshPermissionHosting {
            do {
                let snapshot = try await permissionHost.permissionConfiguration(sessionId: sessionId)
                result.append(try Self.permissionConfiguration(catalog: snapshot.catalog, session: snapshot.session))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.append(.object(["id": .string("dsh-permission-status"), "type": .string("status"),
                    "name": .string("DSH permissions unavailable")]))
            }
        }
        return result
    }

    static func permissionConfiguration(catalog: BackendWireEvent, session: BackendWireEvent) throws -> JSONValue {
        guard let raw = catalog["options"] as? [[String: Any]] else {
            throw PharosClientError.operationFailed("DSH returned an invalid permission catalog")
        }
        var choices: [JSONValue] = []
        var available = Set<String>()
        for entry in raw {
            guard let value = entry["value"] as? String, value != "custom" else { continue }
            available.insert(value)
            var choice: [String: JSONValue] = ["value": .string(value), "name": .string(entry["name"] as? String ?? value)]
            if !Self.isValidPermissionValue(value) { choice["disabled"] = .bool(true) }
            if let description = entry["description"] as? String { choice["description"] = .string(description) }
            choices.append(.object(choice))
        }
        let values = (session["projections"] as? [String: Any])?["values"] as? [String: Any]
        let current = (values?["permissions"] as? [String: Any])?["currentValue"] as? String ?? ""
        if !current.isEmpty && !available.contains(current) {
            choices.insert(.object(["value": .string(current), "name": .string(current + " · current"), "disabled": .bool(true)]), at: 0)
        }
        return .object(["id": .string("dsh-permission"), "name": .string("Permissions"), "type": .string("select"),
            "currentValue": .string(current), "options": .array(choices),
            "description": .string("DSH Session permission preset; sandbox and approval policies can both change.")])
    }

    private static func isValidPermissionValue(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !value.isEmpty && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public func setPermissionConfiguration(sessionId: String, value: String) async throws -> [JSONValue] {
        guard modelChanges.insert(sessionId).inserted else { throw PharosClientError.operationFailed("A DSH configuration change is already running") }
        defer { modelChanges.remove(sessionId) }
        guard let permissionHost = host as? any DshPermissionHosting, let commandHost = host as? any DshCommandHosting,
              Self.isValidPermissionValue(value), value != "custom" else {
            throw PharosClientError.operationFailed("Invalid DSH permission preset")
        }
        let before = try await permissionHost.permissionConfiguration(sessionId: sessionId)
        guard let options = before.catalog["options"] as? [[String: Any]], options.contains(where: { $0["value"] as? String == value }) else {
            throw PharosClientError.operationFailed("The requested DSH permission preset is unavailable")
        }
        let result = try await commandHost.executeCommand(sessionId: sessionId, command: "/permission " + value)
        guard (result["result"] as? [String: Any])?["kind"] as? String == "success" else {
            throw PharosClientError.operationFailed("DSH did not accept the permission change")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            let snapshot = try await permissionHost.permissionConfiguration(sessionId: sessionId)
            let projected = (snapshot.session["projections"] as? [String: Any])?["values"] as? [String: Any]
            if (projected?["permissions"] as? [String: Any])?["currentValue"] as? String == value {
                await publish(.sessionConfigurationUpdated(sessionId: sessionIDPrefix + sessionId))
                guard let configuration = try await configuration(sessionId: sessionId) else {
                    throw PharosClientError.operationFailed("DSH configuration is unavailable")
                }
                return configuration
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw PharosClientError.operationFailed("DSH accepted the command but did not confirm the permission state")
    }

    static func modelConfiguration(catalog: BackendWireEvent, session: BackendWireEvent) throws -> [JSONValue] {
        guard let groups = catalog["groups"] as? [[String: Any]] else {
            throw PharosClientError.operationFailed("DSH returned an invalid model catalog")
        }
        func key(_ provider: String, _ model: String) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(["provider": provider, "model": model]), as: UTF8.self)
        }
        var entries: [JSONValue] = []
        var available = Set<String>()
        for group in groups {
            guard let id = group["id"] as? String, let models = group["models"] as? [[String: Any]] else { continue }
            let providerName = group["name"] as? String ?? id
            var choices: [JSONValue] = []
            for model in models {
                guard let modelID = model["id"] as? String else { continue }
                let choiceID = try key(id, modelID)
                available.insert(choiceID)
                choices.append(.object(["value": .string(choiceID), "name": .string(providerName + " · " + (model["name"] as? String ?? modelID))]))
            }
            if !choices.isEmpty { entries.append(.object(["name": .string(providerName), "options": .array(choices)])) }
        }
        let values = (session["projections"] as? [String: Any])?["values"] as? [String: Any]
        let next = (values?["modelSelection"] as? [String: Any])?["next"] as? [String: Any]
        let current: String
        if let provider = next?["provider"] as? String, let model = next?["model"] as? String {
            current = try key(provider, model)
            if !available.contains(current) {
                entries.insert(.object(["value": .string(current), "name": .string(provider + " · " + model + " · unavailable"), "disabled": .bool(true)]), at: 0)
            }
        } else { current = "" }
        return [.object(["id": .string("dsh-model"), "name": .string("Model"), "type": .string("select"),
            "currentValue": .string(current), "options": .array(entries),
            "notice": .string("Changes may also set the default model for new DSH sessions."),
            "description": .string("DSH may also save this choice as the default for new sessions. Existing running steps keep their model.")])]
    }

    public func setModelConfiguration(sessionId: String, value: String) async throws -> [JSONValue] {
        guard modelChanges.insert(sessionId).inserted else { throw PharosClientError.operationFailed("A DSH model change is already running") }
        defer { modelChanges.remove(sessionId) }
        guard let host = host as? any DshModelHosting,
              let bytes = value.data(using: .utf8),
              let selection = try? JSONDecoder().decode([String: String].self, from: bytes),
              selection.count == 2, let provider = selection["provider"], let model = selection["model"] else {
            throw PharosClientError.operationFailed("Invalid DSH model selection")
        }
        let original = try await host.modelConfiguration(sessionId: sessionId)
        guard let groups = original.catalog["groups"] as? [[String: Any]],
              groups.contains(where: { group in
                  guard group["id"] as? String == provider, let models = group["models"] as? [[String: Any]] else { return false }
                  return models.contains { $0["id"] as? String == model }
              }) else { throw PharosClientError.operationFailed("The selected DSH model is unavailable") }
        let revision = modelRevisions[sessionId, default: 0]
        let confirmed = try await host.selectSessionModel(sessionId: sessionId, provider: provider, model: model)
        guard confirmed["provider"] as? String == provider, confirmed["model"] as? String == model else {
            throw PharosClientError.operationFailed("DSH did not confirm the selected model")
        }
        if modelRevisions[sessionId, default: 0] == revision {
            modelSelections[sessionId] = confirmed
            modelRevisions[sessionId, default: 0] += 1
        }
        let selected = modelSelections[sessionId] ?? confirmed
        let session = Self.withModelSelection(selected, session: original.session)
        await publish(.sessionConfigurationUpdated(sessionId: sessionIDPrefix + sessionId))
        return try Self.modelConfiguration(catalog: original.catalog, session: session)
    }

    public func executeCommand(sessionId: String, line: String) async throws -> SessionCommandResult {
        guard let commandHost = host as? any DshCommandHosting else {
            throw PharosClientError.operationFailed("DSH commands are unavailable for this host")
        }
        let response = try await commandHost.executeCommand(sessionId: sessionId, command: line)
        guard let result = response["result"] as? [String: Any], result["kind"] as? String == "success" else {
            throw PharosClientError.operationFailed("DSH command returned an invalid result")
        }
        let text = result["text"] as? String ?? ""
        return SessionCommandResult(text: text.isEmpty ? "Command completed" : text)
    }

    public func history(sessionId: String) async throws -> [CanonicalTurn] {
        observedSessions.insert(sessionId)
        try await ensureInteractions()
        let revision = progressRevision[sessionId, default: 0]
        let records = try await host.history(sessionId: sessionId)
        let history = DshSessionHistoryReader.turns(from: records, sessionId: sessionIDPrefix + sessionId)
        if revision == progressRevision[sessionId, default: 0] {
            progressBySession[sessionId] = DshSessionHistoryReader.progress(from: records)
        }
        if followers[sessionId] == nil, journalSequence[sessionId] == nil {
            journalSequence[sessionId] = records.compactMap(Self.sequence).max() ?? 0
        }
        if turnIDs[sessionId] == nil, externalTurns[sessionId] == nil,
           let running = history.last, running.status == .inProgress {
            externalTurns[sessionId] = (running.turnNumber, running.turnId)
        }
        do { try await follow(sessionId: sessionId) }
        catch { scheduleFollowerRetry(sessionId: sessionId); throw error }
        return history
    }

    private func ensureInteractions() async throws {
        if interactionTask != nil { return }
        let opening: Task<(String, AsyncStream<BackendWireEvent>), Error>
        if let current = interactionOpening { opening = current }
        else {
            opening = Task { try await interactionHost.interactions() }
            interactionOpening = opening
        }
        do {
            let (clientID, stream) = try await opening.value
            if interactionTask != nil { return }
            interactionOpening = nil
            interactionClientID = clientID
            retrySeconds = 1
            interactionTask = Task { [weak self] in
                for await event in stream {
                    guard let self, !Task.isCancelled else { break }
                    await self.handleInteraction(event, clientID: clientID)
                }
                await self?.interactionEnded(clientID: clientID)
            }
        } catch {
            interactionOpening = nil
            scheduleInteractionRetry()
            throw error
        }
    }

    private func handleInteraction(_ event: BackendWireEvent, clientID: String) async {
        guard interactionClientID == clientID, let type = event["type"] as? String,
              let eventID = event["eventId"] as? String else { return }
        if type == "cancel" {
            await removeQuestion(eventID: eventID)
            return
        }
        guard type == "waterfall", let sessionID = event["agentId"] as? String,
              let name = event["event"] as? String, let request = event["request"] as? [String: Any] else { return }
        let validQuestion = name == "user-questions/request" && {
            guard let items = request["questions"] as? [[String: Any]], !items.isEmpty else { return false }
            return items.allSatisfy { ($0["id"] as? String)?.isEmpty == false && ($0["question"] as? String)?.isEmpty == false }
        }()
        let validPermission = name == "approval/request" && (request["toolName"] as? String)?.isEmpty == false
        guard observedSessions.contains(sessionID), validQuestion || validPermission else {
            let next = Data(#"{"kind":"next"}"#.utf8)
            try? await interactionHost.resolveInteraction(clientID: clientID, eventID: eventID, outcomeData: next)
            return
        }
        let translated = DshMessageTranslator().translateApprovalRequest(
            approvalId: eventID, sessionId: sessionIDPrefix + sessionID, eventType: name, params: request)
        guard !(questions[sessionID] ?? []).contains(where: { $0.id == eventID }) else { return }
        questions[sessionID, default: []].append(translated)
        if validPermission, let callID = request["callId"] as? String, !callID.isEmpty,
           let toolName = request["toolName"] as? String {
            pendingPermissionDetails[eventID] = .init(clientID: clientID, sessionID: sessionID,
                                                      callID: callID, toolName: toolName, original: request)
        }
        if questions[sessionID]?.count == 1 { await publish(.approvalRequired(translated)) }
        if pendingPermissionDetails[eventID] != nil {
            pendingPermissionDetails[eventID]?.published = true
            Task { [weak self] in await self?.enrichPermission(eventID: eventID) }
        }
    }

    private func enrichPermission(eventID: String) async {
        guard let pending = pendingPermissionDetails[eventID], pending.published, interactionClientID == pending.clientID,
              !resolving.contains(eventID), let records = try? await host.history(sessionId: pending.sessionID) else { return }
        let matches = records.compactMap { record -> [String: Any]? in
            guard let event = record["event"] as? [String: Any], event["type"] as? String == "tool/call",
                  let data = event["data"] as? [String: Any], data["callId"] as? String == pending.callID,
                  data["name"] as? String == pending.toolName else { return nil }
            return data
        }
        guard matches.count == 1, let raw = matches.first?["arguments"] else { return }
        let args: [String: Any]?
        if let object = raw as? [String: Any] { args = object }
        else if let string = raw as? String, let data = string.data(using: .utf8) {
            args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } else { args = nil }
        guard let args, !args.isEmpty, interactionClientID == pending.clientID,
              pendingPermissionDetails[eventID] != nil, !resolving.contains(eventID),
              let index = questions[pending.sessionID]?.firstIndex(where: { $0.id == eventID }) else { return }
        var payload = pending.original
        payload["arguments"] = args
        let updated = DshMessageTranslator().translateApprovalRequest(approvalId: eventID,
            sessionId: sessionIDPrefix + pending.sessionID, eventType: "approval/request", params: payload)
        questions[pending.sessionID]?[index] = updated
        pendingPermissionDetails.removeValue(forKey: eventID)
        if index == 0 { await publish(.approvalUpdated(updated)) }
    }

    private func interactionEnded(clientID: String) async {
        guard interactionClientID == clientID else { return }
        interactionTask = nil
        interactionClientID = nil
        let pending = questions.values.flatMap { $0 }
        questions.removeAll()
        pendingPermissionDetails.removeAll()
        for request in pending { await publish(.approvalWithdrawn(approvalId: request.id)) }
        scheduleInteractionRetry()
    }

    private func scheduleInteractionRetry() {
        guard interactionRetry == nil, !observedSessions.isEmpty else { return }
        let delay = retrySeconds
        retrySeconds = min(retrySeconds * 2, 30)
        interactionRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryInteractions()
        }
    }

    private func retryInteractions() async {
        interactionRetry = nil
        guard interactionTask == nil else { return }
        do { try await ensureInteractions() }
        catch { scheduleInteractionRetry() }
    }

    private func removeQuestion(eventID: String) async {
        for (session, queue) in questions {
            guard let index = queue.firstIndex(where: { $0.id == eventID }) else { continue }
            var remaining = queue
            remaining.remove(at: index)
            questions[session] = remaining
            pendingPermissionDetails.removeValue(forKey: eventID)
            if index == 0 {
                await publish(.approvalWithdrawn(approvalId: eventID))
                if let next = remaining.first { await publish(.approvalRequired(next)) }
            }
            return
        }
    }

    public func resolve(sessionId: String, approvalId: String, decision: ApprovalDecision) async throws {
        guard let clientID = interactionClientID, let request = questions[sessionId]?.first,
              request.id == approvalId, resolving.insert(approvalId).inserted else {
            throw PharosClientError.operationFailed("DSH question is no longer active")
        }
        defer { resolving.remove(approvalId) }
        let outcome: [String: Any]
        if case .toolPermission = request.kind {
            switch decision.choice {
            case .allowedOnce: outcome = ["kind": "result", "value": "allowed-once"]
            case .rejected: outcome = ["kind": "result", "value": "rejected"]
            case .allowedAlways: throw PharosClientError.operationFailed("DSH does not offer always-allow for this request")
            case .cancelled: throw PharosClientError.operationFailed("DSH does not expose cancel-turn for this request")
            }
        } else if decision.choice == .rejected { outcome = ["kind": "next"] }
        else {
            guard decision.choice == .allowedOnce, case .structuredQuestionnaire(_, let items) = request.kind,
                  let supplied = decision.answers else { throw PharosClientError.operationFailed("DSH needs answers to the question") }
            let answers: [[String: Any]] = try items.map { item in
                guard let values = supplied[item.id], !values.isEmpty else {
                    throw PharosClientError.operationFailed("Every DSH question needs an answer")
                }
                let selected = values.filter { item.options.contains($0) }
                let custom = values.filter { !item.options.contains($0) }
                guard custom.count <= 1, (custom.isEmpty || item.allowsFreeText == true),
                      item.isMultiSelect || values.count == 1 else {
                    throw PharosClientError.operationFailed("Invalid DSH question answer")
                }
                var answer: [String: Any] = ["id": item.id, "selected": selected]
                if let text = custom.first { answer["custom"] = text }
                return answer
            }
            outcome = ["kind": "result", "value": ["answers": answers]]
        }
        let outcomeData = try JSONSerialization.data(withJSONObject: outcome)
        try await interactionHost.resolveInteraction(clientID: clientID, eventID: approvalId, outcomeData: outcomeData)
        // A concurrent Host cancellation may already have withdrawn this request.
        guard questions[sessionId]?.first?.id == approvalId else { return }
        questions[sessionId]?.removeFirst()
        pendingPermissionDetails.removeValue(forKey: approvalId)
        await publish(.approvalResolved(approvalId: approvalId, decision: decision))
        if let next = questions[sessionId]?.first { await publish(.approvalRequired(next)) }
    }

    public func pendingApproval(sessionId: String) -> CanonicalApprovalRequest? { questions[sessionId]?.first }

    public func progress(sessionId: String) -> CanonicalSessionProgress? {
        progressBySession[sessionId]
    }

    private func follow(sessionId: String) async throws {
        guard followers[sessionId] == nil, following.insert(sessionId).inserted else { return }
        defer { following.remove(sessionId) }
        let stream = try await host.follow(sessionId: sessionId)
        followers[sessionId] = Task { [weak self] in
            for await frame in stream {
                guard let self, !Task.isCancelled else { break }
                await self.handle(frame, sessionId: sessionId)
            }
            await self?.followerFinished(sessionId: sessionId)
        }
    }

    private func followerFinished(sessionId: String) {
        followers.removeValue(forKey: sessionId)
        scheduleFollowerRetry(sessionId: sessionId)
    }

    private func scheduleFollowerRetry(sessionId: String) {
        guard followerRetries[sessionId] == nil, observedSessions.contains(sessionId) else { return }
        let delay = followerRetrySeconds[sessionId, default: 1]
        followerRetrySeconds[sessionId] = min(delay * 2, 30)
        followerRetries[sessionId] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retryFollower(sessionId: sessionId)
        }
    }

    private func retryFollower(sessionId: String) async {
        followerRetries.removeValue(forKey: sessionId)
        do { try await follow(sessionId: sessionId) }
        catch { scheduleFollowerRetry(sessionId: sessionId) }
    }

    private static func sequence(_ event: BackendWireEvent) -> Int? {
        (event["event"] as? [String: Any])?["seq"] as? Int
    }

    private func handle(_ event: BackendWireEvent, sessionId: String) async {
        let uiID = sessionIDPrefix + sessionId
        if event["type"] as? String == "snapshot" {
            followerRetrySeconds[sessionId] = 1
            do {
                let records = try await host.history(sessionId: sessionId)
                for record in records where (Self.sequence(record) ?? 0) > journalSequence[sessionId, default: 0] {
                    await handle(record, sessionId: sessionId)
                }
            } catch { await publish(.backendError(.operationFailed(error.localizedDescription))) }
            return
        }
        if event["type"] as? String == "event", let journal = event["event"] as? [String: Any],
           let type = journal["type"] as? String, let data = journal["data"] as? [String: Any] {
            if let seq = journal["seq"] as? Int {
                guard seq > journalSequence[sessionId, default: 0] else { return }
                journalSequence[sessionId] = seq
            }
            if type == "permission/preset" || type == "sandbox/mode" || type == "approval/policy" {
                await publish(.sessionConfigurationUpdated(sessionId: uiID))
            } else if type == "model/selection", data["provider"] as? String != nil, data["model"] as? String != nil {
                modelSelections[sessionId] = BackendWireEvent(data)
                modelRevisions[sessionId, default: 0] += 1
                await publish(.sessionConfigurationUpdated(sessionId: uiID))
            } else if type == "tool/call", let callID = data["callId"] as? String {
                let pendingIDs = pendingPermissionDetails.filter {
                    $0.value.sessionID == sessionId && $0.value.callID == callID
                }.map(\.key)
                for eventID in pendingIDs { Task { [weak self] in await self?.enrichPermission(eventID: eventID) } }
            } else if type == "turn/start", let number = data["turn"] as? Int {
                if let baseline = turnBaselines[sessionId], number == baseline + 1 { return }
                if let baseline = turnBaselines[sessionId], number > baseline + 1 {
                    await finishOwnedTurnIfReady(sessionId: sessionId, after: baseline)
                }
                let id = "\(uiID):turn:\(number)"
                guard externalTurns[sessionId]?.number != number else { return }
                externalTurns[sessionId] = (number, id)
                activeAttempts[sessionId] = []
                await publish(.turnStarted(.init(turnId: id, sessionId: uiID, turnNumber: number, status: .inProgress)))
            } else if type == "turn/end", let number = data["turn"] as? Int,
                      let external = externalTurns[sessionId], external.number == number {
                do {
                    let records = try await host.history(sessionId: sessionId)
                    let turns = DshSessionHistoryReader.turns(from: records, sessionId: uiID)
                    if let completed = turns.first(where: { $0.turnNumber == number }), completed.status != .inProgress,
                       externalTurns[sessionId]?.number == number {
                        externalTurns.removeValue(forKey: sessionId)
                        activeAttempts.removeValue(forKey: sessionId)
                        await publish(.turnCompleted(completed))
                    }
                } catch { await publish(.backendError(.operationFailed(error.localizedDescription))) }
            } else if type == "goal/change" {
                progressRevision[sessionId, default: 0] += 1
                if data["operation"] as? String == "clear" {
                    progressBySession[sessionId] = CanonicalSessionProgress(goal: nil, todos: progressBySession[sessionId]?.todos ?? [])
                    await publish(.sessionGoalUpdated(sessionId: uiID, goal: nil))
                } else if let goal = SessionProgressMapping.goal(data["goal"] as? [String: Any], statusKey: "phase") {
                    progressBySession[sessionId] = CanonicalSessionProgress(goal: goal, todos: progressBySession[sessionId]?.todos ?? [])
                    await publish(.sessionGoalUpdated(sessionId: uiID, goal: goal))
                }
            } else if type == "todo/write", let todos = SessionProgressMapping.todos(data["todos"], textKey: "content") {
                progressRevision[sessionId, default: 0] += 1
                progressBySession[sessionId] = CanonicalSessionProgress(goal: progressBySession[sessionId]?.goal, todos: todos)
                await publish(.sessionTodosUpdated(sessionId: uiID, todos: todos))
            }
            return
        }
        guard event["type"] as? String == "assistant-stream", let frame = event["frame"] as? [String: Any],
              let turnID = externalTurns[sessionId]?.id ?? turnIDs[sessionId], let attemptID = frame["attemptId"] as? String else { return }
        if let turn = frame["turn"] as? Int,
           turn == (externalTurns[sessionId]?.number ?? ((turnBaselines[sessionId] ?? 0) + 1)) {
            activeAttempts[sessionId, default: []].insert(attemptID)
        }
        guard activeAttempts[sessionId]?.contains(attemptID) == true,
              let chunk = frame["chunk"] as? [String: Any], let type = chunk["type"] as? String,
              let text = chunk["text"] as? String,
              let delta = DshMessageTranslator().translateStreamingDelta(sessionId: uiID, turnId: turnID,
                                                                           deltaType: type, chunk: text) else { return }
        await publish(.streamingDelta(delta))
    }

    public func stageFile(sessionId: String, data: Data, name: String) async throws -> DshStagedFile {
        guard let attachmentHost = host as? any DshAttachmentHosting else {
            throw PharosClientError.operationFailed("DSH file uploads are unavailable")
        }
        return try await attachmentHost.stageFile(sessionId: sessionId, data: data, name: name)
    }

    public func send(sessionId: String, text: String, turnID requestedTurnID: String? = nil) async throws -> CanonicalTurn {
        try await send(sessionId: sessionId, text: text, files: [], requestId: UUID().uuidString, turnID: requestedTurnID)
    }

    public func send(sessionId: String, text: String, files: [DshStagedFile], requestId: String,
                     turnID requestedTurnID: String? = nil) async throws -> CanonicalTurn {
        guard active[sessionId] == nil else { throw PharosClientError.operationFailed("A DSH turn is already running") }
        guard externalTurns[sessionId] == nil else { throw PharosClientError.operationFailed("An external DSH turn is already running") }
        guard starting.insert(sessionId).inserted else { throw PharosClientError.operationFailed("A DSH turn is already starting") }
        defer { starting.remove(sessionId) }
        let previous = try await history(sessionId: sessionId)
        guard externalTurns[sessionId] == nil else { throw PharosClientError.operationFailed("An external DSH turn started while loading history") }
        let lastNumber = previous.last?.turnNumber ?? 0
        let turnID = requestedTurnID ?? ("dsh-pending-" + UUID().uuidString)
        guard !turnID.isEmpty else { throw PharosClientError.operationFailed("DSH turn ID is empty") }
        turnIDs[sessionId] = turnID
        turnBaselines[sessionId] = lastNumber
        activeAttempts[sessionId] = []
        do {
            if files.isEmpty {
                try await host.prompt(sessionId: sessionId, text: text, mode: .queue)
            } else {
                guard let attachmentHost = host as? any DshAttachmentHosting else { throw PharosClientError.operationFailed("DSH file uploads are unavailable") }
                try await attachmentHost.promptWithFiles(sessionId: sessionId, text: text, files: files, requestId: requestId, mode: .queue)
            }
        } catch {
            turnIDs.removeValue(forKey: sessionId)
            turnBaselines.removeValue(forKey: sessionId)
            activeAttempts.removeValue(forKey: sessionId)
            throw error
        }
        let uiID = sessionIDPrefix + sessionId
        let source = host, prefix = sessionIDPrefix
        active[sessionId] = Task { [weak self, source] in
            while !Task.isCancelled {
                do {
                    // Do not retain the service while waiting for I/O or the next poll.
                    let records = try await source.history(sessionId: sessionId)
                    guard !Task.isCancelled else { return }
                    let turns = DshSessionHistoryReader.turns(from: records, sessionId: prefix + sessionId)
                    guard let finished = await self?.finishOwnedTurn(sessionId: sessionId, after: lastNumber, turnID: turnID, turns: turns) else { return }
                    if finished { return }
                } catch {
                    if !Task.isCancelled { await self?.ownedPollFailed(sessionId: sessionId, turnID: turnID, error: error) }
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        var blocks = files.map { file in
            CanonicalBlock(blockId: turnID + "-attachment-" + file.receiptId, kind: .attachment(.init(
                id: file.attachmentId, filename: file.name, mimeType: "application/octet-stream", sizeBytes: Int64(file.byteCount), uri: "")))
        }
        if !text.isEmpty { blocks.append(.init(blockId: turnID + "-user", kind: .userText(text))) }
        return CanonicalTurn(turnId: turnID, sessionId: uiID, turnNumber: lastNumber + 1, status: .inProgress,
            steps: [.init(stepId: turnID, stepNumber: 1, status: .running, blocks: blocks)])
    }

    private func ownedPollFailed(sessionId: String, turnID: String, error: Error) async {
        guard turnIDs[sessionId] == turnID else { return }
        active.removeValue(forKey: sessionId)
        turnIDs.removeValue(forKey: sessionId)
        turnBaselines.removeValue(forKey: sessionId)
        if externalTurns[sessionId] == nil { activeAttempts.removeValue(forKey: sessionId) }
        await publish(.backendError(.operationFailed(error.localizedDescription)))
    }

    private func finishOwnedTurnIfReady(sessionId: String, after number: Int) async {
        guard let turnID = turnIDs[sessionId], let turns = try? await history(sessionId: sessionId) else { return }
        _ = await finishOwnedTurn(sessionId: sessionId, after: number, turnID: turnID, turns: turns)
    }

    private func finishOwnedTurn(sessionId: String, after number: Int, turnID: String, turns: [CanonicalTurn]) async -> Bool {
        guard turnIDs[sessionId] == turnID, let turn = turns.first(where: { $0.turnNumber == number + 1 }),
              turn.status != .inProgress else { return false }
        let completed = CanonicalTurn(turnId: turnID, sessionId: turn.sessionId, turnNumber: turn.turnNumber,
                                      status: turn.status, createdAt: turn.createdAt,
                                      completedAt: turn.completedAt, steps: turn.steps)
        turnIDs.removeValue(forKey: sessionId)
        turnBaselines.removeValue(forKey: sessionId)
        active.removeValue(forKey: sessionId)?.cancel()
        await publish(.turnCompleted(completed))
        return true
    }

    public func steer(sessionId: String, text: String) async throws {
        guard active[sessionId] != nil || externalTurns[sessionId] != nil else {
            throw PharosClientError.operationFailed("No DSH turn to steer")
        }
        try await host.prompt(sessionId: sessionId, text: text, mode: .steer)
    }
}
