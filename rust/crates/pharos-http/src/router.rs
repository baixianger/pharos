//! Axum router mounting `pharos-api::routes` over S1/S2 service traits.

use axum::extract::{Path, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use pharos_api::{
    HealthResponse, PharosApiError, ReplyThreadMessageRequest, ResolveApprovalRequest,
    SendSessionMessageRequest, SendThreadMessageRequest, SteerSessionRequest, openapi_stub_json,
    routes,
};

use crate::approvals::{APPROVALS_ROUTE, list_approvals};
use crate::error::ApiResult;
use crate::services::ResolveApprovalResponse;
use crate::state::AppState;
use crate::ws::events_ws_handler;

/// Build the HTTP/WS API router (no static Web UI — that lives in `pharos-web`).
pub fn api_router(state: AppState) -> Router {
    Router::new()
        .route(routes::HEALTH, get(health))
        .route(routes::OPENAPI, get(openapi))
        .route(routes::EVENTS_WS, get(events_ws_handler))
        .route(APPROVALS_ROUTE, get(list_approvals))
        .route("/api/v1/sessions", get(list_sessions))
        .route("/api/v1/sessions/{id}", get(get_session))
        .route("/api/v1/sessions/{id}/history", get(session_history))
        .route("/api/v1/sessions/{id}/messages", post(send_session_message))
        .route("/api/v1/sessions/{id}/steer", post(steer_session))
        .route("/api/v1/sessions/{id}/approval", post(resolve_approval))
        .route("/api/v1/sessions/{id}/progress", get(session_progress))
        .route("/api/v1/threads", get(list_threads))
        .route("/api/v1/threads/{id}", get(get_thread))
        .route(
            "/api/v1/threads/{id}/messages",
            get(list_thread_messages).post(send_thread_message),
        )
        .route("/api/v1/threads/{id}/reply", post(reply_thread))
        .route("/api/v1/projects", get(list_projects))
        .route("/api/v1/inventory/sessions", get(inventory))
        .with_state(state)
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse::ok_meshd())
}

async fn openapi() -> Json<serde_json::Value> {
    let mut doc = openapi_stub_json();
    // Additive: the frozen Phase-0 stub lacks the S2 approval snapshot route.
    if let Some(paths) = doc.get_mut("paths").and_then(|value| value.as_object_mut()) {
        paths.insert(
            APPROVALS_ROUTE.to_string(),
            serde_json::json!({
                "get": {
                    "operationId": "listPendingApprovals",
                    "description": "Durable current pending HITL approvals (page load / WS reconnect snapshot)",
                    "parameters": [
                        {
                            "name": "state",
                            "in": "query",
                            "required": false,
                            "schema": { "type": "string", "enum": ["pending"] }
                        },
                        {
                            "name": "sessionId",
                            "in": "query",
                            "required": false,
                            "schema": { "type": "string" }
                        }
                    ],
                    "responses": { "200": { "description": "PendingApprovalListResponse" } }
                }
            }),
        );
    }
    Json(doc)
}

async fn list_sessions(State(state): State<AppState>) -> ApiResult<Json<serde_json::Value>> {
    let sessions = state.sessions.list_sessions().await?;
    Ok(Json(serde_json::to_value(sessions).expect("serialize")))
}

async fn get_session(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let session = state.sessions.get_session(&id).await?;
    Ok(Json(serde_json::to_value(session).expect("serialize")))
}

async fn session_history(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let history = state.sessions.list_history(&id).await?;
    Ok(Json(serde_json::to_value(history).expect("serialize")))
}

async fn send_session_message(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<SendSessionMessageRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let turn = state.sessions.send_message(&id, body).await?;
    Ok(Json(serde_json::to_value(turn).expect("serialize")))
}

async fn steer_session(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<SteerSessionRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    state.sessions.steer(&id, body).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
}

async fn resolve_approval(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<ResolveApprovalRequest>,
) -> ApiResult<Json<ResolveApprovalResponse>> {
    // The durable snapshot is authoritative: an unknown approval id is not
    // silently "resolved", it is reported as not found.
    let Some(approval) = state.approvals.get(&body.approval_id).await? else {
        return Err(PharosApiError::ApprovalNotFound {
            id: body.approval_id,
        }
        .into());
    };
    if approval.session_id != id {
        return Err(PharosApiError::InvalidRequest {
            message: format!(
                "approval {} belongs to session {}, not {id}",
                body.approval_id, approval.session_id
            ),
        }
        .into());
    }
    if approval.state == "expired" {
        return Err(PharosApiError::Conflict {
            message: format!("approval {} expired", body.approval_id),
        }
        .into());
    }
    let response = state
        .approvals
        .resolve(&body.approval_id, body.decision)
        .await?;
    if !response.already_resolved {
        // Keep the existing session/adapter decision path; the durable store
        // already recorded the decision so replays are exact no-ops.
        state.sessions.resolve_approval(&id, body).await?;
    }
    Ok(Json(response))
}

async fn session_progress(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let progress = state.sessions.progress(&id).await?;
    Ok(Json(serde_json::to_value(progress).expect("serialize")))
}

async fn list_threads(State(state): State<AppState>) -> ApiResult<Json<serde_json::Value>> {
    let threads = state.threads.list_threads().await?;
    Ok(Json(serde_json::to_value(threads).expect("serialize")))
}

async fn get_thread(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let thread = state.threads.get_thread(&id).await?;
    Ok(Json(serde_json::to_value(thread).expect("serialize")))
}

async fn list_thread_messages(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> ApiResult<Json<serde_json::Value>> {
    let messages = state.threads.list_messages(&id).await?;
    Ok(Json(serde_json::to_value(messages).expect("serialize")))
}

async fn send_thread_message(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<SendThreadMessageRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let message = state.threads.send_message(&id, body).await?;
    Ok(Json(serde_json::to_value(message).expect("serialize")))
}

async fn reply_thread(
    State(state): State<AppState>,
    Path(id): Path<String>,
    Json(body): Json<ReplyThreadMessageRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let response = state.threads.reply(&id, body).await?;
    Ok(Json(serde_json::to_value(response).expect("serialize")))
}

async fn list_projects(State(state): State<AppState>) -> ApiResult<Json<serde_json::Value>> {
    let projects = state.sessions.list_projects().await?;
    Ok(Json(serde_json::to_value(projects).expect("serialize")))
}

async fn inventory(State(state): State<AppState>) -> ApiResult<Json<serde_json::Value>> {
    let snap = state.sessions.inventory().await?;
    Ok(Json(serde_json::to_value(snap).expect("serialize")))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use http_body_util::BodyExt;
    use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest, ClientEvent};
    use serde_json::json;
    use tempfile::TempDir;
    use tower::ServiceExt;

    use super::*;
    use crate::services::{EventBus, FakeSessionService, FakeThreadService, FileApprovalService};

    fn fake_state(approvals: Arc<dyn crate::services::ApprovalService>) -> AppState {
        let events = EventBus::new(32);
        let threads = Arc::new(FakeThreadService::new(events.clone()));
        let sessions = Arc::new(FakeSessionService::new(events.clone()));
        AppState::with_approvals(threads, sessions, events, approvals)
    }

    fn test_app() -> Router {
        let events = EventBus::new(32);
        let threads = Arc::new(FakeThreadService::new(events.clone()));
        let sessions = Arc::new(FakeSessionService::new(events.clone()));
        api_router(AppState::new(threads, sessions, events))
    }

    fn approval(approval_id: &str, session_id: &str) -> ApprovalRequest {
        ApprovalRequest {
            approval_id: approval_id.into(),
            session_id: session_id.into(),
            kind: ApprovalKind::ToolPermission {
                tool_name: "shell".into(),
                params: json!({ "command": "printf PHAROS_HITL_OK" }),
                explanation: None,
            },
            available_choices: Some(vec!["allowedOnce".into(), "rejected".into()]),
        }
    }

    fn file_service(dir: &TempDir) -> Arc<dyn crate::services::ApprovalService> {
        Arc::new(
            FileApprovalService::open(dir.path().join("pending-approvals.json"))
                .expect("open approval store"),
        )
    }

    async fn body_json(response: axum::response::Response) -> serde_json::Value {
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn get(app: &Router, uri: &str) -> (StatusCode, serde_json::Value) {
        let response = app
            .clone()
            .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        (status, body_json(response).await)
    }

    async fn post(
        app: &Router,
        uri: &str,
        body: serde_json::Value,
    ) -> (StatusCode, serde_json::Value) {
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
    async fn health_ok() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let json = body_json(response).await;
        assert_eq!(json["ok"], true);
        assert_eq!(json["contractsVersion"], "0.1.0");
        assert_eq!(json["service"], "pharos-meshd");
    }

    #[tokio::test]
    async fn openapi_stub_served() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/openapi.json")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let json = body_json(response).await;
        assert_eq!(json["openapi"], "3.0.3");
        assert_eq!(json["info"]["version"], "0.1.0");
        assert!(json["paths"].get("/health").is_some());
        assert!(json["paths"].get(APPROVALS_ROUTE).is_some());
    }

    #[tokio::test]
    async fn fake_threads_list() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/threads")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let json = body_json(response).await;
        assert!(
            json.as_array()
                .unwrap()
                .iter()
                .any(|t| t["threadId"] == "fake-thread-1")
        );
    }

    #[tokio::test]
    async fn fake_thread_not_found() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/threads/missing")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        let json = body_json(response).await;
        assert_eq!(json["error"]["code"], "threadNotFound");
        assert_eq!(json["contractsVersion"], "0.1.0");
    }

    #[tokio::test]
    async fn snapshot_lists_pending_and_filters_by_session() {
        let dir = TempDir::new().expect("tempdir");
        let state = fake_state(file_service(&dir));
        state
            .approvals
            .record(approval("a1", "session-1"))
            .await
            .expect("record a1");
        state
            .approvals
            .record(approval("a2", "session-2"))
            .await
            .expect("record a2");
        let app = api_router(state);

        let (status, json) = get(&app, "/api/v1/approvals?state=pending").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["approvals"].as_array().expect("array").len(), 2);
        assert_eq!(json["approvals"][0]["state"], "pending");
        assert_eq!(json["approvals"][0]["availableChoices"][0], "allowedOnce");

        let (status, json) = get(&app, "/api/v1/approvals?sessionId=session-2").await;
        assert_eq!(status, StatusCode::OK);
        let list = json["approvals"].as_array().expect("array");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["approvalId"], "a2");
    }

    #[tokio::test]
    async fn snapshot_rejects_unsupported_state() {
        let dir = TempDir::new().expect("tempdir");
        let app = api_router(fake_state(file_service(&dir)));
        let (status, json) = get(&app, "/api/v1/approvals?state=resolved").await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(json["error"]["code"], "invalidRequest");
    }

    #[tokio::test]
    async fn approval_tap_persists_event_into_snapshot() {
        let dir = TempDir::new().expect("tempdir");
        let state = fake_state(file_service(&dir));
        let events = state.events.clone();
        let _tap = state.spawn_approval_tap();
        events.publish(ClientEvent::ApprovalRequired {
            approval: approval("a1", "session-1"),
        });
        // Let the tap task drain the broadcast event.
        tokio::time::sleep(Duration::from_millis(100)).await;
        let app = api_router(state);
        let (status, json) = get(&app, "/api/v1/approvals?state=pending").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["approvals"].as_array().expect("array").len(), 1);
        assert_eq!(json["approvals"][0]["approvalId"], "a1");
    }

    #[tokio::test]
    async fn resolve_persists_idempotently_and_removes_from_snapshot() {
        let dir = TempDir::new().expect("tempdir");
        let store_path = dir.path().join("pending-approvals.json");
        let state = fake_state(file_service(&dir));
        state
            .approvals
            .record(approval("a1", "fake-session-1"))
            .await
            .expect("record");
        state
            .approvals
            .record(approval("a2", "fake-session-1"))
            .await
            .expect("record");
        let app = api_router(state);

        let (status, json) = post(
            &app,
            "/api/v1/sessions/fake-session-1/approval",
            json!({ "approvalId": "a1", "decision": "allowedOnce" }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["ok"], true);
        assert_eq!(json["alreadyResolved"], false);
        assert_eq!(json["state"], "resolved");
        assert_eq!(json["decision"], "allowedOnce");

        // Second decision (different value) is an explicit no-op.
        let (status, json) = post(
            &app,
            "/api/v1/sessions/fake-session-1/approval",
            json!({ "approvalId": "a1", "decision": "rejected" }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["alreadyResolved"], true);
        assert_eq!(json["decision"], "allowedOnce");

        // a1 gone from the snapshot, a2 still pending.
        let (_, json) = get(&app, "/api/v1/approvals?state=pending").await;
        let list = json["approvals"].as_array().expect("array");
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["approvalId"], "a2");

        // "Restart": a fresh AppState on the same file still knows a1 was resolved.
        let restarted = fake_state(Arc::new(
            FileApprovalService::open(&store_path).expect("reopen"),
        ));
        assert_eq!(
            restarted
                .approvals
                .get("a1")
                .await
                .expect("get")
                .map(|a| a.state),
            Some("resolved".to_string())
        );
        assert!(
            restarted
                .approvals
                .resolve("a1", ApprovalDecision::Rejected)
                .await
                .expect("replay")
                .already_resolved
        );
    }

    #[tokio::test]
    async fn resolve_unknown_approval_is_not_found() {
        let dir = TempDir::new().expect("tempdir");
        let app = api_router(fake_state(file_service(&dir)));
        let (status, json) = post(
            &app,
            "/api/v1/sessions/fake-session-1/approval",
            json!({ "approvalId": "missing", "decision": "rejected" }),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(json["error"]["code"], "approvalNotFound");
    }

    #[tokio::test]
    async fn resolve_session_mismatch_is_invalid_request() {
        let dir = TempDir::new().expect("tempdir");
        let state = fake_state(file_service(&dir));
        state
            .approvals
            .record(approval("a1", "session-1"))
            .await
            .expect("record");
        let app = api_router(state);
        let (status, json) = post(
            &app,
            "/api/v1/sessions/session-2/approval",
            json!({ "approvalId": "a1", "decision": "allowedOnce" }),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(json["error"]["code"], "invalidRequest");
    }

    #[tokio::test]
    async fn resolve_expired_approval_is_conflict() {
        use std::sync::Mutex;

        use pharos_hitl::{PendingApprovalStore, WallClock};
        use time::OffsetDateTime;
        use time::format_description::well_known::Rfc3339;

        #[derive(Debug, Clone)]
        struct TestClock(Arc<Mutex<OffsetDateTime>>);
        impl WallClock for TestClock {
            fn now(&self) -> OffsetDateTime {
                *self.0.lock().expect("clock")
            }
        }

        let dir = TempDir::new().expect("tempdir");
        let clock = TestClock(Arc::new(Mutex::new(
            OffsetDateTime::parse("2026-11-11T10:00:00Z", &Rfc3339).expect("time"),
        )));
        let store = PendingApprovalStore::open_with(
            dir.path().join("pending-approvals.json"),
            clock.clone(),
            time::Duration::seconds(pharos_hitl::HITL_TIMEOUT_SECS as i64),
        )
        .expect("store");
        let state = fake_state(Arc::new(FileApprovalService::from_store(store)));
        state
            .approvals
            .record(approval("a1", "fake-session-1"))
            .await
            .expect("record");
        *clock.0.lock().expect("clock") +=
            time::Duration::seconds(pharos_hitl::HITL_TIMEOUT_SECS as i64 + 1);
        let app = api_router(state);
        let (status, json) = post(
            &app,
            "/api/v1/sessions/fake-session-1/approval",
            json!({ "approvalId": "a1", "decision": "allowedOnce" }),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(json["error"]["code"], "conflict");
    }
}
