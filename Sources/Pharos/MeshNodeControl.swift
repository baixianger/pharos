import Foundation
import PharosMeshCore

/// App-side façade for durable Node commands. SSH remains a bootstrap/rescue
/// fallback only when no matching live Node exists.
enum MeshNodeControl {
    static func activeNode(for host: String?) -> MeshNodeInfo? {
        let nodes = MeshClient.send(MeshRequest(cmd: "node-list")).nodes ?? []
        if host == nil {
            if let ip = HostIdentity.tailscaleIP,
               let match = nodes.first(where: { $0.tailscaleIP == ip }) { return match }
            return nodes.first(where: { normalized($0.host) == normalized(HostIdentity.current) })
        }
        let value = normalized(host)
        return nodes.first { normalized($0.host) == value || normalized($0.tailscaleIP) == value }
    }

    static func spawn(node: MeshNodeInfo, payload: MeshNodeSpawnPayload) async -> MeshNodeCommand {
        await enqueue(nodeID: node.id, action: .spawnAgent, payload: payload,
                      key: "spawn:\(node.id):\(payload.sessionName):\(UUID().uuidString)")
    }

    static func stop(node: MeshNodeInfo, sessionName: String) async -> MeshNodeCommand {
        await enqueue(nodeID: node.id, action: .stopSession,
                      payload: MeshNodeStopPayload(sessionName: sessionName),
                      key: "stop:\(node.id):\(sessionName):\(UUID().uuidString)")
    }

    private static func enqueue<T: Encodable>(nodeID: String, action: MeshNodeCommandAction,
                                               payload: T, key: String) async -> MeshNodeCommand {
        let data = try? JSONEncoder().encode(payload)
        let value = data.flatMap { String(data: $0, encoding: .utf8) }
        let response = MeshClient.send(MeshRequest(cmd: "node-command-enqueue", payload: value,
                                                   nodeID: nodeID, action: action.rawValue,
                                                   idempotencyKey: key,
                                                   deadline: Date().timeIntervalSince1970 + 3_600,
                                                   maxAttempts: 120))
        guard response.ok, let initial = response.command else {
            return MeshNodeCommand(nodeID: nodeID, action: action, payload: value,
                                   idempotencyKey: key, state: .failed,
                                   deadline: Date().timeIntervalSince1970,
                                   result: response.error ?? "command enqueue failed")
        }
        for _ in 0..<360 {
            if let command = MeshClient.send(MeshRequest(cmd: "node-command-list", nodeID: nodeID))
                .commands?.first(where: { $0.id == initial.id }), command.state.isTerminal {
                return command
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        var timedOut = initial
        timedOut.state = .failed; timedOut.result = "timed out waiting for Node ACK"
        return timedOut
    }

    private static func normalized(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}
