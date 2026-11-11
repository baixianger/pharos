//! HTTP acceptance for cross-host (remote) sessions mixed with local sessions.
//!
//! Composes the frozen [`pharos_http::router::api_router`] over
//! [`RemoteSessionMergedService`]: one local fake service plus fake
//! [`RemoteSessionSource`]s standing in for mesh peers (no iroh transport is
//! started here; the wire mapping is covered by `pharos-session` unit tests).
//!
//! Honesty assertions:
//! - unreachable remote hosts make the merged session list fail with
//!   `502 backendUnreachable`, never an empty `200`;
//! - remote sessions are prefixed `peer:<host>:<session>` end to end;
//! - unknown remote hosts are `404 sessionNotFound`;
//! - remote progress is an explicit `502 operationFailed`, never fabricated.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use pharos_api::{
    CanonicalTurn, PharosApiError, ResolveApprovalRequest, SendSessionMessageRequest,
    SessionActivityStatus, SessionSummary, SteerSessionRequest, TurnStatus,
};
use pharos_http::services::{
    EventBus, FakeSessionService, FakeThreadService, RemoteSessionMergedService, SessionService,
};
use pharos_http::{AppState, api_router};
use pharos_session::remote::RemoteSessionSource;
use serde_json::{Value, json};
use tower::ServiceExt;

const REMOTE_HOST: &str = "host-b";
const REMOTE_SESSION: &str = "remote-sess-1";
const PREFIXED_REMOTE_SESSION: &str = "peer:host-b:remote-sess-1";

/// In-memory stand-in for one mesh peer. Deliberately stores and returns the
/// host's own **unprefixed** ids so the merged service proves it namespaces.
struct FakeRemoteHost {
    host: String,
    sessions: HashMap<String, SessionSummary>,
    history: HashMap<String, Vec<CanonicalTurn>>,
    list_error: Option<PharosApiError>,
}

impl FakeRemoteHost {
    fn new(host: &str) -> Self {
        let summary = SessionSummary {
            session_id: REMOTE_SESSION.into(),
            machine_id: host.into(),
            agent_type: "codex".into(),
            workspace_path: "/tmp/remote-ws".into(),
            title: "Remote Session".into(),
            status: SessionActivityStatus::Working,
            latest_message_preview: Some("remote preview".into()),
            updated_at: "2026-11-11T00:00:00Z".into(),
            avatar_seed: "remote-seed".into(),
            inventory_stale: None,
            connection_route: Some("mesh".into()),
        };
        let mut sessions = HashMap::new();
        sessions.insert(REMOTE_SESSION.to_string(), summary);
        let mut history = HashMap::new();
        history.insert(
            REMOTE_SESSION.to_string(),
            vec![CanonicalTurn {
                turn_id: "remote-turn-1".into(),
                session_id: REMOTE_SESSION.into(),
                turn_number: 1,
                status: TurnStatus::Completed,
                created_at: "2026-11-11T00:00:00Z".into(),
                completed_at: Some("2026-11-11T00:00:01Z".into()),
                assistant_text: vec!["remote hello".into()],
            }],
        );
        Self {
            host: host.into(),
            sessions,
            history,
            list_error: None,
        }
    }

    fn with_list_error(mut self, error: PharosApiError) -> Self {
        self.list_error = Some(error);
        self
    }

    fn session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        self.sessions
            .get(session_id)
            .cloned()
            .ok_or_else(|| PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            })
    }
}

#[async_trait]
impl RemoteSessionSource for FakeRemoteHost {
    fn host_device_id(&self) -> &str {
        &self.host
    }

    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        if let Some(error) = &self.list_error {
            return Err(error.clone());
        }
        Ok(self.sessions.values().cloned().collect())
    }

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        self.session(session_id)
    }

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        self.session(session_id)?;
        Ok(self.history.get(session_id).cloned().unwrap_or_default())
    }

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        self.session(session_id)?;
        Ok(CanonicalTurn {
            turn_id: "remote-turn-2".into(),
            session_id: session_id.to_string(),
            turn_number: 2,
            status: TurnStatus::Completed,
            created_at: "2026-11-11T00:00:02Z".into(),
            completed_at: None,
            assistant_text: vec![format!("remote echo: {}", request.text)],
        })
    }

    async fn steer(
        &self,
        session_id: &str,
        _request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        self.session(session_id)?;
        Ok(())
    }

    async fn resolve_approval(
        &self,
        session_id: &str,
        _request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        self.session(session_id)?;
        Ok(())
    }
}

fn app_with(remotes: Vec<Arc<dyn RemoteSessionSource>>) -> Router {
    let events = EventBus::new(32);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let local: Arc<dyn SessionService> = Arc::new(FakeSessionService::new(events.clone()));
    let sessions = Arc::new(RemoteSessionMergedService::new(local, remotes));
    api_router(AppState::new(threads, sessions, events))
}

fn app_with_remote(remote: FakeRemoteHost) -> Router {
    app_with(vec![Arc::new(remote)])
}

async fn body_json(response: axum::response::Response) -> Value {
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
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

async fn post_json(app: &Router, uri: &str, body: Value) -> (StatusCode, Value) {
    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
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

#[tokio::test]
async fn sessions_list_merges_local_and_prefixed_remote_sessions() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(&app, "/api/v1/sessions").await;
    assert_eq!(status, StatusCode::OK);
    let list = body.as_array().expect("session list");
    let ids: Vec<&str> = list
        .iter()
        .map(|session| session["sessionId"].as_str().expect("sessionId"))
        .collect();
    assert!(
        ids.contains(&"fake-session-1"),
        "local session missing: {ids:?}"
    );
    assert!(
        ids.contains(&PREFIXED_REMOTE_SESSION),
        "remote session must be peer:-prefixed: {ids:?}"
    );

    let remote = list
        .iter()
        .find(|session| session["sessionId"] == PREFIXED_REMOTE_SESSION)
        .expect("remote entry");
    assert_eq!(remote["machineId"], REMOTE_HOST);
    assert_eq!(remote["connectionRoute"], "mesh");
    assert_eq!(remote["agentType"], "codex");
}

#[tokio::test]
async fn remote_history_returns_prefixed_remote_turns() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(
        &app,
        &format!("/api/v1/sessions/{PREFIXED_REMOTE_SESSION}/history"),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let turns = body.as_array().expect("history array");
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0]["turnId"], "remote-turn-1");
    assert_eq!(turns[0]["sessionId"], PREFIXED_REMOTE_SESSION);
    assert_eq!(turns[0]["status"], "completed");
    assert_eq!(turns[0]["assistantText"][0], "remote hello");
}

#[tokio::test]
async fn post_message_to_remote_session_returns_turn() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, turn) = post_json(
        &app,
        &format!("/api/v1/sessions/{PREFIXED_REMOTE_SESSION}/messages"),
        json!({ "text": "hello remote" }),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(turn["turnId"], "remote-turn-2");
    assert_eq!(turn["sessionId"], PREFIXED_REMOTE_SESSION);
    assert_eq!(turn["status"], "completed");
    assert_eq!(turn["assistantText"][0], "remote echo: hello remote");
}

#[tokio::test]
async fn remote_get_session_works_through_prefixed_id() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(&app, &format!("/api/v1/sessions/{PREFIXED_REMOTE_SESSION}")).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["sessionId"], PREFIXED_REMOTE_SESSION);
    assert_eq!(body["title"], "Remote Session");
}

#[tokio::test]
async fn unreachable_remote_fails_list_with_backend_unreachable() {
    let remote =
        FakeRemoteHost::new(REMOTE_HOST).with_list_error(PharosApiError::BackendUnreachable {
            backend: REMOTE_HOST.into(),
            reason: "peer offline".into(),
        });
    let app = app_with_remote(remote);
    let (status, body) = get(&app, "/api/v1/sessions").await;
    // An unreachable host must fail loudly, not silently vanish from the list.
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(body["error"]["code"], "backendUnreachable");
    assert_eq!(body["error"]["backend"], REMOTE_HOST);
    assert_eq!(body["error"]["reason"], "peer offline");
    assert_eq!(body["contractsVersion"], "0.1.0");
}

#[tokio::test]
async fn unreachable_remote_fails_inventory_too() {
    let remote =
        FakeRemoteHost::new(REMOTE_HOST).with_list_error(PharosApiError::BackendUnreachable {
            backend: REMOTE_HOST.into(),
            reason: "peer offline".into(),
        });
    let app = app_with_remote(remote);
    let (status, body) = get(&app, "/api/v1/inventory/sessions").await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(body["error"]["code"], "backendUnreachable");
}

#[tokio::test]
async fn inventory_merges_remote_sessions_with_local_status() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(&app, "/api/v1/inventory/sessions").await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<&str> = body["sessions"]
        .as_array()
        .expect("sessions")
        .iter()
        .map(|session| session["sessionId"].as_str().expect("sessionId"))
        .collect();
    assert!(ids.contains(&"fake-session-1"), "{ids:?}");
    assert!(ids.contains(&PREFIXED_REMOTE_SESSION), "{ids:?}");
    // Inventory status stays local: remote hosts report their own agents.
    assert_eq!(body["status"]["supportedAgents"][0], "fake");
}

#[tokio::test]
async fn unknown_remote_host_is_not_found() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(&app, "/api/v1/sessions/peer:nope:s1").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
    assert_eq!(body["error"]["id"], "peer:nope:s1");

    let (status, body) = get(&app, "/api/v1/sessions/peer:nope:s1/history").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"]["code"], "sessionNotFound");
}

#[tokio::test]
async fn remote_progress_is_explicitly_unavailable() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(
        &app,
        &format!("/api/v1/sessions/{PREFIXED_REMOTE_SESSION}/progress"),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_GATEWAY);
    assert_eq!(body["error"]["code"], "operationFailed");
    assert_eq!(
        body["error"]["message"],
        "remote session progress is not available"
    );
}

#[tokio::test]
async fn local_sessions_still_route_locally_when_remotes_are_configured() {
    let app = app_with_remote(FakeRemoteHost::new(REMOTE_HOST));
    let (status, body) = get(&app, "/api/v1/sessions/fake-session-1").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["sessionId"], "fake-session-1");
    assert_eq!(body["machineId"], "fake-host");

    let (status, body) = get(&app, "/api/v1/sessions/fake-session-1/progress").await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["todos"].as_array().is_some());
}

#[tokio::test]
async fn two_remote_hosts_are_both_listed_with_their_own_prefix() {
    let app = app_with(vec![
        Arc::new(FakeRemoteHost::new("host-b")),
        Arc::new(FakeRemoteHost::new("host-c")),
    ]);
    let (status, body) = get(&app, "/api/v1/sessions").await;
    assert_eq!(status, StatusCode::OK);
    let ids: Vec<&str> = body
        .as_array()
        .expect("sessions")
        .iter()
        .map(|session| session["sessionId"].as_str().expect("sessionId"))
        .collect();
    assert!(ids.contains(&"peer:host-b:remote-sess-1"), "{ids:?}");
    assert!(ids.contains(&"peer:host-c:remote-sess-1"), "{ids:?}");
}
