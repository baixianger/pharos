//! Callee-side bridge: serve cross-host session queries/actions from the local
//! synchronous [`crate::SessionService`].
//!
//! [`SessionServiceHostHandler`] is the [`pharos_replica::HostSessionHandler`]
//! an application (agent-runtime mesh bring-up) installs on its
//! [`pharos_replica::ReplicaHandle`]. It only forwards to the local service: the
//! replica layer owns transport, trust-group/epoch checks, the paired-peer
//! allowlist and action replay protection.
//!
//! Honesty rules:
//! - `stop` is not implemented by this host; it answers
//!   [`HostSessionFault::Unsupported`] — never a fabricated success.
//! - Local adapter failures are reported as
//!   [`HostSessionFault::AdapterUnavailable`], unknown sessions as
//!   [`HostSessionFault::UnknownSession`]; everything else is `Internal`.

use std::sync::Arc;

use pharos_api::{ResolveApprovalRequest, SendSessionMessageRequest, SteerSessionRequest};
use pharos_protocol::host_session::{
    HostSessionActionRequest, HostSessionActionResponse, HostSessionQueryData,
    HostSessionQueryKind, HostSessionQueryRequest, HostSessionQueryResponse,
};
use pharos_replica::{HostSessionFault, HostSessionHandler};

use crate::remote::{approval_decision_from_wire, session_summary_to_wire, turn_to_wire};
use crate::{SessionError, SessionService};

/// Serves `host.session.query.v1` / `host.session.action.v1` from a local
/// [`SessionService`].
///
/// Both trait methods are synchronous because the local service is
/// synchronous; the handler must not perform network I/O.
pub struct SessionServiceHostHandler {
    service: Arc<dyn SessionService>,
}

impl SessionServiceHostHandler {
    /// Build a handler over a shared local session service. The application
    /// keeps ownership of the service and installs this handler on the
    /// replica handle (see [`pharos_replica::ReplicaHandleConfig`]).
    pub fn new(service: Arc<dyn SessionService>) -> Self {
        Self { service }
    }

    /// The wrapped local session service.
    pub fn service(&self) -> &Arc<dyn SessionService> {
        &self.service
    }
}

impl HostSessionHandler for SessionServiceHostHandler {
    fn query(
        &self,
        request: HostSessionQueryRequest,
    ) -> Result<HostSessionQueryResponse, HostSessionFault> {
        let host_device_id = request.host_device_id.clone();
        match request.query_kind {
            HostSessionQueryKind::ListSessions => {
                let sessions = self.service.list_sessions().map_err(map_session_error)?;
                Ok(HostSessionQueryResponse::new(
                    host_device_id,
                    HostSessionQueryKind::ListSessions,
                    HostSessionQueryData::Sessions {
                        sessions: sessions.iter().map(session_summary_to_wire).collect(),
                    },
                ))
            }
            HostSessionQueryKind::GetSession => {
                let session_id = request.session_id.as_deref().ok_or_else(|| {
                    HostSessionFault::InvalidRequest("sessionId is required for getSession".into())
                })?;
                let summary = self
                    .service
                    .get_session(session_id)
                    .map_err(map_session_error)?;
                Ok(HostSessionQueryResponse::new(
                    host_device_id,
                    HostSessionQueryKind::GetSession,
                    HostSessionQueryData::Session {
                        session: session_summary_to_wire(&summary),
                    },
                ))
            }
            HostSessionQueryKind::SessionHistory => {
                let session_id = request.session_id.as_deref().ok_or_else(|| {
                    HostSessionFault::InvalidRequest(
                        "sessionId is required for sessionHistory".into(),
                    )
                })?;
                let turns = self
                    .service
                    .list_history(session_id)
                    .map_err(map_session_error)?;
                Ok(HostSessionQueryResponse::new(
                    host_device_id,
                    HostSessionQueryKind::SessionHistory,
                    HostSessionQueryData::History {
                        turns: turns.iter().map(turn_to_wire).collect(),
                    },
                ))
            }
        }
    }

    fn action(
        &self,
        request: HostSessionActionRequest,
    ) -> Result<HostSessionActionResponse, HostSessionFault> {
        let mut response = HostSessionActionResponse::new(
            request.action_id.clone(),
            request.host_device_id.clone(),
            request.session_id.clone(),
        );
        match request.action {
            pharos_protocol::host_session::HostSessionActionPayload::SendMessage {
                text,
                request_id,
            } => {
                let turn = self
                    .service
                    .send_message(
                        &request.session_id,
                        SendSessionMessageRequest { text, request_id },
                    )
                    .map_err(map_session_error)?;
                response = response.with_turn(turn_to_wire(&turn));
            }
            pharos_protocol::host_session::HostSessionActionPayload::Steer { text } => {
                self.service
                    .steer(&request.session_id, SteerSessionRequest { text })
                    .map_err(map_session_error)?;
            }
            pharos_protocol::host_session::HostSessionActionPayload::ResolveApproval {
                approval_id,
                decision,
            } => {
                self.service
                    .resolve_approval(
                        &request.session_id,
                        ResolveApprovalRequest {
                            approval_id,
                            decision: approval_decision_from_wire(decision),
                        },
                    )
                    .map_err(map_session_error)?;
            }
            pharos_protocol::host_session::HostSessionActionPayload::Stop { .. } => {
                // This host cannot stop sessions over the wire. An explicit
                // unsupported error is correct; a fabricated success is not.
                return Err(HostSessionFault::Unsupported(
                    "session stop is not supported by this host".into(),
                ));
            }
        }
        Ok(response)
    }
}

/// Map a local session failure onto the explicit cross-host fault surface.
pub fn map_session_error(error: SessionError) -> HostSessionFault {
    match error {
        SessionError::Adapter(message) => HostSessionFault::AdapterUnavailable(message),
        SessionError::Message(message) => match message.strip_prefix("session not found: ") {
            Some(id) => HostSessionFault::UnknownSession(id.trim().to_string()),
            None => HostSessionFault::Internal(message),
        },
        other => HostSessionFault::Internal(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::sync::Mutex;

    use pharos_api::{
        CanonicalTurn, ResolveApprovalRequest, SendSessionMessageRequest, SessionActivityStatus,
        SessionProgress, SessionSummary, SteerSessionRequest, TurnStatus,
    };
    use pharos_protocol::host_session::{
        HostApprovalDecision, HostSessionActionKind, HostSessionActionPayload,
        HostSessionActivityStatus, HostSessionErrorCode, HostSessionQueryKind,
    };

    use super::*;

    /// Minimal in-memory local service; steer is configurable to fail the way a
    /// `dyn SessionAdapter` failure surfaces (`SessionError::Adapter`).
    struct FakeService {
        sessions: Mutex<HashMap<String, SessionSummary>>,
        history: Mutex<HashMap<String, Vec<CanonicalTurn>>>,
        steer_adapter_error: Option<String>,
    }

    impl FakeService {
        fn new() -> Self {
            let summary = SessionSummary {
                session_id: "s1".into(),
                machine_id: "local-host".into(),
                agent_type: "codex".into(),
                workspace_path: "/tmp/ws".into(),
                title: "Demo".into(),
                status: SessionActivityStatus::Idle,
                latest_message_preview: Some("hi".into()),
                updated_at: "2026-11-11T00:00:00Z".into(),
                avatar_seed: "seed".into(),
                inventory_stale: None,
                connection_route: Some("local".into()),
            };
            let mut sessions = HashMap::new();
            sessions.insert("s1".to_string(), summary);
            let mut history = HashMap::new();
            history.insert(
                "s1".to_string(),
                vec![CanonicalTurn {
                    turn_id: "t1".into(),
                    session_id: "s1".into(),
                    turn_number: 1,
                    status: TurnStatus::Completed,
                    created_at: "2026-11-11T00:00:00Z".into(),
                    completed_at: None,
                    assistant_text: vec!["hello".into()],
                }],
            );
            Self {
                sessions: Mutex::new(sessions),
                history: Mutex::new(history),
                steer_adapter_error: None,
            }
        }

        fn with_steer_adapter_error(mut self, message: &str) -> Self {
            self.steer_adapter_error = Some(message.into());
            self
        }
    }

    impl SessionService for FakeService {
        fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
            Ok(self.sessions.lock().unwrap().values().cloned().collect())
        }

        fn get_session(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
            self.sessions
                .lock()
                .unwrap()
                .get(session_id)
                .cloned()
                .ok_or_else(|| SessionError::new(format!("session not found: {session_id}")))
        }

        fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError> {
            self.history
                .lock()
                .unwrap()
                .get(session_id)
                .cloned()
                .ok_or_else(|| SessionError::new(format!("session not found: {session_id}")))
        }

        fn start_session(
            &self,
            _workspace_path: &str,
            _mode: Option<&str>,
        ) -> Result<SessionSummary, SessionError> {
            Err(SessionError::new("start_session not supported in fake"))
        }

        fn send_message(
            &self,
            session_id: &str,
            request: SendSessionMessageRequest,
        ) -> Result<CanonicalTurn, SessionError> {
            let mut history = self.history.lock().unwrap();
            if !self.sessions.lock().unwrap().contains_key(session_id) {
                return Err(SessionError::new(format!(
                    "session not found: {session_id}"
                )));
            }
            let turns = history.entry(session_id.to_string()).or_default();
            let turn = CanonicalTurn {
                turn_id: format!("turn-{}", turns.len() + 1),
                session_id: session_id.to_string(),
                turn_number: turns.len() as u32 + 1,
                status: TurnStatus::Completed,
                created_at: "2026-11-11T00:00:01Z".into(),
                completed_at: Some("2026-11-11T00:00:01Z".into()),
                assistant_text: vec![format!("echo: {}", request.text)],
            };
            turns.push(turn.clone());
            Ok(turn)
        }

        fn steer(
            &self,
            session_id: &str,
            _request: SteerSessionRequest,
        ) -> Result<(), SessionError> {
            if let Some(message) = &self.steer_adapter_error {
                return Err(SessionError::Adapter(message.clone()));
            }
            if !self.sessions.lock().unwrap().contains_key(session_id) {
                return Err(SessionError::new(format!(
                    "session not found: {session_id}"
                )));
            }
            Ok(())
        }

        fn resolve_approval(
            &self,
            _session_id: &str,
            _request: ResolveApprovalRequest,
        ) -> Result<(), SessionError> {
            Err(SessionError::new(
                "resolve_approval via SessionAdapter not supported yet",
            ))
        }

        fn progress(&self, _session_id: &str) -> Result<SessionProgress, SessionError> {
            Ok(SessionProgress {
                goal: None,
                todos: Vec::new(),
            })
        }

        fn set_progress(
            &self,
            _session_id: &str,
            progress: &SessionProgress,
        ) -> Result<SessionProgress, SessionError> {
            Ok(progress.clone())
        }
    }

    fn handler() -> SessionServiceHostHandler {
        SessionServiceHostHandler::new(Arc::new(FakeService::new()))
    }

    fn query_request(
        kind: HostSessionQueryKind,
        session_id: Option<&str>,
    ) -> HostSessionQueryRequest {
        HostSessionQueryRequest {
            payload_version: pharos_protocol::host_session::QUERY_VERSION,
            host_device_id: "host-b".into(),
            query_kind: kind,
            session_id: session_id.map(str::to_string),
        }
    }

    fn action_request(action: HostSessionActionPayload) -> HostSessionActionRequest {
        HostSessionActionRequest::new("action-1", "host-b", "s1", "idem-1", action)
    }

    #[test]
    fn query_list_carries_host_id_and_wire_summaries() {
        let handler = handler();
        let response = handler
            .query(query_request(HostSessionQueryKind::ListSessions, None))
            .unwrap();
        assert_eq!(response.host_device_id, "host-b");
        assert_eq!(response.query_kind, HostSessionQueryKind::ListSessions);
        let HostSessionQueryData::Sessions { sessions } = response.data else {
            panic!("expected sessions");
        };
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "s1");
        assert_eq!(sessions[0].machine_id, "local-host");
        assert_eq!(sessions[0].status, HostSessionActivityStatus::Idle);
    }

    #[test]
    fn query_get_and_history_roundtrip() {
        let handler = handler();
        let response = handler
            .query(query_request(HostSessionQueryKind::GetSession, Some("s1")))
            .unwrap();
        let HostSessionQueryData::Session { session } = response.data else {
            panic!("expected session");
        };
        assert_eq!(session.session_id, "s1");

        let response = handler
            .query(query_request(
                HostSessionQueryKind::SessionHistory,
                Some("s1"),
            ))
            .unwrap();
        let HostSessionQueryData::History { turns } = response.data else {
            panic!("expected history");
        };
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].turn_id, "t1");
        assert_eq!(turns[0].assistant_text, vec!["hello".to_string()]);
    }

    #[test]
    fn unknown_session_is_explicit_unknown_session_fault() {
        let handler = handler();
        let fault = handler
            .query(query_request(
                HostSessionQueryKind::GetSession,
                Some("missing"),
            ))
            .unwrap_err();
        assert_eq!(fault.code(), HostSessionErrorCode::UnknownSession);
        assert_eq!(fault.message(), "missing");
    }

    #[test]
    fn missing_session_id_is_invalid_request() {
        let handler = handler();
        let fault = handler
            .query(query_request(HostSessionQueryKind::GetSession, None))
            .unwrap_err();
        assert_eq!(fault.code(), HostSessionErrorCode::InvalidRequest);
    }

    #[test]
    fn send_message_action_returns_turn_and_host_id() {
        let handler = handler();
        let response = handler
            .action(action_request(HostSessionActionPayload::SendMessage {
                text: "hello".into(),
                request_id: Some("req-1".into()),
            }))
            .unwrap();
        assert_eq!(response.action_id, "action-1");
        assert_eq!(response.host_device_id, "host-b");
        assert_eq!(response.session_id, "s1");
        let turn = response.turn.expect("sendMessage must report a turn");
        assert_eq!(turn.session_id, "s1");
        assert_eq!(turn.assistant_text, vec!["echo: hello".to_string()]);

        let response = handler
            .action(action_request(HostSessionActionPayload::Steer {
                text: "focus".into(),
            }))
            .unwrap();
        assert!(response.turn.is_none());
        assert_eq!(response.host_device_id, "host-b");
    }

    #[test]
    fn stop_is_unsupported_never_success() {
        let handler = handler();
        let fault = handler
            .action(action_request(HostSessionActionPayload::Stop {
                force: true,
            }))
            .unwrap_err();
        assert_eq!(fault.code(), HostSessionErrorCode::UnsupportedOperation);
        assert!(fault.message().contains("stop is not supported"));
    }

    #[test]
    fn adapter_failure_maps_to_adapter_unavailable() {
        let handler = SessionServiceHostHandler::new(Arc::new(
            FakeService::new().with_steer_adapter_error("no live codex adapter"),
        ));
        let fault = handler
            .action(action_request(HostSessionActionPayload::Steer {
                text: "focus".into(),
            }))
            .unwrap_err();
        assert_eq!(fault.code(), HostSessionErrorCode::AdapterUnavailable);
        assert_eq!(fault.message(), "no live codex adapter");
    }

    #[test]
    fn non_adapter_local_failure_is_internal() {
        let handler = handler();
        let fault = handler
            .action(action_request(HostSessionActionPayload::ResolveApproval {
                approval_id: "a1".into(),
                decision: HostApprovalDecision::AllowedOnce,
            }))
            .unwrap_err();
        assert_eq!(fault.code(), HostSessionErrorCode::Internal);
    }

    #[test]
    fn action_kind_is_derived_from_payload() {
        let request = action_request(HostSessionActionPayload::Steer { text: "x".into() });
        assert_eq!(request.kind(), HostSessionActionKind::Steer);
    }

    #[test]
    fn map_session_error_covers_all_variants() {
        assert_eq!(
            map_session_error(SessionError::Adapter("boom".into())).code(),
            HostSessionErrorCode::AdapterUnavailable
        );
        assert_eq!(
            map_session_error(SessionError::Message("session not found: s9".into())).code(),
            HostSessionErrorCode::UnknownSession
        );
        assert_eq!(
            map_session_error(SessionError::Message("other".into())).code(),
            HostSessionErrorCode::Internal
        );
        assert_eq!(
            map_session_error(SessionError::new("other")).code(),
            HostSessionErrorCode::Internal
        );
    }
}
