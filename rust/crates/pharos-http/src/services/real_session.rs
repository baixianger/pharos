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
use pharos_protocol::AdapterKind;
use pharos_session::{
    AdapterSessionService, EventSink, SessionError, SessionService as CoreSessionService,
};

use super::{EventBus, SessionService};
use crate::services::session::CreateSessionRequest;

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
}
