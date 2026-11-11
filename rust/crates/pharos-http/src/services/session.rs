//! Session / HITL / Goal service trait — owned by S2; S4 only mounts it.

use async_trait::async_trait;
use pharos_api::{
    CanonicalTurn, HostInventorySnapshot, PharosApiError, ProjectSummary, ResolveApprovalRequest,
    SendSessionMessageRequest, SessionProgress, SessionSummary, SteerSessionRequest,
};
use serde::{Deserialize, Serialize};

/// `POST /api/v1/sessions` body — start a live vendor session.
///
/// Only usable when the server was started with a live session adapter
/// (`--session-adapter codex`); otherwise the service returns an explicit
/// unavailable error.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateSessionRequest {
    pub workspace_path: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
}

/// S2 session + inventory + projects surface used by HTTP handlers.
#[async_trait]
pub trait SessionService: Send + Sync {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError>;

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError>;

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError>;

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError>;

    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError>;

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError>;

    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError>;

    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError>;

    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError>;

    /// Start a live session through the configured vendor adapter.
    ///
    /// Default: explicit unavailable error (never a fabricated session).
    async fn create_session(
        &self,
        _request: CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        Err(PharosApiError::OperationFailed {
            message: "session creation is not supported by this service".into(),
        })
    }
}
