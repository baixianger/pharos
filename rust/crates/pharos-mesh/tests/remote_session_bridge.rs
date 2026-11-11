//! Integration: caller-side [`MeshRemoteHostSessionSource`] against a real
//! callee host serving [`SessionServiceHostHandler`] over loopback iroh.
//!
//! Covers the full cross-host Rust path with the production bridge types:
//! A lists/reads/acts on B's sessions, B's local `SessionService` receives the
//! actions, ids are namespaced `peer:<host>:<session>`, an offline B is an
//! explicit `BackendUnreachable` and a host without a live adapter reports the
//! adapter-unavailable error instead of a fake success.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pharos_api::{
    ApprovalDecision, CanonicalTurn, ResolveApprovalRequest, SendSessionMessageRequest,
    SessionActivityStatus, SessionProgress, SessionSummary, SteerSessionRequest, TurnStatus,
};
use pharos_mesh::{
    MeshNodeIdentity, PeerDial, ReplicaHandle, ReplicaHandleConfig, init_node, open_handle,
};
use pharos_session::{
    MeshRemoteHostSessionSource, RemoteSessionSource, SessionError, SessionService,
    SessionServiceHostHandler,
};
use tempfile::{TempDir, tempdir};

const LOCAL_SESSION: &str = "s1";

#[derive(Debug, Clone, PartialEq)]
enum RecordedAction {
    Send(String),
    Steer(String),
    Approval(String, ApprovalDecision),
}

/// Local `SessionService` standing in for a real vendor-backed host service.
struct FakeLocalService {
    sessions: Vec<SessionSummary>,
    turns: Vec<CanonicalTurn>,
    actions: Mutex<Vec<RecordedAction>>,
    adapter_unavailable: bool,
}

impl FakeLocalService {
    fn new(fail_adapter: bool) -> Self {
        Self {
            sessions: vec![session_summary()],
            turns: vec![turn("t1", 1, "first"), turn("t2", 2, "second")],
            actions: Mutex::new(Vec::new()),
            adapter_unavailable: fail_adapter,
        }
    }

    fn actions(&self) -> Vec<RecordedAction> {
        self.actions.lock().unwrap().clone()
    }

    fn record(&self, action: RecordedAction) {
        self.actions.lock().unwrap().push(action);
    }
}

impl SessionService for FakeLocalService {
    fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
        Ok(self.sessions.clone())
    }

    fn get_session(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
        self.sessions
            .iter()
            .find(|session| session.session_id == session_id)
            .cloned()
            .ok_or_else(|| SessionError::new(format!("session not found: {session_id}")))
    }

    fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError> {
        let _ = self.get_session(session_id)?;
        Ok(self.turns.clone())
    }

    fn start_session(
        &self,
        _workspace_path: &str,
        _mode: Option<&str>,
    ) -> Result<SessionSummary, SessionError> {
        Err(SessionError::Adapter(
            "session creation is not supported by this fake host".into(),
        ))
    }

    fn send_message(
        &self,
        session_id: &str,
        request: SendSessionMessageRequest,
    ) -> Result<CanonicalTurn, SessionError> {
        let _ = self.get_session(session_id)?;
        if self.adapter_unavailable {
            return Err(SessionError::Adapter(
                "no live vendor session adapter configured".into(),
            ));
        }
        self.record(RecordedAction::Send(request.text));
        Ok(turn("t3", 3, "remote reply"))
    }

    fn steer(&self, session_id: &str, request: SteerSessionRequest) -> Result<(), SessionError> {
        let _ = self.get_session(session_id)?;
        self.record(RecordedAction::Steer(request.text));
        Ok(())
    }

    fn resolve_approval(
        &self,
        session_id: &str,
        request: ResolveApprovalRequest,
    ) -> Result<(), SessionError> {
        let _ = self.get_session(session_id)?;
        self.record(RecordedAction::Approval(
            request.approval_id,
            request.decision,
        ));
        Ok(())
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

fn session_summary() -> SessionSummary {
    SessionSummary {
        session_id: LOCAL_SESSION.into(),
        machine_id: "host-b".into(),
        agent_type: "codex".into(),
        workspace_path: "/tmp/ws".into(),
        title: "B session".into(),
        status: SessionActivityStatus::Idle,
        latest_message_preview: Some("hello".into()),
        updated_at: "2026-11-11T00:00:00Z".into(),
        avatar_seed: "seed".into(),
        inventory_stale: None,
        connection_route: None,
    }
}

fn turn(turn_id: &str, number: u32, text: &str) -> CanonicalTurn {
    CanonicalTurn {
        turn_id: turn_id.into(),
        session_id: LOCAL_SESSION.into(),
        turn_number: number,
        status: TurnStatus::Completed,
        created_at: "2026-11-11T00:00:00Z".into(),
        completed_at: Some("2026-11-11T00:00:01Z".into()),
        assistant_text: vec![text.into()],
    }
}

struct HostPair {
    _root: TempDir,
    host_identity: MeshNodeIdentity,
    host: Arc<ReplicaHandle>,
    client: Arc<ReplicaHandle>,
}

fn host_config(
    data_dir: std::path::PathBuf,
    identity: &MeshNodeIdentity,
    service: Arc<dyn SessionService>,
) -> ReplicaHandleConfig {
    ReplicaHandleConfig {
        data_dir,
        device_id: identity.device_id.clone(),
        trust_group_id: identity.trust_group_id.clone(),
        membership_epoch: identity.membership_epoch,
        runtime_socket: None,
        relay_disabled: true,
        host_session_handler: Some(Arc::new(SessionServiceHostHandler::new(service))),
        allowed_peer_endpoint_ids: None,
    }
}

fn join_trust_group(client_dir: &Path, host: &MeshNodeIdentity) -> MeshNodeIdentity {
    let (mut identity, _) = init_node(client_dir, "peer").expect("init client");
    identity.trust_group_id = host.trust_group_id.clone();
    identity.membership_epoch = host.membership_epoch;
    std::fs::write(
        client_dir.join("node-identity.json"),
        serde_json::to_vec_pretty(&identity).expect("identity json"),
    )
    .expect("rewrite identity");
    identity
}

async fn host_pair(service: Arc<dyn SessionService>) -> HostPair {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let client_dir = root.path().join("client");
    let host_identity = init_node(&host_dir, "host").expect("init host").0;
    join_trust_group(&client_dir, &host_identity);

    let host = ReplicaHandle::open(host_config(host_dir, &host_identity, service))
        .await
        .expect("host open");
    let client = open_handle(client_dir, None, true)
        .await
        .expect("client open");
    tokio::time::sleep(Duration::from_millis(300)).await;
    HostPair {
        _root: root,
        host_identity,
        host,
        client,
    }
}

fn dial(host: &ReplicaHandle) -> PeerDial {
    PeerDial {
        endpoint_id: host.endpoint_id(),
        addr: Some(host.endpoint_addr()),
    }
}

#[tokio::test]
async fn remote_source_queries_and_actions_local_host_service() {
    let service = Arc::new(FakeLocalService::new(false));
    let pair = host_pair(service.clone()).await;
    let source = MeshRemoteHostSessionSource::new(
        Arc::clone(&pair.client),
        dial(&pair.host),
        pair.host_identity.device_id.clone(),
        Duration::from_secs(15),
    );
    assert_eq!(source.host_device_id(), pair.host_identity.device_id);
    let prefixed = pharos_session::remote_session_id(&pair.host_identity.device_id, LOCAL_SESSION);

    // List: the remote session is merged with a host-namespaced id.
    let sessions = source.list_sessions().await.expect("remote list");
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, prefixed);
    assert_eq!(sessions[0].machine_id, pair.host_identity.device_id);
    assert_eq!(sessions[0].connection_route.as_deref(), Some("mesh"));
    assert_eq!(sessions[0].title, "B session");

    // Get one session.
    let session = source.get_session(LOCAL_SESSION).await.expect("remote get");
    assert_eq!(session.session_id, prefixed);

    // History turns carry the namespaced session id.
    let turns = source
        .list_history(LOCAL_SESSION)
        .await
        .expect("remote history");
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[0].session_id, prefixed);
    assert_eq!(turns[1].assistant_text, vec!["second".to_string()]);

    // Unknown session maps to an explicit not-found error.
    match source.get_session("missing").await {
        Err(pharos_api::PharosApiError::SessionNotFound { id }) => {
            assert_eq!(
                id,
                pharos_session::remote_session_id(&pair.host_identity.device_id, "missing")
            );
        }
        other => panic!("expected session not found, got {other:?}"),
    }

    // Send reaches B's local service; the returned turn is namespaced.
    let sent = source
        .send_message(
            LOCAL_SESSION,
            SendSessionMessageRequest {
                text: "hello over mesh".into(),
                request_id: Some("req-1".into()),
            },
        )
        .await
        .expect("remote send");
    assert_eq!(sent.session_id, prefixed);
    assert_eq!(sent.turn_id, "t3");
    assert_eq!(
        service.actions(),
        vec![RecordedAction::Send("hello over mesh".into())]
    );

    // Retrying the same request id replays the idempotent action end-to-end,
    // so B must not receive it twice.
    let retried = source
        .send_message(
            LOCAL_SESSION,
            SendSessionMessageRequest {
                text: "hello over mesh".into(),
                request_id: Some("req-1".into()),
            },
        )
        .await
        .expect("remote send retry");
    assert_eq!(retried.turn_id, "t3");
    assert_eq!(service.actions().len(), 1, "retry must not reach B twice");

    // Steer and approval decisions are forwarded.
    source
        .steer(
            LOCAL_SESSION,
            SteerSessionRequest {
                text: "focus".into(),
            },
        )
        .await
        .expect("remote steer");
    source
        .resolve_approval(
            LOCAL_SESSION,
            ResolveApprovalRequest {
                approval_id: "approval-1".into(),
                decision: ApprovalDecision::AllowedOnce,
            },
        )
        .await
        .expect("remote approval");
    assert_eq!(
        service.actions(),
        vec![
            RecordedAction::Send("hello over mesh".into()),
            RecordedAction::Steer("focus".into()),
            RecordedAction::Approval("approval-1".into(), ApprovalDecision::AllowedOnce),
        ]
    );
}

#[tokio::test]
async fn adapter_unavailable_host_reports_explicit_error() {
    let service = Arc::new(FakeLocalService::new(true));
    let pair = host_pair(service).await;
    let source = MeshRemoteHostSessionSource::new(
        Arc::clone(&pair.client),
        dial(&pair.host),
        pair.host_identity.device_id.clone(),
        Duration::from_secs(15),
    );

    let error = source
        .send_message(
            LOCAL_SESSION,
            SendSessionMessageRequest {
                text: "hello".into(),
                request_id: None,
            },
        )
        .await
        .expect_err("adapter-unavailable host must not fake a success");
    match error {
        pharos_api::PharosApiError::OperationFailed { message } => {
            assert!(
                message.contains("adapter unavailable"),
                "unexpected message: {message}"
            );
        }
        other => panic!("expected operation failed, got {other:?}"),
    }
}

#[tokio::test]
async fn offline_host_is_backend_unreachable() {
    let service = Arc::new(FakeLocalService::new(false));
    let pair = host_pair(service).await;
    let source = MeshRemoteHostSessionSource::new(
        Arc::clone(&pair.client),
        dial(&pair.host),
        pair.host_identity.device_id.clone(),
        Duration::from_secs(3),
    );

    pair.host.shutdown().await.expect("shutdown host");
    let error = source
        .list_sessions()
        .await
        .expect_err("offline host must not return an empty list");
    match error {
        pharos_api::PharosApiError::BackendUnreachable { backend, .. } => {
            assert_eq!(backend, pair.host_identity.device_id);
        }
        other => panic!("expected backend unreachable, got {other:?}"),
    }
}
