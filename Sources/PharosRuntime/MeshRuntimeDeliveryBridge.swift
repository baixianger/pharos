import Foundation
import PharosMeshCore

/// Local fast path from Broker routing into a managed Agent Runtime session.
/// Returning false is deliberate: the Broker then preserves its durable
/// mailbox and conservative poke transport for remote or unmanaged sessions.
public enum MeshRuntimeDeliveryBridge {
    public static func submit(message: MeshMsg, target: MeshMemberInfo) -> MeshRuntimeDeliveryRoute {
        guard !target.id.isEmpty else { return .fallback }
        let envelope = Envelope(
            body: message.text,
            room: message.room,
            messageID: message.stableID,
            sender: message.from,
            replyToID: message.replyTo?.messageID,
            meshMessage: message
        )
        guard let envelopeData = try? JSONEncoder().encode(envelope),
              let payload = String(data: envelopeData, encoding: .utf8) else { return .fallback }
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "delivery.submit-member",
            "params": [
                "memberID": target.id,
                "idempotencyKey": "mesh:\(message.stableID):\(target.id)",
                "payload": payload,
            ],
        ]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let rawRequest = String(data: requestData, encoding: .utf8) else { return .fallback }
        guard let rawResponse = try? AgentRuntimeClient.send(rawRequest),
              let responseData = rawResponse.data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let result = response["result"] as? [String: Any],
              result["submitted"] as? Bool == true else { return .forward(rawRequest) }
        return .accepted
    }

    private struct Envelope: Codable {
        let body: String
        let room: String
        let messageID: String
        let sender: String
        let replyToID: String?
        let meshMessage: MeshMsg
    }
}
