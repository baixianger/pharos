//! Cold-safe DSH journal → turn outcomes (Swift `DshSessionHistoryReader` subset).

use pharos_codex_adapter::{TurnOutcome, TurnStatus};
use serde_json::Value;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TurnRecord {
    pub number: u32,
    pub status: TurnStatus,
    pub raw_status: String,
    pub assistant_text: String,
    pub vendor_error: Option<String>,
}

impl TurnRecord {
    pub fn turn_id(&self) -> String {
        format!("turn_{}", self.number)
    }

    pub fn into_outcome(self) -> TurnOutcome {
        TurnOutcome {
            turn_id: self.turn_id(),
            status: self.status,
            raw_status: self.raw_status,
            assistant_text: self.assistant_text,
            vendor_error: self.vendor_error,
        }
    }
}

/// Parse `session/page` records into turns (oldest→newest expected).
pub fn parse_turns(records: &[Value]) -> Vec<TurnRecord> {
    let mut turns: Vec<TurnRecord> = Vec::new();
    for record in records {
        if record.get("type").and_then(Value::as_str) != Some("event") {
            continue;
        }
        let event = match record.get("event") {
            Some(event) => event,
            None => continue,
        };
        let typ = event.get("type").and_then(Value::as_str).unwrap_or("");
        let data = event.get("data").cloned().unwrap_or(json_object());
        match typ {
            "turn/start" => {
                let number = data
                    .get("turn")
                    .and_then(Value::as_u64)
                    .unwrap_or((turns.len() as u64) + 1) as u32;
                turns.push(TurnRecord {
                    number,
                    status: TurnStatus::InProgress,
                    raw_status: "inProgress".into(),
                    assistant_text: String::new(),
                    vendor_error: None,
                });
            }
            "assistant/message" => {
                if let Some(turn) = turns.last_mut() {
                    turn.assistant_text.push_str(&extract_assistant_text(&data));
                }
            }
            "turn/end" => {
                if let Some(turn) = turns.last_mut() {
                    let reason = data
                        .pointer("/reason/kind")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown");
                    let (status, raw) = map_end_reason(reason);
                    turn.status = status;
                    turn.raw_status = raw;
                    if matches!(status, TurnStatus::Failed) {
                        turn.vendor_error = Some(format!("turn/end reason={reason}"));
                    }
                }
            }
            _ => {}
        }
    }
    turns
}

fn json_object() -> Value {
    Value::Object(Default::default())
}

fn map_end_reason(reason: &str) -> (TurnStatus, String) {
    match reason {
        "stop" | "finish" | "done" | "completed" => (TurnStatus::Completed, "completed".into()),
        // `aborted` is what dsh 0.2.2-rc.1 emits after session/cancel.
        "interrupt" | "interrupted" | "cancelled" | "cancel" | "aborted" => {
            (TurnStatus::Interrupted, reason.into())
        }
        other => (TurnStatus::Failed, other.into()),
    }
}

fn extract_assistant_text(data: &Value) -> String {
    let mut out = String::new();
    let content = data
        .pointer("/message/content")
        .or_else(|| data.get("content"))
        .and_then(Value::as_array);
    if let Some(items) = content {
        for item in items {
            append_content_item(&mut out, item);
        }
    }
    if let Some(stream) = data.get("stream").and_then(Value::as_array) {
        for item in stream {
            let typ = item.get("type").and_then(Value::as_str).unwrap_or("");
            match typ {
                "text-chunks" => {
                    if let Some(chunks) = item.get("chunks").and_then(Value::as_array) {
                        for chunk in chunks {
                            if let Some(text) = chunk.as_str() {
                                out.push_str(text);
                            }
                        }
                    }
                }
                "text" => {
                    if let Some(text) = item.get("text").and_then(Value::as_str) {
                        out.push_str(text);
                    }
                }
                _ => {}
            }
        }
    }
    out
}

fn append_content_item(out: &mut String, item: &Value) {
    match item.get("type").and_then(Value::as_str) {
        Some("text") => {
            if let Some(text) = item.get("text").and_then(Value::as_str) {
                out.push_str(text);
            }
        }
        Some("text-chunks") => {
            if let Some(chunks) = item.get("chunks").and_then(Value::as_array) {
                for chunk in chunks {
                    if let Some(text) = chunk.as_str() {
                        out.push_str(text);
                    }
                }
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_completed_turn_with_text() {
        let records = vec![
            json!({"type":"event","event":{"type":"turn/start","data":{"turn":1}}}),
            json!({"type":"event","event":{"type":"assistant/message","data":{
                "message":{"content":[{"type":"text","text":"HELLO"}]}
            }}}),
            json!({"type":"event","event":{"type":"turn/end","data":{"turn":1,"reason":{"kind":"stop"}}}}),
        ];
        let turns = parse_turns(&records);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].status, TurnStatus::Completed);
        assert_eq!(turns[0].assistant_text, "HELLO");
        assert_eq!(turns[0].turn_id(), "turn_1");
    }

    #[test]
    fn aborted_maps_to_interrupted_never_completed() {
        let records = vec![
            json!({"type":"event","event":{"type":"turn/start","data":{"turn":2}}}),
            json!({"type":"event","event":{"type":"turn/end","data":{"turn":2,"reason":{"kind":"aborted"}}}}),
        ];
        let turns = parse_turns(&records);
        assert_eq!(turns[0].status, TurnStatus::Interrupted);
        assert_ne!(turns[0].status, TurnStatus::Completed);
    }
}
