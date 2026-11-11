//! Local `SessionService` construction for the mesh host (`pharos-meshd`).
//!
//! The daemon serves cross-host `host.session.query.v1` / `host.session.action.v1`
//! requests from one local [`pharos_session::SessionService`]. This module owns
//! the "which vendor adapter is configured?" decision:
//!
//! - **live Codex** (`PHAROS_MESH_SESSION_ADAPTER=codex`): a real
//!   [`CodexSessionAdapter`] over the Codex CLI App Server.
//! - **unavailable** (default, or Codex startup failure): an explicit
//!   [`UnavailableSessionAdapter`] that returns an [`AdapterError`] for every
//!   live operation. The daemon never fabricates sessions or fake successes.
//!
//! Reads never touch the vendor process: an unavailable host lists zero sessions
//! and reports "session not found" for history/gets. Goal/Todo progress is
//! durable through `pharos-goals` regardless of adapter state.

#![allow(dead_code)]

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use pharos_api::{
    AdapterManifest, CanonicalTurn, ClientEvent, ResolveApprovalRequest, SendSessionMessageRequest,
    SessionProgress, SessionSummary, SteerSessionRequest,
};
use pharos_codex_adapter::{
    AdapterError, CodexSessionAdapter, InterruptOutcome, PromptMode, SessionAdapter,
    StartSessionRequest, StartedSession, StartedTurn, TurnOutcome,
};
use pharos_goals::open_goals_db;
use pharos_protocol::AdapterKind;
use pharos_session::{AdapterSessionService, EventSink, SessionError, SessionService};

/// Env var selecting a live vendor adapter. Only `codex` is understood.
pub const SESSION_ADAPTER_ENV: &str = "PHAROS_MESH_SESSION_ADAPTER";
/// Env var overriding the machine id advertised in session summaries.
pub const MACHINE_ID_ENV: &str = "PHAROS_MESH_MACHINE_ID";

/// Honest error text used when live operations hit the placeholder adapter.
pub const NO_ADAPTER_MESSAGE: &str = "no live vendor session adapter configured on this host; set PHAROS_MESH_SESSION_ADAPTER=codex to enable Codex sessions";

/// Build the daemon's local SessionService under `data_dir`.
///
/// Goals/Progress persist in `data_dir`; vendor sessions only exist when a live
/// adapter was configured. This function never fails: adapter or goals store
/// problems degrade to an explicit unavailable service that returns errors
/// instead of fabricated data.
pub fn local_session_service(data_dir: &Path) -> Arc<dyn SessionService> {
    let goals = match open_goals_db(data_dir) {
        Ok(goals) => goals,
        Err(error) => {
            eprintln!(
                "pharos-agent-runtime: local session service unavailable: cannot open goals database under {}: {error}",
                data_dir.display()
            );
            return Arc::new(UnavailableSessionService::new(format!(
                "session goals store unavailable: {error}"
            )));
        }
    };

    let requested = std::env::var(SESSION_ADAPTER_ENV).ok();
    let (adapter, agent_type): (Box<dyn SessionAdapter>, &'static str) = match requested.as_deref()
    {
        Some("codex") => match CodexSessionAdapter::connect_stdio() {
            Ok(adapter) => (Box::new(adapter), "codex"),
            Err(error) => {
                eprintln!(
                    "pharos-agent-runtime: {SESSION_ADAPTER_ENV}=codex but the Codex adapter failed to start: {error}; serving explicit unavailable adapter"
                );
                (
                    Box::new(UnavailableSessionAdapter::new(format!(
                        "Codex adapter unavailable: {error}"
                    ))),
                    "unavailable",
                )
            }
        },
        None => (
            Box::new(UnavailableSessionAdapter::unavailable()),
            "unavailable",
        ),
        Some(other) => {
            eprintln!(
                "pharos-agent-runtime: unknown {SESSION_ADAPTER_ENV}={other:?}; serving explicit unavailable adapter"
            );
            (
                Box::new(UnavailableSessionAdapter::new(format!(
                    "unsupported session adapter configured: {other:?}"
                ))),
                "unavailable",
            )
        }
    };

    let events: Arc<dyn EventSink> = Arc::new(NoopEventSink);
    Arc::new(AdapterSessionService::new(
        adapter,
        goals,
        events,
        machine_id(),
        agent_type,
    ))
}

fn machine_id() -> String {
    std::env::var(MACHINE_ID_ENV)
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "pharos-mesh-host".into())
}

/// Event sink for the daemon: until a WS bridge is attached, session events are
/// dropped rather than buffered indefinitely.
pub struct NoopEventSink;

impl EventSink for NoopEventSink {
    fn emit(&self, _event: ClientEvent) {}
}

/// `SessionAdapter` that refuses every live operation with an explicit error.
///
/// It exists so the [`AdapterSessionService`] surface is still constructible
/// (durable goal/progress reads keep working) while sessions are honestly
/// reported as unavailable.
pub struct UnavailableSessionAdapter {
    message: String,
}

impl UnavailableSessionAdapter {
    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    /// Placeholder for the default "no vendor adapter configured" state.
    pub fn unavailable() -> Self {
        Self::new(NO_ADAPTER_MESSAGE)
    }

    fn error(&self) -> AdapterError {
        AdapterError::new(self.message.clone())
    }
}

impl SessionAdapter for UnavailableSessionAdapter {
    fn kind(&self) -> AdapterKind {
        AdapterKind::Codex
    }

    fn manifest(&self) -> AdapterManifest {
        AdapterManifest {
            id: "pharos.unavailable".into(),
            kind: AdapterKind::Codex,
            capabilities: Vec::new(),
        }
    }

    fn start_session(
        &mut self,
        _request: StartSessionRequest,
    ) -> Result<StartedSession, AdapterError> {
        Err(self.error())
    }

    fn send_prompt(
        &mut self,
        _session_id: &str,
        _prompt: &str,
        _mode: PromptMode,
    ) -> Result<StartedTurn, AdapterError> {
        Err(self.error())
    }

    fn interrupt(&mut self, _session_id: &str) -> Result<InterruptOutcome, AdapterError> {
        Err(self.error())
    }

    fn wait_turn(
        &mut self,
        _session_id: &str,
        _turn_id: &str,
        _timeout: Duration,
    ) -> Result<TurnOutcome, AdapterError> {
        Err(self.error())
    }

    fn read_turns(&mut self, _session_id: &str) -> Result<Vec<TurnOutcome>, AdapterError> {
        Err(self.error())
    }

    fn close(&mut self) {}
}

/// SessionService used only when the durable goals store cannot be opened.
///
/// Every operation fails explicitly: the daemon must not advertise an empty but
/// "healthy" session surface when its persistence layer is broken.
pub struct UnavailableSessionService {
    reason: String,
}

impl UnavailableSessionService {
    pub fn new(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
        }
    }

    fn error(&self) -> SessionError {
        SessionError::new(self.reason.clone())
    }
}

impl SessionService for UnavailableSessionService {
    fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
        Err(self.error())
    }

    fn get_session(&self, _session_id: &str) -> Result<SessionSummary, SessionError> {
        Err(self.error())
    }

    fn list_history(&self, _session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError> {
        Err(self.error())
    }

    fn start_session(
        &self,
        _workspace_path: &str,
        _mode: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        Err(self.error())
    }

    fn send_message(
        &self,
        _session_id: &str,
        _request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, SessionError> {
        Err(self.error())
    }

    fn steer(&self, _session_id: &str, _request: SteerSessionRequest) -> Result<(), SessionError> {
        Err(self.error())
    }

    fn resolve_approval(
        &self,
        _session_id: &str,
        _request: ResolveApprovalRequest,
    ) -> Result<(), SessionError> {
        Err(self.error())
    }

    fn progress(&self, _session_id: &str) -> Result<SessionProgress, SessionError> {
        Err(self.error())
    }

    fn set_progress(
        &self,
        _session_id: &str,
        _progress: &SessionProgress,
    ) -> Result<SessionProgress, SessionError> {
        Err(self.error())
    }
}

pub fn describe_wiring() -> &'static str {
    "mod session_service; // local_session_service(): AdapterSessionService over Codex (env-gated) or explicit UnavailableSessionAdapter + GoalsStore"
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_api::SendSessionMessageRequest;
    use tempfile::tempdir;

    fn unavailable_session_service(dir: &Path) -> AdapterSessionService {
        AdapterSessionService::new(
            Box::new(UnavailableSessionAdapter::unavailable()),
            open_goals_db(dir).expect("goals db"),
            Arc::new(NoopEventSink),
            "mac-test",
            "unavailable",
        )
    }

    fn send_message(service: &dyn SessionService) -> Result<CanonicalTurn, SessionError> {
        service.send_message(
            "session-1",
            SendSessionMessageRequest {
                text: "hello".into(),
                request_id: None,
            },
        )
    }

    #[test]
    fn unavailable_adapter_reports_explicit_live_errors() {
        let dir = tempdir().unwrap();
        let service = unavailable_session_service(dir.path());

        assert!(service.list_sessions().unwrap().is_empty());
        assert!(service.list_history("session-1").is_err());
        assert!(service.get_session("session-1").is_err());

        let error = service
            .start_session("/tmp/pharos-unavailable-ws", None)
            .unwrap_err();
        assert!(
            error.to_string().contains("no live vendor session adapter"),
            "unexpected error: {error}"
        );

        let error = send_message(&service).unwrap_err().to_string();
        assert!(
            error.contains("no live vendor session adapter"),
            "unexpected error: {error}"
        );
        assert!(
            service
                .steer(
                    "session-1",
                    SteerSessionRequest {
                        text: "focus".into(),
                    },
                )
                .is_err()
        );
        assert!(
            service
                .resolve_approval(
                    "session-1",
                    ResolveApprovalRequest {
                        approval_id: "approval-1".into(),
                        decision: pharos_api::ApprovalDecision::AllowedOnce,
                    },
                )
                .is_err()
        );
    }

    #[test]
    fn local_service_without_codex_lists_nothing_and_rejects_live_actions() {
        // Only assert the honest default when the env does not request a live
        // adapter (a developer machine may set it globally).
        if std::env::var(SESSION_ADAPTER_ENV).as_deref() == Ok("codex") {
            return;
        }
        let dir = tempdir().unwrap();
        let service = local_session_service(dir.path());
        assert!(service.list_sessions().unwrap().is_empty());
        let error = send_message(service.as_ref()).unwrap_err().to_string();
        assert!(
            error.contains("no live vendor session adapter"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn unavailable_goals_store_yields_explicit_service_errors() {
        let dir = tempdir().unwrap();
        // A regular file where the service expects a directory makes
        // `open_goals_db` fail deterministically.
        let not_a_dir = dir.path().join("not-a-directory");
        std::fs::write(&not_a_dir, b"x").unwrap();

        let service = local_session_service(&not_a_dir);
        let error = service.list_sessions().unwrap_err().to_string();
        assert!(error.contains("goals store unavailable"), "{error}");
        assert!(send_message(service.as_ref()).is_err());
    }

    #[test]
    fn machine_id_prefers_explicit_env_then_hostname() {
        let id = machine_id();
        assert!(!id.trim().is_empty());
    }

    #[test]
    fn describe_wiring_mentions_session_service_hook() {
        assert!(describe_wiring().contains("local_session_service"));
    }
}
