//! HTTP integration gate for the rust/web-endpoints additions.
//!
//! Every request goes through the real axum router (`pharos_http::api_router`)
//! over **file-backed** binding / member-settings / attachment stores in a
//! temporary data dir, plus the fake S1/S2 services (their in-memory seed data
//! gives us a real Thread and session to act on). This file intentionally does
//! not call stores directly for the behaviour under test: restart persistence is
//! proven by rebuilding a brand new `AppState` over the same directory.
//!
//! Honest-error coverage: unknown ids (404), invalid input (400), unsupported
//! adapter capabilities (502 extension codes), and "never fake success".

use std::path::Path;
use std::sync::Arc;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use pharos_api::{
    ApprovalDecision, ApprovalKind, ApprovalRequest, CanonicalTurn, HostInventorySnapshot,
    PharosApiError, ProjectSummary, QuestionOption, ResolveApprovalRequest,
    SendSessionMessageRequest, SessionProgress, SessionSummary, SteerSessionRequest,
};
use pharos_hitl::StoredDecision;
use pharos_http::services::{
    FakeSessionService, FakeThreadService, FileApprovalService, FileAttachmentService,
    FileMemberSettingsService, FileThreadBindingService, SessionService, THREAD_BINDINGS_FILE,
};
use pharos_http::{AppState, EventBus, api_router};
use serde_json::{Value, json};
use tempfile::TempDir;
use tower::ServiceExt;

const FAKE_THREAD: &str = "fake-thread-1";
const FAKE_SESSION: &str = "fake-session-1";

fn file_state(dir: &Path) -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    let bindings = Arc::new(
        FileThreadBindingService::open(dir.join(THREAD_BINDINGS_FILE)).expect("bindings store"),
    );
    let members = Arc::new(FileMemberSettingsService::open_in(dir).expect("member store"));
    let attachments = Arc::new(FileAttachmentService::open_in(dir).expect("attachment store"));
    let approvals = Arc::new(
        FileApprovalService::open(dir.join("pending-approvals.json")).expect("approval store"),
    );
    AppState::with_extras(
        threads,
        sessions,
        events,
        approvals,
        bindings,
        members,
        attachments,
    )
}

fn state_with_sessions(dir: &Path, sessions: Arc<dyn SessionService>) -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let bindings = Arc::new(
        FileThreadBindingService::open(dir.join(THREAD_BINDINGS_FILE)).expect("bindings store"),
    );
    let members = Arc::new(FileMemberSettingsService::open_in(dir).expect("member store"));
    let attachments = Arc::new(FileAttachmentService::open_in(dir).expect("attachment store"));
    let approvals = Arc::new(
        FileApprovalService::open(dir.join("pending-approvals.json")).expect("approval store"),
    );
    AppState::with_extras(
        threads,
        sessions,
        events,
        approvals,
        bindings,
        members,
        attachments,
    )
}

/// Session service exposing only the originally-required surface: the new
/// capability methods therefore use the trait's explicit "unsupported"
/// defaults (this is exactly what an adapter without config/lifecycle/attachment
/// support looks like through the HTTP layer).
struct NoCapabilitySessions(FakeSessionService);

#[async_trait::async_trait]
impl SessionService for NoCapabilitySessions {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        self.0.list_sessions().await
    }
    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        self.0.get_session(session_id).await
    }
    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        self.0.list_history(session_id).await
    }
    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        self.0.send_message(session_id, request).await
    }
    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        self.0.steer(session_id, request).await
    }
    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        self.0.resolve_approval(session_id, request).await
    }
    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError> {
        self.0.progress(session_id).await
    }
    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError> {
        self.0.list_projects().await
    }
    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError> {
        self.0.inventory().await
    }
    async fn create_session(
        &self,
        request: pharos_http::services::CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        self.0.create_session(request).await
    }
}

async fn call(app: &Router, method: &str, uri: &str, body: Option<Value>) -> (StatusCode, Value) {
    let builder = Request::builder().method(method).uri(uri);
    let request = match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .expect("request"),
        None => builder.body(Body::empty()).expect("request"),
    };
    let response = app.clone().oneshot(request).await.expect("router call");
    let status = response.status();
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes();
    let json = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    };
    (status, json)
}

async fn call_bytes(app: &Router, uri: &str) -> (StatusCode, Option<String>, Vec<u8>) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(uri)
                .body(Body::empty())
                .expect("request"),
        )
        .await
        .expect("router call");
    let status = response.status();
    let content_type = response
        .headers()
        .get(axum::http::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(str::to_string);
    let bytes = response
        .into_body()
        .collect()
        .await
        .expect("body")
        .to_bytes()
        .to_vec();
    (status, content_type, bytes)
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        out.push(ALPHABET[(b[0] >> 2) as usize] as char);
        out.push(ALPHABET[(((b[0] & 0b11) << 4) | (b[1] >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(ALPHABET[(((b[1] & 0b1111) << 2) | (b[2] >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(ALPHABET[(b[2] & 0b111111) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn approval(approval_id: &str, kind: ApprovalKind, choices: &[&str]) -> ApprovalRequest {
    ApprovalRequest {
        approval_id: approval_id.to_string(),
        session_id: FAKE_SESSION.to_string(),
        kind,
        available_choices: Some(choices.iter().map(|choice| choice.to_string()).collect()),
    }
}

fn tool_approval(approval_id: &str, choices: &[&str]) -> ApprovalRequest {
    approval(
        approval_id,
        ApprovalKind::ToolPermission {
            tool_name: "shell".into(),
            params: json!({ "command": "printf ok" }),
            explanation: None,
        },
        choices,
    )
}

async fn seed_approval(state: &AppState, request: ApprovalRequest) {
    state.approvals.record(request).await.expect("record");
}

// --- thread ↔ session bindings ---------------------------------------------

#[tokio::test]
async fn binding_crud_survives_restart_and_validates_inputs() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));

    let (status, body) = call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["threadId"], FAKE_THREAD);
    assert_eq!(body["member"], "grokbot");
    assert_eq!(body["sessionId"], FAKE_SESSION);
    assert_eq!(body["agentType"], "fake");
    assert!(body["boundAt"].as_str().expect("boundAt").ends_with('Z'));

    // Unknown thread → 404, unknown session → 404, blank session → 400,
    // invalid member name → 400.
    let (status, body) = call(
        &app,
        "PUT",
        "/api/v1/threads/nope/bindings/grokbot",
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "threadNotFound");
    let (status, body) = call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        Some(json!({ "sessionId": "missing-session" })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
    let (status, body) = call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        Some(json!({ "sessionId": "  " })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "invalidRequest");
    let (status, body) = call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/bad%20name"),
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "invalidRequest");

    // Read back through a fresh state over the same data dir (restart).
    let app = api_router(file_state(dir.path()));
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let bindings = body["bindings"].as_array().expect("bindings");
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0]["member"], "grokbot");
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["sessionId"], FAKE_SESSION);

    let (status, body) = call(
        &app,
        "DELETE",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["removed"], true);
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "threadBindingNotFound");
    let (status, _) = call(
        &app,
        "DELETE",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn thread_members_include_replica_members_bound_sessions_and_settings() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/coder"),
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    call(
        &app,
        "PATCH",
        "/api/v1/members/grokbot",
        Some(json!({ "displayName": "Grok Bot", "model": "gpt-5", "mode": "yolo" })),
    )
    .await;

    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/threads/{FAKE_THREAD}/members"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let members = body["members"].as_array().expect("members");
    let ids: Vec<&str> = members
        .iter()
        .map(|member| member["memberId"].as_str().expect("id"))
        .collect();
    assert!(ids.contains(&"human"), "{ids:?}");
    assert!(ids.contains(&"grokbot"), "{ids:?}");
    // A bound member that is not in the Thread replica is surfaced too: the
    // binding is the member's membership.
    let coder = members
        .iter()
        .find(|member| member["memberId"] == "coder")
        .expect("bound member");
    assert_eq!(coder["sessionId"], FAKE_SESSION);
    assert_eq!(coder["agentType"], "fake");
    let grokbot = members
        .iter()
        .find(|member| member["memberId"] == "grokbot")
        .expect("grokbot");
    assert_eq!(grokbot["settings"]["model"], "gpt-5");
    assert_eq!(grokbot["settings"]["displayName"], "Grok Bot");
    assert_eq!(grokbot["sessionId"], FAKE_SESSION);
}

// --- session configuration --------------------------------------------------

#[tokio::test]
async fn session_config_fake_reads_and_updates() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["sessionId"], FAKE_SESSION);
    assert_eq!(body["supported"], true);
    assert_eq!(body["capabilities"]["attachments"], true);
    assert_eq!(body["capabilities"]["stop"], true);
    let model = body["model"].as_str().expect("model");
    assert!(body["supportedFields"].as_array().expect("fields").len() >= 2);

    let (status, body) = call(
        &app,
        "PATCH",
        &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
        Some(json!({ "model": "fake-2", "mode": "yolo" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["model"], "fake-2");
    assert_eq!(body["mode"], "yolo");
    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["model"], "fake-2");
    assert_eq!(body["mode"], "yolo");

    // Invalid patches are client errors, never silent successes.
    for bad in [
        json!({}),
        json!({ "model": "  " }),
        json!({ "mode": "turbo" }),
    ] {
        let (status, body) = call(
            &app,
            "PATCH",
            &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
            Some(bad.clone()),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad} → {body}");
        assert_eq!(body["error"]["code"], "invalidRequest");
    }
    let (status, body) = call(&app, "GET", "/api/v1/sessions/missing/config", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
    let _ = model;
}

#[tokio::test]
async fn unsupported_adapter_capabilities_are_explicit_502() {
    let dir = TempDir::new().expect("tempdir");
    let events = EventBus::new(16);
    let sessions: Arc<dyn SessionService> = Arc::new(NoCapabilitySessions(
        FakeSessionService::new(events.clone()),
    ));
    let app = api_router(state_with_sessions(dir.path(), sessions));

    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert_eq!(body["error"]["code"], "unsupportedOperation");

    let (status, body) = call(
        &app,
        "PATCH",
        &format!("/api/v1/sessions/{FAKE_SESSION}/config"),
        Some(json!({ "model": "gpt-5" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert_eq!(body["error"]["code"], "unsupportedField");
    assert_eq!(body["error"]["field"], "model");

    for (path, field) in [
        (format!("/api/v1/sessions/{FAKE_SESSION}/stop"), "stop"),
        (format!("/api/v1/sessions/{FAKE_SESSION}/revive"), "revive"),
    ] {
        let (status, body) = call(&app, "POST", &path, None).await;
        assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
        assert_eq!(body["error"]["code"], "unsupportedOperation");
        assert_eq!(body["error"]["field"], field);
    }

    // Attachment reference on an adapter that cannot consume attachments.
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
        Some(json!({
            "filename": "notes.txt",
            "contentType": "text/plain",
            "dataBase64": base64(b"hello")
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let attachment_id = body["attachmentId"].as_str().expect("attachment id");
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/messages"),
        Some(json!({ "text": "see file", "attachmentIds": [attachment_id] })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert_eq!(body["error"]["code"], "unsupportedField");
    assert_eq!(body["error"]["field"], "attachments");
    // Without attachment ids the frozen message path still works.
    let (status, _) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/messages"),
        Some(json!({ "text": "plain" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
}

#[tokio::test]
async fn stop_and_revive_supported_by_fake_service() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/stop"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["ok"], true);
    assert_eq!(body["status"], "stopped");
    let (_, session) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}"),
        None,
    )
    .await;
    assert_eq!(session["status"], "stopped");
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/revive"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["status"], "idle");
    let (status, body) = call(&app, "POST", "/api/v1/sessions/missing/stop", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
}

// --- attachments ------------------------------------------------------------

#[tokio::test]
async fn attachment_upload_read_list_and_reference_roundtrip() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    let payload = b"hello attachment";
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
        Some(json!({
            "filename": "notes.txt",
            "contentType": "text/plain",
            "dataBase64": base64(payload),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let attachment_id = body["attachmentId"].as_str().expect("id").to_string();
    assert_eq!(body["sessionId"], FAKE_SESSION);
    assert_eq!(body["filename"], "notes.txt");
    assert_eq!(body["contentType"], "text/plain");
    assert_eq!(body["sizeBytes"], payload.len());
    assert_eq!(body["sha256"].as_str().expect("sha").len(), 64);

    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/attachments/{attachment_id}"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["attachmentId"], attachment_id);
    let (status, content_type, bytes) = call_bytes(
        &app,
        &format!("/api/v1/attachments/{attachment_id}/content"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(content_type.as_deref(), Some("text/plain"));
    assert_eq!(bytes, payload);

    let (status, body) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["attachments"].as_array().expect("list").len(), 1);

    // Restart: the index and blob are durable.
    let app = api_router(file_state(dir.path()));
    let (status, _, bytes) = call_bytes(
        &app,
        &format!("/api/v1/attachments/{attachment_id}/content"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(bytes, payload);

    // A message can reference the attachment (fake service accepts it).
    let (status, turn) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/messages"),
        Some(json!({ "text": "see file", "attachmentIds": [attachment_id] })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{turn}");
    assert_eq!(turn["sessionId"], FAKE_SESSION);

    // Unknown / mismatched / malformed references are explicit errors.
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/messages"),
        Some(json!({ "text": "x", "attachmentIds": ["missing"] })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "attachmentNotFound");
    let (status, body) = call(&app, "GET", "/api/v1/attachments/missing", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "attachmentNotFound");
}

#[tokio::test]
async fn attachment_upload_validates_type_size_filename_and_session() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    for (payload, expected_code) in [
        (
            json!({"filename": "x.exe", "contentType": "application/x-msdownload", "dataBase64": base64(b"x")}),
            "invalidRequest",
        ),
        (
            json!({"filename": "a/b.txt", "contentType": "text/plain", "dataBase64": base64(b"x")}),
            "invalidRequest",
        ),
        (
            json!({"filename": "x.txt", "contentType": "text/plain", "dataBase64": "!!!"}),
            "invalidRequest",
        ),
    ] {
        let (status, body) = call(
            &app,
            "POST",
            &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
            Some(payload.clone()),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{payload} → {body}");
        assert_eq!(body["error"]["code"], expected_code);
    }
    // Oversize (10 MiB + 1 byte) is rejected before it is stored.
    let oversize = vec![b'A'; 10 * 1024 * 1024 + 1];
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
        Some(json!({
            "filename": "big.txt",
            "contentType": "text/plain",
            "dataBase64": base64(&oversize),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"]["code"], "invalidRequest");
    // Unknown session cannot receive attachments.
    let (status, body) = call(
        &app,
        "POST",
        "/api/v1/sessions/missing/attachments",
        Some(json!({
            "filename": "x.txt",
            "contentType": "text/plain",
            "dataBase64": base64(b"x"),
        })),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
    // Nothing was stored by the rejected uploads.
    let (_, body) = call(
        &app,
        "GET",
        &format!("/api/v1/sessions/{FAKE_SESSION}/attachments"),
        None,
    )
    .await;
    assert!(body["attachments"].as_array().expect("list").is_empty());
}

// --- member settings / avatars ---------------------------------------------

#[tokio::test]
async fn member_settings_patch_and_avatar_persist_across_restart() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));

    let (status, body) = call(&app, "GET", "/api/v1/members/grokbot", None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["memberId"], "grokbot");
    assert_eq!(body["avatar"], Value::Null);
    assert!(body["bindings"].as_array().expect("bindings").is_empty());

    let (status, body) = call(
        &app,
        "PATCH",
        "/api/v1/members/grokbot",
        Some(json!({
            "displayName": "Grok Bot",
            "model": "gpt-5",
            "mode": "yolo",
            "avatarShape": "sphere",
            "avatarColor": "black",
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["displayName"], "Grok Bot");
    assert_eq!(body["model"], "gpt-5");
    assert_eq!(body["mode"], "yolo");
    assert_eq!(body["avatarShape"], "sphere");

    let png = b"\x89PNG\r\n\x1a\nfake-avatar".to_vec();
    let (status, body) = call(
        &app,
        "PUT",
        "/api/v1/members/grokbot/avatar",
        Some(json!({ "contentType": "image/png", "dataBase64": base64(&png) })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["avatar"]["contentType"], "image/png");
    assert_eq!(body["avatar"]["sizeBytes"], png.len());
    let (status, content_type, bytes) = call_bytes(&app, "/api/v1/members/grokbot/avatar").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(content_type.as_deref(), Some("image/png"));
    assert_eq!(bytes, png);

    // Restart: settings + avatar are durable.
    let app = api_router(file_state(dir.path()));
    let (status, body) = call(&app, "GET", "/api/v1/members/grokbot", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["model"], "gpt-5");
    assert_eq!(body["avatar"]["sizeBytes"], png.len());
    let (status, _, bytes) = call_bytes(&app, "/api/v1/members/grokbot/avatar").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(bytes, png);

    let (status, body) = call(&app, "DELETE", "/api/v1/members/grokbot/avatar", None).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (status, body) = call(&app, "GET", "/api/v1/members/grokbot/avatar", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "attachmentNotFound");
    let (status, _) = call(&app, "DELETE", "/api/v1/members/grokbot/avatar", None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn member_settings_and_avatar_reject_invalid_input() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    for bad in [
        json!({}),
        json!({ "mode": "turbo" }),
        json!({ "displayName": "  " }),
        json!({ "displayName": "x".repeat(81) }),
        json!({ "model": "x".repeat(121) }),
    ] {
        let (status, body) =
            call(&app, "PATCH", "/api/v1/members/grokbot", Some(bad.clone())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad} → {body}");
        assert_eq!(body["error"]["code"], "invalidRequest");
    }
    // Malformed member ids are client errors, not silent empty views.
    let long_id = "x".repeat(65);
    let (status, body) = call(&app, "GET", &format!("/api/v1/members/{long_id}"), None).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"]["code"], "invalidRequest");
    // Avatar content type and size validation.
    let (status, body) = call(
        &app,
        "PUT",
        "/api/v1/members/grokbot/avatar",
        Some(json!({ "contentType": "image/gif", "dataBase64": base64(b"gif") })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "invalidRequest");
    let oversize = vec![b'A'; 512 * 1024 + 1];
    let (status, body) = call(
        &app,
        "PUT",
        "/api/v1/members/grokbot/avatar",
        Some(json!({ "contentType": "image/png", "dataBase64": base64(&oversize) })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(body["error"]["code"], "invalidRequest");
    // Nothing was persisted by the rejected writes.
    let (status, body) = call(&app, "GET", "/api/v1/members/grokbot", None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["avatar"], Value::Null);
    assert_eq!(body["model"], Value::Null);
}

#[tokio::test]
async fn member_view_lists_bindings() {
    let dir = TempDir::new().expect("tempdir");
    let app = api_router(file_state(dir.path()));
    call(
        &app,
        "PUT",
        &format!("/api/v1/threads/{FAKE_THREAD}/bindings/grokbot"),
        Some(json!({ "sessionId": FAKE_SESSION })),
    )
    .await;
    let (status, body) = call(&app, "GET", "/api/v1/members/grokbot", None).await;
    assert_eq!(status, StatusCode::OK);
    let bindings = body["bindings"].as_array().expect("bindings");
    assert_eq!(bindings.len(), 1);
    assert_eq!(bindings[0]["threadId"], FAKE_THREAD);
    assert_eq!(bindings[0]["sessionId"], FAKE_SESSION);
}

// --- extended approval decisions -------------------------------------------

#[tokio::test]
async fn cancelled_decision_persists_is_idempotent_and_requires_offer() {
    let dir = TempDir::new().expect("tempdir");
    let state = file_state(dir.path());
    let app = api_router(state.clone());
    seed_approval(
        &state,
        tool_approval("a1", &["allowedOnce", "rejected", "cancelled"]),
    )
    .await;

    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "a1", "decision": "cancelled" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["decision"], "cancelled");
    assert_eq!(body["alreadyResolved"], false);
    let (_, snapshot) = call(&app, "GET", "/api/v1/approvals?state=pending", None).await;
    assert!(
        snapshot["approvals"]
            .as_array()
            .expect("pending")
            .is_empty()
    );

    // Idempotent first-wins: a later different decision reports the effective one.
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "a1", "decision": "allowedOnce" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["alreadyResolved"], true);
    assert_eq!(body["decision"], "cancelled");

    // Restart: the cancelled decision is durable (read from the on-disk store).
    let store = pharos_hitl::PendingApprovalStore::open(dir.path().join("pending-approvals.json"))
        .expect("reopen approval store");
    let persisted = store.get("a1").expect("get").expect("a1");
    assert_eq!(persisted.state_str(), "resolved");
    assert_eq!(persisted.decision, Some(StoredDecision::Cancelled));

    // A cancelled decision that the adapter never offered is a 400 and leaves
    // the approval pending (retryable) — it is never silently consumed.
    let state = file_state(dir.path());
    let app = api_router(state.clone());
    seed_approval(&state, tool_approval("a2", &["allowedOnce", "rejected"])).await;
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "a2", "decision": "cancelled" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"]["code"], "invalidRequest");
    let (_, snapshot) = call(&app, "GET", "/api/v1/approvals?state=pending", None).await;
    assert_eq!(snapshot["approvals"].as_array().expect("pending").len(), 1);
}

#[tokio::test]
async fn questionnaire_answers_are_persisted_with_the_decision() {
    let dir = TempDir::new().expect("tempdir");
    let state = file_state(dir.path());
    let app = api_router(state.clone());
    seed_approval(
        &state,
        approval(
            "q1",
            ApprovalKind::StructuredQuestionnaire {
                intent: "choose env".into(),
                questions: vec![QuestionOption {
                    id: "env".into(),
                    question: "Which env?".into(),
                    options: vec!["prod".into(), "staging".into()],
                    is_multi_select: false,
                }],
            },
            &["allowedOnce", "rejected"],
        ),
    )
    .await;
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({
            "approvalId": "q1",
            "decision": "allowedOnce",
            "questionnaireAnswers": [{ "questionId": "env", "selected": ["prod"] }],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["decision"], "allowedOnce");
    assert_eq!(body["questionnaireAnswers"][0]["questionId"], "env");
    assert_eq!(body["questionnaireAnswers"][0]["selected"][0], "prod");

    // Restart: answers survive with the decision (on-disk store).
    let store = pharos_hitl::PendingApprovalStore::open(dir.path().join("pending-approvals.json"))
        .expect("reopen approval store");
    let persisted = store.get("q1").expect("get").expect("q1");
    assert_eq!(persisted.decision, Some(StoredDecision::AllowedOnce));
    assert_eq!(
        persisted.questionnaire_answers.as_deref(),
        Some(
            &[pharos_hitl::QuestionnaireAnswer {
                question_id: "env".into(),
                selected: vec!["prod".into()],
                text: None,
            }][..]
        )
    );
    // Replay keeps the recorded answers.
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "q1", "decision": "rejected" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["alreadyResolved"], true);
    assert_eq!(body["questionnaireAnswers"][0]["selected"][0], "prod");

    // Answers that reference an unknown question are rejected without consuming.
    let state = file_state(dir.path());
    let app = api_router(state.clone());
    seed_approval(
        &state,
        approval(
            "q2",
            ApprovalKind::StructuredQuestionnaire {
                intent: "choose env".into(),
                questions: vec![QuestionOption {
                    id: "env".into(),
                    question: "Which env?".into(),
                    options: vec!["prod".into()],
                    is_multi_select: false,
                }],
            },
            &["allowedOnce"],
        ),
    )
    .await;
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({
            "approvalId": "q2",
            "decision": "allowedOnce",
            "questionnaireAnswers": [{ "questionId": "nope", "selected": ["prod"] }],
        })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert_eq!(body["error"]["code"], "invalidRequest");
    let (_, snapshot) = call(&app, "GET", "/api/v1/approvals?state=pending", None).await;
    assert_eq!(snapshot["approvals"].as_array().expect("pending").len(), 1);
}

#[tokio::test]
async fn cancelled_dispatch_failure_reverts_durable_decision() {
    let dir = TempDir::new().expect("tempdir");
    let events = EventBus::new(16);
    let sessions: Arc<dyn SessionService> =
        Arc::new(NoCapabilitySessions(FakeSessionService::new(events)));
    let state = state_with_sessions(dir.path(), sessions);
    let app = api_router(state.clone());
    seed_approval(
        &state,
        tool_approval("a1", &["allowedOnce", "rejected", "cancelled"]),
    )
    .await;
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "a1", "decision": "cancelled" })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY, "{body}");
    assert_eq!(body["error"]["code"], "unsupportedOperation");
    // The failed dispatch must not consume the approval: durable + retryable.
    let (_, snapshot) = call(&app, "GET", "/api/v1/approvals?state=pending", None).await;
    assert_eq!(snapshot["approvals"].as_array().expect("pending").len(), 1);
    let store = pharos_hitl::PendingApprovalStore::open(dir.path().join("pending-approvals.json"))
        .expect("reopen approval store");
    let persisted = store.get("a1").expect("get").expect("a1");
    assert_eq!(persisted.state_str(), "pending");
}

// --- legacy compatibility ---------------------------------------------------

#[tokio::test]
async fn legacy_approval_body_still_works_and_openapi_lists_new_routes() {
    let dir = TempDir::new().expect("tempdir");
    let state = file_state(dir.path());
    let app = api_router(state.clone());
    seed_approval(&state, tool_approval("a1", &["allowedOnce", "rejected"])).await;
    let (status, body) = call(
        &app,
        "POST",
        &format!("/api/v1/sessions/{FAKE_SESSION}/approval"),
        Some(json!({ "approvalId": "a1", "decision": "allowedOnce" })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["decision"], "allowedOnce");
    assert_eq!(body["alreadyResolved"], false);

    let (status, doc) = call(&app, "GET", "/openapi.json", None).await;
    assert_eq!(status, StatusCode::OK);
    for path in [
        "/api/v1/threads/{threadId}/bindings",
        "/api/v1/threads/{threadId}/members",
        "/api/v1/sessions/{sessionId}/config",
        "/api/v1/sessions/{sessionId}/stop",
        "/api/v1/sessions/{sessionId}/revive",
        "/api/v1/sessions/{sessionId}/attachments",
        "/api/v1/attachments/{attachmentId}",
        "/api/v1/members/{memberId}",
        "/api/v1/members/{memberId}/avatar",
    ] {
        assert!(doc["paths"].get(path).is_some(), "openapi missing {path}");
    }
    assert_eq!(doc["info"]["version"], "0.1.0");
    let _ = ApprovalDecision::Rejected;
}
