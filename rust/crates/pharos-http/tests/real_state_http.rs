//! HTTP-level integration for the **real** S1/S2 wiring (no fake services).
//!
//! Exercises the frozen router over [`build_real_app_state`]: durable Thread
//! create/read/message/reply, persistence across a state rebuild from the same
//! data dir, and honest session responses when no vendor adapter is configured.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use pharos_http::{
    AppState, EventBus, RealOptions, SessionAdapterChoice, api_router, build_real_app_state,
};
use serde_json::{Value, json};
use tempfile::TempDir;
use tower::ServiceExt;

fn app_for(data_dir: &std::path::Path) -> Router {
    let state = build_real_app_state(RealOptions::new(data_dir)).expect("real state");
    api_router(state)
}

async fn body_json(response: axum::response::Response) -> Value {
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

async fn send_json(app: &Router, method: &str, uri: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method(method)
                .uri(uri)
                .header("content-type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = response.status();
    (status, body_json(response).await)
}

async fn get(app: &Router, uri: &str) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    (status, body_json(response).await)
}

#[tokio::test]
async fn real_threads_create_read_message_reply_and_persist() {
    let dir = TempDir::new().unwrap();
    let app = app_for(dir.path());

    // No fake seed data.
    let (status, threads) = get(&app, "/api/v1/threads").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(threads, json!([]));

    // Create a durable Thread through HTTP.
    let (status, thread) = send_json(
        &app,
        "POST",
        "/api/v1/threads",
        json!({"threadId": "http-thread-1", "memberIds": ["human", "grokbot"]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(thread["threadId"], "http-thread-1");
    assert_eq!(thread["title"], "http-thread-1");
    let members = thread["memberIds"].as_array().unwrap();
    assert!(members.iter().any(|m| m == "human"));
    assert!(members.iter().any(|m| m == "grokbot"));

    let (status, _) = get(&app, "/api/v1/threads/http-thread-1").await;
    assert_eq!(status, StatusCode::OK);

    // Send a directed message.
    let (status, message) = send_json(
        &app,
        "POST",
        "/api/v1/threads/http-thread-1/messages",
        json!({"text": "hello", "targetMemberIds": ["grokbot"]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(message["threadId"], "http-thread-1");
    assert_eq!(message["senderId"], "human");
    assert_eq!(message["text"], "hello");
    let message_id = message["id"].as_str().unwrap().to_string();

    // The replyOnce member replies; re-posting the same reply is idempotent.
    let reply_body = json!({"asMember": "grokbot", "text": "ack", "messageId": message_id});
    let (status, reply) = send_json(
        &app,
        "POST",
        "/api/v1/threads/http-thread-1/reply",
        reply_body.clone(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["replyTo"], message_id);
    let reply_id = reply["replyId"].as_str().unwrap().to_string();
    let (status, again) = send_json(
        &app,
        "POST",
        "/api/v1/threads/http-thread-1/reply",
        reply_body,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(again["replyId"], reply_id);

    let (status, messages) = get(&app, "/api/v1/threads/http-thread-1/messages").await;
    assert_eq!(status, StatusCode::OK);
    let messages = messages.as_array().unwrap();
    assert_eq!(messages.len(), 2);
    assert_eq!(messages[1]["replyTo"]["messageId"], message_id);

    // Missing Thread is a 404, and a send never creates one implicitly.
    let (status, error) = get(&app, "/api/v1/threads/missing").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error["error"]["code"], "threadNotFound");

    // --- restart: rebuild state from the SAME data dir ---
    drop(app);
    let app = app_for(dir.path());
    let (status, threads) = get(&app, "/api/v1/threads").await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        threads
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["threadId"] == "http-thread-1"),
        "thread must survive state rebuild: {threads}"
    );
    let (status, messages) = get(&app, "/api/v1/threads/http-thread-1/messages").await;
    assert_eq!(status, StatusCode::OK);
    let texts: Vec<&str> = messages
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, vec!["hello", "ack"]);
}

#[tokio::test]
async fn real_sessions_are_empty_and_live_actions_unavailable() {
    let dir = TempDir::new().unwrap();
    let app = app_for(dir.path());

    // Unconfigured real Session service: no fake-session-1.
    let (status, sessions) = get(&app, "/api/v1/sessions").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sessions, json!([]));

    let (status, error) = get(&app, "/api/v1/sessions/fake-session-1").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(error["error"]["code"], "sessionNotFound");

    let (status, error) = send_json(
        &app,
        "POST",
        "/api/v1/sessions/fake-session-1/messages",
        json!({"text": "hi"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(error["error"]["code"], "operationFailed");
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .contains("--session-adapter"),
        "explicit unavailable message expected: {error}"
    );

    let (status, error) = send_json(
        &app,
        "POST",
        "/api/v1/sessions",
        json!({"workspacePath": "/tmp/pharos-ws"}),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(error["error"]["code"], "operationFailed");

    let (status, inventory) = get(&app, "/api/v1/inventory/sessions").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(inventory["sessions"], json!([]));
    assert_eq!(inventory["status"]["supportedAgents"], json!([]));
}

#[tokio::test]
async fn real_inventory_and_projects_never_fabricate_data() {
    let dir = TempDir::new().unwrap();
    let state: AppState = build_real_app_state(RealOptions::new(dir.path())).unwrap();
    // Unused state construction guard: events bus stays available for WS.
    let _ = EventBus::new(4);
    let app = api_router(state);
    let (status, projects) = get(&app, "/api/v1/projects").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(projects, json!([]));
}

#[test]
fn real_options_can_select_codex_adapter_without_connecting() {
    // Only exercises option plumbing; connecting a live adapter is opt-in at
    // runtime and intentionally not done in unit tests.
    let options = RealOptions::new("/tmp/pharos-web-test")
        .with_session_adapter(SessionAdapterChoice::parse("codex").unwrap());
    assert_eq!(options.session_adapter, SessionAdapterChoice::Codex);
}
