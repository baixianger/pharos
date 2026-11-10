import Foundation
import PharosClientKit
import PharosMeshCore

/// Webhook-backed Thread member `grokbot` (display nick `Pharos`).
/// Wake-only: POST IDs to the human-proxy webhook; never ships message text.
/// Honest Runtime states: webhook success → `injected`; `replyOnce` → `completed`;
/// 45 minutes without a room reply → `failed`.
public actor GrokbotThreadBridge {
    public static let memberID = "grokbot"
    public static let displayNick = "Pharos"
    public static let agentKind = "grokbot"
    public static let timeout: Duration = .seconds(45 * 60)

    public struct Pending: Equatable, Sendable {
        public let deliveryID: String
        public let thread: String
        public let messageID: String
        public let from: String
        public let host: String
        public let injectedAt: ContinuousClock.Instant
    }

    public typealias RuntimeCall = @Sendable (String, [String: Any]) throws -> Any
    public typealias HistoryCall = @Sendable (String) async throws -> [MeshMsg]
    public typealias NotifyCall = @Sendable (
        _ thread: String, _ messageID: String, _ from: String, _ host: String
    ) async -> HumanProxyChannel.NotifyResult

    private let runtime: RuntimeCall
    private let history: HistoryCall
    private let notify: NotifyCall
    private let hostLabel: String
    private let driverID: String
    private var conversationID: String?
    private var sequence = 0
    private var pending: Pending?
    private var polling = false
    private var accepting = true

    public init(
        runtime: @escaping RuntimeCall = AgyThreadRuntimeBridge.localRuntime,
        history: @escaping HistoryCall,
        notify: @escaping NotifyCall = { thread, messageID, from, host in
            await HumanProxyChannel.notifyThreadMention(
                thread: thread, messageID: messageID, from: from, host: host
            )
        },
        hostLabel: String = ProcessInfo.processInfo.hostName,
        driverID: String = "grokbot-thread:" + UUID().uuidString
    ) {
        self.runtime = runtime
        self.history = history
        self.notify = notify
        self.hostLabel = hostLabel
        self.driverID = driverID
    }

    public func pendingDelivery() -> Pending? { pending }

    public func ensureRegistered() throws {
        _ = try runtime(
            "driver.register",
            [
                "driverID": driverID,
                "kind": Self.agentKind,
                "capabilities": ["delivery.poll"],
            ]
        )
        if conversationID == nil {
            let registered = try runtime(
                "conversation.register",
                [
                    "driverID": driverID,
                    "kind": Self.agentKind,
                    "vendorSessionID": Self.memberID,
                    "memberID": Self.memberID,
                ]
            ) as? [String: Any]
            guard let id = registered?["id"] as? String else {
                throw PharosClientError.operationFailed("Runtime did not register grokbot")
            }
            conversationID = id
        }
        guard let conversationID else { return }
        sequence += 1
        _ = try runtime(
            "conversation.state",
            [
                "conversationID": conversationID,
                "presence": accepting ? "online" : "offline",
                "activity": pending == nil ? "idle" : "running",
                "attention": "none",
                "persistence": "persistent",
                "source": "nativeProtocol",
                "sourceEpoch": driverID,
                "sequence": sequence,
            ]
        )
    }

    /// Poll Runtime, wake proxy on new directed mail, and advance honest states.
    public func poll() async throws {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        try ensureRegistered()
        guard let conversationID else { return }

        if let current = pending {
            if try await roomHasReply(for: current) {
                _ = try runtime(
                    "delivery.ack",
                    [
                        "deliveryID": current.deliveryID,
                        "state": "completed",
                        "detail": "grokbot replyOnce persisted",
                    ]
                )
                pending = nil
            } else if ContinuousClock.now - current.injectedAt >= Self.timeout {
                _ = try runtime(
                    "delivery.ack",
                    [
                        "deliveryID": current.deliveryID,
                        "state": "failed",
                        "detail": "grokbot reply timeout (45m)",
                    ]
                )
                pending = nil
            }
            return
        }

        guard accepting else { return }
        let records = try runtime(
            "delivery.poll", ["conversationID": conversationID]
        ) as? [[String: Any]] ?? []
        guard let record = records.first,
              let deliveryID = record["id"] as? String,
              let payload = record["payload"] as? String,
              let envelope = try? JSONSerialization.jsonObject(
                with: Data(payload.utf8)
              ) as? [String: Any],
              let message = envelope["meshMessage"] as? [String: Any],
              let targets = message["targetMemberIDs"] as? [String],
              targets.contains(Self.memberID),
              let room = envelope["room"] as? String, !room.isEmpty,
              let messageID = envelope["messageID"] as? String, !messageID.isEmpty,
              let sender = (envelope["sender"] as? String)
                ?? (message["from"] as? String),
              !sender.isEmpty else {
            if let id = records.first?["id"] as? String {
                _ = try runtime(
                    "delivery.ack",
                    [
                        "deliveryID": id,
                        "state": "failed",
                        "detail": "Missing explicit Mesh target binding for grokbot",
                    ]
                )
            }
            return
        }

        let notifyResult = await notify(room, messageID, sender, hostLabel)
        switch notifyResult {
        case .posted:
            _ = try runtime(
                "delivery.ack",
                [
                    "deliveryID": deliveryID,
                    "state": "injected",
                    "detail": "human-proxy webhook posted (wake-only)",
                ]
            )
            pending = Pending(
                deliveryID: deliveryID, thread: room, messageID: messageID,
                from: sender, host: hostLabel, injectedAt: .now
            )
        case .skippedMissingConfig:
            _ = try runtime(
                "delivery.ack",
                [
                    "deliveryID": deliveryID,
                    "state": "failed",
                    "detail": "human-proxy webhook env missing",
                ]
            )
        case .failed(let detail):
            _ = try runtime(
                "delivery.ack",
                [
                    "deliveryID": deliveryID,
                    "state": "failed",
                    "detail": "human-proxy webhook failed: \(detail)",
                ]
            )
        }
    }

    public func setAccepting(_ value: Bool) { accepting = value }

    private func roomHasReply(for current: Pending) async throws -> Bool {
        let messages = try await history(current.thread)
        return messages.contains {
            $0.authorMemberID == Self.memberID
                && $0.replyTo?.messageID == current.messageID
        }
    }
}
