//! Integration tests against **real** S1/S2 services (durable Thread store,
//! unconfigured real Session service) served over real HTTP.
//!
//! These tests deliberately do not use `fake_app_state`: they build
//! `build_real_app_state` over a fresh `tempfile::tempdir()` and assert that
//! persisted Thread data survives a server restart, that no fake thread /
//! session seeds leak into the real backend, and that bearer-token auth works
//! end to end.

use std::path::{Path, PathBuf};
use std::time::Duration;

use pharos_http::AppState;
use pharos_http::services::{RealOptions, build_real_app_state};
use pharos_web::{AuthToken, resolve_webui_dir, serve_ephemeral, serve_ephemeral_with_token};
use reqwest::StatusCode;
use serde_json::{Value, json};

/// Keep every HTTP request bounded so a broken server fails instead of hanging.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);

fn webui() -> PathBuf {
    resolve_webui_dir(None).expect("webui/ must exist at repo root")
}

fn real_state(data_dir: &Path) -> AppState {
    build_real_app_state(RealOptions::new(data_dir)).expect("build real app state")
}

/// Reopen the real backend, tolerating a short SQLite lock hand-over after the
/// previous server task was aborted (should not happen, but restart tests must
/// not flake on an OS-level lock release delay).
async fn real_state_with_retry(data_dir: &Path) -> AppState {
    let mut last_error = String::new();
    for attempt in 0..40 {
        match build_real_app_state(RealOptions::new(data_dir)) {
            Ok(state) => return state,
            Err(error) => {
                last_error = error.to_string();
                if attempt + 1 < 40 {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
        }
    }
    panic!(
        "reopening real state at {} failed after retries: {last_error}",
        data_dir.display()
    );
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .expect("http client")
}

async fn get_json(client: &reqwest::Client, url: String) -> (StatusCode, Value) {
    let response = client.get(url).send().await.expect("GET request");
    let status = response.status();
    let body = response.json().await.expect("GET json body");
    (status, body)
}

async fn post_json(client: &reqwest::Client, url: String, body: Value) -> (StatusCode, Value) {
    let response = client
        .post(url)
        .json(&body)
        .send()
        .await
        .expect("POST request");
    let status = response.status();
    let body = response.json().await.expect("POST json body");
    (status, body)
}

/// GET a static asset as raw text/bytes (used for the unauthenticated UI check).
async fn get_text(client: &reqwest::Client, url: String) -> (StatusCode, String) {
    let response = client.get(url).send().await.expect("GET request");
    let status = response.status();
    let body = response.text().await.expect("text body");
    (status, body)
}

#[tokio::test]
async fn real_services_expose_no_fake_data() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let (addr, handle) = serve_ephemeral(webui(), real_state(data_dir.path()))
        .await
        .expect("serve ephemeral");
    let base = format!("http://{addr}");
    let client = client();

    // Health works without touching either backend.
    let (status, health) = get_json(&client, format!("{base}/health")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(health["ok"], true);

    // Threads: a fresh real data dir has no threads at all — in particular no
    // `fake-thread-1` seed from the fake service.
    let (status, threads) = get_json(&client, format!("{base}/api/v1/threads")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        threads,
        json!([]),
        "real backend must not seed fake threads, got {threads}"
    );

    let (status, missing_thread) =
        get_json(&client, format!("{base}/api/v1/threads/fake-thread-1")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(missing_thread["error"]["code"], "threadNotFound");

    // Sessions: no fake session list, and unknown ids are honest 404s.
    let (status, sessions) = get_json(&client, format!("{base}/api/v1/sessions")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        sessions,
        json!([]),
        "real backend must not seed fake sessions, got {sessions}"
    );

    let (status, missing_session) =
        get_json(&client, format!("{base}/api/v1/sessions/fake-session-1")).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(missing_session["error"]["code"], "sessionNotFound");

    // Sending to a session without a live adapter must fail explicitly, never
    // fabricate a turn.
    let (status, send_error) = post_json(
        &client,
        format!("{base}/api/v1/sessions/fake-session-1/messages"),
        json!({ "text": "does this work?" }),
    )
    .await;
    assert!(
        !status.is_success(),
        "unconfigured session send must not succeed, got {status}: {send_error}"
    );
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(send_error["error"]["code"], "operationFailed");
    let message = send_error["error"]["message"]
        .as_str()
        .expect("error message");
    assert!(
        message.contains("live") && message.contains("adapter"),
        "error must mention the missing live adapter, got {message:?}"
    );

    // Creating a live session without `--session-adapter codex` is also an
    // explicit error, not a fake session.
    let (status, create_error) = post_json(
        &client,
        format!("{base}/api/v1/sessions"),
        json!({ "workspacePath": "/tmp/pharos-real-sessions-test", "mode": null }),
    )
    .await;
    assert!(
        !status.is_success(),
        "unconfigured session create must not succeed, got {status}: {create_error}"
    );
    assert_eq!(create_error["error"]["code"], "operationFailed");
    assert!(
        create_error["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("--session-adapter")),
        "create error must mention --session-adapter, got {create_error}"
    );

    handle.abort();
    let _ = handle.await;
}

#[tokio::test]
async fn real_thread_roundtrip_persists_across_restart() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let webui_dir = webui();
    let client = client();

    let message_id: String;
    {
        let (addr, handle) = serve_ephemeral(webui_dir.clone(), real_state(data_dir.path()))
            .await
            .expect("serve ephemeral");
        let base = format!("http://{addr}");

        // Create the thread explicitly: no pre-seeded rooms exist.
        let (status, thread) = post_json(
            &client,
            format!("{base}/api/v1/threads"),
            json!({ "threadId": "http-thread-1", "memberIds": ["human", "grokbot"] }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "create thread: {thread}");
        assert_eq!(thread["threadId"], "http-thread-1");
        let members = thread["memberIds"].as_array().expect("memberIds");
        assert!(members.iter().any(|member| member == "human"));
        assert!(members.iter().any(|member| member == "grokbot"));

        // Send a human message targeted at grokbot.
        let (status, sent) = post_json(
            &client,
            format!("{base}/api/v1/threads/http-thread-1/messages"),
            json!({ "text": "hello", "targetMemberIds": ["grokbot"] }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "send message: {sent}");
        let id = sent["id"].as_str().expect("message id").to_string();
        assert!(!id.is_empty(), "message id must not be empty");
        assert_eq!(sent["senderId"], "human");
        assert_eq!(sent["text"], "hello");
        message_id = id;

        let (status, messages) = get_json(
            &client,
            format!("{base}/api/v1/threads/http-thread-1/messages"),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let messages = messages.as_array().expect("messages array");
        assert_eq!(messages.len(), 1, "one message after send: {messages:?}");
        assert_eq!(messages[0]["text"], "hello");

        // Reply as grokbot, correlated to the human message.
        let (status, reply) = post_json(
            &client,
            format!("{base}/api/v1/threads/http-thread-1/reply"),
            json!({ "asMember": "grokbot", "text": "ack", "messageId": message_id }),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "reply: {reply}");
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["replyTo"], message_id);
        assert!(
            !reply["replyId"].as_str().unwrap_or_default().is_empty(),
            "replyId must be present: {reply}"
        );

        let (status, messages) = get_json(
            &client,
            format!("{base}/api/v1/threads/http-thread-1/messages"),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let messages = messages.as_array().expect("messages array");
        assert_eq!(messages.len(), 2, "ack must be stored: {messages:?}");
        let reply_message = messages
            .iter()
            .find(|message| message["senderId"] == "grokbot")
            .expect("grokbot reply message");
        assert_eq!(reply_message["text"], "ack");
        assert_eq!(reply_message["replyTo"]["messageId"], message_id);

        // Kill the server; the data dir stays alive for the restart.
        handle.abort();
        let _ = handle.await;
    }

    // Brand-new AppState over the SAME data dir must see the persisted thread.
    let restarted_state = real_state_with_retry(data_dir.path()).await;
    let (addr, handle) = serve_ephemeral(webui_dir, restarted_state)
        .await
        .expect("serve after restart");
    let base = format!("http://{addr}");

    let (status, threads) = get_json(&client, format!("{base}/api/v1/threads")).await;
    assert_eq!(status, StatusCode::OK);
    let threads = threads.as_array().expect("threads array");
    assert!(
        threads
            .iter()
            .any(|thread| thread["threadId"] == "http-thread-1"),
        "restarted server must still list http-thread-1, got {threads:?}"
    );

    let (status, messages) = get_json(
        &client,
        format!("{base}/api/v1/threads/http-thread-1/messages"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let messages = messages.as_array().expect("messages array");
    assert_eq!(
        messages.len(),
        2,
        "both messages must survive restart: {messages:?}"
    );
    assert!(
        messages.iter().any(|message| message["text"] == "hello"),
        "human message must survive restart: {messages:?}"
    );
    assert!(
        messages.iter().any(|message| message["text"] == "ack"),
        "reply must survive restart: {messages:?}"
    );

    handle.abort();
    let _ = handle.await;
}

#[tokio::test]
async fn bearer_token_auth_over_real_http() {
    let data_dir = tempfile::tempdir().expect("tempdir");
    let token = AuthToken::new("integration-token-123").expect("token");
    let (addr, handle) =
        serve_ephemeral_with_token(webui(), real_state(data_dir.path()), Some(token))
            .await
            .expect("serve ephemeral with token");
    let base = format!("http://{addr}");
    let client = client();

    // API without a token -> 401 with the contract error body.
    let response = client
        .get(format!("{base}/api/v1/threads"))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    let body: Value = response.json().await.expect("401 json");
    assert_eq!(body["error"]["code"], "unauthorized");
    assert_eq!(body["error"]["message"], "missing or invalid bearer token");

    // Wrong token -> 401.
    let response = client
        .get(format!("{base}/api/v1/threads"))
        .bearer_auth("wrong-token")
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // Correct bearer header -> 200.
    let response = client
        .get(format!("{base}/api/v1/threads"))
        .bearer_auth("integration-token-123")
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::OK);
    let threads: Value = response.json().await.expect("threads json");
    assert_eq!(threads, json!([]));

    // Query token (browser WebSocket / simple clients) -> 200.
    let response = client
        .get(format!("{base}/api/v1/threads?token=integration-token-123"))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::OK);

    // Mutating API routes are protected too.
    let response = client
        .post(format!("{base}/api/v1/threads"))
        .json(&json!({ "threadId": "unauthorized-thread" }))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);

    // /health stays public so liveness can be probed before auth.
    let response = client
        .get(format!("{base}/health"))
        .send()
        .await
        .expect("request");
    assert_eq!(response.status(), StatusCode::OK);

    // Static UI assets stay public so the page can load and surface the 401.
    let (status, index) = get_text(&client, format!("{base}/")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        index.contains("dsh-stream.js"),
        "index.html must be served without auth"
    );
    let (status, js) = get_text(&client, format!("{base}/dsh-stream.js")).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!js.is_empty());

    handle.abort();
    let _ = handle.await;
}
