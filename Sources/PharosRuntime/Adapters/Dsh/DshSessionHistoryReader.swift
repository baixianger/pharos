import Foundation
import PharosClientKit

/// Builds the visible transcript from cold-safe DSH journal pages.
public struct DshSessionHistoryReader: Sendable {
    private let host: DshWebHost
    public init(host: DshWebHost = DshWebHost()) { self.host = host }

    public func load(sessionId: String) async throws -> [CanonicalTurn] {
        let records = try await host.history(sessionId: sessionId)
        return Self.turns(from: records, sessionId: "dsh:" + sessionId)
    }

    static func progress(from records: [BackendWireEvent]) -> CanonicalSessionProgress? {
        var goal: CanonicalSessionGoal?
        var todos: [CanonicalSessionTodo] = []
        var found = false
        for record in records {
            guard let event = record["event"] as? [String: Any],
                  let type = event["type"] as? String, let data = event["data"] as? [String: Any] else { continue }
            if type == "goal/change" {
                if data["operation"] as? String == "clear" {
                    goal = nil
                    found = true
                } else if let value = SessionProgressMapping.goal(data["goal"] as? [String: Any], statusKey: "phase") {
                    goal = value
                    found = true
                }
            } else if type == "todo/write", let value = SessionProgressMapping.todos(data["todos"], textKey: "content") {
                todos = value
                found = true
            }
        }
        return found ? .init(goal: goal, todos: todos) : nil
    }

    static func turns(from records: [BackendWireEvent], sessionId: String) -> [CanonicalTurn] {
        struct Turn {
            let number: Int
            var blocks: [CanonicalBlock] = []
            var status: TurnStatus = .inProgress
        }
        let translator = DshMessageTranslator()
        var turns: [Turn] = []
        var pendingInbox: [CanonicalBlock] = []
        var names: [String: String] = [:]
        for record in records {
            guard record["type"] as? String == "event",
                  let event = record["event"] as? [String: Any],
                  let type = event["type"] as? String,
                  let data = event["data"] as? [String: Any] else { continue }
            if type == "turn/start" {
                turns.append(Turn(number: data["turn"] as? Int ?? turns.count + 1, blocks: pendingInbox))
                pendingInbox.removeAll()
                continue
            }
            if type == "agent/inbox/spliced" {
                let seq = event["seq"] as? Int ?? turns.count
                for message in data["inserted"] as? [[String: Any]] ?? [] {
                    guard let source = message["source"] as? [String: Any],
                          source["kind"] as? String == "pharos-mesh"
                            || (source["kind"] as? String == "plugin"
                                && source["plugin"] as? String == "dsh-plugin-pharos-runtime") else { continue }
                    let text = (message["content"] as? [[String: Any]] ?? []).compactMap { item -> String? in
                        guard item["type"] as? String == "text" else { return nil }
                        return item["text"] as? String
                    }.joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    let messageID = message["id"] as? String ?? String(seq)
                    let block = CanonicalBlock(blockId: "plugin-\(messageID)", kind: .userText(text))
                    if let index = turns.indices.last, turns[index].status == .inProgress { turns[index].blocks.append(block) }
                    else { pendingInbox.append(block) }
                }
                continue
            }
            guard !turns.isEmpty else { continue }
            let index = turns.count - 1
            let seq = event["seq"] as? Int ?? index
            switch type {
            case "user/message":
                let source = (data["source"] as? [String: Any])?["kind"] as? String
                guard source == nil || source == "user" else { continue }
                for (partIndex, item) in (data["content"] as? [[String: Any]] ?? []).enumerated() {
                    switch item["type"] as? String {
                    case "text":
                        if let text = item["text"] as? String, !text.isEmpty {
                            turns[index].blocks.append(.init(blockId: "user-\(seq)-\(partIndex)", kind: .userText(text)))
                        }
                    case "file":
                        guard let ref = item["attachment"] as? [String: Any],
                              let id = ref["attachmentId"] as? String, !id.isEmpty,
                              let name = ref["name"] as? String, let bytes = ref["bytes"] as? Int, bytes >= 0 else { continue }
                        let attachment = CanonicalAttachment(id: id, filename: name, mimeType: "application/octet-stream", sizeBytes: Int64(bytes), uri: "")
                        turns[index].blocks.append(.init(blockId: "user-attachment-\(seq)-\(partIndex)", kind: .attachment(attachment)))
                    default: break
                    }
                }
            case "assistant/message":
                let message = data["message"] as? [String: Any]
                let content = (message?["content"] as? [[String: Any]]) ?? (data["content"] as? [[String: Any]]) ?? []
                turns[index].blocks += translator.translateAssistantMessage(blockId: "assistant-\(seq)", contentArray: content)
            case "tool/call":
                guard let id = data["callId"] as? String else { continue }
                let name = data["name"] as? String ?? "Tool"
                names[id] = name
                turns[index].blocks.append(translator.translateToolCall(callId: id, toolName: name, rawArguments: data["arguments"]))
            case "tool/result":
                let message = data["message"] as? [String: Any] ?? [:]
                guard let id = (message["toolCallId"] as? String) ?? (data["callId"] as? String) else { continue }
                turns[index].blocks.append(translator.translateToolResult(callId: id, toolName: names[id] ?? "Tool",
                    rawResult: message["content"] ?? data["result"], isError: data["error"] != nil))
            case "turn/end":
                let reason = (data["reason"] as? [String: Any])?["kind"] as? String ?? "unknown"
                switch reason {
                case "stop", "finish", "done", "completed": turns[index].status = .completed
                case "interrupt", "interrupted", "cancelled", "cancel": turns[index].status = .cancelled
                default: turns[index].status = .failed
                }
            default: break
            }
        }
        return turns.map { turn in
            let id = "\(sessionId):turn:\(turn.number)"
            return CanonicalTurn(turnId: id, sessionId: sessionId, turnNumber: turn.number, status: turn.status,
                steps: [.init(stepId: id, stepNumber: 1, status: turn.status == .inProgress ? .running : .completed, blocks: turn.blocks)])
        }
    }
}
