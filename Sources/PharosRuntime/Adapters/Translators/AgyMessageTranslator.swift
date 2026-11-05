import Foundation
import PharosClientKit

/// Bidirectional translator between Antigravity (`agy 1.5.1`) ACP / transcript frames and the Pharos Canonical Session Message Model.
/// Adheres strictly to docs/MESSAGE-MODEL.md §2.3 & §5 and handles PIT-AG-07 (tool results decoupled across transcript steps).
public final class AgyMessageTranslator: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlightToolCalls: [String: CanonicalToolCall] = [:]

    public init() {}

    /// Translates ACP `session/prompt` start into a `CanonicalTurn`.
    public func translatePromptStart(
        turnId: String,
        sessionId: String,
        turnNumber: Int = 1,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalTurn {
        CanonicalTurn(
            turnId: turnId,
            sessionId: sessionId,
            turnNumber: turnNumber,
            status: .inProgress,
            createdAt: Date(),
            steps: [],
            rawVendorPayload: rawPayload.flatMap { toJSONValueDict($0) }
        )
    }

    /// Translates ACP `session/prompt` finish with stopReason into a completed `CanonicalTurn`.
    public func translatePromptEnd(
        currentTurn: CanonicalTurn,
        stopReason: String?,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalTurn {
        let status: TurnStatus
        switch stopReason?.lowercased() {
        case "end_turn", "stop", "completed":
            status = .completed
        case "cancelled", "interrupt":
            status = .cancelled
        case "max_tokens", "length":
            status = .completed
        default:
            status = .completed
        }

        var payload = currentTurn.rawVendorPayload ?? [:]
        if let raw = rawPayload {
            for (k, v) in toJSONValueDict(raw) {
                payload[k] = v
            }
        }
        if let sr = stopReason {
            payload["stopReason"] = .string(sr)
        }

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

    /// Translates ACP `session/update` delta chunks into `CanonicalStreamingDelta`.
    public func translateStreamingChunk(
        sessionId: String,
        turnId: String,
        chunk: String,
        isThinking: Bool = false
    ) -> CanonicalStreamingDelta {
        if isThinking {
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .reasoningDelta(chunk)
            )
        } else {
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .textDelta(chunk)
            )
        }
    }

    /// Translates a `transcript.jsonl` journal line into canonical blocks.
    /// Handles PIT-AG-07: Correlates decoupled tool results with prior tool calls using `tool_call_id`.
    public func translateTranscriptLine(
        lineDict: [String: Any],
        stepIndex: Int
    ) -> [CanonicalBlock] {
        var blocks: [CanonicalBlock] = []
        let lineType = lineDict["type"] as? String ?? ""
        let stepId = "step_\(stepIndex)"
        let rawJSON = toJSONValueDict(lineDict)

        switch lineType {
        case "USER_INPUT":
            let text = lineDict["content"] as? String ?? ""
            blocks.append(CanonicalBlock(
                blockId: "\(stepId)_user",
                kind: .userText(text),
                rawVendorPayload: rawJSON
            ))

        case "PLANNER_RESPONSE":
            // 1. Thinking / reasoning block
            if let thinking = lineDict["thinking"] as? String, !thinking.isEmpty {
                blocks.append(CanonicalBlock(
                    blockId: "\(stepId)_thought",
                    kind: .reasoning(CanonicalReasoningBlock(thinking: thinking)),
                    rawVendorPayload: rawJSON
                ))
            }

            // 2. Assistant textual content
            if let content = lineDict["content"] as? String, !content.isEmpty {
                blocks.append(CanonicalBlock(
                    blockId: "\(stepId)_text",
                    kind: .assistantText(content),
                    rawVendorPayload: rawJSON
                ))
            }

            // 3. Tool calls array
            if let toolCalls = lineDict["tool_calls"] as? [[String: Any]] {
                lock.lock()
                defer { lock.unlock() }

                for tc in toolCalls {
                    let callId = tc["id"] as? String ?? tc["call_id"] as? String ?? UUID().uuidString
                    let name = tc["name"] as? String ?? tc["function"] as? String ?? "unknown"
                    let args = tc["arguments"] as? [String: Any] ?? tc["parameters"] as? [String: Any] ?? [:]
                    let call = CanonicalToolCall(callId: callId, toolName: name, arguments: toJSONValueDict(args))
                    inFlightToolCalls[callId] = call
                    blocks.append(CanonicalBlock(
                        blockId: "tool_call_\(callId)",
                        kind: .toolCall(call),
                        rawVendorPayload: rawJSON
                    ))
                }
            }

        case "TOOL_RESULT", "OBSERVATION":
            // Result of a prior tool call (PIT-AG-07 correlation)
            let callId = lineDict["tool_call_id"] as? String ?? lineDict["call_id"] as? String ?? ""
            let toolName: String
            lock.lock()
            toolName = inFlightToolCalls[callId]?.toolName ?? lineDict["tool_name"] as? String ?? "unknown"
            inFlightToolCalls.removeValue(forKey: callId)
            lock.unlock()

            let output = lineDict["content"] as? String ?? lineDict["result"] as? String ?? ""
            let isError = lineDict["is_error"] as? Bool ?? false
            blocks.append(CanonicalBlock(
                blockId: "tool_result_\(callId)",
                kind: .toolResult(CanonicalToolResult(
                    callId: callId,
                    toolName: toolName,
                    result: .string(output),
                    isError: isError
                )),
                rawVendorPayload: rawJSON
            ))

        default:
            break
        }

        return blocks
    }

    /// Translates ACP `session/request_permission` into a `CanonicalApprovalRequest`.
    public func translatePermissionRequest(
        approvalId: String,
        sessionId: String,
        toolName: String,
        params: [String: Any],
        rawPayload: [String: Any]? = nil
    ) -> CanonicalApprovalRequest {
        CanonicalApprovalRequest(
            approvalId: approvalId,
            sessionId: sessionId,
            kind: .toolPermission(
                toolName: toolName,
                params: toJSONValueDict(params),
                explanation: "Antigravity requested permission to execute \(toolName)"
            ),
            rawVendorPayload: rawPayload.flatMap { toJSONValueDict($0) }
        )
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
        if let n = val as? NSNumber { return .number(n.doubleValue) }
        if let d = val as? [String: Any] { return .object(toJSONValueDict(d)) }
        if let a = val as? [Any] { return .array(toJSONValueArray(a)) }
        return .null
    }
}
