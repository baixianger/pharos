//! Caller-side remote host session source.
//!
//! [`MeshRemoteHostSessionSource`] asks another Host (over the mesh Peer RPC
//! contract `host.session.query.v1` / `host.session.action.v1`) for its sessions
//! and forwards user actions to it. Session identifiers leaving this module are
//! namespaced with [`REMOTE_SESSION_PREFIX`] (`peer:<host>:<session>`) so the
//! HTTP/API composition can route them without ambiguity; identifiers entering
//! the mesh query are always the target host's own unprefixed ids.
//!
//! Everything here is read-only/best-effort with explicit failures: an offline
//! peer is [`PharosApiError::BackendUnreachable`], never an empty list.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use pharos_api::{
    ApprovalDecision, CanonicalTurn, PharosApiError, ResolveApprovalRequest,
    SendSessionMessageRequest, SessionActivityStatus, SessionSummary, SteerSessionRequest,
    TurnStatus,
};
use pharos_protocol::host_session::{
    HostApprovalDecision, HostSessionActionPayload, HostSessionActionRequest,
    HostSessionActionResponse, HostSessionActivityStatus, HostSessionErrorCode,
    HostSessionQueryData, HostSessionQueryRequest, HostSessionQueryResponse, HostSessionSummary,
    HostSessionTurn, HostSessionTurnStatus,
};
use pharos_replica::{PeerDial, ReplicaHandle, ReplicaRpcError};
use uuid::Uuid;

/// Namespace prefix for session ids owned by another host.
pub const REMOTE_SESSION_PREFIX: &str = "peer:";

/// Build the API-facing id of a session owned by `host_device_id`.
///
/// `remote_session_id("host-b", "s1") == "peer:host-b:s1"`.
pub fn remote_session_id(host_device_id: &str, session_id: &str) -> String {
    format!("{REMOTE_SESSION_PREFIX}{host_device_id}:{session_id}")
}

/// Split `peer:<host>:<session>` back into `(host, session)`.
///
/// Returns `None` when `value` is not a remote id or either segment is empty.
/// The host device id is the first `:`-delimited segment; session ids may
/// themselves contain `:` (the remainder is kept verbatim).
pub fn split_remote_session_id(value: &str) -> Option<(&str, &str)> {
    let rest = value.strip_prefix(REMOTE_SESSION_PREFIX)?;
    let (host_device_id, session_id) = rest.split_once(':')?;
    if host_device_id.is_empty() || session_id.is_empty() {
        return None;
    }
    Some((host_device_id, session_id))
}

/// Whether `value` claims the remote-session namespace (even if malformed).
pub fn is_remote_session_id(value: &str) -> bool {
    value.starts_with(REMOTE_SESSION_PREFIX)
}

/// Add the remote prefix unless the id is already namespaced.
pub fn prefix_remote_session_id(host_device_id: &str, session_id: &str) -> String {
    if is_remote_session_id(session_id) {
        session_id.to_string()
    } else {
        remote_session_id(host_device_id, session_id)
    }
}

// ---------------------------------------------------------------------------
// Wire <-> API mapping
// ---------------------------------------------------------------------------

pub fn activity_status_to_wire(status: SessionActivityStatus) -> HostSessionActivityStatus {
    match status {
        SessionActivityStatus::Idle => HostSessionActivityStatus::Idle,
        SessionActivityStatus::Working => HostSessionActivityStatus::Working,
        SessionActivityStatus::NeedsHuman => HostSessionActivityStatus::NeedsHuman,
        SessionActivityStatus::Stopped => HostSessionActivityStatus::Stopped,
        SessionActivityStatus::Unknown => HostSessionActivityStatus::Unknown,
    }
}

pub fn activity_status_from_wire(status: HostSessionActivityStatus) -> SessionActivityStatus {
    match status {
        HostSessionActivityStatus::Idle => SessionActivityStatus::Idle,
        HostSessionActivityStatus::Working => SessionActivityStatus::Working,
        HostSessionActivityStatus::NeedsHuman => SessionActivityStatus::NeedsHuman,
        HostSessionActivityStatus::Stopped => SessionActivityStatus::Stopped,
        HostSessionActivityStatus::Unknown => SessionActivityStatus::Unknown,
    }
}

pub fn turn_status_to_wire(status: TurnStatus) -> HostSessionTurnStatus {
    match status {
        TurnStatus::InProgress => HostSessionTurnStatus::InProgress,
        TurnStatus::Completed => HostSessionTurnStatus::Completed,
        TurnStatus::Failed => HostSessionTurnStatus::Failed,
        TurnStatus::Cancelled => HostSessionTurnStatus::Cancelled,
        TurnStatus::NeedsHuman => HostSessionTurnStatus::NeedsHuman,
    }
}

pub fn turn_status_from_wire(status: HostSessionTurnStatus) -> TurnStatus {
    match status {
        HostSessionTurnStatus::InProgress => TurnStatus::InProgress,
        HostSessionTurnStatus::Completed => TurnStatus::Completed,
        HostSessionTurnStatus::Failed => TurnStatus::Failed,
        HostSessionTurnStatus::Cancelled => TurnStatus::Cancelled,
        HostSessionTurnStatus::NeedsHuman => TurnStatus::NeedsHuman,
    }
}

pub fn approval_decision_to_wire(decision: ApprovalDecision) -> HostApprovalDecision {
    match decision {
        ApprovalDecision::AllowedOnce => HostApprovalDecision::AllowedOnce,
        ApprovalDecision::AllowedAlways => HostApprovalDecision::AllowedAlways,
        ApprovalDecision::Rejected => HostApprovalDecision::Rejected,
    }
}

pub fn approval_decision_from_wire(decision: HostApprovalDecision) -> ApprovalDecision {
    match decision {
        HostApprovalDecision::AllowedOnce => ApprovalDecision::AllowedOnce,
        HostApprovalDecision::AllowedAlways => ApprovalDecision::AllowedAlways,
        HostApprovalDecision::Rejected => ApprovalDecision::Rejected,
    }
}

/// Map a local API summary into its wire mirror (callee side).
pub fn session_summary_to_wire(summary: &SessionSummary) -> HostSessionSummary {
    HostSessionSummary {
        session_id: summary.session_id.clone(),
        machine_id: summary.machine_id.clone(),
        agent_type: summary.agent_type.clone(),
        workspace_path: summary.workspace_path.clone(),
        title: summary.title.clone(),
        status: activity_status_to_wire(summary.status),
        latest_message_preview: summary.latest_message_preview.clone(),
        updated_at: summary.updated_at.clone(),
        avatar_seed: summary.avatar_seed.clone(),
        inventory_stale: summary.inventory_stale,
        connection_route: summary.connection_route.clone(),
    }
}

/// Map a wire summary from `host_device_id` into an API summary.
///
/// The returned id is namespaced (`peer:<host>:<session>`), the machine id is
/// the remote device id, and the connection route is explicitly `"mesh"`.
pub fn session_summary_from_wire(
    host_device_id: &str,
    summary: HostSessionSummary,
) -> SessionSummary {
    SessionSummary {
        session_id: prefix_remote_session_id(host_device_id, &summary.session_id),
        machine_id: host_device_id.to_string(),
        agent_type: summary.agent_type,
        workspace_path: summary.workspace_path,
        title: summary.title,
        status: activity_status_from_wire(summary.status),
        latest_message_preview: summary.latest_message_preview,
        updated_at: summary.updated_at,
        avatar_seed: summary.avatar_seed,
        inventory_stale: summary.inventory_stale,
        connection_route: Some("mesh".to_string()),
    }
}

/// Map a local turn into its wire mirror (callee side).
pub fn turn_to_wire(turn: &CanonicalTurn) -> HostSessionTurn {
    HostSessionTurn {
        turn_id: turn.turn_id.clone(),
        session_id: turn.session_id.clone(),
        turn_number: turn.turn_number,
        status: turn_status_to_wire(turn.status),
        created_at: turn.created_at.clone(),
        completed_at: turn.completed_at.clone(),
        assistant_text: turn.assistant_text.clone(),
    }
}

/// Map a wire turn into an API turn whose `session_id` is the namespaced id.
pub fn turn_from_wire(prefixed_session_id: &str, turn: HostSessionTurn) -> CanonicalTurn {
    CanonicalTurn {
        turn_id: turn.turn_id,
        session_id: prefixed_session_id.to_string(),
        turn_number: turn.turn_number,
        status: turn_status_from_wire(turn.status),
        created_at: turn.created_at,
        completed_at: turn.completed_at,
        assistant_text: turn.assistant_text,
    }
}

// ---------------------------------------------------------------------------
// Remote source trait
// ---------------------------------------------------------------------------

/// One remote Host that can serve session queries/actions.
///
/// Implementations receive the *target host's own* (unprefixed) session id and
/// return API DTOs whose session ids are namespaced with
/// [`REMOTE_SESSION_PREFIX`]. Transport failures must surface as
/// [`PharosApiError::BackendUnreachable`]; they must never be turned into an
/// empty result.
#[async_trait]
pub trait RemoteSessionSource: Send + Sync {
    /// Device id of the remote host this source speaks to.
    fn host_device_id(&self) -> &str;

    /// All sessions on the remote host, ids prefixed.
    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError>;

    /// One session on the remote host, id prefixed.
    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError>;

    /// Turn history of one remote session, turn ids prefixed.
    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError>;

    /// Send a message to a remote session; the returned turn id is prefixed.
    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError>;

    /// Steer a remote session.
    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError>;

    /// Resolve a pending approval on a remote session.
    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError>;
}

/// [`RemoteSessionSource`] over the mesh `host.session.query.v1` /
/// `host.session.action.v1` Peer RPC contract.
pub struct MeshRemoteHostSessionSource {
    replica: Arc<ReplicaHandle>,
    peer: PeerDial,
    host_device_id: String,
    timeout: Duration,
}

impl MeshRemoteHostSessionSource {
    /// `peer` is the dial target of `host_device_id`; `timeout` bounds one RPC.
    pub fn new(
        replica: Arc<ReplicaHandle>,
        peer: PeerDial,
        host_device_id: impl Into<String>,
        timeout: Duration,
    ) -> Self {
        Self {
            replica,
            peer,
            host_device_id: host_device_id.into(),
            timeout,
        }
    }

    pub fn replica(&self) -> &Arc<ReplicaHandle> {
        &self.replica
    }

    pub fn peer(&self) -> &PeerDial {
        &self.peer
    }

    pub fn timeout(&self) -> Duration {
        self.timeout
    }

    fn prefixed(&self, session_id: &str) -> String {
        prefix_remote_session_id(&self.host_device_id, session_id)
    }

    async fn query(
        &self,
        request: HostSessionQueryRequest,
        prefixed_session_id: Option<&str>,
    ) -> Result<HostSessionQueryResponse, PharosApiError> {
        self.replica
            .peer_host_session_query(self.peer.clone(), request, self.timeout)
            .await
            .map_err(|error| map_rpc_error(error, &self.host_device_id, prefixed_session_id))
    }

    async fn action(
        &self,
        request: HostSessionActionRequest,
        prefixed_session_id: &str,
    ) -> Result<HostSessionActionResponse, PharosApiError> {
        self.replica
            .peer_host_session_action(self.peer.clone(), request, self.timeout)
            .await
            .map_err(|error| map_rpc_error(error, &self.host_device_id, Some(prefixed_session_id)))
    }
}

#[async_trait]
impl RemoteSessionSource for MeshRemoteHostSessionSource {
    fn host_device_id(&self) -> &str {
        &self.host_device_id
    }

    async fn list_sessions(&self) -> Result<Vec<SessionSummary>, PharosApiError> {
        let request = HostSessionQueryRequest::list_sessions(&self.host_device_id);
        let response = self.query(request, None).await?;
        match response.data {
            HostSessionQueryData::Sessions { sessions } => Ok(sessions
                .into_iter()
                .map(|summary| session_summary_from_wire(&self.host_device_id, summary))
                .collect()),
            _ => Err(unexpected_query_data("listSessions")),
        }
    }

    async fn get_session(&self, session_id: &str) -> Result<SessionSummary, PharosApiError> {
        let prefixed = self.prefixed(session_id);
        let request =
            HostSessionQueryRequest::get_session(&self.host_device_id, session_id.to_string());
        let response = self.query(request, Some(&prefixed)).await?;
        match response.data {
            HostSessionQueryData::Session { session } => {
                Ok(session_summary_from_wire(&self.host_device_id, session))
            }
            _ => Err(unexpected_query_data("getSession")),
        }
    }

    async fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, PharosApiError> {
        let prefixed = self.prefixed(session_id);
        let request =
            HostSessionQueryRequest::session_history(&self.host_device_id, session_id.to_string());
        let response = self.query(request, Some(&prefixed)).await?;
        match response.data {
            HostSessionQueryData::History { turns } => Ok(turns
                .into_iter()
                .map(|turn| turn_from_wire(&prefixed, turn))
                .collect()),
            _ => Err(unexpected_query_data("sessionHistory")),
        }
    }

    async fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, PharosApiError> {
        let prefixed = self.prefixed(session_id);
        let action_id = Uuid::new_v4().to_string();
        // A caller-supplied request id is the natural idempotency key for a
        // retried HTTP request; otherwise the generated action id is unique.
        let idempotency_key = request
            .request_id
            .clone()
            .unwrap_or_else(|| action_id.clone());
        let wire = HostSessionActionRequest::new(
            action_id,
            self.host_device_id.clone(),
            session_id.to_string(),
            idempotency_key,
            HostSessionActionPayload::SendMessage {
                text: request.text,
                request_id: request.request_id,
            },
        );
        let response = self.action(wire, &prefixed).await?;
        let turn = response
            .turn
            .ok_or_else(|| PharosApiError::OperationFailed {
                message: format!(
                    "remote host {} reported no turn for the message",
                    self.host_device_id
                ),
            })?;
        Ok(turn_from_wire(&prefixed, turn))
    }

    async fn steer(
        &self,
        session_id: &str,
        request: SteerSessionRequest,
    ) -> Result<(), PharosApiError> {
        let prefixed = self.prefixed(session_id);
        let wire = HostSessionActionRequest::new(
            Uuid::new_v4().to_string(),
            self.host_device_id.clone(),
            session_id.to_string(),
            Uuid::new_v4().to_string(),
            HostSessionActionPayload::Steer { text: request.text },
        );
        self.action(wire, &prefixed).await?;
        Ok(())
    }

    async fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), PharosApiError> {
        let prefixed = self.prefixed(session_id);
        let wire = HostSessionActionRequest::new(
            Uuid::new_v4().to_string(),
            self.host_device_id.clone(),
            session_id.to_string(),
            Uuid::new_v4().to_string(),
            HostSessionActionPayload::ResolveApproval {
                approval_id: request.approval_id,
                decision: approval_decision_to_wire(request.decision),
            },
        );
        self.action(wire, &prefixed).await?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

/// Map a Peer RPC failure onto the frozen HTTP API error contract.
///
/// `prefixed_session_id` is the API-facing session id for queries that address
/// one session; it is used for `UnknownSession` so the 404 body names the id the
/// caller actually used.
pub(crate) fn map_rpc_error(
    error: ReplicaRpcError,
    host_device_id: &str,
    prefixed_session_id: Option<&str>,
) -> PharosApiError {
    match error {
        ReplicaRpcError::HostSession { code, message } => match code {
            HostSessionErrorCode::Unauthorized => PharosApiError::OperationFailed {
                message: format!("unauthorized: {message}"),
            },
            HostSessionErrorCode::UnknownSession => match prefixed_session_id {
                Some(id) => PharosApiError::SessionNotFound { id: id.to_string() },
                None => PharosApiError::OperationFailed {
                    message: format!("remote host reported unknown session: {message}"),
                },
            },
            HostSessionErrorCode::HostUnreachable => PharosApiError::BackendUnreachable {
                backend: host_device_id.to_string(),
                reason: message,
            },
            HostSessionErrorCode::AdapterUnavailable => PharosApiError::OperationFailed {
                message: format!("remote host adapter unavailable: {message}"),
            },
            HostSessionErrorCode::InvalidRequest => PharosApiError::InvalidRequest { message },
            HostSessionErrorCode::UnsupportedOperation => {
                let reason = if message.trim().is_empty() {
                    "this operation".to_string()
                } else {
                    message
                };
                PharosApiError::OperationFailed {
                    message: format!("remote host does not support {reason}"),
                }
            }
            HostSessionErrorCode::Internal => PharosApiError::OperationFailed {
                message: format!("remote host internal error: {message}"),
            },
        },
        ReplicaRpcError::Unauthorized(message) => PharosApiError::OperationFailed {
            message: format!("unauthorized: {message}"),
        },
        ReplicaRpcError::Unreachable(reason) => PharosApiError::BackendUnreachable {
            backend: host_device_id.to_string(),
            reason,
        },
        other => PharosApiError::OperationFailed {
            message: format!("remote host session rpc failed: {other}"),
        },
    }
}

fn unexpected_query_data(kind: &str) -> PharosApiError {
    PharosApiError::OperationFailed {
        message: format!("remote host returned unexpected query data for {kind}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::host_session::{
        HostSessionErrorCode, HostSessionQueryKind, HostSessionTurnStatus,
    };

    fn wire_summary() -> HostSessionSummary {
        HostSessionSummary {
            session_id: "s1".into(),
            machine_id: "host-b".into(),
            agent_type: "codex".into(),
            workspace_path: "/tmp/ws".into(),
            title: "Demo".into(),
            status: HostSessionActivityStatus::NeedsHuman,
            latest_message_preview: Some("hi".into()),
            updated_at: "2026-11-11T00:00:00Z".into(),
            avatar_seed: "seed".into(),
            inventory_stale: None,
            connection_route: Some("mesh".into()),
        }
    }

    fn wire_turn() -> HostSessionTurn {
        HostSessionTurn {
            turn_id: "t1".into(),
            session_id: "s1".into(),
            turn_number: 2,
            status: HostSessionTurnStatus::Completed,
            created_at: "2026-11-11T00:00:00Z".into(),
            completed_at: Some("2026-11-11T00:00:01Z".into()),
            assistant_text: vec!["hello".into()],
        }
    }

    #[test]
    fn remote_session_ids_roundtrip() {
        let id = remote_session_id("host-b", "s1");
        assert_eq!(id, "peer:host-b:s1");
        assert_eq!(split_remote_session_id(&id), Some(("host-b", "s1")));
        assert!(is_remote_session_id(&id));
    }

    #[test]
    fn split_keeps_colons_in_session_id() {
        assert_eq!(
            split_remote_session_id("peer:host-b:a:b"),
            Some(("host-b", "a:b"))
        );
    }

    #[test]
    fn split_rejects_malformed_and_local_ids() {
        assert_eq!(split_remote_session_id("local-session"), None);
        assert_eq!(split_remote_session_id("peer:"), None);
        assert_eq!(split_remote_session_id("peer:host-b"), None);
        assert_eq!(split_remote_session_id("peer::s1"), None);
        assert_eq!(split_remote_session_id("peer:host-b:"), None);
    }

    #[test]
    fn prefixing_is_idempotent() {
        let prefixed = remote_session_id("host-b", "s1");
        assert_eq!(prefix_remote_session_id("host-b", "s1"), prefixed);
        assert_eq!(prefix_remote_session_id("host-b", &prefixed), prefixed);
    }

    #[test]
    fn wire_summary_maps_to_remote_api_summary() {
        let summary = session_summary_from_wire("host-b", wire_summary());
        assert_eq!(summary.session_id, "peer:host-b:s1");
        assert_eq!(summary.machine_id, "host-b");
        assert_eq!(summary.status, SessionActivityStatus::NeedsHuman);
        assert_eq!(summary.connection_route.as_deref(), Some("mesh"));
        assert_eq!(summary.latest_message_preview.as_deref(), Some("hi"));
    }

    #[test]
    fn api_summary_maps_to_wire_mirror() {
        let summary = session_summary_from_wire("host-b", wire_summary());
        let wire = session_summary_to_wire(&summary);
        assert_eq!(wire.session_id, "peer:host-b:s1");
        assert_eq!(wire.status, HostSessionActivityStatus::NeedsHuman);
        assert_eq!(wire.connection_route.as_deref(), Some("mesh"));
    }

    #[test]
    fn wire_turn_maps_to_prefixed_api_turn() {
        let turn = turn_from_wire("peer:host-b:s1", wire_turn());
        assert_eq!(turn.turn_id, "t1");
        assert_eq!(turn.session_id, "peer:host-b:s1");
        assert_eq!(turn.turn_number, 2);
        assert_eq!(turn.status, TurnStatus::Completed);
        assert_eq!(turn.assistant_text, vec!["hello".to_string()]);

        let wire = turn_to_wire(&turn);
        assert_eq!(wire.session_id, "peer:host-b:s1");
        assert_eq!(wire.status, HostSessionTurnStatus::Completed);
    }

    #[test]
    fn all_statuses_roundtrip() {
        let activity = [
            SessionActivityStatus::Idle,
            SessionActivityStatus::Working,
            SessionActivityStatus::NeedsHuman,
            SessionActivityStatus::Stopped,
            SessionActivityStatus::Unknown,
        ];
        for status in activity {
            assert_eq!(
                activity_status_from_wire(activity_status_to_wire(status)),
                status
            );
        }
        let turns = [
            TurnStatus::InProgress,
            TurnStatus::Completed,
            TurnStatus::Failed,
            TurnStatus::Cancelled,
            TurnStatus::NeedsHuman,
        ];
        for status in turns {
            assert_eq!(turn_status_from_wire(turn_status_to_wire(status)), status);
        }
        let decisions = [
            ApprovalDecision::AllowedOnce,
            ApprovalDecision::AllowedAlways,
            ApprovalDecision::Rejected,
        ];
        for decision in decisions {
            assert_eq!(
                approval_decision_from_wire(approval_decision_to_wire(decision)),
                decision
            );
        }
    }

    #[test]
    fn unauthorized_maps_to_operation_failed_with_prefix() {
        let mapped = map_rpc_error(
            ReplicaRpcError::HostSession {
                code: HostSessionErrorCode::Unauthorized,
                message: "peer is not in this host's paired allowlist".into(),
            },
            "host-b",
            None,
        );
        match mapped {
            PharosApiError::OperationFailed { message } => {
                assert!(message.starts_with("unauthorized: "), "{message}");
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
    }

    #[test]
    fn unknown_session_maps_to_prefixed_session_not_found() {
        let mapped = map_rpc_error(
            ReplicaRpcError::HostSession {
                code: HostSessionErrorCode::UnknownSession,
                message: "unknown session: s1".into(),
            },
            "host-b",
            Some("peer:host-b:s1"),
        );
        assert_eq!(
            mapped,
            PharosApiError::SessionNotFound {
                id: "peer:host-b:s1".into()
            }
        );
    }

    #[test]
    fn unreachable_and_host_unreachable_map_to_backend_unreachable() {
        let mapped = map_rpc_error(
            ReplicaRpcError::Unreachable("timeout waiting for peer".into()),
            "host-b",
            None,
        );
        assert_eq!(
            mapped,
            PharosApiError::BackendUnreachable {
                backend: "host-b".into(),
                reason: "timeout waiting for peer".into(),
            }
        );
        let mapped = map_rpc_error(
            ReplicaRpcError::HostSession {
                code: HostSessionErrorCode::HostUnreachable,
                message: "host offline".into(),
            },
            "host-b",
            None,
        );
        assert!(matches!(mapped, PharosApiError::BackendUnreachable { .. }));
    }

    #[test]
    fn adapter_invalid_and_unsupported_errors_map_explicitly() {
        let map = |code, message: &str| {
            map_rpc_error(
                ReplicaRpcError::HostSession {
                    code,
                    message: message.into(),
                },
                "host-b",
                None,
            )
        };

        match map(HostSessionErrorCode::AdapterUnavailable, "no codex") {
            PharosApiError::OperationFailed { message } => {
                assert_eq!(message, "remote host adapter unavailable: no codex")
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        assert_eq!(
            map(HostSessionErrorCode::InvalidRequest, "bad payload"),
            PharosApiError::InvalidRequest {
                message: "bad payload".into()
            }
        );
        match map(HostSessionErrorCode::UnsupportedOperation, "session stop") {
            PharosApiError::OperationFailed { message } => assert!(
                message.starts_with("remote host does not support"),
                "{message}"
            ),
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        match map(HostSessionErrorCode::Internal, "boom") {
            PharosApiError::OperationFailed { message } => {
                assert!(message.contains("remote host internal error"), "{message}")
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
    }

    #[test]
    fn other_rpc_errors_are_operation_failed() {
        let mapped = map_rpc_error(ReplicaRpcError::Invalid("bad rpc".into()), "host-b", None);
        assert!(matches!(mapped, PharosApiError::OperationFailed { .. }));
    }

    #[test]
    fn unexpected_query_data_names_the_kind() {
        let error = unexpected_query_data("listSessions");
        match error {
            PharosApiError::OperationFailed { message } => {
                assert!(message.contains("listSessions"), "{message}")
            }
            other => panic!("expected OperationFailed, got {other:?}"),
        }
        // Query kind helper strings stay aligned with the wire contract.
        assert_eq!(
            HostSessionQueryRequest::list_sessions("host-b").query_kind,
            HostSessionQueryKind::ListSessions
        );
    }
}
