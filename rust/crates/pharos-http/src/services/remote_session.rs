//! Composition service: local sessions plus remote-host sessions over the mesh.
//!
//! [`RemoteSessionMergedService`] implements the HTTP [`SessionService`] over
//! one local service plus a list of [`RemoteSessionSource`]s. Remote session
//! ids are namespaced as `peer:<host>:<session>` by the sources / this module;
//! requests carrying that prefix are routed to the matching remote host and
//! never fall through to the local service by accident.
//!
//! Honesty rules:
//! - a remote host that cannot be reached fails the whole merge with
//!   [`PharosApiError::BackendUnreachable`] — remotes are never silently
//!   dropped from a list;
//! - remote goal/todo progress is not part of the wire contract, so it returns
//!   an explicit [`PharosApiError::OperationFailed`] instead of a fabricated
//!   empty progress.

use std::sync::Arc;

use async_trait::async_trait;
use pharos_api::{
    CanonicalTurn, HostInventorySnapshot, PharosApiError, ProjectSummary, ResolveApprovalRequest,
    SendSessionMessageRequest, SessionProgress, SessionSummary, SteerSessionRequest,
};
use pharos_session::remote::{
    RemoteSessionSource, is_remote_session_id, prefix_remote_session_id, split_remote_session_id,
};

use super::SessionService;
use super::session::CreateSessionRequest;

/// Message for remote progress reads (not part of `host.session.*`).
pub const REMOTE_PROGRESS_UNAVAILABLE: &str = "remote session progress is not available";

/// A routed remote session: the owning source plus the target host's own
/// (unprefixed) session id.
type RemoteRoute<'source, 'session> =
    Option<(&'source Arc<dyn RemoteSessionSource>, &'session str)>;

/// Fan-out session service: local backend + one source per remote host.
pub struct RemoteSessionMergedService {
    local: Arc<dyn SessionService>,
    remotes: Vec<Arc<dyn RemoteSessionSource>>,
}

impl RemoteSessionMergedService {
    /// Build the merged service. Local sessions take precedence when ids
    /// collide (they should not: remote ids are `peer:`-namespaced).
    pub fn new(local: Arc<dyn SessionService>, remotes: Vec<Arc<dyn RemoteSessionSource>>) -> Self {
        Self { local, remotes }
    }

    /// The local session service.
    pub fn local(&self) -> &Arc<dyn SessionService> {
        &self.local
    }

    /// The configured remote hosts.
    pub fn remotes(&self) -> &[Arc<dyn RemoteSessionSource>] {
        &self.remotes
    }

    /// Resolve a session id to `(source, target host's own session id)`.
    ///
    /// Returns `Ok(None)` for local ids and an explicit not-found error for a
    /// `peer:`-namespaced id whose host is not configured.
    fn route_remote<'a, 'b>(
        &'a self,
        session_id: &'b str,
    ) -> Result<RemoteRoute<'a, 'b>, PharosApiError> {
        if let Some((host_device_id, remote_session_id)) = split_remote_session_id(session_id) {
            let source = self
                .remotes
                .iter()
                .find(|source| source.host_device_id() == host_device_id)
                .ok_or_else(|| PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                })?;
            return Ok(Some((source, remote_session_id)));
        }
        if is_remote_session_id(session_id) {
            // Malformed `peer:` id (e.g. "peer:" or "peer:host"): explicit 404,
            // never forwarded to the local service.
            return Err(PharosApiError::SessionNotFound {
                id: session_id.to_string(),
            });
        }
        Ok(None)
    }

    /// Prefix remote-returned summaries that are not namespaced yet (sources
    /// are expected to prefix; this keeps the merge contract explicit).
    fn normalize_summary(host_device_id: &str, mut summary: SessionSummary) -> SessionSummary {
        summary.session_id = prefix_remote_session_id(host_device_id, &summary.session_id);
        summary
    }

    /// Same for turns, so `turn.sessionId` always matches the requested id.
    fn normalize_turn(host_device_id: &str, mut turn: CanonicalTurn) -> CanonicalTurn {
        turn.session_id = prefix_remote_session_id(host_device_id, &turn.session_id);
        turn
    }
}

#[async_trait]
impl SessionService for RemoteSessionMergedService {
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        let mut sessions = self.local.list_sessions().await?;
        for remote in &self.remotes {
            let host_device_id = remote.host_device_id().to_string();
            let remote_sessions = remote.list_sessions().await?;
            sessions.extend(
                remote_sessions
                    .into_iter()
                    .map(|summary| Self::normalize_summary(&host_device_id, summary)),
            );
        }
        Ok(sessions)
    }

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        match self.route_remote(session_id)? {
            Some((source, remote_session_id)) => {
                let host_device_id = source.host_device_id().to_string();
                let summary = source.get_session(remote_session_id).await?;
                Ok(Self::normalize_summary(&host_device_id, summary))
            }
            None => self.local.get_session(session_id).await,
        }
    }

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        match self.route_remote(session_id)? {
            Some((source, remote_session_id)) => {
                let host_device_id = source.host_device_id().to_string();
                let turns = source.list_history(remote_session_id).await?;
                Ok(turns
                    .into_iter()
                    .map(|turn| Self::normalize_turn(&host_device_id, turn))
                    .collect())
            }
            None => self.local.list_history(session_id).await,
        }
    }

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        match self.route_remote(session_id)? {
            Some((source, remote_session_id)) => {
                let host_device_id = source.host_device_id().to_string();
                let turn = source.send_message(remote_session_id, request).await?;
                Ok(Self::normalize_turn(&host_device_id, turn))
            }
            None => self.local.send_message(session_id, request).await,
        }
    }

    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        match self.route_remote(session_id)? {
            Some((source, remote_session_id)) => source.steer(remote_session_id, request).await,
            None => self.local.steer(session_id, request).await,
        }
    }

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        match self.route_remote(session_id)? {
            Some((source, remote_session_id)) => {
                source.resolve_approval(remote_session_id, request).await
            }
            None => self.local.resolve_approval(session_id, request).await,
        }
    }

    async fn progress(&self, session_id: &str) -> Result<SessionProgress, PharosApiError> {
        match self.route_remote(session_id)? {
            Some(_) => Err(PharosApiError::OperationFailed {
                message: REMOTE_PROGRESS_UNAVAILABLE.to_string(),
            }),
            None => self.local.progress(session_id).await,
        }
    }

    async fn list_projects(&self) -> Result<Vec<ProjectSummary>, PharosApiError> {
        // Projects are a local-daemon registry concern; remote hosts are not
        // queried for them (no wire operation exists).
        self.local.list_projects().await
    }

    async fn inventory(&self) -> Result<HostInventorySnapshot, PharosApiError> {
        let mut inventory = self.local.inventory().await?;
        for remote in &self.remotes {
            let host_device_id = remote.host_device_id().to_string();
            let remote_sessions = remote.list_sessions().await?;
            inventory.sessions.extend(
                remote_sessions
                    .into_iter()
                    .map(|summary| Self::normalize_summary(&host_device_id, summary)),
            );
        }
        // Status stays local: remote hosts have their own inventories.
        Ok(inventory)
    }

    async fn create_session(
        &self,
        request: CreateSessionRequest,
    ) -> Result<SessionSummary, PharosApiError> {
        // New sessions are always started on this host.
        self.local.create_session(request).await
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use pharos_api::{SessionActivityStatus, TurnStatus};
    use pharos_session::remote::RemoteSessionSource;

    use super::super::fake::{FakeSessionService, FakeThreadService};
    use super::*;
    use crate::services::EventBus;

    /// In-memory remote host. Sessions are stored under the host's own
    /// (unprefixed) ids; this exercises the merge/prefix contract.
    struct FakeRemote {
        host: String,
        sessions: HashMap<String, SessionSummary>,
        history: HashMap<String, Vec<CanonicalTurn>>,
        list_error: Option<PharosApiError>,
    }

    impl FakeRemote {
        fn new(host: &str) -> Self {
            let summary = SessionSummary {
                session_id: "rs1".into(),
                machine_id: host.into(),
                agent_type: "codex".into(),
                workspace_path: "/tmp/remote-ws".into(),
                title: "Remote".into(),
                status: SessionActivityStatus::Working,
                latest_message_preview: None,
                updated_at: "2026-11-11T00:00:00Z".into(),
                avatar_seed: "remote".into(),
                inventory_stale: None,
                connection_route: Some("mesh".into()),
            };
            let mut sessions = HashMap::new();
            sessions.insert("rs1".to_string(), summary);
            let mut history = HashMap::new();
            history.insert(
                "rs1".to_string(),
                vec![CanonicalTurn {
                    turn_id: "rt1".into(),
                    session_id: "rs1".into(),
                    turn_number: 1,
                    status: TurnStatus::Completed,
                    created_at: "2026-11-11T00:00:00Z".into(),
                    completed_at: None,
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
    }

    #[async_trait]
    impl RemoteSessionSource for FakeRemote {
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
            self.sessions
                .get(session_id)
                .cloned()
                .ok_or_else(|| PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                })
        }

        async fn list_history(
            &self,
            session_id: &str,
        ) -> Result<Vec<CanonicalTurn>, PharosApiError> {
            self.history
                .get(session_id)
                .cloned()
                .ok_or_else(|| PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                })
        }

        async fn send_message(
            &self,
            session_id: &str,
            request: SendSessionMessageRequest,
        ) -> Result<CanonicalTurn, PharosApiError> {
            if !self.sessions.contains_key(session_id) {
                return Err(PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                });
            }
            Ok(CanonicalTurn {
                turn_id: "rt2".into(),
                session_id: session_id.to_string(),
                turn_number: 2,
                status: TurnStatus::Completed,
                created_at: "2026-11-11T00:00:01Z".into(),
                completed_at: None,
                assistant_text: vec![format!("remote echo: {}", request.text)],
            })
        }

        async fn steer(
            &self,
            session_id: &str,
            _request: SteerSessionRequest,
        ) -> Result<(), PharosApiError> {
            if !self.sessions.contains_key(session_id) {
                return Err(PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                });
            }
            Ok(())
        }

        async fn resolve_approval(
            &self,
            session_id: &str,
            _request: ResolveApprovalRequest,
        ) -> Result<(), PharosApiError> {
            if !self.sessions.contains_key(session_id) {
                return Err(PharosApiError::SessionNotFound {
                    id: session_id.to_string(),
                });
            }
            Ok(())
        }
    }

    fn merged(remotes: Vec<Arc<dyn RemoteSessionSource>>) -> RemoteSessionMergedService {
        let events = EventBus::new(8);
        let local: Arc<dyn SessionService> = Arc::new(FakeSessionService::new(events));
        RemoteSessionMergedService::new(local, remotes)
    }

    #[tokio::test]
    async fn list_merges_local_and_prefixed_remote_sessions() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let sessions = service.list_sessions().await.unwrap();
        let ids: Vec<&str> = sessions.iter().map(|s| s.session_id.as_str()).collect();
        assert!(ids.contains(&"fake-session-1"));
        assert!(ids.contains(&"peer:host-b:rs1"), "{ids:?}");
        let remote = sessions
            .iter()
            .find(|s| s.session_id == "peer:host-b:rs1")
            .unwrap();
        assert_eq!(remote.machine_id, "host-b");
    }

    #[tokio::test]
    async fn unreachable_remote_fails_the_list() {
        let remote =
            FakeRemote::new("host-b").with_list_error(PharosApiError::BackendUnreachable {
                backend: "host-b".into(),
                reason: "timeout".into(),
            });
        let service = merged(vec![Arc::new(remote)]);
        let error = service.list_sessions().await.unwrap_err();
        assert!(matches!(error, PharosApiError::BackendUnreachable { .. }));
    }

    #[tokio::test]
    async fn remote_routes_strip_and_reprefix_ids() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let summary = service.get_session("peer:host-b:rs1").await.unwrap();
        assert_eq!(summary.session_id, "peer:host-b:rs1");
        let turns = service.list_history("peer:host-b:rs1").await.unwrap();
        assert_eq!(turns[0].session_id, "peer:host-b:rs1");
        let turn = service
            .send_message(
                "peer:host-b:rs1",
                SendSessionMessageRequest {
                    text: "hi".into(),
                    request_id: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(turn.session_id, "peer:host-b:rs1");
        assert_eq!(turn.assistant_text, vec!["remote echo: hi".to_string()]);
    }

    #[tokio::test]
    async fn unknown_remote_host_is_not_found_never_local() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let error = service.get_session("peer:nope:rs1").await.unwrap_err();
        assert_eq!(
            error,
            PharosApiError::SessionNotFound {
                id: "peer:nope:rs1".into()
            }
        );
        let error = service.list_history("peer:nope:rs1").await.unwrap_err();
        assert!(matches!(error, PharosApiError::SessionNotFound { .. }));
        let error = service.get_session("peer:").await.unwrap_err();
        assert!(matches!(error, PharosApiError::SessionNotFound { .. }));
    }

    #[tokio::test]
    async fn local_ids_still_route_locally() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let summary = service.get_session("fake-session-1").await.unwrap();
        assert_eq!(summary.session_id, "fake-session-1");
        assert!(
            service
                .list_history("fake-session-1")
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn remote_progress_is_explicitly_unavailable() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let error = service.progress("peer:host-b:rs1").await.unwrap_err();
        match error {
            PharosApiError::OperationFailed { message } => {
                assert_eq!(message, REMOTE_PROGRESS_UNAVAILABLE);
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        // Local progress keeps working.
        assert!(service.progress("fake-session-1").await.is_ok());
    }

    #[tokio::test]
    async fn inventory_merges_remote_sessions_with_local_status() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let inventory = service.inventory().await.unwrap();
        assert_eq!(inventory.status.supported_agents, vec!["fake".to_string()]);
        let ids: Vec<&str> = inventory
            .sessions
            .iter()
            .map(|s| s.session_id.as_str())
            .collect();
        assert!(ids.contains(&"fake-session-1"));
        assert!(ids.contains(&"peer:host-b:rs1"));
    }

    #[tokio::test]
    async fn create_session_is_local_only() {
        let service = merged(vec![Arc::new(FakeRemote::new("host-b"))]);
        let summary = service
            .create_session(CreateSessionRequest {
                workspace_path: "/tmp/new-ws".into(),
                mode: None,
            })
            .await
            .unwrap();
        assert!(!summary.session_id.starts_with("peer:"));
        assert_eq!(summary.machine_id, "fake-host");
    }

    #[tokio::test]
    async fn merged_state_is_usable_with_fake_threads() {
        // Guards the composition used by the HTTP acceptance test.
        let events = EventBus::new(8);
        let local: Arc<dyn SessionService> = Arc::new(FakeSessionService::new(events.clone()));
        let merged = Arc::new(RemoteSessionMergedService::new(
            local,
            vec![Arc::new(FakeRemote::new("host-b"))],
        ));
        let threads = Arc::new(FakeThreadService::new(events.clone()));
        let state = crate::AppState::new(threads, merged, events);
        assert_eq!(state.sessions.list_sessions().await.unwrap().len(), 2);
    }
}
