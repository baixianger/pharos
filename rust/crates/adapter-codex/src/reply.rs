//! Final-answer inspection for Codex `thread/read` replies.
//!
//! The App Server exposes one `agentMessage` item per assistant message and
//! tags each with a `phase`: interim narration is streamed as `commentary`,
//! while the answer meant for the user carries `phase == "final_answer"`.
//! Callers that route a delivery reply may only post the final answer; joining
//! every `agentMessage` (the historical adapter behavior) leaks commentary
//! into the reply.
//!
//! This module is transport-free so Runtime can inspect an already-fetched
//! `thread/read` result without linking a live Codex CLI.

use serde_json::Value;

/// Outcome of inspecting a single turn in a `thread/read` result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplyInspection {
    /// The turn is still running (or the thread/turn is not readable yet).
    Waiting,
    /// The turn ended `failed`, `interrupted`, or `cancelled`.
    Failed,
    /// The turn completed but produced no usable `final_answer` message.
    NoFinalAnswer,
    /// The matching completed turn's final-answer text.
    Ready(String),
}

/// Inspect the reply for `turn_id` in a recorded Codex `thread/read` result.
///
/// Accepts either `{"thread": {"turns": [...]}}` or `{"turns": [...]}`
/// (and the same shapes wrapped in an RPC `{"result": ...}` envelope).
///
/// - missing turn / non-terminal status -> [`ReplyInspection::Waiting`]
/// - `failed` / `interrupted` / `cancelled` -> [`ReplyInspection::Failed`]
/// - `completed` + last non-empty `phase == "final_answer"` agent message
///   -> [`ReplyInspection::Ready`]
/// - `completed` without one -> [`ReplyInspection::NoFinalAnswer`]
pub fn inspect_turn_reply(thread_read_result: &Value, turn_id: &str) -> ReplyInspection {
    let Some(turns) = turn_list(thread_read_result) else {
        return ReplyInspection::Waiting;
    };
    let Some(turn) = turns
        .iter()
        .find(|turn| turn.get("id").and_then(Value::as_str) == Some(turn_id))
    else {
        return ReplyInspection::Waiting;
    };
    let status = turn.get("status").and_then(Value::as_str).unwrap_or("");
    match status {
        "failed" | "interrupted" | "cancelled" => return ReplyInspection::Failed,
        "completed" => {}
        _ => return ReplyInspection::Waiting,
    }
    let empty: Vec<Value> = Vec::new();
    let items = turn
        .get("items")
        .and_then(Value::as_array)
        .unwrap_or(&empty);
    match final_answer_text(items) {
        Some(text) => ReplyInspection::Ready(text),
        None => ReplyInspection::NoFinalAnswer,
    }
}

/// Text of the last `agentMessage` item tagged `phase == "final_answer"` with
/// non-empty trimmed text, or `None` when the turn has no final answer.
pub fn final_answer_text(items: &[Value]) -> Option<String> {
    items
        .iter()
        .rev()
        .filter_map(|item| final_answer_item(item)?.get("text")?.as_str())
        .find(|text| !text.trim().is_empty())
        .map(str::to_owned)
}

/// Reply text for a turn: prefer the `final_answer` agent message, else fall
/// back to the last non-empty `agentMessage` (older Codex versions omitted
/// `phase`). Never joins multiple messages.
pub fn assistant_reply_text(items: &[Value]) -> Option<String> {
    final_answer_text(items).or_else(|| {
        items
            .iter()
            .rev()
            .filter(|item| item.get("type").and_then(Value::as_str) == Some("agentMessage"))
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .find(|text| !text.trim().is_empty())
            .map(str::to_owned)
    })
}

fn final_answer_item(item: &Value) -> Option<&Value> {
    if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
        return None;
    }
    if item.get("phase").and_then(Value::as_str) != Some("final_answer") {
        return None;
    }
    Some(item)
}

fn turn_list(thread_read_result: &Value) -> Option<&Vec<Value>> {
    const PATHS: [&str; 4] = [
        "/turns",
        "/thread/turns",
        "/result/turns",
        "/result/thread/turns",
    ];
    PATHS
        .iter()
        .find_map(|path| thread_read_result.pointer(path).and_then(Value::as_array))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn recorded_thread_read() -> Value {
        // Shape captured from Codex CLI 0.167 App Server `thread/read`
        // (`includeTurns: true`), with commentary narration before the answer.
        json!({
            "thread": {
                "id": "019a7e0c-thread-0001",
                "preview": "Reply exactly PHAROS_FINAL",
                "status": {"type": "idle"},
                "turns": [
                    {
                        "id": "019a7e0c-turn-seed",
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "id": "item_0",
                                "content": [{"type": "text", "text": "Reply exactly PHAROS_SEED"}]
                            },
                            {
                                "type": "agentMessage",
                                "id": "item_1",
                                "text": "PHAROS_SEED",
                                "phase": "final_answer"
                            }
                        ],
                        "error": null
                    },
                    {
                        "id": "019a7e0c-turn-delivery",
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "id": "item_2",
                                "content": [{"type": "text", "text": "[Pharos Mesh delivery]"}]
                            },
                            {
                                "type": "agentMessage",
                                "id": "item_3",
                                "text": "I will reply to the mesh room now.",
                                "phase": "commentary"
                            },
                            {
                                "type": "reasoning",
                                "id": "item_4",
                                "summary": [{"type": "summary_text", "text": "thinking"}]
                            },
                            {
                                "type": "agentMessage",
                                "id": "item_5",
                                "text": "PHAROS_FINAL",
                                "phase": "final_answer"
                            }
                        ],
                        "error": null
                    }
                ]
            }
        })
    }

    #[test]
    fn prefers_final_answer_over_commentary() {
        assert_eq!(
            inspect_turn_reply(&recorded_thread_read(), "019a7e0c-turn-delivery"),
            ReplyInspection::Ready("PHAROS_FINAL".to_owned())
        );
    }

    #[test]
    fn ignores_unrelated_turns() {
        // The seed turn also has a final answer; inspection must key on turn id.
        assert_eq!(
            inspect_turn_reply(&recorded_thread_read(), "019a7e0c-turn-seed"),
            ReplyInspection::Ready("PHAROS_SEED".to_owned())
        );
    }

    #[test]
    fn accepts_bare_turns_shape() {
        let bare = json!({
            "turns": [{
                "id": "turn-1",
                "status": "completed",
                "items": [
                    {"type": "agentMessage", "text": "narration", "phase": "commentary"},
                    {"type": "agentMessage", "text": "answer", "phase": "final_answer"}
                ]
            }]
        });
        assert_eq!(
            inspect_turn_reply(&bare, "turn-1"),
            ReplyInspection::Ready("answer".to_owned())
        );
    }

    #[test]
    fn accepts_result_wrapped_shape() {
        let wrapped = json!({"result": recorded_thread_read()});
        assert_eq!(
            inspect_turn_reply(&wrapped, "019a7e0c-turn-delivery"),
            ReplyInspection::Ready("PHAROS_FINAL".to_owned())
        );
    }

    #[test]
    fn failed_turn_is_failed() {
        let failed = json!({"turns": [{
            "id": "turn-1",
            "status": "failed",
            "error": {"message": "boom"},
            "items": [{"type": "agentMessage", "text": "partial", "phase": "final_answer"}]
        }]});
        assert_eq!(
            inspect_turn_reply(&failed, "turn-1"),
            ReplyInspection::Failed
        );
    }

    #[test]
    fn interrupted_turn_is_failed() {
        let interrupted = json!({"thread": {"turns": [{
            "id": "turn-1",
            "status": "interrupted",
            "items": [{"type": "agentMessage", "text": "partial", "phase": "final_answer"}]
        }]}});
        assert_eq!(
            inspect_turn_reply(&interrupted, "turn-1"),
            ReplyInspection::Failed
        );
    }

    #[test]
    fn cancelled_turn_is_failed() {
        let cancelled = json!({"turns": [{"id": "turn-1", "status": "cancelled", "items": []}]});
        assert_eq!(
            inspect_turn_reply(&cancelled, "turn-1"),
            ReplyInspection::Failed
        );
    }

    #[test]
    fn in_progress_turn_is_waiting() {
        let running = json!({"turns": [{
            "id": "turn-1",
            "status": "inProgress",
            "items": [{"type": "agentMessage", "text": "working", "phase": "commentary"}]
        }]});
        assert_eq!(
            inspect_turn_reply(&running, "turn-1"),
            ReplyInspection::Waiting
        );
    }

    #[test]
    fn missing_turn_is_waiting() {
        assert_eq!(
            inspect_turn_reply(&recorded_thread_read(), "019a7e0c-turn-unknown"),
            ReplyInspection::Waiting
        );
        assert_eq!(
            inspect_turn_reply(&json!({"thread": {"turns": []}}), "turn-1"),
            ReplyInspection::Waiting
        );
        assert_eq!(
            inspect_turn_reply(&json!({"thread": {}}), "turn-1"),
            ReplyInspection::Waiting
        );
        assert_eq!(
            inspect_turn_reply(&json!({"unexpected": true}), "turn-1"),
            ReplyInspection::Waiting
        );
    }

    #[test]
    fn completed_without_final_answer_is_no_final_answer() {
        let commentary_only = json!({"turns": [{
            "id": "turn-1",
            "status": "completed",
            "items": [
                {"type": "agentMessage", "text": "still working on it", "phase": "commentary"},
                {"type": "commandExecution", "id": "cmd-1", "command": "ls"}
            ]
        }]});
        assert_eq!(
            inspect_turn_reply(&commentary_only, "turn-1"),
            ReplyInspection::NoFinalAnswer
        );
    }

    #[test]
    fn blank_final_answer_is_no_final_answer() {
        let blank = json!({"turns": [{
            "id": "turn-1",
            "status": "completed",
            "items": [
                {"type": "agentMessage", "text": "answer", "phase": "commentary"},
                {"type": "agentMessage", "text": "   \n\t", "phase": "final_answer"}
            ]
        }]});
        assert_eq!(
            inspect_turn_reply(&blank, "turn-1"),
            ReplyInspection::NoFinalAnswer
        );
    }

    #[test]
    fn final_answer_helper_selects_last_non_empty_final_answer() {
        let items = vec![
            json!({"type": "agentMessage", "text": "commentary", "phase": "commentary"}),
            json!({"type": "agentMessage", "text": "first", "phase": "final_answer"}),
            json!({"type": "agentMessage", "text": "second", "phase": "final_answer"}),
        ];
        assert_eq!(final_answer_text(&items).as_deref(), Some("second"));
        assert_eq!(final_answer_text(&items[..1]), None);
        assert_eq!(final_answer_text(&[]), None);
    }

    #[test]
    fn assistant_reply_text_falls_back_to_last_agent_message() {
        let legacy = vec![
            json!({"type": "agentMessage", "text": "old narration"}),
            json!({"type": "agentMessage", "text": "legacy answer"}),
            json!({"type": "agentMessage", "text": "  "}),
        ];
        assert_eq!(
            assistant_reply_text(&legacy).as_deref(),
            Some("legacy answer")
        );
        // A final_answer still wins when both are present.
        let mixed = vec![
            json!({"type": "agentMessage", "text": "legacy answer"}),
            json!({"type": "agentMessage", "text": "final", "phase": "final_answer"}),
        ];
        assert_eq!(assistant_reply_text(&mixed).as_deref(), Some("final"));
        assert_eq!(assistant_reply_text(&[]), None);
    }
}
