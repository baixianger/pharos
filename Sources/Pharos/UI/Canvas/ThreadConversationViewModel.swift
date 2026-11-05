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
    }

    // MARK: - Lifecycle & History Loading

    public func loadThreadData() async {
        do {
            // 1. Fetch thread summaries to resolve title and roster member IDs
            let allThreads = try await clientService.fetchThreads()
            if let found = allThreads.first(where: { $0.threadId == threadId }) {
                self.threadSummary = found

                // Implicit human participant invariant (RFC-006 §2):
                // Filter out the human user so only autonomous agent members appear in the roster.
                let agentMemberIds = found.memberIds.filter { id in
                    id != implicitHumanId && id != "human" && id != "tester"
                }

                var loadedMembers: [ClientMemberDetail] = []
                for name in agentMemberIds {
                    if let detail = try? await clientService.fetchMemberDetail(name: name) {
                        loadedMembers.append(detail)
                    } else {
                        // Fallback placeholder member detail if not registered in central member registry
                        loadedMembers.append(ClientMemberDetail(
                            name: name,
                            agent: name,
                            machine: "mesh",
                            model: "default",
                            mode: "yolo",
                            status: "active",
                            avatarSeed: name
                        ))
                    }
                }
                self.rosterMembers = loadedMembers
            }

            // 2. Fetch existing plain chat bubble messages
            let history = try await clientService.fetchThreadMessages(threadId: threadId)
            self.messages = history
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

    // MARK: - Event Handling

    public func handleClientEvent(_ event: PharosClientEvent) {
        switch event {
        case .threadMessageReceived(let msg):
            guard msg.threadId == threadId else { return }
            if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
                messages[idx] = msg
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
                    attachments: existing.attachments
                )
            }

        case .memberStatusChanged(let name, let status):
            if let idx = rosterMembers.firstIndex(where: { $0.name == name }) {
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
                attachments: confirmedMsg.attachments
            )
            if let idx = messages.firstIndex(where: { $0.id == optimisticId }) {
                messages[idx] = finalMsg
            }
            isSending = false
        } catch {
            self.activeError = (error as? PharosClientError) ?? .operationFailed(error.localizedDescription)
            isSending = false
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
                attachments: existing.attachments
            )
        }
    }

    public func dismissError() {
        self.activeError = nil
    }
}
