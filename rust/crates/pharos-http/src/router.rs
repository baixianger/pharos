//! Axum router mounting `pharos-api::routes` over S1/S2 service traits.

use axum::extract::{Path, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use pharos_api::{
    HealthResponse, PharosApiError, ReplyThreadMessageRequest, SendThreadMessageRequest,
    SteerSessionRequest, openapi_stub_json, routes,
};

use crate::approvals::{APPROVALS_ROUTE, list_approvals};
use crate::error::{ApiError, ApiResult};
use crate::services::{
    CreateSessionRequest, CreateThreadRequest, ExtendedResolveApprovalResponse,
    ResolveApprovalDecisionRequest,
};
use crate::state::AppState;
use crate::web_routes;
use crate::ws::events_ws_handler;

/// Build the HTTP/WS API router (no static Web UI — that lives in `pharos-web`).
pub fn api_router(state: AppState) -> Router {
    Router::new()
        .route(routes::HEALTH, get(health))
        .route(routes::OPENAPI, get(openapi))
        .route(routes::EVENTS_WS, get(events_ws_handler))
        .route(APPROVALS_ROUTE, get(list_approvals))
        .route("/api/v1/sessions", get(list_sessions).post(create_session))
        .route("/api/v1/sessions/{id}", get(get_session))
        .route("/api/v1/sessions/{id}/history", get(session_history))
        .route(
            "/api/v1/sessions/{id}/messages",
            post(web_routes::send_session_message),
        )
        .route("/api/v1/sessions/{id}/steer", post(steer_session))
        .route("/api/v1/sessions/{id}/approval", post(resolve_approval))
        .route("/api/v1/sessions/{id}/progress", get(session_progress))
        .route("/api/v1/threads", get(list_threads).post(create_thread))
        .route("/api/v1/threads/{id}", get(get_thread))
        .route(
            "/api/v1/threads/{id}/messages",
            get(list_thread_messages).post(send_thread_message),
        )
        .route("/api/v1/threads/{id}/reply", post(reply_thread))
        .route("/api/v1/projects", get(list_projects))
        .route("/api/v1/inventory/sessions", get(inventory))
        // --- web-endpoints additions (kept in one block for merge friendliness)
        .route(
            "/api/v1/threads/{id}/members",
            get(web_routes::thread_members),
        )
        .route(
            "/api/v1/threads/{id}/bindings",
            get(web_routes::list_thread_bindings),
        )
        .route(
            "/api/v1/threads/{id}/bindings/{member}",
            get(web_routes::get_thread_binding)
                .put(web_routes::put_thread_binding)
                .delete(web_routes::delete_thread_binding),
        )
        .route(
            "/api/v1/sessions/{id}/config",
            get(web_routes::get_session_config).patch(web_routes::patch_session_config),
        )
        .route("/api/v1/sessions/{id}/stop", post(web_routes::stop_session))
        .route(
            "/api/v1/sessions/{id}/revive",
            post(web_routes::revive_session),
        )
        .route(
            "/api/v1/sessions/{id}/attachments",
            get(web_routes::list_session_attachments).post(web_routes::upload_session_attachment),
        )
        .route("/api/v1/attachments/{id}", get(web_routes::get_attachment))
        .route(
            "/api/v1/attachments/{id}/content",
            get(web_routes::get_attachment_content),
        )
        .route(
            "/api/v1/members/{id}",
            get(web_routes::get_member).patch(web_routes::patch_member),
        )
        .route(
            "/api/v1/members/{id}/avatar",
            get(web_routes::get_member_avatar)
                .put(web_routes::put_member_avatar)
                .delete(web_routes::delete_member_avatar),
        )
        // Base64 JSON uploads need headroom over the 2 MiB axum default; the
        // handlers enforce the real decoded limits (10 MiB attachment / 512 KiB
        // avatar) and answer 400, not the extractor's opaque 413.
        .layer(axum::extract::DefaultBodyLimit::max(
            web_routes::MAX_ENCODED_BODY_BYTES,
        ))
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
    // Additive: web-endpoints routes (thread bindings, session config,
    // lifecycle, attachments, member settings). The frozen stub above is not
    // modified.
    if let Some(paths) = doc.get_mut("paths").and_then(|value| value.as_object_mut()) {
        for (path, spec) in web_endpoint_openapi_paths() {
            paths.insert(path, spec);
        }
    }
    // Additive: routes the router has always served but the frozen Phase-0
    // stub omits. Operations are merged into existing path objects so the
    // methods the stub already documents (e.g. `GET /api/v1/sessions`,
    // `GET /api/v1/threads`) stay intact instead of being replaced.
    for (path, method, spec) in router_served_openapi_operations() {
        merge_openapi_operation(&mut doc, path, method, spec);
    }
    Json(doc)
}

/// OpenAPI operations served by [`api_router`] but absent from the frozen stub.
fn router_served_openapi_operations() -> Vec<(&'static str, &'static str, serde_json::Value)> {
    vec![
        (
            "/api/v1/sessions",
            "post",
            serde_json::json!({
                "operationId": "createSession",
                "responses": {
                    "200": {"description": "SessionSummary"},
                    "400": {"description": "invalidRequest"}
                }
            }),
        ),
        (
            "/api/v1/sessions/{sessionId}",
            "get",
            serde_json::json!({
                "operationId": "getSession",
                "responses": {
                    "200": {"description": "SessionSummary"},
                    "404": {"description": "sessionNotFound"}
                }
            }),
        ),
        (
            "/api/v1/sessions/{sessionId}/history",
            "get",
            serde_json::json!({
                "operationId": "sessionHistory",
                "responses": {
                    "200": {"description": "CanonicalTurn[]"},
                    "404": {"description": "sessionNotFound"}
                }
            }),
        ),
        (
            "/api/v1/sessions/{sessionId}/steer",
            "post",
            serde_json::json!({
                "operationId": "steerSession",
                "responses": {
                    "200": {"description": "ok"},
                    "404": {"description": "sessionNotFound"}
                }
            }),
        ),
        (
            "/api/v1/threads",
            "post",
            serde_json::json!({
                "operationId": "createThread",
                "responses": {
                    "200": {"description": "ThreadSummary"},
                    "400": {"description": "invalidRequest"}
                }
            }),
        ),
        (
            "/api/v1/threads/{threadId}",
            "get",
            serde_json::json!({
                "operationId": "getThread",
                "responses": {
                    "200": {"description": "ThreadSummary"},
                    "404": {"description": "threadNotFound"}
                }
            }),
        ),
        (
            "/api/v1/inventory/sessions",
            "get",
            serde_json::json!({
                "operationId": "sessionInventory",
                "responses": {
                    "200": {"description": "Session inventory snapshot"}
                }
            }),
        ),
    ]
}

/// Merge one operation into a path object, creating the path when absent.
fn merge_openapi_operation(
    doc: &mut serde_json::Value,
    path: &str,
    method: &str,
    spec: serde_json::Value,
) {
    let Some(paths) = doc.get_mut("paths").and_then(|value| value.as_object_mut()) else {
        return;
    };
    let entry = paths
        .entry(path.to_string())
        .or_insert_with(|| serde_json::json!({}));
    if let Some(entry) = entry.as_object_mut() {
        entry.insert(method.to_string(), spec);
    }
}

/// OpenAPI path specs for the routes added by the web-endpoints stream.
fn web_endpoint_openapi_paths() -> serde_json::Map<String, serde_json::Value> {
    let mut paths = serde_json::Map::new();
    let mut insert = |path: &str, value: serde_json::Value| {
        paths.insert(path.to_string(), value);
    };
    insert(
        "/api/v1/threads/{threadId}/members",
        serde_json::json!({
            "get": {"operationId": "listThreadMembers", "responses": {"200": {"description": "Thread member views (replica members + bound sessions + settings)"}}}
        }),
    );
    insert(
        "/api/v1/threads/{threadId}/bindings",
        serde_json::json!({
            "get": {"operationId": "listThreadSessionBindings", "responses": {"200": {"description": "{bindings: ThreadBinding[]}"}}}
        }),
    );
    insert(
        "/api/v1/threads/{threadId}/bindings/{member}",
        serde_json::json!({
            "get": {"operationId": "getThreadSessionBinding", "responses": {"200": {"description": "ThreadBinding"}, "404": {"description": "threadBindingNotFound"}}},
            "put": {"operationId": "putThreadSessionBinding", "responses": {"200": {"description": "ThreadBinding"}, "400": {"description": "invalidRequest"}, "404": {"description": "threadNotFound | sessionNotFound"}}},
            "delete": {"operationId": "deleteThreadSessionBinding", "responses": {"200": {"description": "{ok, threadId, member, removed}"}, "404": {"description": "threadBindingNotFound"}}}
        }),
    );
    insert(
        "/api/v1/sessions/{sessionId}/config",
        serde_json::json!({
            "get": {"operationId": "getSessionConfig", "responses": {"200": {"description": "SessionConfigView"}, "404": {"description": "sessionNotFound"}, "502": {"description": "unsupportedOperation"}}},
            "patch": {"operationId": "patchSessionConfig", "responses": {"200": {"description": "SessionConfigView"}, "400": {"description": "invalidRequest"}, "404": {"description": "sessionNotFound"}, "502": {"description": "unsupportedField"}}}
        }),
    );
    insert(
        "/api/v1/sessions/{sessionId}/stop",
        serde_json::json!({
            "post": {"operationId": "stopSession", "responses": {"200": {"description": "SessionLifecycleResponse"}, "404": {"description": "sessionNotFound"}, "502": {"description": "unsupportedOperation"}}}
        }),
    );
    insert(
        "/api/v1/sessions/{sessionId}/revive",
        serde_json::json!({
            "post": {"operationId": "reviveSession", "responses": {"200": {"description": "SessionLifecycleResponse"}, "404": {"description": "sessionNotFound"}, "502": {"description": "unsupportedOperation"}}}
        }),
    );
    insert(
        "/api/v1/sessions/{sessionId}/attachments",
        serde_json::json!({
            "get": {"operationId": "listSessionAttachments", "responses": {"200": {"description": "{attachments: AttachmentMetadata[]}"}, "404": {"description": "sessionNotFound"}}},
            "post": {"operationId": "uploadSessionAttachment", "responses": {"200": {"description": "AttachmentMetadata"}, "400": {"description": "invalidRequest"}, "404": {"description": "sessionNotFound"}}}
        }),
    );
    insert(
        "/api/v1/attachments/{attachmentId}",
        serde_json::json!({
            "get": {"operationId": "getAttachment", "responses": {"200": {"description": "AttachmentMetadata"}, "404": {"description": "attachmentNotFound"}}}
        }),
    );
    insert(
        "/api/v1/attachments/{attachmentId}/content",
        serde_json::json!({
            "get": {"operationId": "getAttachmentContent", "responses": {"200": {"description": "raw bytes"}, "404": {"description": "attachmentNotFound"}}}
        }),
    );
    insert(
        "/api/v1/members/{memberId}",
        serde_json::json!({
            "get": {"operationId": "getMemberSettings", "responses": {"200": {"description": "MemberSettingsView"}, "400": {"description": "invalidRequest"}}},
            "patch": {"operationId": "patchMemberSettings", "responses": {"200": {"description": "MemberSettingsView"}, "400": {"description": "invalidRequest"}}}
        }),
    );
    insert(
        "/api/v1/members/{memberId}/avatar",
        serde_json::json!({
            "get": {"operationId": "getMemberAvatar", "responses": {"200": {"description": "raw image bytes"}, "404": {"description": "attachmentNotFound"}}},
            "put": {"operationId": "putMemberAvatar", "responses": {"200": {"description": "MemberSettingsView"}, "400": {"description": "invalidRequest"}}},
            "delete": {"operationId": "deleteMemberAvatar", "responses": {"200": {"description": "{ok, memberId}"}, "404": {"description": "attachmentNotFound"}}}
        }),
    );
    paths
}

async fn list_sessions(State(state): State<AppState>) -> ApiResult<Json<serde_json::Value>> {
    let sessions = state.sessions.list_sessions().await?;
    Ok(Json(serde_json::to_value(sessions).expect("serialize")))
}

async fn create_session(
    State(state): State<AppState>,
    Json(body): Json<CreateSessionRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let session = state.sessions.create_session(body).await?;
    Ok(Json(serde_json::to_value(session).expect("serialize")))
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
    Json(body): Json<ResolveApprovalDecisionRequest>,
) -> ApiResult<Json<ExtendedResolveApprovalResponse>> {
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
    let approval_id = body.approval_id.clone();
    let response = state
        .approvals
        .resolve_with(
            &approval_id,
            body.decision,
            body.questionnaire_answers.clone(),
        )
        .await?;
    if !response.already_resolved {
        // Keep the existing session/adapter decision path; the durable store
        // already recorded the decision so replays are exact no-ops. If the
        // dispatch fails, undo the durable decision: a failed dispatch must not
        // consume the approval silently (retry must be possible).
        if let Err(error) = state
            .sessions
            .resolve_approval_decision(
                &id,
                &approval_id,
                body.decision,
                body.questionnaire_answers.as_deref(),
            )
            .await
        {
            if let Err(revert_error) = state.approvals.revert_decision(&approval_id).await {
                tracing::error!(
                    approval_id = %approval_id,
                    ?revert_error,
                    "failed to revert approval decision after session dispatch error"
                );
            }
            return Err(ApiError::from_capability_error(error));
        }
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

async fn create_thread(
    State(state): State<AppState>,
    Json(body): Json<CreateThreadRequest>,
) -> ApiResult<Json<serde_json::Value>> {
    let thread = state.threads.create_thread(body).await?;
    Ok(Json(serde_json::to_value(thread).expect("serialize")))
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

    /// `/openapi.json` must document every route `api_router` serves. This list
    /// is written out by hand on purpose: it is the independent check that a
    /// newly mounted route was not forgotten in the stub.
    #[tokio::test]
    async fn openapi_lists_every_router_served_route() {
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
        let expected: &[(&str, &str)] = &[
            ("/health", "get"),
            ("/api/v1/events", "get"),
            ("/api/v1/approvals", "get"),
            ("/api/v1/sessions", "get"),
            ("/api/v1/sessions", "post"),
            ("/api/v1/sessions/{sessionId}", "get"),
            ("/api/v1/sessions/{sessionId}/history", "get"),
            ("/api/v1/sessions/{sessionId}/messages", "post"),
            ("/api/v1/sessions/{sessionId}/steer", "post"),
            ("/api/v1/sessions/{sessionId}/approval", "post"),
            ("/api/v1/sessions/{sessionId}/progress", "get"),
            ("/api/v1/sessions/{sessionId}/config", "get"),
            ("/api/v1/sessions/{sessionId}/config", "patch"),
            ("/api/v1/sessions/{sessionId}/stop", "post"),
            ("/api/v1/sessions/{sessionId}/revive", "post"),
            ("/api/v1/sessions/{sessionId}/attachments", "get"),
            ("/api/v1/sessions/{sessionId}/attachments", "post"),
            ("/api/v1/attachments/{attachmentId}", "get"),
            ("/api/v1/attachments/{attachmentId}/content", "get"),
            ("/api/v1/threads", "get"),
            ("/api/v1/threads", "post"),
            ("/api/v1/threads/{threadId}", "get"),
            ("/api/v1/threads/{threadId}/messages", "get"),
            ("/api/v1/threads/{threadId}/messages", "post"),
            ("/api/v1/threads/{threadId}/reply", "post"),
            ("/api/v1/threads/{threadId}/members", "get"),
            ("/api/v1/threads/{threadId}/bindings", "get"),
            ("/api/v1/threads/{threadId}/bindings/{member}", "get"),
            ("/api/v1/threads/{threadId}/bindings/{member}", "put"),
            ("/api/v1/threads/{threadId}/bindings/{member}", "delete"),
            ("/api/v1/members/{memberId}", "get"),
            ("/api/v1/members/{memberId}", "patch"),
            ("/api/v1/members/{memberId}/avatar", "get"),
            ("/api/v1/members/{memberId}/avatar", "put"),
            ("/api/v1/members/{memberId}/avatar", "delete"),
            ("/api/v1/projects", "get"),
            ("/api/v1/inventory/sessions", "get"),
        ];
        for (path, method) in expected {
            let documented = json["paths"]
                .get(*path)
                .and_then(|operations| operations.get(*method))
                .is_some();
            assert!(
                documented,
                "/openapi.json is missing {method} {path}; add it to router_served_openapi_operations()"
            );
        }
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
    #[tokio::test]
    async fn failed_session_dispatch_leaves_approval_retryable() {
        let dir = TempDir::new().expect("tempdir");
        let store_path = dir.path().join("pending-approvals.json");
        let state = fake_state(file_service(&dir));
        // The durable store knows the session (an adapter announced it), but the
        // fake session dispatcher does not: the resolve must fail downstream.
        state
            .approvals
            .record(approval("orphan-1", "ghost-session"))
            .await
            .expect("record");
        let app = api_router(state);

        let (status, json) = post(
            &app,
            "/api/v1/sessions/ghost-session/approval",
            json!({ "approvalId": "orphan-1", "decision": "allowedOnce" }),
        )
        .await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        assert_eq!(json["error"]["code"], "sessionNotFound");

        // The failed dispatch must not consume the decision: still pending ...
        let (_, json) = get(&app, "/api/v1/approvals?state=pending").await;
        assert_eq!(
            json["approvals"].as_array().expect("array").len(),
            1,
            "failed dispatch must leave the approval retryable"
        );
        // ... and durable across a restart, so a retry can still take effect.
        let restarted = fake_state(Arc::new(
            FileApprovalService::open(&store_path).expect("reopen"),
        ));
        let pending = restarted
            .approvals
            .list_pending(None)
            .await
            .expect("list pending");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].state, "pending");
        let retry = restarted
            .approvals
            .resolve("orphan-1", ApprovalDecision::AllowedOnce)
            .await
            .expect("retry resolve");
        assert!(
            !retry.already_resolved,
            "a decision consumed by a failed dispatch would make the retry a no-op"
        );
    }

    #[tokio::test]
    async fn create_thread_route_creates_and_lists() {
        let app = test_app();
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/threads")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"threadId":"route-thread","memberIds":["human","grokbot"]}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let json = body_json(response).await;
        assert_eq!(json["threadId"], "route-thread");
        assert_eq!(json["memberIds"][0], "human");

        let response = app
            .oneshot(
                Request::builder()
                    .uri("/api/v1/threads")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let json = body_json(response).await;
        assert!(
            json.as_array()
                .unwrap()
                .iter()
                .any(|t| t["threadId"] == "route-thread")
        );
    }

    #[tokio::test]
    async fn create_session_route_starts_fake_session() {
        let app = test_app();
        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/sessions")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        r#"{"workspacePath":"/tmp/pharos-fake-ws","mode":null}"#,
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let json = body_json(response).await;
        assert!(
            json["sessionId"]
                .as_str()
                .unwrap()
                .starts_with("fake-session-")
        );
        assert_eq!(json["workspacePath"], "/tmp/pharos-fake-ws");
    }
}
