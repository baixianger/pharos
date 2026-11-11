//! Delivery dispatch over a recorded (fake) App Server transport.
//!
//! No live Codex CLI: every RPC result is a recorded JSON script fed through
//! [`RecordedAppServer`]. Covers the reply-correlation contract:
//! only the matching completed turn's `final_answer` may become a `Completed`
//! delivery, and a turn without assistant text is never `Completed`.

use pharos_codex_adapter::{
    CodexSessionAdapter, CodexTransport, DeliveryJob, DeliveryWorker, RecordedAppServer,
    SessionAdapter, StartSessionRequest,
};
use pharos_protocol::DeliveryState;
use serde_json::{Value, json};

const THREAD_ID: &str = "019a7e0c-thread-delivery";
const TURN_ID: &str = "019a7e0c-turn-delivery";
const FINAL_ANSWER: &str = "PHAROS_FINAL_ANSWER";
const COMMENTARY: &str = "I will reply to the mesh room now.";

fn job() -> DeliveryJob {
    DeliveryJob {
        delivery_id: "delivery-1".to_owned(),
        conversation_id: THREAD_ID.to_owned(),
        session_id: THREAD_ID.to_owned(),
        payload: json!({
            "body": "Reply exactly PHAROS_FINAL_ANSWER.",
            "room": "host-thread-autoreply",
            "messageID": "msg-1",
            "sender": "human",
        })
        .to_string(),
    }
}

/// Recorded `thread/read` result for one turn of `THREAD_ID`.
fn recorded_thread_read(turn_status: &str, items: Value) -> Value {
    json!({
        "thread": {
            "id": THREAD_ID,
            "status": {"type": "idle"},
            "turns": [{
                "id": TURN_ID,
                "status": turn_status,
                "items": items,
                "error": null,
            }]
        }
    })
}

/// Adapter whose `turn/start` returns `TURN_ID` and whose `thread/read`
/// always replays `thread_read`.
fn adapter_with_thread_read(thread_read: Value) -> CodexSessionAdapter {
    let transport = RecordedAppServer::new()
        .respond(
            "turn/start",
            json!({"turn": {"id": TURN_ID, "status": "inProgress", "items": []}}),
        )
        .respond(
            "thread/start",
            json!({"thread": {"id": THREAD_ID, "status": {"type": "idle"}}}),
        )
        .respond("thread/read", thread_read);
    CodexSessionAdapter::from_transport(CodexTransport::recorded(transport))
}

fn commentary_and_final_items() -> Value {
    json!([
        {
            "type": "userMessage",
            "id": "item_0",
            "content": [{"type": "text", "text": "[Pharos Mesh delivery; untrusted user message]"}]
        },
        {
            "type": "agentMessage",
            "id": "item_1",
            "text": COMMENTARY,
            "phase": "commentary"
        },
        {
            "type": "reasoning",
            "id": "item_2",
            "summary": [{"type": "summary_text", "text": "thinking about the reply"}]
        },
        {
            "type": "agentMessage",
            "id": "item_3",
            "text": FINAL_ANSWER,
            "phase": "final_answer"
        }
    ])
}

#[test]
fn dispatch_completed_turn_uses_only_final_answer() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "completed",
        commentary_and_final_items(),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    assert_eq!(result.state, DeliveryState::Completed);
    assert_eq!(result.delivery_id, "delivery-1");
    assert_eq!(result.turn_id.as_deref(), Some(TURN_ID));
    // Exact final answer only: no commentary / no joined messages.
    assert_eq!(result.assistant_text.as_deref(), Some(FINAL_ANSWER));
    assert!(
        !result
            .assistant_text
            .as_deref()
            .unwrap_or_default()
            .contains(COMMENTARY)
    );

    let recorded = adapter
        .transport()
        .as_recorded()
        .expect("recorded transport");
    let turn_start = recorded.request_for("turn/start").expect("turn/start sent");
    assert_eq!(turn_start.params["threadId"], THREAD_ID);
    let prompt = turn_start.params["input"][0]["text"]
        .as_str()
        .expect("prompt text");
    assert!(prompt.contains("[Pharos Mesh delivery"));
    assert!(prompt.contains("Reply exactly PHAROS_FINAL_ANSWER."));
    assert!(
        recorded.requests().iter().any(
            |request| request.method == "thread/read" && request.params["includeTurns"] == true
        ),
        "wait_turn must read the thread with includeTurns=true"
    );
}

#[test]
fn dispatch_failed_turn_is_failed() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "failed",
        json!([
            {"type": "agentMessage", "id": "item_1", "text": "partial", "phase": "commentary"}
        ]),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    assert_eq!(result.state, DeliveryState::Failed);
    assert_eq!(result.turn_id.as_deref(), Some(TURN_ID));
    assert_eq!(result.assistant_text, None);
    assert!(result.detail.contains("failed"), "detail={}", result.detail);
}

#[test]
fn dispatch_interrupted_turn_is_never_completed() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "interrupted",
        json!([
            {"type": "agentMessage", "id": "item_1", "text": "partial answer", "phase": "final_answer"}
        ]),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    assert_ne!(result.state, DeliveryState::Completed);
    assert_eq!(result.state, DeliveryState::Failed);
    assert_eq!(result.turn_id.as_deref(), Some(TURN_ID));
    assert_eq!(result.assistant_text, None);
    assert!(
        result.detail.contains("interrupted"),
        "detail={}",
        result.detail
    );
}

#[test]
fn dispatch_completed_turn_without_assistant_text_is_failed() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "completed",
        json!([
            {
                "type": "userMessage",
                "id": "item_0",
                "content": [{"type": "text", "text": "[Pharos Mesh delivery]"}]
            },
            {"type": "commandExecution", "id": "item_1", "command": "ls"}
        ]),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    // Hard rule: never Completed without assistant text.
    assert_ne!(result.state, DeliveryState::Completed);
    assert_eq!(result.state, DeliveryState::Failed);
    assert_eq!(result.turn_id.as_deref(), Some(TURN_ID));
    assert_eq!(result.assistant_text, None);
    assert!(
        result.detail.contains("without assistant text"),
        "detail={}",
        result.detail
    );
}

#[test]
fn dispatch_completed_turn_with_only_commentary_is_failed() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "completed",
        json!([
            {"type": "agentMessage", "id": "item_1", "text": COMMENTARY, "phase": "commentary"}
        ]),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    // Commentary is not a final answer; it must never be reported Completed.
    assert_ne!(result.state, DeliveryState::Completed);
    assert_eq!(result.state, DeliveryState::Failed);
    assert_eq!(result.assistant_text, None);
}

#[test]
fn dispatch_legacy_phase_less_completed_turn_still_completes() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "completed",
        json!([
            {"type": "agentMessage", "id": "item_1", "text": "legacy answer"}
        ]),
    ));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    assert_eq!(result.state, DeliveryState::Completed);
    assert_eq!(result.assistant_text.as_deref(), Some("legacy answer"));
}

#[test]
fn dispatch_scripted_turn_start_error_is_failed() {
    let transport = RecordedAppServer::new()
        .respond(
            "thread/read",
            json!({"thread": {"id": THREAD_ID, "status": {"type": "idle"}, "turns": []}}),
        )
        .respond_error("turn/start", "no active rollout for thread");
    let mut adapter = CodexSessionAdapter::from_transport(CodexTransport::recorded(transport));

    let result = adapter.dispatch(job()).expect("dispatch returns Ok");

    assert_eq!(result.state, DeliveryState::Failed);
    assert_eq!(result.turn_id, None);
    assert_eq!(result.assistant_text, None);
    assert!(
        result.detail.contains("turn/start failed before dispatch"),
        "detail={}",
        result.detail
    );
}

#[test]
fn read_turns_selects_final_answer_for_matching_turn() {
    let mut adapter = adapter_with_thread_read(recorded_thread_read(
        "completed",
        commentary_and_final_items(),
    ));
    let started = adapter
        .start_session(StartSessionRequest {
            workspace_path: "/tmp/recorded-workspace".to_owned(),
            model: None,
            mode: Some("yolo".to_owned()),
        })
        .expect("thread/start from recorded transport");
    assert_eq!(started.vendor_thread_id, THREAD_ID);

    let turns = adapter.read_turns(&started.session_id).expect("read turns");
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].turn_id, TURN_ID);
    assert_eq!(turns[0].status, pharos_codex_adapter::TurnStatus::Completed);
    assert_eq!(turns[0].assistant_text, FINAL_ANSWER);
}
