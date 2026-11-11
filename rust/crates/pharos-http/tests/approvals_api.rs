//! Independent black-box HTTP gate for durable pending-approval persistence.
//!
//! These tests exercise the real axum router (`pharos_http::api_router`) over a
//! real file-backed `FileApprovalService` and assert the externally visible
//! contract instead of calling the store directly:
//!
//! - `GET /api/v1/approvals?state=pending[&sessionId=]` snapshot shape/order,
//! - the event-bus approval tap (`ClientEvent::ApprovalRequired`/`Updated`/
//!   `Resolved`/`Withdrawn` -> durable store),
//! - restart durability (a brand new `AppState` over the same store file),
//! - idempotent first-wins `POST /api/v1/sessions/{id}/approval`,
//! - error contract for unknown/mismatched/expired approvals,
//! - no approval resurrection after a late `ApprovalRequired` event.
//!
//! No network listeners are used; every request goes through `Router::oneshot`.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest, ClientEvent};
use pharos_hitl::{HITL_TIMEOUT_SECS, PendingApprovalStore, WallClock};
use pharos_http::{
    AppState, ApprovalService, EventBus, FakeSessionService, FakeThreadService,
    FileApprovalService, SessionService, ThreadService, api_router,
};
use serde_json::{Value, json};
use tempfile::TempDir;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;
use tower::ServiceExt;

const APPROVALS_URI: &str = "/api/v1/approvals?state=pending";
const FAKE_SESSION: &str = "fake-session-1";

/// Deterministic wall clock so createdAt/expiresAt/expiry are exact.
#[derive(Debug, Clone)]
struct TestClock(Arc<Mutex<OffsetDateTime>>);

impl TestClock {
    fn new() -> Self {
        Self(Arc::new(Mutex::new(
            OffsetDateTime::parse("2026-11-11T10:00:00Z", &Rfc3339).expect("fixed test clock"),
        )))
    }

    fn advance(&self, seconds: i64) {
        *self.0.lock().expect("test clock lock") += time::Duration::seconds(seconds);
    }
}

impl WallClock for TestClock {
    fn now(&self) -> OffsetDateTime {
        *self.0.lock().expect("test clock lock")
    }
}

fn approval(approval_id: &str, session_id: &str) -> ApprovalRequest {
    ApprovalRequest {
        approval_id: approval_id.to_string(),
        session_id: session_id.to_string(),
        kind: ApprovalKind::ToolPermission {
            tool_name: "shell".to_string(),
            params: json!({ "command": "printf PHAROS_HITL_API_OK" }),
            explanation: Some("independent verifier approval".to_string()),
        },
        available_choices: Some(vec!["allowedOnce".to_string(), "rejected".to_string()]),
    }
}

fn state_with(approvals: Arc<dyn ApprovalService>) -> AppState {
    let events = EventBus::new(64);
    let threads: Arc<dyn ThreadService> = Arc::new(FakeThreadService::new(events.clone()));
    let sessions: Arc<dyn SessionService> = Arc::new(FakeSessionService::new(events.clone()));
    AppState::with_approvals(threads, sessions, events, approvals)
}

/// Real file-backed store, as `pharos-web` wires it in production.
fn file_state(store_path: &Path) -> AppState {
    let approvals: Arc<dyn ApprovalService> =
        Arc::new(FileApprovalService::open(store_path).expect("open durable approval store"));
    state_with(approvals)
}

/// File-backed store with an injectable clock (deterministic ordering/expiry).
fn clock_state(store_path: &Path, clock: TestClock) -> AppState {
    let store = PendingApprovalStore::open_with(
        store_path,
        clock,
        time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
    )
    .expect("open clocked durable approval store");
    let approvals: Arc<dyn ApprovalService> = Arc::new(FileApprovalService::from_store(store));
    state_with(approvals)
}

async fn send(app: &Router, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    let mut builder = Request::builder().method(method).uri(uri);
    let body = match body {
        Some(value) => {
            builder = builder.header("content-type", "application/json");
            Body::from(value.to_string())
        }
        None => Body::empty(),
    };
    let response = app
        .clone()
        .oneshot(builder.body(body).expect("build request"))
        .await
        .expect("router oneshot must not fail");
    let status = response.status();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("collect response body")
        .to_bytes();
    let json = if bytes.is_empty() {
        Value::Null
    } else {
        match serde_json::from_slice(&bytes) {
            Ok(value) => value,
            // Handlers answer JSON; axum extractor rejections (e.g. a malformed
            // JSON body) are plain text, which callers can assert on by status.
            Err(_) => Value::String(String::from_utf8_lossy(&bytes).into_owned()),
        }
    };
    (status, json)
}

async fn get(app: &Router, uri: &str) -> (StatusCode, Value) {
    send(app, "GET", uri, None).await
}

async fn post(app: &Router, uri: &str, body: Value) -> (StatusCode, Value) {
    send(app, "POST", uri, Some(body)).await
}

/// GET the pending snapshot, asserting the route answers with the documented shape.
async fn snapshot(app: &Router) -> Vec<Value> {
    let (status, json) = get(app, APPROVALS_URI).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "GET {APPROVALS_URI} must succeed; body: {json}"
    );
    json["approvals"]
        .as_array()
        .unwrap_or_else(|| panic!("snapshot body must contain an approvals array; got {json}"))
        .clone()
}

/// Poll the snapshot until `predicate` holds (approval-tap tasks are async).
async fn wait_for_snapshot<F>(app: &Router, label: &str, mut predicate: F) -> Vec<Value>
where
    F: FnMut(&[Value]) -> bool,
{
    for _ in 0..100 {
        let items = snapshot(app).await;
        if predicate(&items) {
            return items;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out after 2s waiting for {label}");
}

fn parse_rfc3339(value: &Value, field: &str) -> OffsetDateTime {
    let raw = value
        .as_str()
        .unwrap_or_else(|| panic!("{field} must be a string; got {value}"));
    OffsetDateTime::parse(raw, &Rfc3339).unwrap_or_else(|error| {
        panic!("{field} must be RFC3339 ({raw:?}): {error}");
    })
}

fn ids(items: &[Value]) -> Vec<String> {
    items
        .iter()
        .map(|item| {
            item["approvalId"]
                .as_str()
                .unwrap_or_else(|| panic!("approval item must carry approvalId; got {item}"))
                .to_string()
        })
        .collect()
}

#[tokio::test]
async fn snapshot_lists_pending_approvals_oldest_first_and_filters_by_session() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let clock = TestClock::new();
    let state = clock_state(&path, clock.clone());
    state
        .approvals
        .record(approval("a1", "session-1"))
        .await
        .expect("record a1");
    clock.advance(1);
    state
        .approvals
        .record(approval("a2", "session-2"))
        .await
        .expect("record a2");
    let app = api_router(state);

    // `state` is optional and defaults to pending.
    let (status, json) = get(&app, "/api/v1/approvals").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "GET /api/v1/approvals without a state query must default to pending; body: {json}"
    );
    assert_eq!(
        json["approvals"]
            .as_array()
            .expect("default snapshot must list approvals")
            .len(),
        2,
        "the default pending snapshot must list both approvals"
    );

    let (status, json) = get(&app, APPROVALS_URI).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "GET {APPROVALS_URI} must succeed; body: {json}"
    );
    let list = json["approvals"]
        .as_array()
        .expect("snapshot must carry an approvals array");
    assert_eq!(
        ids(list),
        vec!["a1".to_string(), "a2".to_string()],
        "pending approvals must be oldest-first (createdAt ascending), got {json}"
    );

    let first = &list[0];
    assert_eq!(first["approvalId"], "a1", "first item must be approval a1");
    assert_eq!(
        first["sessionId"], "session-1",
        "snapshot must expose the owning session id"
    );
    assert_eq!(
        first["kind"]["type"], "toolPermission",
        "snapshot must expose the same approval kind shape as ClientEvent approvals"
    );
    assert_eq!(first["kind"]["toolName"], "shell");
    assert_eq!(
        first["kind"]["params"]["command"],
        "printf PHAROS_HITL_API_OK"
    );
    assert_eq!(
        first["availableChoices"],
        json!(["allowedOnce", "rejected"]),
        "availableChoices must pass through the contract camelCase values"
    );
    assert_eq!(first["state"], "pending");
    assert!(
        first.get("decision").is_none(),
        "a pending snapshot must not leak a decision field"
    );
    assert!(
        first.get("resolvedAt").is_none(),
        "a pending snapshot must not leak a resolvedAt field"
    );
    let created = parse_rfc3339(&first["createdAt"], "createdAt");
    let expires = parse_rfc3339(&first["expiresAt"], "expiresAt");
    assert_eq!(
        (expires - created).whole_seconds(),
        HITL_TIMEOUT_SECS as i64,
        "expiresAt must be exactly the 45m HITL window after createdAt"
    );

    // Session filtering is exact and does not depend on the session existing locally.
    let (status, json) = get(&app, "/api/v1/approvals?state=pending&sessionId=session-2").await;
    assert_eq!(status, StatusCode::OK);
    let filtered = json["approvals"].as_array().expect("filtered approvals");
    assert_eq!(
        ids(filtered),
        vec!["a2".to_string()],
        "sessionId must filter the snapshot"
    );
    let (status, json) = get(&app, "/api/v1/approvals?state=pending&sessionId=session-1").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        ids(json["approvals"].as_array().expect("filtered approvals")),
        vec!["a1".to_string()],
        "sessionId=session-1 must only return a1"
    );
    let (status, json) = get(
        &app,
        "/api/v1/approvals?state=pending&sessionId=missing-session",
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        json["approvals"]
            .as_array()
            .expect("filtered approvals")
            .is_empty(),
        "an unknown session filter must return an empty list, not an error"
    );

    // An empty sessionId is treated as "no filter" (all sessions).
    let (status, json) = get(&app, "/api/v1/approvals?state=pending&sessionId=").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        json["approvals"].as_array().expect("approvals").len(),
        2,
        "an empty sessionId query must not be interpreted as an empty session id"
    );
}

#[tokio::test]
async fn approval_tap_persists_required_updated_withdrawn_and_ignores_unknown_resolved() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let state = file_state(&path);
    let events = state.events.clone();
    let app = api_router(state.clone());
    let tap = state.spawn_approval_tap();

    events.publish(ClientEvent::ApprovalRequired {
        approval: approval("tap-1", FAKE_SESSION),
    });
    let items = wait_for_snapshot(&app, "the tap to persist ApprovalRequired", |items| {
        items.len() == 1
    })
    .await;
    assert_eq!(items[0]["approvalId"], "tap-1");
    assert_eq!(items[0]["state"], "pending");

    // ApprovalUpdated is an upsert keyed by approvalId: update in place, no duplicate.
    let mut updated = approval("tap-1", FAKE_SESSION);
    if let ApprovalKind::ToolPermission { tool_name, .. } = &mut updated.kind {
        *tool_name = "shell-v2".to_string();
    }
    events.publish(ClientEvent::ApprovalUpdated { approval: updated });
    let items = wait_for_snapshot(&app, "the tap to refresh ApprovalUpdated", |items| {
        items.len() == 1 && items[0]["kind"]["toolName"] == "shell-v2"
    })
    .await;
    assert_eq!(
        items.len(),
        1,
        "ApprovalUpdated must update the persisted approval in place, never duplicate it"
    );

    // An ApprovalResolved for an approval the store never saw is benign.
    events.publish(ClientEvent::ApprovalResolved {
        approval_id: "never-persisted".to_string(),
        decision: ApprovalDecision::Rejected,
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let items = snapshot(&app).await;
    assert_eq!(
        ids(&items),
        vec!["tap-1".to_string()],
        "an ApprovalResolved for an unknown id must not disturb persisted pending approvals"
    );

    events.publish(ClientEvent::ApprovalWithdrawn {
        approval_id: "tap-1".to_string(),
    });
    let items = wait_for_snapshot(&app, "the tap to withdraw the approval", |items| {
        items.is_empty()
    })
    .await;
    assert!(
        items.is_empty(),
        "ApprovalWithdrawn must remove the approval from the durable snapshot"
    );

    tap.abort();
}

#[tokio::test]
async fn pending_approval_survives_new_appstate_on_the_same_store_file() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");

    {
        let state = file_state(&path);
        state
            .approvals
            .record(approval("persist-1", FAKE_SESSION))
            .await
            .expect("record pending approval");
        let app = api_router(state);
        let items = snapshot(&app).await;
        assert_eq!(
            ids(&items),
            vec!["persist-1".to_string()],
            "the first AppState must list the recorded pending approval"
        );
    }

    // The bytes on disk must be a real versioned store, not an in-memory illusion.
    let raw =
        std::fs::read(&path).expect("store file must exist after recording a pending approval");
    assert!(!raw.is_empty(), "store file must not be empty");
    let on_disk: Value = serde_json::from_slice(&raw).expect("store file must be valid JSON");
    assert_eq!(
        on_disk["version"], 1,
        "store file must use the versioned envelope"
    );
    let records = on_disk["approvals"]
        .as_array()
        .expect("store file must carry an approvals array");
    assert_eq!(
        records.len(),
        1,
        "store file must contain exactly one record"
    );
    assert_eq!(records[0]["approvalId"], "persist-1");
    assert_eq!(records[0]["state"], "pending");

    // A brand new AppState over the same file is what a restarted process does.
    let restarted = file_state(&path);
    let app = api_router(restarted);
    let items = snapshot(&app).await;
    assert_eq!(
        ids(&items),
        vec!["persist-1".to_string()],
        "a new AppState over the same file must still list the pending approval"
    );
    assert_eq!(items[0]["sessionId"], FAKE_SESSION);
    assert_eq!(
        items[0]["availableChoices"],
        json!(["allowedOnce", "rejected"])
    );
    let created = parse_rfc3339(&items[0]["createdAt"], "createdAt");
    let expires = parse_rfc3339(&items[0]["expiresAt"], "expiresAt");
    assert_eq!(
        (expires - created).whole_seconds(),
        HITL_TIMEOUT_SECS as i64,
        "the 45m expiry window must survive a restart unchanged"
    );
}

#[tokio::test]
async fn resolve_is_idempotent_durable_and_never_resurrected() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let state = file_state(&path);
    let mut adapter_events = state.events.subscribe();
    state
        .approvals
        .record(approval("resolve-1", FAKE_SESSION))
        .await
        .expect("record pending approval");
    let app = api_router(state);

    let resolve_uri = format!("/api/v1/sessions/{FAKE_SESSION}/approval");
    let (status, json) = post(
        &app,
        &resolve_uri,
        json!({ "approvalId": "resolve-1", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "first decision must succeed; body: {json}"
    );
    assert!(
        json["ok"].as_bool().unwrap_or(false),
        "decision response must be ok:true"
    );
    assert_eq!(json["approvalId"], "resolve-1");
    assert_eq!(json["state"], "resolved");
    assert_eq!(json["decision"], "allowedOnce");
    assert!(
        json["alreadyResolved"].is_boolean(),
        "alreadyResolved must be present as a bool"
    );
    assert!(
        !json["alreadyResolved"].as_bool().unwrap_or(true),
        "the first decision must report alreadyResolved:false"
    );

    // The existing session/adapter decision path is dispatched exactly once.
    let dispatched = tokio::time::timeout(Duration::from_secs(2), adapter_events.recv())
        .await
        .expect("first decision must dispatch an ApprovalResolved event to the session layer")
        .expect("event bus must deliver the dispatched decision");
    match dispatched {
        ClientEvent::ApprovalResolved {
            approval_id,
            decision,
        } => {
            assert_eq!(approval_id, "resolve-1");
            assert_eq!(decision, ApprovalDecision::AllowedOnce);
        }
        other => panic!("expected ClientEvent::ApprovalResolved, got {other:?}"),
    }

    assert!(
        snapshot(&app).await.is_empty(),
        "a resolved approval must leave the pending snapshot"
    );

    // Replay with a different decision is an explicit first-wins no-op.
    let (status, json) = post(
        &app,
        &resolve_uri,
        json!({ "approvalId": "resolve-1", "decision": "rejected" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "an idempotent replay must not error; body: {json}"
    );
    assert!(
        json["alreadyResolved"].as_bool().unwrap_or(false),
        "a replay must report alreadyResolved:true"
    );
    assert_eq!(
        json["decision"], "allowedOnce",
        "the first decision must win; a replay must not overwrite it"
    );
    assert_eq!(json["state"], "resolved");
    assert!(
        tokio::time::timeout(Duration::from_millis(250), adapter_events.recv())
            .await
            .is_err(),
        "a replay must not dispatch a second approval decision to the session layer"
    );
    assert!(
        snapshot(&app).await.is_empty(),
        "a replay must not resurrect a pending approval"
    );

    // Durability across a fresh AppState: the original decision is still authoritative.
    let restarted = file_state(&path);
    let app = api_router(restarted.clone());
    assert!(
        snapshot(&app).await.is_empty(),
        "resolved approvals must stay out of the snapshot after a restart"
    );
    let (status, json) = post(
        &app,
        &resolve_uri,
        json!({ "approvalId": "resolve-1", "decision": "rejected" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        json["alreadyResolved"].as_bool().unwrap_or(false),
        "a restarted state must remember the approval was already resolved"
    );
    assert_eq!(
        json["decision"], "allowedOnce",
        "a restarted state must report the original decision, not the replay decision"
    );

    // A late ApprovalRequired must not resurrect the resolved approval. Order the
    // events so the control approval proves the tap already drained the late one.
    let events = restarted.events.clone();
    let _tap = restarted.spawn_approval_tap();
    events.publish(ClientEvent::ApprovalRequired {
        approval: approval("resolve-1", FAKE_SESSION),
    });
    events.publish(ClientEvent::ApprovalRequired {
        approval: approval("control-1", FAKE_SESSION),
    });
    let items = wait_for_snapshot(&app, "the tap to process the control approval", |items| {
        items.iter().any(|item| item["approvalId"] == "control-1")
    })
    .await;
    assert_eq!(
        ids(&items),
        vec!["control-1".to_string()],
        "a late ApprovalRequired for a resolved approval must not resurrect it"
    );
}

#[tokio::test]
async fn snapshot_and_resolve_error_contract() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let state = file_state(&path);
    state
        .approvals
        .record(approval("a1", FAKE_SESSION))
        .await
        .expect("record a1");
    state
        .approvals
        .record(approval("a2", "session-2"))
        .await
        .expect("record a2");
    let app = api_router(state);

    // Unknown approval: explicit 404, never a silent success.
    let (status, json) = post(
        &app,
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        json!({ "approvalId": "missing", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "unknown approval ids must be 404 approvalNotFound; body: {json}"
    );
    assert_eq!(json["error"]["code"], "approvalNotFound");
    assert_eq!(json["error"]["id"], "missing");
    assert_eq!(
        json["contractsVersion"], "0.1.0",
        "contract error bodies must carry contractsVersion"
    );

    // Session mismatch is rejected before any durable mutation.
    let (status, json) = post(
        &app,
        "/api/v1/sessions/session-2/approval",
        json!({ "approvalId": "a1", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a path/approval session mismatch must be 400 invalidRequest; body: {json}"
    );
    assert_eq!(json["error"]["code"], "invalidRequest");
    assert_eq!(json["contractsVersion"], "0.1.0");
    let items = snapshot(&app).await;
    assert_eq!(
        ids(&items),
        vec!["a1".to_string(), "a2".to_string()],
        "a rejected session mismatch must not mutate the pending snapshot"
    );

    // Unsupported snapshot states are an error, not a fabricated empty success.
    let (status, json) = get(&app, "/api/v1/approvals?state=resolved").await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "state=resolved must be 400 invalidRequest; body: {json}"
    );
    assert_eq!(json["error"]["code"], "invalidRequest");
    assert_eq!(json["contractsVersion"], "0.1.0");
    assert!(
        json.get("approvals").is_none(),
        "an unsupported state must not return a fabricated approvals list"
    );

    // Malformed decisions are rejected by the JSON extractor and never coerced.
    let (status, _) = post(
        &app,
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        json!({ "approvalId": "a1", "decision": "maybe" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::UNPROCESSABLE_ENTITY,
        "unknown decision values must be rejected, not coerced to a default"
    );
    assert_eq!(
        snapshot(&app).await.len(),
        2,
        "a malformed decision must not resolve anything"
    );
}

#[tokio::test]
async fn expired_approval_is_hidden_and_conflicts_on_resolve() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let clock = TestClock::new();
    let state = clock_state(&path, clock.clone());
    state
        .approvals
        .record(approval("expiring-1", FAKE_SESSION))
        .await
        .expect("record approval");
    let app = api_router(state);

    clock.advance(HITL_TIMEOUT_SECS as i64 - 1);
    assert_eq!(
        snapshot(&app).await.len(),
        1,
        "one second before the 45m deadline the approval must still be pending"
    );

    clock.advance(1);
    assert!(
        snapshot(&app).await.is_empty(),
        "at the expiry instant the approval must disappear from the pending snapshot"
    );

    let (status, json) = post(
        &app,
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        json!({ "approvalId": "expiring-1", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "deciding an expired approval must conflict, not succeed; body: {json}"
    );
    assert_eq!(json["error"]["code"], "conflict");
    assert!(
        json["error"]["message"]
            .as_str()
            .is_some_and(|message| !message.is_empty()),
        "the conflict error must explain the expiry; body: {json}"
    );
    assert!(
        snapshot(&app).await.is_empty(),
        "an expired approval must not become pending again after a failed decision"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_decisions_resolve_exactly_once() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let state = file_state(&path);
    state
        .approvals
        .record(approval("race-1", FAKE_SESSION))
        .await
        .expect("record approval");
    let app = api_router(state);

    let resolve_uri = format!("/api/v1/sessions/{FAKE_SESSION}/approval");
    let first_app = app.clone();
    let second_app = app.clone();
    let first_uri = resolve_uri.clone();
    let second_uri = resolve_uri;
    let first = tokio::spawn(async move {
        post(
            &first_app,
            &first_uri,
            json!({ "approvalId": "race-1", "decision": "allowedOnce" }),
        )
        .await
    });
    let second = tokio::spawn(async move {
        post(
            &second_app,
            &second_uri,
            json!({ "approvalId": "race-1", "decision": "rejected" }),
        )
        .await
    });
    let (first, second) = tokio::join!(first, second);
    let (first_status, first_json) = first.expect("first concurrent decision task");
    let (second_status, second_json) = second.expect("second concurrent decision task");

    assert_eq!(
        first_status,
        StatusCode::OK,
        "concurrent decision 1 must answer 200; body: {first_json}"
    );
    assert_eq!(
        second_status,
        StatusCode::OK,
        "concurrent decision 2 must answer 200; body: {second_json}"
    );
    let applied = [&first_json, &second_json]
        .iter()
        .filter(|json| json["alreadyResolved"].as_bool() == Some(false))
        .count();
    assert_eq!(
        applied, 1,
        "exactly one concurrent decision must take effect; got {first_json} and {second_json}"
    );
    assert_eq!(
        first_json["decision"], second_json["decision"],
        "both concurrent responses must report the same first-wins decision"
    );
    assert!(
        snapshot(&app).await.is_empty(),
        "the approval must be resolved after concurrent decisions"
    );
}

#[tokio::test]
async fn pre_existing_routes_keep_their_shape() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let app = api_router(file_state(&path));

    let (status, json) = get(&app, "/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["ok"], true);
    assert_eq!(json["contractsVersion"], "0.1.0");

    let (status, json) = get(&app, "/api/v1/sessions").await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the sessions route must stay mounted"
    );
    assert!(
        json.as_array()
            .expect("sessions list")
            .iter()
            .any(|session| session["sessionId"] == FAKE_SESSION),
        "the pre-existing sessions route must still return the fake sessions; got {json}"
    );

    let (status, json) = get(&app, &format!("/api/v1/sessions/{FAKE_SESSION}")).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "the session detail route must stay mounted"
    );
    assert_eq!(json["sessionId"], FAKE_SESSION);

    let (status, json) = get(&app, "/openapi.json").await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        json["paths"].get("/api/v1/sessions").is_some(),
        "the frozen OpenAPI paths must be preserved"
    );
    assert!(
        json["paths"].get("/api/v1/approvals").is_some(),
        "the additive approvals route must be documented in OpenAPI"
    );
}

/// Regression (found by the independent verifier, fixed in f0fb14a): a durable
/// decision must not be consumed when the adapter/session dispatch fails.
///
/// `resolve_approval` records the durable decision before delegating to
/// `SessionService::resolve_approval` (that ordering is what makes concurrent
/// double decisions exactly-once). A failed delegation must therefore revert the
/// durable decision: the HTTP response is the dispatch error, the approval stays
/// pending (also across a restart), and a retry really re-dispatches instead of
/// short-circuiting on `alreadyResolved:true`.
#[tokio::test]
async fn failed_session_dispatch_leaves_approval_pending_and_retryable() {
    let dir = TempDir::new().expect("tempdir");
    let path = dir.path().join("pending-approvals.json");
    let state = file_state(&path);
    // The durable store knows this session (an adapter could have announced it),
    // but FakeSessionService only knows `fake-session-1`, so dispatch fails.
    state
        .approvals
        .record(approval("orphan-1", "ghost-session"))
        .await
        .expect("record approval for a session the dispatch layer does not know");
    let app = api_router(state);

    let resolve_uri = "/api/v1/sessions/ghost-session/approval";
    let (status, json) = post(
        &app,
        resolve_uri,
        json!({ "approvalId": "orphan-1", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "the existing session path still rejects unknown sessions; body: {json}"
    );
    assert_eq!(json["error"]["code"], "sessionNotFound");
    assert_eq!(
        ids(&snapshot(&app).await),
        vec!["orphan-1".to_string()],
        "a failed session/adapter dispatch must leave the approval pending for retry"
    );

    // The revert is durable, not just in-memory: a fresh AppState on the same
    // file must still see the approval pending.
    let restarted = file_state(&path);
    let app = api_router(restarted);
    let items = snapshot(&app).await;
    assert_eq!(
        ids(&items),
        vec!["orphan-1".to_string()],
        "the reverted approval must be durable across a restart"
    );
    assert_eq!(items[0]["state"], "pending");

    // A retry after the failed dispatch must attempt the dispatch again instead
    // of returning a fake `alreadyResolved:true` success.
    let (status, json) = post(
        &app,
        resolve_uri,
        json!({ "approvalId": "orphan-1", "decision": "allowedOnce" }),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "a retry must re-attempt the failed dispatch (not short-circuit on alreadyResolved); body: {json}"
    );
    assert_eq!(json["error"]["code"], "sessionNotFound");
    assert!(
        json.get("alreadyResolved").is_none(),
        "the dispatch error must not be masked by an alreadyResolved success field"
    );
    assert_eq!(
        ids(&snapshot(&app).await),
        vec!["orphan-1".to_string()],
        "a retry that fails dispatch again must still leave the approval pending"
    );
}
