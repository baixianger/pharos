import Foundation
import PharosClientKit
import PharosMeshCore

/// A locally owned, explicitly bound DSH Session consuming one Runtime queue.
/// Product mode replies via `replyOnce`; legacy Broker say-once remains optional.
public actor DshThreadRuntimeBridge {
    public struct Binding: Sendable {
        public let memberID: String
        public let sessionID: String
        public let providerSessionID: String
        public init(memberID: String, sessionID: String, providerSessionID: String) {
            self.memberID = memberID; self.sessionID = sessionID; self.providerSessionID = providerSessionID
        }
    }
    public typealias RuntimeCall = @Sendable (String, [String: Any]) throws -> Any
    public typealias BrokerCall = @Sendable (MeshRequest) throws -> Void
    public typealias ReplyCall = @Sendable (AgyThreadRelay.Delivery, String) async throws -> Void
    private let binding: Binding
    private let driverID = "dsh-thread:" + UUID().uuidString
    private let runtime: RuntimeCall
    private let reply: ReplyCall
    private let send: AgyThreadRelay.Send
    private var conversationID: String?
    private var sequence = 0
    private var inFlight: (id: String, delivery: AgyThreadRelay.Delivery)?
    private var polling = false
    private var accepting = true
    private lazy var relay = AgyThreadRelay(send: send, reply: { [weak self] delivery, text in
        guard let self else { throw PharosClientError.connectionFailed("DSH Thread bridge stopped") }
        try await self.post(delivery, text: text)
    })

    public init(binding: Binding, send: @escaping AgyThreadRelay.Send,
                runtime: @escaping RuntimeCall = AgyThreadRuntimeBridge.localRuntime,
                reply: @escaping ReplyCall) {
        self.binding = binding; self.send = send; self.runtime = runtime; self.reply = reply
    }

    public init(binding: Binding, send: @escaping AgyThreadRelay.Send,
                runtime: @escaping RuntimeCall = AgyThreadRuntimeBridge.localRuntime,
                broker: @escaping BrokerCall) {
        self.init(binding: binding, send: send, runtime: runtime, reply: { delivery, text in
            try broker(MeshRequest(
                cmd: "say-once", room: delivery.room, memberID: delivery.memberID,
                text: text, replyToID: delivery.messageID,
                idempotencyKey: "dsh-delivery:" + delivery.messageID
            ))
        })
    }

    public func poll() async throws {
        guard !polling else { return }
        guard !binding.memberID.isEmpty, !binding.sessionID.isEmpty, !binding.providerSessionID.isEmpty else {
            throw PharosClientError.operationFailed("Incomplete DSH Session binding")
        }
        polling = true
        defer { polling = false }
        _ = try runtime("driver.register", ["driverID": driverID, "kind": "dsh", "capabilities": ["delivery.poll"]])
        if conversationID == nil {
            let registered = try runtime("conversation.register", ["driverID": driverID, "kind": "dsh",
                "vendorSessionID": binding.providerSessionID, "memberID": binding.memberID]) as? [String: Any]
            guard let id = registered?["id"] as? String else {
                throw PharosClientError.operationFailed("Runtime did not register the Session")
            }
            conversationID = id
        }
        guard let conversationID else { return }
        sequence += 1
        do {
            _ = try runtime("conversation.state", ["conversationID": conversationID, "presence": accepting ? "online" : "offline",
                "activity": inFlight == nil ? "idle" : "running", "attention": "none", "persistence": "persistent",
                "source": "nativeProtocol", "sourceEpoch": driverID, "sequence": sequence])
        } catch {
            self.conversationID = nil
            throw error
        }
        await relay.retryPendingReplies()
        guard accepting, inFlight == nil else { return }
        let records = try runtime("delivery.poll", ["conversationID": conversationID]) as? [[String: Any]] ?? []
        guard let record = records.first, let id = record["id"] as? String,
              let payload = record["payload"] as? String else { return }
        guard let envelope = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let message = envelope["meshMessage"] as? [String: Any],
              let targets = message["targetMemberIDs"] as? [String], targets.contains(binding.memberID),
              let room = envelope["room"] as? String, !room.isEmpty,
              let messageID = envelope["messageID"] as? String, !messageID.isEmpty,
              let text = envelope["body"] as? String,
              message["id"] as? String == messageID,
              message["room"] as? String == room,
              message["text"] as? String == text else {
            _ = try runtime("delivery.ack", ["deliveryID": id, "state": "failed", "detail": "Missing explicit Mesh target binding"])
            return
        }
        let delivery = AgyThreadRelay.Delivery(memberID: binding.memberID, sessionID: binding.sessionID,
            providerSessionID: binding.providerSessionID, room: room, messageID: messageID, text: text)
        // Persist a non-replayable boundary before starting the Host turn.
        _ = try runtime("delivery.ack", ["deliveryID": id, "state": "injected", "detail": "DSH start pending or in progress"])
        inFlight = (id, delivery)
        do { try await relay.deliver(delivery) }
        catch {
            inFlight = nil
            throw error
        }
    }

    public func setAccepting(_ value: Bool) { accepting = value }
    public func isRetiredAndIdle() -> Bool { !accepting && inFlight == nil }

    public func shutdown() {
        guard let conversationID else { return }
        sequence += 1
        _ = try? runtime("conversation.state", ["conversationID": conversationID, "presence": "offline",
            "activity": "idle", "attention": "none", "persistence": "persistent",
            "source": "nativeProtocol", "sourceEpoch": driverID, "sequence": sequence])
    }

    public func handle(_ event: PharosClientEvent) async {
        if let failed = await relay.handle(event), let current = inFlight, current.delivery == failed {
            _ = try? runtime("delivery.ack", ["deliveryID": current.id, "state": "failed", "detail": "DSH turn failed or returned no text"])
            inFlight = nil
        }
    }

    private func post(_ delivery: AgyThreadRelay.Delivery, text: String) async throws {
        guard let current = inFlight, current.delivery == delivery else {
            throw PharosClientError.operationFailed("DSH Thread delivery is no longer active")
        }
        try await reply(delivery, text)
        _ = try runtime("delivery.ack", [
            "deliveryID": current.id, "state": "completed",
            "detail": "Reply persisted to Mesh room",
        ])
        inFlight = nil
    }
}
