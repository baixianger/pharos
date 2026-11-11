import SwiftUI
import PharosClientKit

/// Observable ViewModel driving the collaborative multi-agent group chat Thread path (RFC-006 §2, §5).
/// Coordinates plain chat bubble message histories, real-time multi-agent delivery receipt progression,
/// and enforces the implicit human participant invariant.
@MainActor
@Observable
public final class ThreadConversationViewModel {
    public let threadId: String
    public let clientService: PharosClientService
    public let implicitHumanId: String
    public let implicitHumanName: String

    public var threadSummary: ClientThreadSummary?
    public var messages: [ClientThreadMessage] = []
    public var rosterMembers: [ClientMemberDetail] = []
    public var activeError: PharosClientError?
    public var isSending: Bool = false

    private var eventListeningTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var rosterRevision = 0

    public init(
        threadId: String,
        clientService: PharosClientService,
        implicitHumanId: String = "human",
        implicitHumanName: String = "You"
    ) {
        self.threadId = threadId
        self.clientService = clientService
        self.implicitHumanId = implicitHumanId
        self.implicitHumanName = implicitHumanName
    }

    isolated deinit {
        eventListeningTask?.cancel()
        historyRefreshTask?.cancel()
    }

    // MARK: - Lifecycle & History Loading

    static func visibleAgentIDs(in summary: ClientThreadSummary, implicitHumanId: String = "human") -> [String] {
        var seen: Set<String> = [implicitHumanId, "human", "tester"]
        return summary.memberIds.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public func loadThreadData() async {
        startListeningToEvents()
        do {
            try await refreshRoster()
            let history = try await clientService.fetchThreadMessages(threadId: threadId)
            self.messages = history
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
        }

        historyRefreshTask?.cancel()
        historyRefreshTask = Task { [weak self, clientService, threadId] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { return }
                do { try await self.refreshRoster() }
                catch { self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription) }
                guard !self.isSending else { continue }
                do {
                    let history = try await clientService.fetchThreadMessages(threadId: threadId)
                    guard !Task.isCancelled, !self.isSending else { continue }
                    self.messages = history
                } catch {
                    self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
                }
            }
        }
    }

    func refreshRoster() async throws {
        let initialRevision = rosterRevision
        let allThreads = try await clientService.fetchThreads()
        guard let found = allThreads.first(where: { $0.threadId == threadId }) else {
            guard rosterRevision == initialRevision else { return }
            threadSummary = nil
            rosterMembers = []
            return
        }
        let ids = Self.visibleAgentIDs(in: found, implicitHumanId: implicitHumanId)
        var loaded: [ClientMemberDetail] = []
        for id in ids {
            if let detail = try? await clientService.fetchMemberDetail(name: id) { loaded.append(detail) }
            else {
                loaded.append(ClientMemberDetail(name: id, agent: id, machine: "mesh", model: "", mode: "",
                                                 status: "unknown", avatarSeed: id))
            }
        }
        guard rosterRevision == initialRevision else { return }
        threadSummary = found
        rosterMembers = loaded
    }

    public func startListeningToEvents() {
        eventListeningTask?.cancel()
        eventListeningTask = Task { [weak self, clientService] in
            for await event in clientService.events() {
                guard let self, !Task.isCancelled else { break }
                self.handleClientEvent(event)
            }
        }
    }

    // MARK: - Event Handling

    public func handleClientEvent(_ event: PharosClientEvent) {
        switch event {
        case .threadMessageReceived(let msg):
            guard msg.threadId == threadId else { return }
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                let existing = messages[idx]
                if existing.senderId == implicitHumanId {
                    messages[idx] = ClientThreadMessage(id: msg.id, threadId: msg.threadId,
                        senderId: existing.senderId, senderName: existing.senderName,
                        senderAvatarSeed: msg.senderAvatarSeed, text: msg.text, timestamp: msg.timestamp,
                        receipt: msg.receipt, attachments: msg.attachments, replyTo: msg.replyTo)
                } else {
                    messages[idx] = msg
                }
            } else {
                messages.append(msg)
            }

        case .threadReceiptUpdated(let tId, let mId, let receipt):
            guard tId == threadId else { return }
            if let idx = messages.firstIndex(where: { $0.id == mId }) {
                let existing = messages[idx]
                messages[idx] = ClientThreadMessage(
                    id: existing.id,
                    threadId: existing.threadId,
                    senderId: existing.senderId,
                    senderName: existing.senderName,
                    senderAvatarSeed: existing.senderAvatarSeed,
                    text: existing.text,
                    timestamp: existing.timestamp,
                    receipt: receipt,
                    attachments: existing.attachments,
                    replyTo: existing.replyTo
                )
            }

        case .memberStatusChanged(let name, let status):
            let matchingIDs = rosterMembers.indices.filter { rosterMembers[$0].avatarSeed == name }
            let matchingNames = rosterMembers.indices.filter { rosterMembers[$0].name == name }
            let idx = matchingIDs.count == 1 ? matchingIDs.first : (matchingNames.count == 1 ? matchingNames.first : nil)
            if let idx {
                rosterRevision += 1
                let m = rosterMembers[idx]
                rosterMembers[idx] = ClientMemberDetail(
                    name: m.name,
                    agent: m.agent,
                    machine: m.machine,
                    model: m.model,
                    mode: m.mode,
                    status: status,
                    tmuxSession: m.tmuxSession,
                    avatarSeed: m.avatarSeed
                )
            }

        case .backendError(let error):
            self.activeError = error

        default:
            break
        }
    }

    // MARK: - Message Dispatch

    public func sendMessage(text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Plain chat bubble DTO: Optimistic user message with .pending receipt
        let optimisticId = "msg_opt_\(UUID().uuidString.prefix(6))"
        let optimisticMsg = ClientThreadMessage(
            id: optimisticId,
            threadId: threadId,
            senderId: implicitHumanId,
            senderName: implicitHumanName,
            senderAvatarSeed: nil,
            text: text,
            timestamp: Date(),
            receipt: .pending
        )

        messages.append(optimisticMsg)
        isSending = true

        do {
            let confirmedMsg = try await clientService.sendThreadMessage(threadId: threadId, text: text)
            // Preserve client human sender identity invariant
            let finalMsg = ClientThreadMessage(
                id: confirmedMsg.id,
                threadId: confirmedMsg.threadId,
                senderId: implicitHumanId,
                senderName: implicitHumanName,
                senderAvatarSeed: confirmedMsg.senderAvatarSeed,
                text: confirmedMsg.text,
                timestamp: confirmedMsg.timestamp,
                receipt: confirmedMsg.receipt,
                attachments: confirmedMsg.attachments,
                replyTo: confirmedMsg.replyTo
            )
            confirmSentMessage(finalMsg, optimisticId: optimisticId)
            isSending = false
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
            isSending = false
        }
    }

    /// The event stream can announce the committed message before the send
    /// call returns. Reconcile by server ID, never by text or timestamp.
    func confirmSentMessage(_ confirmed: ClientThreadMessage, optimisticId: String) {
        if let existing = messages.firstIndex(where: { $0.id == confirmed.id }) {
            let eventMessage = messages[existing]
            messages[existing] = ClientThreadMessage(id: eventMessage.id, threadId: eventMessage.threadId,
                senderId: confirmed.senderId, senderName: confirmed.senderName,
                senderAvatarSeed: eventMessage.senderAvatarSeed, text: eventMessage.text,
                timestamp: eventMessage.timestamp, receipt: eventMessage.receipt,
                attachments: eventMessage.attachments, replyTo: eventMessage.replyTo)
            messages.removeAll { $0.id == optimisticId && $0.id != confirmed.id }
        } else if let optimistic = messages.firstIndex(where: { $0.id == optimisticId }) {
            messages[optimistic] = confirmed
        }
    }

    public func updateMessageReceipt(messageId: String, receipt: DeliveryReceiptState) {
        if let idx = messages.firstIndex(where: { $0.id == messageId }) {
            let existing = messages[idx]
            messages[idx] = ClientThreadMessage(
                id: existing.id,
                threadId: existing.threadId,
                senderId: existing.senderId,
                senderName: existing.senderName,
                senderAvatarSeed: existing.senderAvatarSeed,
                text: existing.text,
                timestamp: existing.timestamp,
                receipt: receipt,
                attachments: existing.attachments,
                replyTo: existing.replyTo
            )
        }
    }

    public func dismissError() {
        self.activeError = nil
    }
}
