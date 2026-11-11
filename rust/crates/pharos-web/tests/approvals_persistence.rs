//! End-to-end HITL persistence gate: a pending approval recorded before a
//! "process restart" is still listed afterwards, can be decided exactly once,
//! and the decision is durable.

use std::time::Duration;

use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest, ClientEvent};
use pharos_web::{persistent_app_state, resolve_webui_dir, serve_ephemeral};
use serde_json::{Value, json};
use tempfile::TempDir;

const APPROVAL_ID: &str = "hitl-persist-e2e";
const SESSION_ID: &str = "fake-session-1";

fn approval(approval_id: &str) -> ApprovalRequest {
    ApprovalRequest {
        approval_id: approval_id.to_string(),
        session_id: SESSION_ID.to_string(),
        kind: ApprovalKind::ToolPermission {
            tool_name: "shell".to_string(),
            params: json!({ "command": "printf PHAROS_HITL_PERSIST_OK" }),
            explanation: Some("e2e pending approval".to_string()),
        },
        available_choices: Some(vec!["allowedOnce".to_string(), "rejected".to_string()]),
    }
}

async fn snapshot(base: &str) -> Value {
    reqwest::get(format!("{base}/api/v1/approvals?state=pending"))
        .await
        .expect("snapshot request")
        .error_for_status()
        .expect("snapshot status")
        .json()
        .await
        .expect("snapshot json")
}

#[tokio::test]
async fn pending_approval_survives_restart_and_is_decided_once() {
    let webui = resolve_webui_dir(None).expect("webui/ must exist for e2e gate");
    let dir = TempDir::new().expect("tempdir");

    // --- First process: approval arrives via the WS event bus + approval tap ---
    let state = persistent_app_state(dir.path()).expect("first state");
    let events = state.events.clone();
    let (addr, handle) = serve_ephemeral(webui.clone(), state)
        .await
        .expect("first server");
    let base = format!("http://{addr}");
    events.publish(ClientEvent::ApprovalRequired {
        approval: approval(APPROVAL_ID),
    });
    tokio::time::sleep(Duration::from_millis(150)).await;

    let first = snapshot(&base).await;
    let listed = first["approvals"].as_array().expect("approvals array");
    assert_eq!(listed.len(), 1, "tap must persist the approval event");
    assert_eq!(listed[0]["approvalId"], APPROVAL_ID);
    assert_eq!(listed[0]["sessionId"], SESSION_ID);
    assert_eq!(listed[0]["state"], "pending");
    assert_eq!(listed[0]["kind"]["toolName"], "shell");

    // Session filter is honored.
    let filtered: Value = reqwest::get(format!(
        "{base}/api/v1/approvals?state=pending&sessionId=other-session"
    ))
    .await
    .expect("filtered request")
    .json()
    .await
    .expect("filtered json");
    assert!(filtered["approvals"].as_array().expect("array").is_empty());

    // --- "Restart": stop the server, build a fresh AppState on the same dir ---
    handle.abort();
    tokio::time::sleep(Duration::from_millis(100)).await;

    let restarted = persistent_app_state(dir.path()).expect("restarted state");
    let (addr, handle) = serve_ephemeral(webui, restarted.clone())
        .await
        .expect("restarted server");
    let base = format!("http://{addr}");

    let after_restart = snapshot(&base).await;
    let listed = after_restart["approvals"]
        .as_array()
        .expect("approvals array");
    assert_eq!(
        listed.len(),
        1,
        "pending approval must survive a process restart"
    );
    assert_eq!(listed[0]["approvalId"], APPROVAL_ID);

    // --- Decide exactly once ---
    let client = reqwest::Client::new();
    let resolve_url = format!("{base}/api/v1/sessions/{SESSION_ID}/approval");
    let decided: Value = client
        .post(&resolve_url)
        .json(&json!({ "approvalId": APPROVAL_ID, "decision": "allowedOnce" }))
        .send()
        .await
        .expect("resolve request")
        .error_for_status()
        .expect("resolve status")
        .json()
        .await
        .expect("resolve json");
    assert_eq!(decided["ok"], true);
    assert_eq!(decided["alreadyResolved"], false);
    assert_eq!(decided["decision"], "allowedOnce");

    assert!(
        snapshot(&base).await["approvals"]
            .as_array()
            .expect("array")
            .is_empty(),
        "resolved approval must leave the pending snapshot"
    );

    // A second decision (different value) is an explicit idempotent replay.
    let replay: Value = client
        .post(&resolve_url)
        .json(&json!({ "approvalId": APPROVAL_ID, "decision": "rejected" }))
        .send()
        .await
        .expect("replay request")
        .error_for_status()
        .expect("replay status")
        .json()
        .await
        .expect("replay json");
    assert_eq!(replay["alreadyResolved"], true);
    assert_eq!(replay["decision"], "allowedOnce");

    // --- The decision itself is durable across another restart ---
    handle.abort();
    tokio::time::sleep(Duration::from_millis(100)).await;
    drop(restarted);

    let durable = persistent_app_state(dir.path()).expect("durable state");
    let record = durable
        .approvals
        .get(APPROVAL_ID)
        .await
        .expect("get approval")
        .expect("approval must still be on disk");
    assert_eq!(record.state, "resolved");
    let replay = durable
        .approvals
        .resolve(APPROVAL_ID, ApprovalDecision::Rejected)
        .await
        .expect("durable replay");
    assert!(replay.already_resolved);
    assert_eq!(replay.decision, ApprovalDecision::AllowedOnce);
    assert!(
        dir.path()
            .join(pharos_web::PENDING_APPROVALS_FILE)
            .is_file(),
        "approval store file must exist in the data dir"
    );
}

#[tokio::test]
async fn corrupt_approval_store_fails_loudly_instead_of_resetting() {
    let dir = TempDir::new().expect("tempdir");
    std::fs::write(
        dir.path().join(pharos_web::PENDING_APPROVALS_FILE),
        b"{ definitely not json",
    )
    .expect("write corrupt store");
    let Err(error) = persistent_app_state(dir.path()) else {
        panic!("corrupt approval store must fail instead of resetting");
    };
    assert!(error.contains("pending approval store"), "error: {error}");
    // The corrupt bytes are preserved for inspection, never silently replaced.
    let raw = std::fs::read(dir.path().join(pharos_web::PENDING_APPROVALS_FILE)).expect("read");
    assert_eq!(raw.as_slice(), b"{ definitely not json".as_slice());
}
