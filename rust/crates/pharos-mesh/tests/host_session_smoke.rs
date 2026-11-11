//! Integration: cross-host session query/action over loopback iroh.
//!
//! Two in-process Hosts (`A` caller, `B` callee) exchange
//! `host.session.query.v1` / `host.session.action.v1` on the real iroh
//! transport:
//!
//! - A lists B's sessions, reads history and sends a message that B receives;
//! - a peer outside B's paired allowlist is rejected with `unauthorized`;
//! - a peer in another trust group is rejected;
//! - a stopped B is reported as `unreachable`, never as an empty success;
//! - a retried action with the same idempotency key is not performed twice.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use pharos_mesh::{
    HostSessionFault, HostSessionHandler, MeshNodeIdentity, PeerDial, ReplicaHandle,
    ReplicaHandleConfig, init_node, open_handle,
};
use pharos_protocol::host_session::{
    ACTION_CAPABILITY, HostApprovalDecision, HostSessionActionPayload, HostSessionActionRequest,
    HostSessionActivityStatus, HostSessionErrorCode, HostSessionQueryData, HostSessionQueryKind,
    HostSessionQueryRequest, HostSessionQueryResponse, HostSessionSummary, HostSessionTurn,
    HostSessionTurnStatus, QUERY_CAPABILITY,
};
use pharos_replica::ReplicaRpcError;
use tempfile::tempdir;

const TARGET_SESSION: &str = "b-session-1";

/// In-test callee: a recording `HostSessionHandler` standing in for the local
/// SessionService. Records received actions so B-side delivery is asserted.
#[derive(Default)]
struct RecordingHostSessions {
    sessions: Vec<HostSessionSummary>,
    turns: Vec<HostSessionTurn>,
    actions: Mutex<Vec<HostSessionActionRequest>>,
}

impl RecordingHostSessions {
    fn new() -> Self {
        Self {
            sessions: vec![summary(TARGET_SESSION)],
            turns: vec![
                turn("turn-1", TARGET_SESSION, 1, "first"),
                turn("turn-2", TARGET_SESSION, 2, "second"),
            ],
            actions: Mutex::new(Vec::new()),
        }
    }

    fn received(&self) -> Vec<HostSessionActionRequest> {
        self.actions.lock().unwrap().clone()
    }
}

impl HostSessionHandler for RecordingHostSessions {
    fn query(
        &self,
        request: HostSessionQueryRequest,
    ) -> Result<HostSessionQueryResponse, HostSessionFault> {
        let host = request.host_device_id.clone();
        match request.query_kind {
            HostSessionQueryKind::ListSessions => Ok(HostSessionQueryResponse::new(
                host,
                request.query_kind,
                HostSessionQueryData::Sessions {
                    sessions: self.sessions.clone(),
                },
            )),
            HostSessionQueryKind::GetSession => {
                let session_id = request.session_id.unwrap_or_default();
                let session = self
                    .sessions
                    .iter()
                    .find(|session| session.session_id == session_id)
                    .cloned()
                    .ok_or_else(|| HostSessionFault::UnknownSession(session_id))?;
                Ok(HostSessionQueryResponse::new(
                    host,
                    request.query_kind,
                    HostSessionQueryData::Session { session },
                ))
            }
            HostSessionQueryKind::SessionHistory => {
                let session_id = request.session_id.unwrap_or_default();
                if session_id != TARGET_SESSION {
                    return Err(HostSessionFault::UnknownSession(session_id));
                }
                Ok(HostSessionQueryResponse::new(
                    host,
                    request.query_kind,
                    HostSessionQueryData::History {
                        turns: self.turns.clone(),
                    },
                ))
            }
        }
    }

    fn action(
        &self,
        request: HostSessionActionRequest,
    ) -> Result<pharos_protocol::host_session::HostSessionActionResponse, HostSessionFault> {
        if request.session_id != TARGET_SESSION {
            return Err(HostSessionFault::UnknownSession(request.session_id));
        }
        let mut response = pharos_protocol::host_session::HostSessionActionResponse::new(
            &request.action_id,
            &request.host_device_id,
            &request.session_id,
        );
        match &request.action {
            HostSessionActionPayload::SendMessage { .. } => {
                self.actions.lock().unwrap().push(request);
                response = response.with_turn(turn("turn-3", TARGET_SESSION, 3, "new"));
                Ok(response)
            }
            HostSessionActionPayload::Steer { .. }
            | HostSessionActionPayload::ResolveApproval { .. } => {
                self.actions.lock().unwrap().push(request);
                Ok(response)
            }
            HostSessionActionPayload::Stop { .. } => Err(HostSessionFault::Unsupported(
                "session stop is not supported by this host".into(),
            )),
        }
    }
}

fn summary(session_id: &str) -> HostSessionSummary {
    HostSessionSummary {
        session_id: session_id.into(),
        machine_id: "host-b".into(),
        agent_type: "codex".into(),
        workspace_path: "/tmp/ws".into(),
        title: "Demo session".into(),
        status: HostSessionActivityStatus::Idle,
        latest_message_preview: Some("hello".into()),
        updated_at: "2026-11-11T00:00:00Z".into(),
        avatar_seed: "seed".into(),
        inventory_stale: None,
        connection_route: None,
    }
}

fn turn(turn_id: &str, session_id: &str, number: u32, text: &str) -> HostSessionTurn {
    HostSessionTurn {
        turn_id: turn_id.into(),
        session_id: session_id.into(),
        turn_number: number,
        status: HostSessionTurnStatus::Completed,
        created_at: "2026-11-11T00:00:00Z".into(),
        completed_at: Some("2026-11-11T00:00:01Z".into()),
        assistant_text: vec![text.into()],
    }
}

fn init_identity(dir: &Path, name: &str) -> MeshNodeIdentity {
    init_node(dir, name).expect("init node").0
}

/// Join an existing trust group (same trust group id + epoch).
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

fn host_config(
    data_dir: PathBuf,
    identity: &MeshNodeIdentity,
    handler: Arc<RecordingHostSessions>,
    allowed_peers: Option<Vec<String>>,
) -> ReplicaHandleConfig {
    ReplicaHandleConfig {
        data_dir,
        device_id: identity.device_id.clone(),
        trust_group_id: identity.trust_group_id.clone(),
        membership_epoch: identity.membership_epoch,
        runtime_socket: None,
        relay_disabled: true,
        host_session_handler: Some(handler as Arc<dyn HostSessionHandler>),
        allowed_peer_endpoint_ids: allowed_peers,
    }
}

fn dial(host: &ReplicaHandle) -> PeerDial {
    PeerDial {
        endpoint_id: host.endpoint_id(),
        addr: Some(host.endpoint_addr()),
    }
}

#[tokio::test]
async fn peer_session_query_and_action_roundtrip() {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let client_dir = root.path().join("client");

    let host_identity = init_identity(&host_dir, "host");
    let client_identity = join_trust_group(&client_dir, &host_identity);

    let handler = Arc::new(RecordingHostSessions::new());
    let host = ReplicaHandle::open(host_config(
        host_dir.clone(),
        &host_identity,
        Arc::clone(&handler),
        None,
    ))
    .await
    .expect("host open");
    let client = open_handle(client_dir, None, true)
        .await
        .expect("client open");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let peer = dial(&host);

    // The hello advertises host session capabilities when a handler is wired.
    let hello = client
        .peer_host_runtime_hello(peer.clone(), Duration::from_secs(15))
        .await
        .expect("hello");
    assert_eq!(hello.host_device_id, host_identity.device_id);
    assert!(hello.capabilities.iter().any(|cap| cap == QUERY_CAPABILITY));
    assert!(
        hello
            .capabilities
            .iter()
            .any(|cap| cap == ACTION_CAPABILITY)
    );

    // A lists B's sessions.
    let listed = client
        .peer_host_session_query(
            peer.clone(),
            HostSessionQueryRequest::list_sessions(&host_identity.device_id),
            Duration::from_secs(15),
        )
        .await
        .expect("list sessions");
    let HostSessionQueryData::Sessions { sessions } = listed.data else {
        panic!("expected sessions data");
    };
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, TARGET_SESSION);

    // A reads B's history.
    let history = client
        .peer_host_session_query(
            peer.clone(),
            HostSessionQueryRequest::session_history(&host_identity.device_id, TARGET_SESSION),
            Duration::from_secs(15),
        )
        .await
        .expect("session history");
    let HostSessionQueryData::History { turns } = history.data else {
        panic!("expected history data");
    };
    assert_eq!(turns.len(), 2);
    assert_eq!(turns[1].assistant_text, vec!["second".to_string()]);

    // A reads one session.
    let single = client
        .peer_host_session_query(
            peer.clone(),
            HostSessionQueryRequest::get_session(&host_identity.device_id, TARGET_SESSION),
            Duration::from_secs(15),
        )
        .await
        .expect("get session");
    let HostSessionQueryData::Session { session } = single.data else {
        panic!("expected session data");
    };
    assert_eq!(session.title, "Demo session");

    // Unknown session is a structured error, not an empty success.
    let unknown = client
        .peer_host_session_query(
            peer.clone(),
            HostSessionQueryRequest::session_history(&host_identity.device_id, "missing"),
            Duration::from_secs(15),
        )
        .await
        .expect_err("unknown session must fail");
    match unknown {
        ReplicaRpcError::HostSession { code, .. } => {
            assert_eq!(code, HostSessionErrorCode::UnknownSession);
        }
        other => panic!("expected host session error, got {other:?}"),
    }

    // A sends a message to B's session; B receives it.
    let send = HostSessionActionRequest::new(
        uuid::Uuid::new_v4().to_string(),
        &host_identity.device_id,
        TARGET_SESSION,
        "idem-send-1",
        HostSessionActionPayload::SendMessage {
            text: "hello from A".into(),
            request_id: Some("req-1".into()),
        },
    );
    let sent = client
        .peer_host_session_action(peer.clone(), send.clone(), Duration::from_secs(15))
        .await
        .expect("send message");
    assert_eq!(sent.session_id, TARGET_SESSION);
    assert_eq!(sent.turn.as_ref().expect("turn").turn_id, "turn-3");
    let received = handler.received();
    assert_eq!(received.len(), 1);
    assert_eq!(received[0].session_id, TARGET_SESSION);
    match &received[0].action {
        HostSessionActionPayload::SendMessage { text, request_id } => {
            assert_eq!(text, "hello from A");
            assert_eq!(request_id.as_deref(), Some("req-1"));
        }
        other => panic!("unexpected action: {other:?}"),
    }

    // Exact retry reuses the cached response without a second delivery.
    let retried = client
        .peer_host_session_action(peer.clone(), send.clone(), Duration::from_secs(15))
        .await
        .expect("replayed send message");
    assert_eq!(retried, sent);
    assert_eq!(handler.received().len(), 1, "retry must not deliver twice");

    // Same idempotency key with a different body is an explicit conflict.
    let mut conflicting = send.clone();
    conflicting.action = HostSessionActionPayload::SendMessage {
        text: "different".into(),
        request_id: None,
    };
    let conflict = client
        .peer_host_session_action(peer.clone(), conflicting, Duration::from_secs(15))
        .await
        .expect_err("idempotency conflict must fail");
    match conflict {
        ReplicaRpcError::HostSession { code, .. } => {
            assert_eq!(code, HostSessionErrorCode::InvalidRequest);
        }
        other => panic!("expected host session error, got {other:?}"),
    }
    assert_eq!(handler.received().len(), 1);

    // Steer and approval decisions reach B.
    for (index, action) in [
        HostSessionActionPayload::Steer {
            text: "focus on tests".into(),
        },
        HostSessionActionPayload::ResolveApproval {
            approval_id: "approval-1".into(),
            decision: HostApprovalDecision::AllowedOnce,
        },
    ]
    .into_iter()
    .enumerate()
    {
        let request = HostSessionActionRequest::new(
            uuid::Uuid::new_v4().to_string(),
            &host_identity.device_id,
            TARGET_SESSION,
            format!("idem-extra-{index}"),
            action,
        );
        client
            .peer_host_session_action(peer.clone(), request, Duration::from_secs(15))
            .await
            .expect("action");
    }
    assert_eq!(handler.received().len(), 3);

    // Unsupported stop is an explicit error, never a fake success.
    let stop = HostSessionActionRequest::new(
        uuid::Uuid::new_v4().to_string(),
        &host_identity.device_id,
        TARGET_SESSION,
        "idem-stop-1",
        HostSessionActionPayload::Stop { force: false },
    );
    let stop_error = client
        .peer_host_session_action(peer.clone(), stop, Duration::from_secs(15))
        .await
        .expect_err("stop must be explicitly unsupported");
    match stop_error {
        ReplicaRpcError::HostSession { code, message } => {
            assert_eq!(code, HostSessionErrorCode::UnsupportedOperation);
            assert!(message.contains("stop"), "{message}");
        }
        other => panic!("expected host session error, got {other:?}"),
    }

    // A request targeted at another host id is rejected rather than served.
    let wrong_host = HostSessionQueryRequest::list_sessions("some-other-host");
    let error = client
        .peer_host_session_query(peer, wrong_host, Duration::from_secs(15))
        .await
        .expect_err("wrong host id must fail");
    match error {
        ReplicaRpcError::HostSession { code, .. } => {
            assert_eq!(code, HostSessionErrorCode::InvalidRequest);
        }
        other => panic!("expected host session error, got {other:?}"),
    }

    let _ = client_identity;
}

#[tokio::test]
async fn peer_outside_allowlist_is_rejected() {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let allowed_dir = root.path().join("allowed");
    let stranger_dir = root.path().join("stranger");
    let foreign_dir = root.path().join("foreign");

    let host_identity = init_identity(&host_dir, "host");
    let allowed_identity = join_trust_group(&allowed_dir, &host_identity);
    join_trust_group(&stranger_dir, &host_identity);
    // Different trust group entirely.
    let foreign_identity = init_identity(&foreign_dir, "foreign");

    let allowed = open_handle(allowed_dir, None, true)
        .await
        .expect("allowed peer open");
    tokio::time::sleep(Duration::from_millis(200)).await;

    let handler = Arc::new(RecordingHostSessions::new());
    let host = ReplicaHandle::open(host_config(
        host_dir,
        &host_identity,
        handler,
        Some(vec![allowed.endpoint_id_string()]),
    ))
    .await
    .expect("host open");

    let stranger = open_handle(stranger_dir, None, true)
        .await
        .expect("stranger open");
    let foreign = open_handle(foreign_dir, None, true)
        .await
        .expect("foreign open");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The allowlisted peer is served.
    let ok = allowed
        .peer_host_session_query(
            dial(&host),
            HostSessionQueryRequest::list_sessions(&host_identity.device_id),
            Duration::from_secs(15),
        )
        .await
        .expect("allowlisted peer");
    assert_eq!(ok.query_kind, HostSessionQueryKind::ListSessions);

    // A same-trust-group peer outside the paired allowlist is rejected.
    let rejected = stranger
        .peer_host_session_query(
            dial(&host),
            HostSessionQueryRequest::list_sessions(&host_identity.device_id),
            Duration::from_secs(15),
        )
        .await
        .expect_err("non-allowlisted peer must be rejected");
    match rejected {
        ReplicaRpcError::HostSession { code, .. } => {
            assert_eq!(code, HostSessionErrorCode::Unauthorized);
        }
        other => panic!("expected unauthorized, got {other:?}"),
    }

    // A peer in another trust group is rejected as unauthorized too.
    let foreign_error = foreign
        .peer_host_session_query(
            dial(&host),
            HostSessionQueryRequest::list_sessions(&foreign_identity.device_id),
            Duration::from_secs(15),
        )
        .await
        .expect_err("foreign trust group must be rejected");
    match foreign_error {
        ReplicaRpcError::HostSession { code, .. } => {
            assert_eq!(code, HostSessionErrorCode::Unauthorized);
        }
        other => panic!("expected unauthorized, got {other:?}"),
    }
    let _ = allowed_identity;
}

#[tokio::test]
async fn host_session_disabled_is_an_explicit_error() {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let client_dir = root.path().join("client");
    let host_identity = init_identity(&host_dir, "host");
    join_trust_group(&client_dir, &host_identity);

    // Plain open_handle: no host session handler configured.
    let host = open_handle(host_dir, None, true).await.expect("host open");
    let client = open_handle(client_dir, None, true)
        .await
        .expect("client open");
    tokio::time::sleep(Duration::from_millis(300)).await;

    let error = client
        .peer_host_session_query(
            dial(&host),
            HostSessionQueryRequest::list_sessions(&host_identity.device_id),
            Duration::from_secs(15),
        )
        .await
        .expect_err("disabled host sessions must fail");
    match error {
        ReplicaRpcError::HostSession { code, message } => {
            assert_eq!(code, HostSessionErrorCode::UnsupportedOperation);
            assert!(message.contains("not enabled"), "{message}");
        }
        other => panic!("expected unsupported-operation, got {other:?}"),
    }
}

#[tokio::test]
async fn offline_host_is_unreachable_not_empty_success() {
    let root = tempdir().unwrap();
    let host_dir = root.path().join("host");
    let client_dir = root.path().join("client");
    let host_identity = init_identity(&host_dir, "host");
    join_trust_group(&client_dir, &host_identity);

    let handler = Arc::new(RecordingHostSessions::new());
    let host = ReplicaHandle::open(host_config(host_dir, &host_identity, handler, None))
        .await
        .expect("host open");
    let client = open_handle(client_dir, None, true)
        .await
        .expect("client open");
    tokio::time::sleep(Duration::from_millis(300)).await;

    // B goes offline.
    host.shutdown().await.expect("host shutdown");

    let result = client
        .peer_host_session_query(
            dial(&host),
            HostSessionQueryRequest::list_sessions(&host_identity.device_id),
            Duration::from_secs(3),
        )
        .await;
    match result {
        Err(ReplicaRpcError::Unreachable(reason)) => {
            assert!(!reason.is_empty());
        }
        other => panic!("expected unreachable error, got {other:?}"),
    }
}
