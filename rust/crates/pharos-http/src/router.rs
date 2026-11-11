//! Axum router mounting `pharos-api::routes` over S1/S2 service traits.

use axum::extract::{Path, State};
use axum::routing::{get, post};
use axum::{Json, Router};
use pharos_api::{
    HealthResponse, ReplyThreadMessageRequest, ResolveApprovalRequest, SendSessionMessageRequest,
    SendThreadMessageRequest, SteerSessionRequest, openapi_stub_json, routes,
};

use crate::error::ApiResult;
use crate::services::{CreateSessionRequest, CreateThreadRequest};
use crate::state::AppState;
use crate::ws::events_ws_handler;

/// Build the HTTP/WS API router (no static Web UI — that lives in `pharos-web`).
pub fn api_router(state: AppState) -> Router {
    Router::new()
        .route(routes::HEALTH, get(health))
        .route(routes::OPENAPI, get(openapi))
        .route(routes::EVENTS_WS, get(events_ws_handler))
        .route("/api/v1/sessions", get(list_sessions).post(create_session))
        .route("/api/v1/sessions/{id}", get(get_session))
        .route("/api/v1/sessions/{id}/history", get(session_history))
        .route("/api/v1/sessions/{id}/messages", post(send_session_message))
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
        .with_state(state)
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse::ok_meshd())
}

async fn openapi() -> Json<serde_json::Value> {
    Json(openapi_stub_json())
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
) -> ApiResult<Json<serde_json::Value>> {
    state.sessions.resolve_approval(&id, body).await?;
    Ok(Json(serde_json::json!({ "ok": true })))
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

    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    use super::*;
    use crate::services::{EventBus, FakeSessionService, FakeThreadService};

    fn test_app() -> Router {
        let events = EventBus::new(32);
        let threads = Arc::new(FakeThreadService::new(events.clone()));
        let sessions = Arc::new(FakeSessionService::new(events.clone()));
        api_router(AppState::new(threads, sessions, events))
    }

    async fn body_json(response: axum::response::Response) -> serde_json::Value {
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        serde_json::from_slice(&bytes).unwrap()
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
