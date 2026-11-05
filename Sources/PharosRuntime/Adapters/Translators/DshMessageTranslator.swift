import Foundation
import PharosClientKit

/// Bidirectional translator between DeepSeek Harness (`dsh 0.2.1-rc.5`) wire payloads and the Pharos Canonical Session Message Model.
/// Adheres strictly to docs/MESSAGE-MODEL.md §2.1 & §5 and handles PIT-DS-16 (stringified tool arguments).
public final class DshMessageTranslator: Sendable {
    public init() {}

    /// Translates a dsh `turn/start` event into an initial in-progress `CanonicalTurn`.
    public func translateTurnStart(turnNumber: Int, sessionId: String, rawPayload: [String: Any]? = nil) -> CanonicalTurn {
        let rawJSON = rawPayload.flatMap { toJSONValueDict($0) }
        return CanonicalTurn(
            turnId: "turn_\(turnNumber)",
            sessionId: sessionId,
            turnNumber: turnNumber,
            status: .inProgress,
            createdAt: Date(),
            steps: [],
            rawVendorPayload: rawJSON
        )
    }

    /// Completes a `CanonicalTurn` given a dsh `turn/end` event.
    public func translateTurnEnd(
        currentTurn: CanonicalTurn,
        reasonKind: String,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalTurn {
        let status: TurnStatus
        switch reasonKind.lowercased() {
        case "stop", "finish", "done":
            status = .completed
        case "interrupt", "cancelled", "cancel":
            status = .cancelled
        case "needs-interaction", "approval", "question":
            status = .needsHuman
        default:
            status = .failed
        }

        var payload = currentTurn.rawVendorPayload ?? [:]
        if let raw = rawPayload {
            for (k, v) in toJSONValueDict(raw) {
                payload[k] = v
            }
        }
        payload["reasonKind"] = .string(reasonKind)

        return CanonicalTurn(
            turnId: currentTurn.turnId,
            sessionId: currentTurn.sessionId,
            turnNumber: currentTurn.turnNumber,
            status: status,
            createdAt: currentTurn.createdAt,
            completedAt: Date(),
            steps: currentTurn.steps,
            rawVendorPayload: payload
        )
    }

    /// Translates streaming assistant deltas from dsh `assistant-stream`.
    public func translateStreamingDelta(
        sessionId: String,
        turnId: String,
        deltaType: String,
        chunk: String
    ) -> CanonicalStreamingDelta? {
        switch deltaType {
        case "text-delta", "text":
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .textDelta(chunk)
            )
        case "reasoning-delta", "reasoning", "thought":
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .reasoningDelta(chunk)
            )
        default:
            return nil
        }
    }

    /// Translates committed dsh assistant message items into canonical blocks.
    public func translateAssistantMessage(
        blockId: String,
        contentArray: [[String: Any]],
        rawPayload: [String: Any]? = nil
    ) -> [CanonicalBlock] {
        var blocks: [CanonicalBlock] = []
        let rawJSON = rawPayload.flatMap { toJSONValueDict($0) }

        for (idx, item) in contentArray.enumerated() {
            let itemType = item["type"] as? String ?? ""
            let subId = "\(blockId)_\(idx)"
            switch itemType {
            case "reasoning", "thought":
                let thinking = item["text"] as? String ?? item["reasoning"] as? String ?? ""
                let summary = item["summary"] as? String
                let duration = item["durationMs"] as? Int
                blocks.append(CanonicalBlock(
                    blockId: subId,
                    kind: .reasoning(CanonicalReasoningBlock(thinking: thinking, summary: summary, durationMs: duration)),
                    rawVendorPayload: rawJSON
                ))
            case "text":
                let text = item["text"] as? String ?? ""
                blocks.append(CanonicalBlock(
                    blockId: subId,
                    kind: .assistantText(text),
                    rawVendorPayload: rawJSON
                ))
            default:
                break
            }
        }
        return blocks
    }

    /// Translates a dsh `tool/call` wire frame.
    /// Handles PIT-DS-16: Secondary JSON parse on stringified arguments, preserving raw in `rawArguments`.
    public func translateToolCall(
        callId: String,
        toolName: String,
        rawArguments: Any?,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalBlock {
        var parsedArguments: [String: JSONValue] = [:]
        var rawArgsString: String? = nil

        if let str = rawArguments as? String {
            rawArgsString = str
            if let data = str.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsedArguments = toJSONValueDict(json)
            }
        } else if let dict = rawArguments as? [String: Any] {
            parsedArguments = toJSONValueDict(dict)
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let str = String(data: data, encoding: .utf8) {
                rawArgsString = str
            }
        }

        let toolCall = CanonicalToolCall(
            callId: callId,
            toolName: toolName,
            arguments: parsedArguments,
            rawArguments: rawArgsString
        )
        return CanonicalBlock(
            blockId: "tool_call_\(callId)",
            kind: .toolCall(toolCall),
            rawVendorPayload: rawPayload.flatMap { toJSONValueDict($0) }
        )
    }

    /// Translates a dsh `tool/result` wire frame.
    public func translateToolResult(
        callId: String,
        toolName: String,
        rawResult: Any?,
        isError: Bool = false,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalBlock {
        let resultJSON: JSONValue
        if let str = rawResult as? String {
            resultJSON = .string(str)
        } else if let dict = rawResult as? [String: Any] {
            resultJSON = .object(toJSONValueDict(dict))
        } else if let arr = rawResult as? [Any] {
            resultJSON = .array(toJSONValueArray(arr))
        } else {
            resultJSON = .null
        }

        let toolResult = CanonicalToolResult(
            callId: callId,
            toolName: toolName,
            result: resultJSON,
            isError: isError
        )
        return CanonicalBlock(
            blockId: "tool_result_\(callId)",
            kind: .toolResult(toolResult),
            rawVendorPayload: rawPayload.flatMap { toJSONValueDict($0) }
        )
    }

    /// Translates dsh `$events` approval waterfall requests.
    public func translateApprovalRequest(
        approvalId: String,
        sessionId: String,
        eventType: String,
        params: [String: Any],
        rawPayload: [String: Any]? = nil
    ) -> CanonicalApprovalRequest {
        let rawJSON = rawPayload.flatMap { toJSONValueDict($0) }
        if eventType == "user-questions/request" || params["questions"] != nil {
            var questions: [CanonicalQuestionOption] = []
            if let qs = params["questions"] as? [[String: Any]] {
                for (idx, q) in qs.enumerated() {
                    let qId = q["id"] as? String ?? "q_\(idx)"
                    let qText = q["question"] as? String ?? q["prompt"] as? String ?? ""
                    let opts = q["options"] as? [String] ?? []
                    let multi = q["isMultiSelect"] as? Bool ?? false
                    questions.append(CanonicalQuestionOption(id: qId, question: qText, options: opts, isMultiSelect: multi))
                }
            }
            let intent = params["intent"] as? String ?? "plan-review"
            return CanonicalApprovalRequest(
                approvalId: approvalId,
                sessionId: sessionId,
                kind: .structuredQuestionnaire(intent: intent, questions: questions),
                rawVendorPayload: rawJSON
            )
        } else {
            let tool = params["toolName"] as? String ?? params["tool"] as? String ?? "unknown"
            let p = (params["arguments"] as? [String: Any]) ?? (params["parameters"] as? [String: Any]) ?? [:]
            let explanation = params["explanation"] as? String ?? params["reason"] as? String
            return CanonicalApprovalRequest(
                approvalId: approvalId,
                sessionId: sessionId,
                kind: .toolPermission(toolName: tool, params: toJSONValueDict(p), explanation: explanation),
                rawVendorPayload: rawJSON
            )
        }
    }

    // MARK: - Helpers

    private func toJSONValueDict(_ dict: [String: Any]) -> [String: JSONValue] {
        var res: [String: JSONValue] = [:]
        for (k, v) in dict {
            res[k] = toJSONValue(v)
        }
        return res
    }

    private func toJSONValueArray(_ arr: [Any]) -> [JSONValue] {
        arr.map { toJSONValue($0) }
    }

    private func toJSONValue(_ val: Any) -> JSONValue {
        if let s = val as? String { return .string(s) }
        if let b = val as? Bool { return .bool(b) }
        if let n = val as? NSNumber {
            return .number(n.doubleValue)
        }
        if let d = val as? [String: Any] {
            return .object(toJSONValueDict(d))
        }
        if let a = val as? [Any] {
            return .array(toJSONValueArray(a))
        }
        return .null
    }
}
