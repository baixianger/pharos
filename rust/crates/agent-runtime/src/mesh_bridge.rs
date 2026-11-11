//! Mesh host bring-up for `pharos-meshd` (RFC-007 S3 + cross-host sessions).
//!
//! [`spawn`] starts a dedicated OS thread with its own multi-thread tokio
//! runtime, binds the iroh mesh endpoint through
//! [`pharos_mesh::open_handle_with_host_sessions`] and installs a
//! [`pharos_session::host_bridge::SessionServiceHostHandler`] so paired peers
//! can run `host.session.query.v1` / `host.session.action.v1` against this
//! host's local [`pharos_session::SessionService`].
//!
//! The endpoint must outlive the caller (it serves Peer RPC for the daemon's
//! process lifetime), so the thread parks forever after reporting readiness.
//! [`spawn`] only returns once the host is actually online; failures are
//! returned as [`MeshBridgeError`] instead of being logged and ignored.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use pharos_session::SessionService;
use pharos_session::host_bridge::SessionServiceHostHandler;
use thiserror::Error;

/// How long [`spawn`] waits for the iroh endpoint to bind and the handler to be
/// installed before reporting a startup failure.
pub const STARTUP_TIMEOUT: Duration = Duration::from_secs(30);

/// Optional mesh bring-up configuration threaded from the daemon CLI flags.
#[derive(Debug, Clone)]
pub struct MeshBridgeOptions {
    /// Directory holding the mesh node identity (`node-identity.json`,
    /// `signing.key`, `peers.json`). Initialized with
    /// `pharos-mesh-node init-node` before the daemon starts.
    pub data_dir: PathBuf,
    /// Optional agent-runtime Unix socket used for `host.runtime.call.v1`
    /// forwarding (peer → daemon `delivery.submit-member`).
    pub runtime_socket: Option<PathBuf>,
    /// Disable iroh relays (LAN / loopback smoke runs).
    pub relay_disabled: bool,
}

/// Details of the online mesh host, for logging and loopback tooling.
#[derive(Debug, Clone)]
pub struct MeshHostHandle {
    /// Mesh device id (identity recorded in `node-identity.json`).
    pub device_id: String,
    /// iroh endpoint id as a string (stable, loggable).
    pub endpoint_id: String,
    /// Full endpoint address; lets local tests/tools dial this host directly.
    pub endpoint_addr: pharos_mesh::EndpointAddr,
}

impl MeshHostHandle {
    /// Reconstruct the [`pharos_mesh::PeerDial`] for this host.
    pub fn peer_dial(&self) -> pharos_mesh::PeerDial {
        pharos_mesh::PeerDial {
            endpoint_id: self.endpoint_addr.id,
            addr: Some(self.endpoint_addr.clone()),
        }
    }

    pub fn describe(&self) -> String {
        format!(
            "mesh host online device={} endpoint={}",
            self.device_id, self.endpoint_id
        )
    }
}

/// Explicit mesh host bring-up failures. Never silently ignored by the daemon.
#[derive(Debug, Error)]
pub enum MeshBridgeError {
    #[error("mesh endpoint: {0}")]
    Mesh(#[from] pharos_mesh::MeshError),
    #[error("mesh host thread failed to start: {0}")]
    Thread(String),
    #[error("mesh host tokio runtime failed to start: {0}")]
    Runtime(String),
    #[error("mesh host did not come online within {0:?}")]
    StartupTimeout(Duration),
}

/// Start the mesh host and block until it is online.
///
/// Returns once the iroh endpoint is bound and the session handler installed;
/// after that the host keeps serving on the spawned thread until process exit.
pub fn spawn(
    options: MeshBridgeOptions,
    service: Arc<dyn SessionService>,
) -> Result<MeshHostHandle, MeshBridgeError> {
    let (ready_tx, ready_rx) = mpsc::channel::<Result<MeshHostHandle, MeshBridgeError>>();
    thread::Builder::new()
        .name("pharos-mesh-host".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    let _ = ready_tx.send(Err(MeshBridgeError::Runtime(error.to_string())));
                    return;
                }
            };
            runtime.block_on(async move {
                let handler: Arc<dyn pharos_mesh::HostSessionHandler> =
                    Arc::new(SessionServiceHostHandler::new(service));
                let handle = match pharos_mesh::open_handle_with_host_sessions(
                    options.data_dir.clone(),
                    options.runtime_socket.clone(),
                    options.relay_disabled,
                    Some(handler),
                )
                .await
                {
                    Ok(handle) => handle,
                    Err(error) => {
                        let _ = ready_tx.send(Err(MeshBridgeError::Mesh(error)));
                        return;
                    }
                };
                let info = MeshHostHandle {
                    device_id: handle.device_id().to_string(),
                    endpoint_id: handle.endpoint_id_string(),
                    endpoint_addr: handle.endpoint_addr(),
                };
                if ready_tx.send(Ok(info)).is_err() {
                    eprintln!(
                        "pharos-agent-runtime: mesh host caller dropped before startup completed; keeping host online"
                    );
                }
                // Serve for the process lifetime. The ReplicaHandle owns the
                // iroh endpoint + accept loop, so it must stay alive here.
                std::future::pending::<()>().await;
            });
        })
        .map_err(|error| MeshBridgeError::Thread(error.to_string()))?;

    ready_rx
        .recv_timeout(STARTUP_TIMEOUT)
        .unwrap_or(Err(MeshBridgeError::StartupTimeout(STARTUP_TIMEOUT)))
}

pub fn describe_wiring() -> &'static str {
    "mod mesh_bridge; // spawn(): dedicated thread + tokio runtime + open_handle_with_host_sessions(SessionServiceHostHandler)"
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_api::{
        CanonicalTurn, ResolveApprovalRequest, SendSessionMessageRequest, SessionActivityStatus,
        SessionProgress, SessionSummary, SteerSessionRequest,
    };
    use pharos_protocol::host_session::{HostSessionQueryData, HostSessionQueryRequest};
    use pharos_session::SessionError;
    use std::time::Duration;
    use tempfile::tempdir;

    /// One fake session, served by a sync in-memory SessionService.
    struct FakeSessionService {
        summary: SessionSummary,
    }

    impl FakeSessionService {
        fn new() -> Self {
            Self {
                summary: SessionSummary {
                    session_id: "fake-mesh-session-1".into(),
                    machine_id: "host-machine".into(),
                    agent_type: "fake".into(),
                    workspace_path: "/tmp/pharos-fake-mesh-ws".into(),
                    title: "Fake mesh session".into(),
                    status: SessionActivityStatus::Idle,
                    latest_message_preview: Some("hello from the fake host".into()),
                    updated_at: "2026-11-11T00:00:00Z".into(),
                    avatar_seed: "fake-seed".into(),
                    inventory_stale: None,
                    connection_route: Some("local".into()),
                },
            }
        }
    }

    impl SessionService for FakeSessionService {
        fn list_sessions(&self) -> Result<Vec<SessionSummary>, SessionError> {
            Ok(vec![self.summary.clone()])
        }

        fn get_session(&self, session_id: &str) -> Result<SessionSummary, SessionError> {
            if session_id == self.summary.session_id {
                Ok(self.summary.clone())
            } else {
                Err(SessionError::new(format!(
                    "session not found: {session_id}"
                )))
            }
        }

        fn list_history(&self, session_id: &str) -> Result<Vec<CanonicalTurn>, SessionError> {
            if session_id == self.summary.session_id {
                Ok(Vec::new())
            } else {
                Err(SessionError::new(format!(
                    "session not found: {session_id}"
                )))
            }
        }

        fn start_session(
            &self,
            _workspace_path: &str,
            _mode: Option<&str>,
        ) -> Result<SessionSummary, SessionError> {
            Err(SessionError::new("fake service: start_session unsupported"))
        }

        fn send_message(
            &self,
            _session_id: &str,
            _request: SendSessionMessageRequest,
        ) -> Result<CanonicalTurn, SessionError> {
            Err(SessionError::new("fake service: send_message unsupported"))
        }

        fn steer(
            &self,
            _session_id: &str,
            _request: SteerSessionRequest,
        ) -> Result<(), SessionError> {
            Err(SessionError::new("fake service: steer unsupported"))
        }

        fn resolve_approval(
            &self,
            _session_id: &str,
            _request: ResolveApprovalRequest,
        ) -> Result<(), SessionError> {
            Err(SessionError::new(
                "fake service: resolve_approval unsupported",
            ))
        }

        fn progress(&self, _session_id: &str) -> Result<SessionProgress, SessionError> {
            Err(SessionError::new("fake service: progress unsupported"))
        }

        fn set_progress(
            &self,
            _session_id: &str,
            _progress: &SessionProgress,
        ) -> Result<SessionProgress, SessionError> {
            Err(SessionError::new("fake service: set_progress unsupported"))
        }
    }

    /// Two identities in the same trust group: a host (spawned) and a peer
    /// client that queries it over loopback iroh.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn mesh_host_serves_peer_list_sessions_over_loopback() {
        let root = tempdir().unwrap();
        let host_dir = root.path().join("host");
        let client_dir = root.path().join("client");

        let (host_identity, _) = pharos_mesh::init_node(&host_dir, "host").unwrap();
        let (mut client_identity, _) = pharos_mesh::init_node(&client_dir, "client").unwrap();
        // The client joins the host's trust group (loopback smoke pattern from
        // pharos-mesh/tests/peer_rpc_smoke.rs).
        client_identity.trust_group_id = host_identity.trust_group_id.clone();
        client_identity.membership_epoch = host_identity.membership_epoch;
        std::fs::write(
            client_dir.join("node-identity.json"),
            serde_json::to_vec_pretty(&client_identity).unwrap(),
        )
        .unwrap();

        let expected_session = FakeSessionService::new().summary.clone();
        let host = spawn(
            MeshBridgeOptions {
                data_dir: host_dir,
                runtime_socket: None,
                relay_disabled: true,
            },
            Arc::new(FakeSessionService::new()),
        )
        .expect("mesh host spawn");
        assert_eq!(host.device_id, host_identity.device_id);
        assert!(!host.endpoint_id.is_empty());

        let client = pharos_mesh::open_handle(client_dir, None, true)
            .await
            .expect("client open");
        tokio::time::sleep(Duration::from_millis(300)).await;

        let response = client
            .peer_host_session_query(
                host.peer_dial(),
                HostSessionQueryRequest::list_sessions(host_identity.device_id.clone()),
                Duration::from_secs(20),
            )
            .await
            .expect("peer host session query");
        assert_eq!(response.host_device_id, host_identity.device_id);
        let HostSessionQueryData::Sessions { sessions } = response.data else {
            panic!("expected listSessions data, got {:?}", response.data);
        };
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, expected_session.session_id);
        assert_eq!(sessions[0].machine_id, expected_session.machine_id);
    }
}
