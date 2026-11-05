import Foundation
import PharosClientKit

/// Bidirectional translator between OpenAI Codex (`codex-cli 0.166.0`) wire items and the Pharos Canonical Session Message Model.
/// Adheres strictly to docs/MESSAGE-MODEL.md §2.2 & §5 and handles PIT-CX-14 (commentary phase flag preservation).
public final class CodexMessageTranslator: Sendable {
    public init() {}

    /// Translates a Codex `turn/started` notification into a `CanonicalTurn`.
    public func translateTurnStarted(
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

    /// Translates a Codex `turn/completed` notification.
    public func translateTurnCompleted(
        currentTurn: CanonicalTurn,
        status: String,
        error: [String: Any]? = nil,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalTurn {
        let turnStatus: TurnStatus
        if status.lowercased() == "completed" || status.lowercased() == "done" {
            turnStatus = .completed
        } else if status.lowercased() == "cancelled" || status.lowercased() == "interrupted" {
            turnStatus = .cancelled
        } else {
            turnStatus = .failed
        }

        var payload = currentTurn.rawVendorPayload ?? [:]
        if let raw = rawPayload {
            for (k, v) in toJSONValueDict(raw) {
                payload[k] = v
            }
        }
        if let err = error {
            payload["error"] = .object(toJSONValueDict(err))
        }

        return CanonicalTurn(
            turnId: currentTurn.turnId,
            sessionId: currentTurn.sessionId,
            turnNumber: currentTurn.turnNumber,
            status: turnStatus,
            createdAt: currentTurn.createdAt,
            completedAt: Date(),
            steps: currentTurn.steps,
            rawVendorPayload: payload
        )
    }

    /// Translates live token streaming deltas from Codex WebSocket notifications.
    public func translateStreamingDelta(
        sessionId: String,
        turnId: String,
        itemType: String,
        deltaText: String
    ) -> CanonicalStreamingDelta? {
        switch itemType {
        case "agentMessage":
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .textDelta(deltaText)
            )
        case "reasoning":
            return CanonicalStreamingDelta(
                sessionId: sessionId,
                turnId: turnId,
                deltaType: .reasoningDelta(deltaText)
            )
        default:
            return nil
        }
    }

    /// Translates completed items from Codex (`item/completed`).
    /// Handles PIT-CX-14: Preserves commentary phase flag in `rawVendorPayload`.
    public func translateItemCompleted(
        itemId: String,
        itemType: String,
        itemDict: [String: Any],
        rawPayload: [String: Any]? = nil
    ) -> CanonicalBlock? {
        let rawJSON = rawPayload.flatMap { toJSONValueDict($0) } ?? toJSONValueDict(itemDict)

        switch itemType {
        case "userMessage":
            let text = itemDict["text"] as? String ?? itemDict["content"] as? String ?? ""
            return CanonicalBlock(blockId: itemId, kind: .userText(text), rawVendorPayload: rawJSON)

        case "agentMessage":
            let text = itemDict["text"] as? String ?? itemDict["content"] as? String ?? ""
            var vendorPayload = rawJSON
            if let phase = itemDict["phase"] as? String {
                vendorPayload["phase"] = .string(phase) // PIT-CX-14
            }
            return CanonicalBlock(blockId: itemId, kind: .assistantText(text), rawVendorPayload: vendorPayload)

        case "reasoning":
            let thinking = itemDict["content"] as? String ?? itemDict["text"] as? String ?? ""
            let summary = itemDict["summary"] as? String
            return CanonicalBlock(
                blockId: itemId,
                kind: .reasoning(CanonicalReasoningBlock(thinking: thinking, summary: summary)),
                rawVendorPayload: rawJSON
            )

        case "commandExecution":
            let cmd = itemDict["command"] as? String ?? ""
            let cwd = itemDict["cwd"] as? String
            let exitCode = (itemDict["exitCode"] as? NSNumber)?.intValue
            let stdout = itemDict["stdout"] as? String
            let stderr = itemDict["stderr"] as? String
            return CanonicalBlock(
                blockId: itemId,
                kind: .terminalCommand(CanonicalTerminalCommand(
                    command: cmd, cwd: cwd, exitCode: exitCode, stdout: stdout, stderr: stderr
                )),
                rawVendorPayload: rawJSON
            )

        case "fileChange":
            let path = itemDict["path"] as? String ?? ""
            let kindStr = itemDict["kind"] as? String ?? "modify"
            let patchKind: PatchKind
            switch kindStr {
            case "create", "new": patchKind = .create
            case "delete", "remove": patchKind = .delete
            default: patchKind = .modify
            }
            let diff = itemDict["diff"] as? String ?? itemDict["patch"] as? String ?? ""
            return CanonicalBlock(
                blockId: itemId,
                kind: .filePatch(CanonicalFilePatch(path: path, kind: patchKind, diff: diff)),
                rawVendorPayload: rawJSON
            )

        case "mcpToolCall":
            let callId = itemDict["callId"] as? String ?? itemId
            let toolName = itemDict["tool"] as? String ?? itemDict["name"] as? String ?? "unknown"
            let args = itemDict["arguments"] as? [String: Any] ?? [:]
            return CanonicalBlock(
                blockId: itemId,
                kind: .toolCall(CanonicalToolCall(callId: callId, toolName: toolName, arguments: toJSONValueDict(args))),
                rawVendorPayload: rawJSON
            )

        default:
            return nil
        }
    }

    /// Translates Codex `thread/status/changed` (`waitingOnApproval`) into `CanonicalApprovalRequest`.
    public func translateApprovalRequest(
        approvalId: String,
        sessionId: String,
        command: String?,
        explanation: String?,
        rawPayload: [String: Any]? = nil
    ) -> CanonicalApprovalRequest {
        var params: [String: JSONValue] = [:]
        if let c = command {
            params["command"] = .string(c)
        }
        return CanonicalApprovalRequest(
            approvalId: approvalId,
            sessionId: sessionId,
            kind: .toolPermission(toolName: "commandExecution", params: params, explanation: explanation),
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
