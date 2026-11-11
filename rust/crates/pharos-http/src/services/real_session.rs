//! Real S2-backed Session service for `pharos-web`.
//!
//! Wraps [`pharos_session::AdapterSessionService`] over a `dyn SessionAdapter`:
//!
//! - **live mode** (`--session-adapter codex`): real vendor sessions; list,
//!   history, send, steer and approval resolution go through the adapter.
//! - **unconfigured mode** (default): no vendor process is spawned. Reads are
//!   empty / not-found, and every live action returns an explicit
//!   [`PharosApiError::OperationFailed`] — never a fabricated success.
//!
//! Goal/Todo progress reads come from the durable `pharos-goals` store under
//! the server data dir. Session events are forwarded to the WS [`EventBus`].

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use pharos_api::{
    CanonicalTurn, ClientEvent, HostInventorySnapshot, HostInventoryStatus, PharosApiError,
    ProjectSummary, ResolveApprovalRequest, SendSessionMessageRequest, SessionProgress,
    SessionSummary, SteerSessionRequest,
};
use pharos_codex_adapter::SessionAdapter;
use pharos_goals::GoalsStore;
use pharos_hitl::{QuestionnaireAnswer, StoredDecision};
use pharos_protocol::AdapterKind;
use pharos_session::{
    AdapterSessionService, EventSink, SessionError, SessionService as CoreSessionService,
};

use super::session::{
    CreateSessionRequest, SessionConfigPatch, SessionConfigView, SessionLifecycleResponse,
    unsupported_field, unsupported_operation,
};
use super::{EventBus, SessionService};

/// Honest error message for live actions when no vendor adapter was configured.
pub const NO_ADAPTER_MESSAGE: &str =
    "no live session adapter configured; restart pharos-web with --session-adapter codex";

/// Session service backed by the S2 adapter service (live) or by a durable
/// goals store only (unconfigured).
pub struct RealSessionService {
    /// `Some` only when a live vendor adapter was configured at startup.
    live: Option<Mutex<AdapterSessionService>>,
    /// Goals store used for progress reads when there is no live service.
    goals: Option<Mutex<GoalsStore>>,
    agent_type: String,
    supported_agents: Vec<String>,
    unavailable_agents: Vec<String>,
}

impl RealSessionService {
    /// Unconfigured service: no vendor adapter, empty session list, explicit
    /// errors for live actions.
    pub fn unconfigured(goals: GoalsStore, _events: EventBus) -> Self {
        let supported = Vec::new();
        Self {
            live: None,
            goals: Some(Mutex::new(goals)),
            agent_type: "none".into(),
            unavailable_agents: known_agent_names(&supported),
            supported_agents: supported,
        }
    }

    /// Live service over a vendor [`SessionAdapter`].
    pub fn with_live_adapter(
        adapter: Box<dyn SessionAdapter>,
        goals: GoalsStore,
        events: EventBus,
        agent_type: impl Into<String>,
    ) -> Self {
        let agent_type = agent_type.into();
        let sink: Arc<dyn EventSink> = Arc::new(EventBusSink { bus: events });
        let service =
            AdapterSessionService::new(adapter, goals, sink, machine_id(), agent_type.clone());
        let supported_agents = vec![agent_type.clone()];
        Self {
            live: Some(Mutex::new(service)),
            goals: None,
            agent_type,
            unavailable_agents: known_agent_names(&supported_agents),
            supported_agents,
        }
    }

    /// Configured vendor adapter label (`"none"` when unconfigured).
    pub fn agent_type(&self) -> &str {
        &self.agent_type
    }

    /// Start a live session. Exposed for composition and tests; the HTTP route
    /// `POST /api/v1/sessions` calls this through [`SessionService`].
    pub fn start_session(
        &self,
        workspace_path: &str,
        mode: Option<&str>,
    ) -> Result<SessionSummary, PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(no_adapter_error());
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service
            .start_session(workspace_path, mode)
            .map_err(map_session_error)
    }

    fn lock_error() -> PharosApiError {
        PharosApiError::OperationFailed {
            message: "session service lock poisoned".into(),
        }
    }
}

#[async_trait]
impl SessionService for RealSessionService {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Ok(Vec::new());
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service.list_sessions().map_err(map_session_error)
    }

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service.get_session(session_id).map_err(map_session_error)
    }

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service.list_history(session_id).map_err(map_session_error)
    }

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(no_adapter_error());
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service
            .send_message(session_id, request)
            .map_err(map_session_error)
    }

    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(no_adapter_error());
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service
            .steer(session_id, request)
            .map_err(map_session_error)
    }

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        let Some(lock) = self.live.as_ref() else {
            return Err(no_adapter_error());
        };
        let service = lock.lock().map_err(|_| Self::lock_error())?;
        service
            .resolve_approval(session_id, request)
            .map_err(map_session_error)
    }

    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError> {
        if let Some(lock) = self.live.as_ref() {
            let service = lock.lock().map_err(|_| Self::lock_error())?;
            return service.progress(session_id).map_err(map_session_error);
        }
        let Some(goals) = self.goals.as_ref() else {
            return Ok(SessionProgress {
                goal: None,
                todos: Vec::new(),
            });
        };
        let goals = goals.lock().map_err(|_| Self::lock_error())?;
        goals
            .progress(session_id)
            .map_err(|error| PharosApiError::OperationFailed {
                message: format!("goals store: {error}"),
            })
    }

    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError> {
        // The daemon-owned project registry is not wired yet; report an empty
        // registry instead of inventing projects.
        Ok(Vec::new())
    }

    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError> {
        let sessions = self.list_sessions().await?;
        Ok(HostInventorySnapshot {
            sessions,
            status: HostInventoryStatus {
                supported_agents: self.supported_agents.clone(),
                unavailable_agents: self.unavailable_agents.clone(),
            },
        })
    }

    async fn create_session(
        &self,
        request: CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        self.start_session(&request.workspace_path, request.mode.as_deref())
    }

    async fn session_config(&self, session_id: &str) -> Result<SessionConfigView, PharosApiError> {
        // Unknown session (also every session in unconfigured mode) is an
        // honest 404 rather than an invented configuration.
        let _ = self.get_session(session_id).await?;
        Ok(SessionConfigView::unsupported(session_id))
    }

    async fn update_session_config(
        &self,
        session_id: &str,
        patch: SessionConfigPatch,
    ) -> Result<SessionConfigView, PharosApiError> {
        let _ = self.get_session(session_id).await?;
        if let Err(message) = patch.validate() {
            return Err(PharosApiError::InvalidRequest { message });
        }
        let field = if patch.model.is_some() {
            "model"
        } else {
            "mode"
        };
        Err(unsupported_field(
            field,
            format!(
                "the {} session adapter does not support updating session configuration",
                self.agent_type
            ),
        ))
    }

    async fn stop_session(
        &self,
        session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        let _ = self.get_session(session_id).await?;
        Err(unsupported_operation(
            "stop",
            format!(
                "the {} session adapter does not support stopping sessions",
                self.agent_type
            ),
        ))
    }

    async fn revive_session(
        &self,
        session_id: &str,
    ) -> Result<SessionLifecycleResponse, PharosApiError> {
        let _ = self.get_session(session_id).await?;
        Err(unsupported_operation(
            "revive",
            format!(
                "the {} session adapter does not support reviving sessions",
                self.agent_type
            ),
        ))
    }

    async fn send_message_with_attachments(
        &self,
        session_id: &str,
        _request: SendSessionMessageRequest,
        _attachment_ids: Vec<String>,
    ) -> Result<CanonicalTurn, PharosApiError> {
        let _ = self.get_session(session_id).await?;
        // No configured adapter can consume attachment bytes: report the
        // unsupported field instead of pretending the message was sent.
        Err(unsupported_field(
            "attachments",
            format!(
                "the {} session adapter cannot consume message attachments",
                self.agent_type
            ),
        ))
    }

    async fn resolve_approval_decision(
        &self,
        session_id: &str,
        approval_id: &str,
        decision: StoredDecision,
        _answers: Option<&[QuestionnaireAnswer]>,
    ) -> Result<(), PharosApiError> {
        if self.live.is_none() {
            return Err(no_adapter_error());
        }
        match decision.to_api() {
            Some(decision) => {
                self.resolve_approval(
                    session_id,
                    ResolveApprovalRequest {
                        approval_id: approval_id.to_string(),
                        decision,
                    },
                )
                .await
            }
            None => Err(unsupported_operation(
                "cancel",
                format!(
                    "the {} session adapter cannot cancel in-flight turns",
                    self.agent_type
                ),
            )),
        }
    }
}

/// Bridge S2 events onto the S4 WS bus.
struct EventBusSink {
    bus: EventBus,
}

impl EventSink for EventBusSink {
    fn emit(&self, event: ClientEvent) {
        self.bus.publish(event);
    }
}

fn no_adapter_error() -> PharosApiError {
    PharosApiError::OperationFailed {
        message: NO_ADAPTER_MESSAGE.into(),
    }
}

fn known_agent_names(supported: &[String]) -> Vec<String> {
    [
        AdapterKind::Codex,
        AdapterKind::Dsh,
        AdapterKind::Agy,
        AdapterKind::Cursor,
        AdapterKind::Grokbot,
    ]
    .iter()
    .map(|kind| kind.as_str().to_string())
    .filter(|name| !supported.contains(name))
    .collect()
}

fn machine_id() -> String {
    std::env::var("PHAROS_WEB_MACHINE_ID")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "pharos-web-host".into())
}

/// Map the S2 service error surface onto the frozen HTTP contract errors.
pub fn map_session_error(error: SessionError) -> PharosApiError {
    match error {
        SessionError::Message(message) => match message.strip_prefix("session not found: ") {
            Some(id) => PharosApiError::SessionNotFound {
                id: id.trim().to_string(),
            },
            None => PharosApiError::OperationFailed { message },
        },
        SessionError::Adapter(message) => PharosApiError::OperationFailed {
            message: format!("session adapter: {message}"),
        },
        other => PharosApiError::OperationFailed {
            message: other.to_string(),
        },
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use pharos_api::{AdapterManifest, SendSessionMessageRequest, TurnStatus};
    use pharos_codex_adapter::{
        AdapterError, InterruptOutcome, PromptMode, SessionAdapter, StartSessionRequest,
        StartedSession, StartedTurn, TurnOutcome, TurnStatus as AdapterTurnStatus,
    };

    use super::*;

    struct FakeAdapter;

    impl SessionAdapter for FakeAdapter {
        fn kind(&self) -> AdapterKind {
            AdapterKind::Codex
        }

        fn manifest(&self) -> AdapterManifest {
            AdapterManifest {
                id: "pharos.fake".into(),
                kind: AdapterKind::Codex,
                capabilities: vec!["session.list".into()],
            }
        }

        fn start_session(
            &mut self,
            _request: StartSessionRequest,
        ) -> Result<StartedSession, AdapterError> {
            Ok(StartedSession {
                session_id: "live-session-1".into(),
                vendor_thread_id: "vendor-thread-1".into(),
            })
        }

        fn send_prompt(
            &mut self,
            session_id: &str,
            _prompt: &str,
            _mode: PromptMode,
        ) -> Result<StartedTurn, AdapterError> {
            Ok(StartedTurn {
                session_id: session_id.to_owned(),
                turn_id: "turn-1".into(),
            })
        }

        fn interrupt(&mut self, session_id: &str) -> Result<InterruptOutcome, AdapterError> {
            Ok(InterruptOutcome {
                session_id: session_id.to_owned(),
                turn_id: Some("turn-1".into()),
                turn_status: Some(AdapterTurnStatus::Interrupted),
            })
        }

        fn wait_turn(
            &mut self,
            _session_id: &str,
            turn_id: &str,
            _timeout: Duration,
        ) -> Result<TurnOutcome, AdapterError> {
            Ok(TurnOutcome {
                turn_id: turn_id.to_owned(),
                status: AdapterTurnStatus::Completed,
                raw_status: "completed".into(),
                assistant_text: "PHAROS_FAKE_OK".into(),
                vendor_error: None,
            })
        }

        fn read_turns(&mut self, _session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
            Ok(Vec::new())
        }

        fn close(&mut self) {}
    }

    fn goals(dir: &std::path::Path) -> GoalsStore {
        pharos_goals::open_goals_db(dir).unwrap()
    }

    #[tokio::test]
    async fn live_adapter_lists_history_sends_and_publishes() {
        let dir = tempfile::tempdir().unwrap();
        let events = EventBus::new(16);
        let mut subscriber = events.subscribe();
        let service = RealSessionService::with_live_adapter(
            Box::new(FakeAdapter),
            goals(dir.path()),
            events,
            "codex",
        );

        let summary = service
            .start_session("/tmp/pharos-ws", Some("yolo"))
            .unwrap();
        assert_eq!(summary.session_id, "live-session-1");
        assert_eq!(summary.agent_type, "codex");

        let sessions = service.list_sessions().await.unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(
            service
                .get_session("live-session-1")
                .await
                .unwrap()
                .session_id,
            "live-session-1"
        );
        assert!(
            service
                .list_history("live-session-1")
                .await
                .unwrap()
                .is_empty()
        );

        let turn = service
            .send_message(
                "live-session-1",
                SendSessionMessageRequest {
                    text: "hello".into(),
                    request_id: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(turn.status, TurnStatus::Completed);
        assert_eq!(turn.assistant_text, vec!["PHAROS_FAKE_OK".to_string()]);
        assert_eq!(
            service.list_history("live-session-1").await.unwrap().len(),
            1
        );

        let inventory = service.inventory().await.unwrap();
        assert_eq!(inventory.sessions.len(), 1);
        assert_eq!(inventory.status.supported_agents, vec!["codex".to_string()]);
        assert!(
            inventory
                .status
                .unavailable_agents
                .contains(&"dsh".to_string())
        );

        let mut saw_turn_completed = false;
        while let Ok(event) = subscriber.recv().await {
            if matches!(event, ClientEvent::TurnCompleted { .. }) {
                saw_turn_completed = true;
                break;
            }
        }
        assert!(saw_turn_completed, "turnCompleted must reach the WS bus");
    }

    #[tokio::test]
    async fn unconfigured_reports_not_found_and_explicit_unavailable() {
        let dir = tempfile::tempdir().unwrap();
        let service = RealSessionService::unconfigured(goals(dir.path()), EventBus::new(8));
        assert!(service.list_sessions().await.unwrap().is_empty());
        assert!(matches!(
            service.get_session("missing").await.unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
        assert!(matches!(
            service.list_history("missing").await.unwrap_err(),
            PharosApiError::SessionNotFound { .. }
        ));
        let send_error = service
            .send_message(
                "missing",
                SendSessionMessageRequest {
                    text: "hi".into(),
                    request_id: None,
                },
            )
            .await
            .unwrap_err();
        match send_error {
            PharosApiError::OperationFailed { message } => {
                assert!(message.contains("--session-adapter"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        let create_error = service
            .create_session(CreateSessionRequest {
                workspace_path: "/tmp/x".into(),
                mode: None,
            })
            .await
            .unwrap_err();
        assert!(matches!(
            create_error,
            PharosApiError::OperationFailed { .. }
        ));
        assert!(service.list_projects().await.unwrap().is_empty());
        let inventory = service.inventory().await.unwrap();
        assert!(inventory.status.supported_agents.is_empty());
        assert!(
            inventory
                .status
                .unavailable_agents
                .contains(&"codex".to_string())
        );
    }

    #[test]
    fn session_not_found_message_maps_to_contract_error() {
        let mapped = map_session_error(SessionError::Message("session not found: abc-123".into()));
        assert_eq!(
            mapped,
            PharosApiError::SessionNotFound {
                id: "abc-123".into()
            }
        );
        let mapped = map_session_error(SessionError::Adapter("boom".into()));
        assert!(matches!(mapped, PharosApiError::OperationFailed { .. }));
    }

    #[tokio::test]
    async fn http_routes_use_live_real_session_service() {
        use axum::body::Body;
        use axum::http::{Request, StatusCode};
        use http_body_util::BodyExt;
        use tower::ServiceExt;

        let dir = tempfile::tempdir().unwrap();
        let events = EventBus::new(16);
        let sessions = RealSessionService::with_live_adapter(
            Box::new(FakeAdapter),
            goals(dir.path()),
            events.clone(),
            "codex",
        );
        sessions
            .start_session("/tmp/pharos-live-ws", Some("yolo"))
            .unwrap();
        let state = crate::AppState::new(
            Arc::new(crate::services::FakeThreadService::new(events.clone())),
            Arc::new(sessions),
            events,
        );
        let app = crate::router::api_router(state);

        async fn json(
            app: &axum::Router,
            method: &str,
            uri: &str,
            body: &str,
        ) -> (StatusCode, serde_json::Value) {
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
            let bytes = response.into_body().collect().await.unwrap().to_bytes();
            (status, serde_json::from_slice(&bytes).unwrap())
        }

        let (status, list) = json(&app, "GET", "/api/v1/sessions", "").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(list.as_array().unwrap().len(), 1);
        assert_eq!(list[0]["sessionId"], "live-session-1");
        assert_eq!(list[0]["agentType"], "codex");

        let (status, history) =
            json(&app, "GET", "/api/v1/sessions/live-session-1/history", "").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(history, serde_json::json!([]));

        let (status, turn) = json(
            &app,
            "POST",
            "/api/v1/sessions/live-session-1/messages",
            r#"{"text":"hello"}"#,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(turn["status"], "completed");
        assert_eq!(turn["assistantText"][0], "PHAROS_FAKE_OK");

        let (status, history) =
            json(&app, "GET", "/api/v1/sessions/live-session-1/history", "").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(history.as_array().unwrap().len(), 1);

        let (status, progress) =
            json(&app, "GET", "/api/v1/sessions/live-session-1/progress", "").await;
        assert_eq!(status, StatusCode::OK);
        assert!(progress["todos"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn unconfigured_config_and_lifecycle_are_honest_404() {
        let dir = tempfile::tempdir().unwrap();
        let service = RealSessionService::unconfigured(goals(dir.path()), EventBus::new(8));
        for error in [
            service.session_config("missing").await.unwrap_err(),
            service
                .update_session_config(
                    "missing",
                    SessionConfigPatch {
                        model: Some("gpt-5".into()),
                        mode: None,
                    },
                )
                .await
                .unwrap_err(),
            service.stop_session("missing").await.unwrap_err(),
            service.revive_session("missing").await.unwrap_err(),
            service
                .send_message_with_attachments(
                    "missing",
                    SendSessionMessageRequest {
                        text: "x".into(),
                        request_id: None,
                    },
                    vec!["id".into()],
                )
                .await
                .unwrap_err(),
        ] {
            assert!(
                matches!(error, PharosApiError::SessionNotFound { .. }),
                "{error:?}"
            );
        }
        // No live adapter: extended approval decision is an explicit 502, and
        // `cancelled` is not silently turned into rejected.
        for decision in [StoredDecision::AllowedOnce, StoredDecision::Cancelled] {
            let error = service
                .resolve_approval_decision("missing", "a1", decision, None)
                .await
                .unwrap_err();
            match error {
                PharosApiError::OperationFailed { message } => {
                    assert!(message.contains("--session-adapter"), "{message}");
                }
                other => panic!("expected OperationFailed, got {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn live_adapter_reports_honest_unsupported_capabilities() {
        let dir = tempfile::tempdir().unwrap();
        let events = EventBus::new(16);
        let service = RealSessionService::with_live_adapter(
            Box::new(FakeAdapter),
            goals(dir.path()),
            events,
            "codex",
        );
        let summary = service
            .start_session("/tmp/pharos-ws", Some("yolo"))
            .unwrap();
        let session_id = summary.session_id;

        // Known live session: honest empty config view (nothing invented).
        let view = service.session_config(&session_id).await.expect("config");
        assert!(!view.supported);
        assert!(view.supported_fields.is_empty());
        assert!(view.model.is_none());
        assert!(view.mode.is_none());
        assert!(view.models.is_empty());
        assert!(view.modes.is_empty());
        assert!(view.readonly);

        let error = service
            .update_session_config(
                &session_id,
                SessionConfigPatch {
                    model: Some("gpt-5".into()),
                    mode: None,
                },
            )
            .await
            .unwrap_err();
        match error {
            PharosApiError::OperationFailed { message } => {
                assert!(
                    message.starts_with(crate::services::UNSUPPORTED_FIELD_PREFIX),
                    "{message}"
                );
                assert!(message.contains("model"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }

        let stop_error = service.stop_session(&session_id).await.unwrap_err();
        match stop_error {
            PharosApiError::OperationFailed { message } => {
                assert!(
                    message.starts_with(crate::services::UNSUPPORTED_OPERATION_PREFIX),
                    "{message}"
                );
                assert!(message.contains("stop"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        let revive_error = service.revive_session(&session_id).await.unwrap_err();
        match revive_error {
            PharosApiError::OperationFailed { message } => {
                assert!(message.contains("revive"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }

        let attachments_error = service
            .send_message_with_attachments(
                &session_id,
                SendSessionMessageRequest {
                    text: "with attachment".into(),
                    request_id: None,
                },
                vec!["0123456789abcdef0123456789abcdef".into()],
            )
            .await
            .unwrap_err();
        match attachments_error {
            PharosApiError::OperationFailed { message } => {
                assert!(
                    message.starts_with(crate::services::UNSUPPORTED_FIELD_PREFIX),
                    "{message}"
                );
                assert!(message.contains("attachments"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }

        // The live adapter has no cancel capability: honest unsupported op.
        let cancel_error = service
            .resolve_approval_decision(&session_id, "a1", StoredDecision::Cancelled, None)
            .await
            .unwrap_err();
        match cancel_error {
            PharosApiError::OperationFailed { message } => {
                assert!(
                    message.starts_with(crate::services::UNSUPPORTED_OPERATION_PREFIX),
                    "{message}"
                );
                assert!(message.contains("cancel"), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
    }
}
