import Foundation
import PharosMeshProtocol

/// Maps the legacy `host-reply` / `say-once` stdin envelope onto product
/// `replyOnce`. Codex's Rust worker still emits say-once JSON; product Mesh
/// must not require the retired Broker.
public enum MeshDistributedHostReply {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidRequest
        case missingField(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRequest:
                "host-reply requires a say-once JSON request"
            case .missingField(let name):
                "host-reply is missing \(name)"
            }
        }
    }

    public static func apply(
        _ request: MeshRequest, using agent: DistributedAgentChat
    ) async throws -> MeshMsg {
        guard request.cmd == "say-once" || request.cmd == "host-reply" else {
            throw Error.invalidRequest
        }
        guard let room = request.room?.trimmingCharacters(in: .whitespacesAndNewlines),
              !room.isEmpty else { throw Error.missingField("room") }
        guard let memberID = request.memberID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !memberID.isEmpty else { throw Error.missingField("memberID") }
        guard let original = request.replyToID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty else { throw Error.missingField("replyToID") }
        guard let text = request.text else { throw Error.missingField("text") }
        return try await agent.replyOnce(
            room: room, memberID: memberID,
            originalMessageID: original, text: text
        )
    }
}
