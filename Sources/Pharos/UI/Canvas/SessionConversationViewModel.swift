import SwiftUI
import PharosClientKit

/// Observable ViewModel driving the 1:1 direct agent Session chat,
/// live token delta coalescing, mid-turn steering, and interactive approvals.
@MainActor
@Observable
public final class SessionConversationViewModel {
    public private(set) var isLoadingHistory = true
    struct LiveTool: Encodable, Equatable {
        let name: String
        var text: String
    }

    public let sessionId: String
    public let clientService: PharosClientService

    public var turns: [CanonicalTurn] = []
    public var activeApproval: CanonicalApprovalRequest?
    var goal: CanonicalSessionGoal?
    var todos: [CanonicalSessionTodo] = []
    public var activeError: PharosClientError? { didSet { errorRevision += 1 } }
    public var isTurnInProgress: Bool = false
    public private(set) var commandResult: String?
    public private(set) var configuration: ClientSessionConfiguration?
    /// True when the configuration fetch failed, so the shell can report the
    /// honest "Configuration unavailable" notice instead of pretending the
    /// Session has no model/mode controls.
    public private(set) var configurationLoadFailed = false
    public private(set) var supportsTextAttachments = false
    public private(set) var configurationInFlight = false
    private var configurationRevision = 0
    private var commandInFlight = false

    // Live streaming coalescing buffers (RFC-006 §4)
    public var activeTurnId: String?
    public var liveStreamingText: String = ""
    public var liveReasoningText: String = ""
    var liveTools: [LiveTool] = []

    private var eventListeningTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var approvalInFlight: String?
    private var historyGeneration = 0
    private var errorRevision = 0
    private var turnRevision = 0
    private var turnMutationRevisions: [String: Int] = [:]
    private var goalRevision = 0
    private var todoRevision = 0
    private var approvalRevision = 0

    public init(sessionId: String, clientService: PharosClientService) {
        self.sessionId = sessionId
        self.clientService = clientService
    }

    isolated deinit {
        eventListeningTask?.cancel()
        recoveryTask?.cancel()
    }

    // MARK: - Lifecycle & Event Subscription

    public func loadHistory() async {
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = true
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        startListeningToEvents()
        let initialErrorRevision = errorRevision
        let initialTurnRevision = turnRevision
        let initialGoalRevision = goalRevision
        let initialTodoRevision = todoRevision
        let initialApprovalRevision = approvalRevision
        let initialConfigurationRevision = configurationRevision
        do {
            let history = try await clientService.fetchSessionHistory(sessionId: sessionId)
            guard generation == historyGeneration, !Task.isCancelled else { return }
            var merged = history
            for turn in turns where (turnMutationRevisions[turn.turnId] ?? 0) > initialTurnRevision {
                if let index = merged.firstIndex(where: { $0.turnId == turn.turnId }) {
                    merged[index] = turn
                } else if let index = merged.firstIndex(where: { $0.turnNumber > turn.turnNumber }) {
                    merged.insert(turn, at: index)
                } else {
                    merged.append(turn)
                }
            }
            self.turns = merged
            if initialTurnRevision == turnRevision {
                if let last = history.last, last.status == .inProgress {
                    self.isTurnInProgress = true
                    self.activeTurnId = last.turnId
                } else {
                    self.isTurnInProgress = false
                    self.activeTurnId = nil
                    self.liveStreamingText = ""
                    self.liveReasoningText = ""
                    self.liveTools.removeAll()
                }
            }
            let progress = try await clientService.fetchSessionProgress(sessionId: sessionId)
            guard generation == historyGeneration, !Task.isCancelled else { return }
            if let progress {
                if initialGoalRevision == goalRevision { goal = progress.goal }
                if initialTodoRevision == todoRevision { todos = progress.todos }
            }
            let approval = try await clientService.fetchSessionApproval(sessionId: sessionId)
            guard generation == historyGeneration, !Task.isCancelled else { return }
            if approvalRevision == initialApprovalRevision { activeApproval = approval }
            let config: ClientSessionConfiguration?
            do {
                config = try await clientService.fetchSessionConfiguration(sessionId: sessionId)
            } catch {
                guard generation == historyGeneration, !Task.isCancelled else { return }
                configurationLoadFailed = true
                throw error
            }
            guard generation == historyGeneration, !Task.isCancelled else { return }
            if initialConfigurationRevision == configurationRevision {
                configuration = config
                configurationLoadFailed = false
            }
            let supportsText = await clientService.supportsSessionTextAttachments(sessionId: sessionId)
            guard generation == historyGeneration, !Task.isCancelled else { return }
            supportsTextAttachments = supportsText
            if initialErrorRevision == errorRevision { activeError = nil }
        } catch {
            guard generation == historyGeneration, !Task.isCancelled else { return }
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
        }
    }

    public func startListeningToEvents() {
        guard eventListeningTask == nil else { return }
        let stream = clientService.events()
        eventListeningTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleClientEvent(event)
            }
            self?.eventListeningTask = nil
        }
    }

    @MainActor
    public func handleClientEvent(_ event: PharosClientEvent) {
        switch event {
        case .sessionConnectionRestored(let id):
            guard id == sessionId, recoveryTask == nil else { return }
            recoveryTask = Task { [weak self] in
                guard let self else { return }
                while self.isLoadingHistory && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if !Task.isCancelled { await self.loadHistory() }
                self.recoveryTask = nil
            }

        case .sessionConfigurationUpdated(let id):
            guard id == sessionId else { return }
            configurationRevision += 1
            let revision = configurationRevision
            Task { [weak self] in
                guard let self else { return }
                do {
                    let config = try await clientService.fetchSessionConfiguration(sessionId: sessionId)
                    if self.configurationRevision == revision {
                        self.configuration = config
                        self.configurationLoadFailed = false
                    }
                } catch {
                    self.configurationLoadFailed = true
                    self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
                }
            }

        case .turnStarted(let turn):
            guard turn.sessionId == sessionId else { return }
            recordTurnMutation(turn.turnId)
            isTurnInProgress = true
            activeTurnId = turn.turnId
            liveStreamingText = ""
            liveReasoningText = ""
            liveTools.removeAll()
            if let idx = turns.firstIndex(where: { $0.turnId == turn.turnId }) {
                turns[idx] = turn
            } else {
                turns.append(turn)
            }

        case .streamingDelta(let delta):
            guard delta.sessionId == sessionId else { return }
            turnRevision += 1
            if activeTurnId != delta.turnId { liveTools.removeAll() }
            isTurnInProgress = true
            activeTurnId = delta.turnId
            switch delta.deltaType {
            case .textDelta(let chunk):
                liveStreamingText += chunk
            case .reasoningDelta(let chunk):
                liveReasoningText += chunk
            case .toolCallDelta(let callId, let chunk):
                appendToolOutput(name: callId, chunk: chunk)
            case .terminalOutputDelta(let chunk):
                appendToolOutput(name: "Terminal output", chunk: chunk)
            }

        case .turnCompleted(let turn):
            guard turn.sessionId == sessionId else { return }
            recordTurnMutation(turn.turnId)
            if activeTurnId == turn.turnId || activeTurnId == nil {
                isTurnInProgress = false
                activeTurnId = nil
                liveStreamingText = ""
                liveReasoningText = ""
                liveTools.removeAll()
            }
            if let idx = turns.firstIndex(where: { $0.turnId == turn.turnId }) {
                turns[idx] = turn
            } else {
                turns.append(turn)
            }

        case .sessionGoalUpdated(let id, let goal):
            guard id == sessionId else { return }
            goalRevision += 1
            self.goal = goal

        case .sessionTodosUpdated(let id, let todos):
            guard id == sessionId else { return }
            todoRevision += 1
            self.todos = todos

        case .approvalRequired(let request):
            guard request.sessionId == sessionId else { return }
            approvalRevision += 1
            self.activeApproval = request

        case .approvalUpdated(let request):
            guard request.sessionId == sessionId, activeApproval?.approvalId == request.approvalId else { return }
            approvalRevision += 1
            self.activeApproval = request

        case .approvalResolved(let approvalId, _):
            approvalRevision += 1
            if activeApproval?.approvalId == approvalId {
                self.activeApproval = nil
            }

        case .approvalWithdrawn(let approvalId):
            approvalRevision += 1
            if activeApproval?.approvalId == approvalId { self.activeApproval = nil }

        case .backendError(let error):
            self.activeError = error

        default:
            break
        }
    }

    private func recordTurnMutation(_ turnId: String) {
        turnRevision += 1
        turnMutationRevisions[turnId] = turnRevision
    }

    private func appendToolOutput(name: String, chunk: String) {
        if let index = liveTools.firstIndex(where: { $0.name == name }) {
            liveTools[index].text += chunk
        } else {
            liveTools.append(.init(name: name, text: chunk))
        }
    }

    // MARK: - Prompt Sending & Steering

    @discardableResult
    public func sendPrompt(text: String, isSteer: Bool = false, files: [SessionFileUpload] = [], requestId: String = UUID().uuidString) async -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty else { return false }
        guard files.isEmpty || (!isSteer && !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")) else {
            activeError = .operationFailed("Attachments cannot be used with commands or steering")
            return false
        }

        if !isSteer && text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            guard !commandInFlight else {
                activeError = .operationFailed("A command is still running. Please retry.")
                return false
            }
            commandInFlight = true
            defer { commandInFlight = false }
            do {
                if let result = try await clientService.executeSessionCommand(sessionId: sessionId, line: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    commandResult = result.text
                    activeError = nil
                    return true
                }
            } catch {
                commandResult = nil
                activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
                return false
            }
        }
        commandResult = nil

        // History isolation: Turn numbers are scoped exclusively to this session
        let turnNumber = (turns.last?.turnNumber ?? 0) + 1
        let optimisticTurnId = "turn_opt_\(UUID().uuidString.prefix(6))"

        // Create optimistic user block
        let userBlock = CanonicalBlock(
            blockId: "blk_usr_\(UUID().uuidString.prefix(6))",
            kind: .userText(text)
        )
        let optimisticTurn = CanonicalTurn(
            turnId: optimisticTurnId,
            sessionId: sessionId,
            turnNumber: turnNumber,
            status: .inProgress,
            steps: [CanonicalStep(stepId: "step_1", stepNumber: 1, status: .running, blocks: [userBlock])]
        )

        recordTurnMutation(optimisticTurnId)
        turns.append(optimisticTurn)
        if !isSteer {
            isTurnInProgress = true
            activeTurnId = optimisticTurnId
        }

        do {
            if isSteer {
                try await clientService.steerSession(sessionId: sessionId, text: text)
            } else {
                let confirmedTurn = try await clientService.sendSessionMessage(sessionId: sessionId, text: text, files: files, requestId: requestId)
                if let idx = turns.firstIndex(where: { $0.turnId == optimisticTurnId }) {
                    if turns.contains(where: { $0.turnId == confirmedTurn.turnId && $0.status != .inProgress }) {
                        turns.remove(at: idx)
                        turnMutationRevisions.removeValue(forKey: optimisticTurnId)
                        if activeTurnId == optimisticTurnId { isTurnInProgress = false; activeTurnId = nil }
                    } else {
                        turns[idx] = confirmedTurn
                        turnMutationRevisions.removeValue(forKey: optimisticTurnId)
                        recordTurnMutation(confirmedTurn.turnId)
                    }
                }
                if activeTurnId == optimisticTurnId { activeTurnId = confirmedTurn.turnId }
            }
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
            turns.removeAll { $0.turnId == optimisticTurnId }
            turnMutationRevisions.removeValue(forKey: optimisticTurnId)
            if activeTurnId == optimisticTurnId {
                activeTurnId = nil
                isTurnInProgress = false
            }
            return false
        }
        return true
    }

    public func setConfiguration(configId: String, value: String) async {
        guard !configurationInFlight else { return }
        configurationInFlight = true
        defer { configurationInFlight = false }
        let revision = configurationRevision
        do {
            let updated = try await clientService.setSessionConfiguration(sessionId: sessionId, configId: configId, value: value)
            if revision == configurationRevision { configuration = updated }
            activeError = nil
        } catch { activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription) }
    }

    // MARK: - Approval Resolution

    public func resolveApproval(decision: ApprovalDecision) async {
        guard let request = activeApproval, approvalInFlight == nil else { return }
        approvalInFlight = request.approvalId
        defer { approvalInFlight = nil }
        do {
            try await clientService.resolveSessionApproval(
                sessionId: sessionId,
                approvalId: request.approvalId,
                decision: decision
            )
            if activeApproval?.approvalId == request.approvalId { activeApproval = nil }
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
        }
    }

    public func dismissError() {
        self.activeError = nil
    }

    public func interruptSession() async {
        isTurnInProgress = false
        activeTurnId = nil
        liveStreamingText = ""
        liveReasoningText = ""
        liveTools.removeAll()
    }
}
