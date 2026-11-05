import SwiftUI
import PharosClientKit

/// Observable ViewModel driving the 1:1 direct agent Session chat,
/// live token delta coalescing, mid-turn steering, and interactive approvals.
@MainActor
@Observable
public final class SessionConversationViewModel {
    public let sessionId: String
    public let clientService: PharosClientService

    public var turns: [CanonicalTurn] = []
    public var activeApproval: CanonicalApprovalRequest?
    public var activeError: PharosClientError?
    public var isTurnInProgress: Bool = false

    // Live streaming coalescing buffers (RFC-006 §4)
    public var activeTurnId: String?
    public var liveStreamingText: String = ""
    public var liveReasoningText: String = ""

    private var eventListeningTask: Task<Void, Never>?

    public init(sessionId: String, clientService: PharosClientService) {
        self.sessionId = sessionId
        self.clientService = clientService
    }

    isolated deinit {
        eventListeningTask?.cancel()
    }

    // MARK: - Lifecycle & Event Subscription

    public func loadHistory() async {
        do {
            let history = try await clientService.fetchSessionHistory(sessionId: sessionId)
            self.turns = history
            if let last = history.last, last.status == .inProgress {
                self.isTurnInProgress = true
                self.activeTurnId = last.turnId
            }
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
        }
        startListeningToEvents()
    }

    public func startListeningToEvents() {
        eventListeningTask?.cancel()
        eventListeningTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.clientService.events() {
                guard !Task.isCancelled else { break }
                self.handleClientEvent(event)
            }
        }
    }

    @MainActor
    public func handleClientEvent(_ event: PharosClientEvent) {
        switch event {
        case .turnStarted(let turn):
            guard turn.sessionId == sessionId else { return }
            isTurnInProgress = true
            activeTurnId = turn.turnId
            liveStreamingText = ""
            liveReasoningText = ""
            if let idx = turns.firstIndex(where: { $0.turnId == turn.turnId }) {
                turns[idx] = turn
            } else {
                turns.append(turn)
            }

        case .streamingDelta(let delta):
            guard delta.sessionId == sessionId else { return }
            isTurnInProgress = true
            activeTurnId = delta.turnId
            switch delta.deltaType {
            case .textDelta(let chunk):
                liveStreamingText += chunk
            case .reasoningDelta(let chunk):
                liveReasoningText += chunk
            case .toolCallDelta(let callId, let chunk):
                liveStreamingText += "\n[Tool \(callId)]: \(chunk)"
            case .terminalOutputDelta(let chunk):
                liveStreamingText += chunk
            }

        case .turnCompleted(let turn):
            guard turn.sessionId == sessionId else { return }
            isTurnInProgress = false
            activeTurnId = nil
            liveStreamingText = ""
            liveReasoningText = ""
            if let idx = turns.firstIndex(where: { $0.turnId == turn.turnId }) {
                turns[idx] = turn
            } else {
                turns.append(turn)
            }

        case .approvalRequired(let request):
            guard request.sessionId == sessionId else { return }
            self.activeApproval = request

        case .approvalResolved(let approvalId, _):
            if activeApproval?.approvalId == approvalId {
                self.activeApproval = nil
            }

        case .backendError(let error):
            self.activeError = error

        default:
            break
        }
    }

    // MARK: - Prompt Sending & Steering

    public func sendPrompt(text: String, isSteer: Bool = false) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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

        turns.append(optimisticTurn)
        isTurnInProgress = true
        activeTurnId = optimisticTurnId

        do {
            if isSteer {
                try await clientService.steerSession(sessionId: sessionId, text: text)
            } else {
                let confirmedTurn = try await clientService.sendSessionMessage(sessionId: sessionId, text: text)
                if let idx = turns.firstIndex(where: { $0.turnId == optimisticTurnId }) {
                    turns[idx] = confirmedTurn
                }
            }
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
            isTurnInProgress = false
        }
    }

    // MARK: - Approval Resolution

    public func resolveApproval(decision: ApprovalDecision) async {
        guard let request = activeApproval else { return }
        do {
            try await clientService.resolveSessionApproval(
                sessionId: sessionId,
                approvalId: request.approvalId,
                decision: decision
            )
            self.activeApproval = nil
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
    }
}
