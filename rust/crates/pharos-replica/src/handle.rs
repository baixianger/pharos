//! `ReplicaHandle` — Peer RPC + local replica mutations for other streams.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use pharos_iroh::{
    EndpointAddr, EndpointId, MeshIrohEndpoint, MeshIrohError, MeshTransportExchange, PeerDial,
};
use pharos_protocol::ReplicaRpcOperation;
use pharos_protocol::host_session::{
    ACTION_CAPABILITY, HostSessionActionRequest, HostSessionActionResponse, HostSessionErrorBody,
    HostSessionErrorCode, HostSessionQueryRequest, HostSessionQueryResponse, QUERY_CAPABILITY,
};
use serde::Serialize;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::host_session::{
    ActionReplayCache, HostSessionAudit, HostSessionFault, HostSessionHandler, ReplayCheck,
    SharedActionReplayCache,
};
use crate::rpc::{
    HostRuntimeCallRequest, HostRuntimeCallResponse, HostRuntimeHello, ReplicaRpcError,
    ReplicaRpcHeader, ReplicaSyncPullRequest, ReplicaSyncPullResponse, ReplicaSyncPushRequest,
    ReplicaSyncPushResponse, SyncedMessage,
};
use crate::runtime_client::RuntimeClient;
use crate::store::{MessageRow, ReplicaStore};

/// Default bound for the host session action replay cache.
const ACTION_REPLAY_CAPACITY: usize = 256;

#[derive(Clone)]
pub struct ReplicaHandleConfig {
    pub data_dir: PathBuf,
    pub device_id: String,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    /// Optional local agent-runtime Unix socket for host.runtime.call forwarding.
    pub runtime_socket: Option<PathBuf>,
    /// Disable iroh relays (LAN / loopback smoke).
    pub relay_disabled: bool,
    /// Serve `host.session.query.v1` / `host.session.action.v1` from this hook.
    /// When `None` the host answers those operations with an explicit
    /// `unsupported-operation` error.
    pub host_session_handler: Option<Arc<dyn HostSessionHandler>>,
    /// When `Some`, host session RPCs are only served to these peer endpoint
    /// IDs (the paired-peer allowlist). `None` keeps the legacy
    /// trust-group/epoch-only authorization.
    pub allowed_peer_endpoint_ids: Option<Vec<String>>,
}

impl std::fmt::Debug for ReplicaHandleConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ReplicaHandleConfig")
            .field("data_dir", &self.data_dir)
            .field("device_id", &self.device_id)
            .field("trust_group_id", &self.trust_group_id)
            .field("membership_epoch", &self.membership_epoch)
            .field("runtime_socket", &self.runtime_socket)
            .field("relay_disabled", &self.relay_disabled)
            .field("host_session_handler", &self.host_session_handler.is_some())
            .field("allowed_peer_endpoint_ids", &self.allowed_peer_endpoint_ids)
            .finish()
    }
}

/// Process-local handle exposing replica store + Peer RPC over iroh.
pub struct ReplicaHandle {
    store: Arc<Mutex<ReplicaStore>>,
    endpoint: MeshIrohEndpoint,
    config: ReplicaHandleConfig,
    runtime: Option<RuntimeClient>,
    host_sessions: Option<Arc<dyn HostSessionHandler>>,
    replay: SharedActionReplayCache,
}

impl ReplicaHandle {
    pub async fn open(config: ReplicaHandleConfig) -> Result<Arc<Self>, ReplicaRpcError> {
        let store = ReplicaStore::open(&config.data_dir)
            .map_err(|e| ReplicaRpcError::Store(e.to_string()))?;
        store
            .upsert_trust_group(&config.trust_group_id, config.membership_epoch as i64, "{}")
            .map_err(|e| ReplicaRpcError::Store(e.to_string()))?;
        let endpoint = MeshIrohEndpoint::bind(Some(&config.data_dir), config.relay_disabled)
            .await
            .map_err(|e| ReplicaRpcError::Runtime(e.to_string()))?;
        let runtime = config
            .runtime_socket
            .as_ref()
            .map(|p| RuntimeClient::new(p.clone()));
        let host_sessions = config.host_session_handler.clone();
        let handle = Arc::new(Self {
            store: Arc::new(Mutex::new(store)),
            endpoint,
            config,
            runtime,
            host_sessions,
            replay: std::sync::Mutex::new(ActionReplayCache::new(ACTION_REPLAY_CAPACITY)),
        });
        let serve = Arc::clone(&handle);
        handle
            .endpoint
            .set_handler(move |req, remote| {
                let serve = Arc::clone(&serve);
                async move { serve.handle_incoming(req, remote).await }
            })
            .await;
        info!(
            device = %handle.config.device_id,
            endpoint = %handle.endpoint.endpoint_id_string(),
            "replica handle online"
        );
        Ok(handle)
    }

    pub fn endpoint_id(&self) -> EndpointId {
        self.endpoint.endpoint_id()
    }

    pub fn endpoint_id_string(&self) -> String {
        self.endpoint.endpoint_id_string()
    }

    pub fn endpoint_addr(&self) -> EndpointAddr {
        self.endpoint.endpoint_addr()
    }

    pub fn device_id(&self) -> &str {
        &self.config.device_id
    }

    pub fn trust_group_id(&self) -> &str {
        &self.config.trust_group_id
    }

    pub fn membership_epoch(&self) -> u64 {
        self.config.membership_epoch
    }

    pub async fn store(&self) -> tokio::sync::MutexGuard<'_, ReplicaStore> {
        self.store.lock().await
    }

    /// Local host.runtime.hello payload (also served to peers).
    pub fn local_hello(&self) -> HostRuntimeHello {
        let mut hello = HostRuntimeHello::local(&self.config.device_id);
        if self.host_sessions.is_some() {
            hello.capabilities.push(QUERY_CAPABILITY.to_string());
            hello.capabilities.push(ACTION_CAPABILITY.to_string());
        }
        hello
    }

    /// Whether this host serves cross-host session queries/actions.
    pub fn supports_host_sessions(&self) -> bool {
        self.host_sessions.is_some()
    }

    /// Peer: host.session.query.v1
    pub async fn peer_host_session_query(
        &self,
        peer: PeerDial,
        request: HostSessionQueryRequest,
        timeout: Duration,
    ) -> Result<HostSessionQueryResponse, ReplicaRpcError> {
        request
            .validate()
            .map_err(|body| ReplicaRpcError::HostSession {
                code: body.code,
                message: body.message,
            })?;
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::HostSessionQuery,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let (_, body) = self.exchange(peer, header, Some(request), timeout).await?;
        let response: HostSessionQueryResponse = decode_body(body)?;
        response
            .validate()
            .map_err(|body| ReplicaRpcError::HostSession {
                code: body.code,
                message: body.message,
            })?;
        Ok(response)
    }

    /// Peer: host.session.action.v1
    pub async fn peer_host_session_action(
        &self,
        peer: PeerDial,
        request: HostSessionActionRequest,
        timeout: Duration,
    ) -> Result<HostSessionActionResponse, ReplicaRpcError> {
        request
            .validate()
            .map_err(|body| ReplicaRpcError::HostSession {
                code: body.code,
                message: body.message,
            })?;
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::HostSessionAction,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let (_, body) = self.exchange(peer, header, Some(request), timeout).await?;
        let response: HostSessionActionResponse = decode_body(body)?;
        response
            .validate()
            .map_err(|body| ReplicaRpcError::HostSession {
                code: body.code,
                message: body.message,
            })?;
        Ok(response)
    }

    /// Peer: host.runtime.hello.v1
    pub async fn peer_host_runtime_hello(
        &self,
        peer: PeerDial,
        timeout: Duration,
    ) -> Result<HostRuntimeHello, ReplicaRpcError> {
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::HostRuntimeHello,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let response = self.exchange(peer, header, None::<()>, timeout).await?;
        decode_body(response.1)
    }

    /// Peer: host.runtime.call.v1 (allowlisted delivery.submit-member).
    pub async fn peer_host_runtime_call(
        &self,
        peer: PeerDial,
        request: HostRuntimeCallRequest,
        timeout: Duration,
    ) -> Result<HostRuntimeCallResponse, ReplicaRpcError> {
        request.validate()?;
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::HostRuntimeCall,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let response = self.exchange(peer, header, Some(request), timeout).await?;
        decode_body(response.1)
    }

    /// Peer: replica.sync.pull.v1
    pub async fn peer_sync_pull(
        &self,
        peer: PeerDial,
        request: ReplicaSyncPullRequest,
        timeout: Duration,
    ) -> Result<ReplicaSyncPullResponse, ReplicaRpcError> {
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::ReplicaSyncPull,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let response = self.exchange(peer, header, Some(request), timeout).await?;
        decode_body(response.1)
    }

    /// Peer: replica.sync.push.v1
    pub async fn peer_sync_push(
        &self,
        peer: PeerDial,
        request: ReplicaSyncPushRequest,
        timeout: Duration,
    ) -> Result<ReplicaSyncPushResponse, ReplicaRpcError> {
        let header = ReplicaRpcHeader::request(
            ReplicaRpcOperation::ReplicaSyncPush,
            &self.config.trust_group_id,
            self.config.membership_epoch,
        );
        let response = self.exchange(peer, header, Some(request), timeout).await?;
        decode_body(response.1)
    }

    /// Insert a local message (used by sync push smoke / tests).
    pub async fn upsert_local_message(
        &self,
        message: SyncedMessage,
    ) -> Result<(), ReplicaRpcError> {
        let store = self.store.lock().await;
        store
            .upsert_message(&message_row(&message))
            .map_err(|e| ReplicaRpcError::Store(e.to_string()))
    }

    /// Close this handle's iroh endpoint. Tests use it to simulate a Host
    /// going offline; production callers keep the handle alive for its process.
    pub async fn shutdown(&self) -> Result<(), ReplicaRpcError> {
        self.endpoint
            .close()
            .await
            .map_err(|error| ReplicaRpcError::Runtime(error.to_string()))
    }

    async fn exchange<B: Serialize>(
        &self,
        peer: PeerDial,
        header: ReplicaRpcHeader,
        body: Option<B>,
        timeout: Duration,
    ) -> Result<(ReplicaRpcHeader, Option<Vec<u8>>), ReplicaRpcError> {
        let body_bytes = match body {
            Some(value) => Some(serde_json::to_vec(&value)?),
            None => None,
        };
        let response = self
            .endpoint
            .exchange(
                &peer,
                MeshTransportExchange {
                    header: header.encode()?,
                    body: body_bytes,
                },
                timeout,
            )
            .await
            .map_err(map_exchange_error)?;
        let response_header = ReplicaRpcHeader::decode(&response.header)?;
        if response_header.disposition == pharos_protocol::ReplicaRpcDisposition::Error {
            let raw_code = response_header
                .error_code
                .clone()
                .unwrap_or_else(|| "peer-error".into());
            // Host session failures carry a structured body so callers can map
            // explicit codes (unauthorized / unknown-session / adapter-unavailable).
            if matches!(
                response_header.operation,
                ReplicaRpcOperation::HostSessionQuery | ReplicaRpcOperation::HostSessionAction
            ) && let Some(body) = response.body.as_deref()
                && let Ok(error_body) = serde_json::from_slice::<HostSessionErrorBody>(body)
            {
                return Err(ReplicaRpcError::HostSession {
                    code: error_body.code,
                    message: error_body.message,
                });
            }
            if let Some(code) = HostSessionErrorCode::parse(&raw_code) {
                return Err(ReplicaRpcError::HostSession {
                    code,
                    message: raw_code,
                });
            }
            return Err(ReplicaRpcError::Runtime(raw_code));
        }
        Ok((response_header, response.body))
    }

    async fn handle_incoming(
        &self,
        request: MeshTransportExchange,
        remote: EndpointId,
    ) -> MeshTransportExchange {
        match self.dispatch(request, remote).await {
            Ok(exchange) => exchange,
            Err(err) => {
                warn!(error = %err, %remote, "replica rpc dispatch failed");
                let fallback = ReplicaRpcHeader {
                    version: 1,
                    request_id: uuid::Uuid::nil(),
                    operation: ReplicaRpcOperation::HostRuntimeHello,
                    trust_group_id: self.config.trust_group_id.clone(),
                    membership_epoch: self.config.membership_epoch,
                    disposition: pharos_protocol::ReplicaRpcDisposition::Error,
                    error_code: Some("dispatch-failed".into()),
                };
                MeshTransportExchange {
                    header: fallback.encode().unwrap_or_default(),
                    body: None,
                }
            }
        }
    }

    async fn dispatch(
        &self,
        request: MeshTransportExchange,
        remote: EndpointId,
    ) -> Result<MeshTransportExchange, ReplicaRpcError> {
        let header = ReplicaRpcHeader::decode(&request.header)?;
        if header.trust_group_id != self.config.trust_group_id {
            return Ok(reject_or_error(
                &header,
                "trust-group-mismatch",
                HostSessionErrorBody::unauthorized("peer trust group does not match this host"),
            ));
        }
        if header.membership_epoch != self.config.membership_epoch {
            return Ok(reject_or_error(
                &header,
                "membership-epoch-mismatch",
                HostSessionErrorBody::unauthorized(
                    "peer membership epoch does not match this host",
                ),
            ));
        }
        match header.operation {
            ReplicaRpcOperation::HostRuntimeHello => {
                let hello = self.local_hello();
                ok_exchange(&header, Some(hello))
            }
            ReplicaRpcOperation::HostRuntimeCall => {
                let call: HostRuntimeCallRequest = decode_required_body(request.body.as_deref())?;
                call.validate()?;
                if call.host_device_id != self.config.device_id {
                    return Ok(error_exchange(&header, "runtime-identity-mismatch"));
                }
                let runtime = self.runtime.as_ref().ok_or_else(|| {
                    ReplicaRpcError::Runtime("runtime socket not configured".into())
                })?;
                let jsonrpc_response = runtime
                    .call_raw(&call.jsonrpc_request)
                    .map_err(|e| ReplicaRpcError::Runtime(e.to_string()))?;
                let response = HostRuntimeCallResponse {
                    host_device_id: self.config.device_id.clone(),
                    jsonrpc_response,
                };
                info!(%remote, "host.runtime.call forwarded");
                ok_exchange(&header, Some(response))
            }
            ReplicaRpcOperation::ReplicaSyncPull => {
                let pull: ReplicaSyncPullRequest = match request.body.as_deref() {
                    Some(bytes) => serde_json::from_slice(bytes)?,
                    None => ReplicaSyncPullRequest {
                        room_id: None,
                        since_ts: 0.0,
                        limit: 256,
                    },
                };
                let store = self.store.lock().await;
                let rows = store
                    .messages_since(pull.room_id.as_deref(), pull.since_ts, pull.limit)
                    .map_err(|e| ReplicaRpcError::Store(e.to_string()))?;
                let messages = rows.into_iter().map(synced_message).collect();
                ok_exchange(&header, Some(ReplicaSyncPullResponse { messages }))
            }
            ReplicaRpcOperation::ReplicaSyncPush => {
                let push: ReplicaSyncPushRequest = decode_required_body(request.body.as_deref())?;
                let store = self.store.lock().await;
                let mut applied = 0u64;
                for message in push.messages {
                    store
                        .upsert_message(&message_row(&message))
                        .map_err(|e| ReplicaRpcError::Store(e.to_string()))?;
                    applied += 1;
                }
                ok_exchange(&header, Some(ReplicaSyncPushResponse { applied }))
            }
            ReplicaRpcOperation::HostSessionQuery => {
                let request: HostSessionQueryRequest =
                    match decode_required_body(request.body.as_deref()) {
                        Ok(request) => request,
                        Err(error) => {
                            return Ok(error_exchange_with_body(
                                &header,
                                HostSessionFault::InvalidRequest(error.to_string()).body(),
                            ));
                        }
                    };
                self.dispatch_host_session_query(&header, request, remote)
            }
            ReplicaRpcOperation::HostSessionAction => {
                let request: HostSessionActionRequest =
                    match decode_required_body(request.body.as_deref()) {
                        Ok(request) => request,
                        Err(error) => {
                            return Ok(error_exchange_with_body(
                                &header,
                                HostSessionFault::InvalidRequest(error.to_string()).body(),
                            ));
                        }
                    };
                self.dispatch_host_session_action(&header, request, remote)
            }
        }
    }

    fn dispatch_host_session_query(
        &self,
        header: &ReplicaRpcHeader,
        request: HostSessionQueryRequest,
        remote: EndpointId,
    ) -> Result<MeshTransportExchange, ReplicaRpcError> {
        let session_id = request.session_id.clone();
        let outcome = (|| {
            self.authorize_host_session(remote)?;
            let handler = self.host_session_handler()?;
            if request.host_device_id != self.config.device_id {
                return Err(HostSessionFault::InvalidRequest(
                    "hostDeviceId does not target this host".into(),
                ));
            }
            request
                .validate()
                .map_err(|body| HostSessionFault::InvalidRequest(body.message))?;
            handler.query(request)
        })();
        match outcome {
            Ok(response) => {
                self.audit_host_session(header, remote, session_id.as_deref(), "ok");
                ok_exchange(header, Some(response))
            }
            Err(fault) => {
                self.audit_host_session(
                    header,
                    remote,
                    session_id.as_deref(),
                    fault.code().as_str(),
                );
                Ok(error_exchange_with_body(header, fault.body()))
            }
        }
    }

    fn dispatch_host_session_action(
        &self,
        header: &ReplicaRpcHeader,
        request: HostSessionActionRequest,
        remote: EndpointId,
    ) -> Result<MeshTransportExchange, ReplicaRpcError> {
        let session_id = Some(request.session_id.clone());
        let outcome = (|| {
            self.authorize_host_session(remote)?;
            let handler = self.host_session_handler()?;
            if request.host_device_id != self.config.device_id {
                return Err(HostSessionFault::InvalidRequest(
                    "hostDeviceId does not target this host".into(),
                ));
            }
            request
                .validate()
                .map_err(|body| HostSessionFault::InvalidRequest(body.message))?;
            // Replay protection: a retried action must not run twice.
            let scope = remote.to_string();
            {
                let replay = self.replay.lock().map_err(|_| {
                    HostSessionFault::Internal("action replay cache is poisoned".into())
                })?;
                match replay.check(&scope, &request) {
                    ReplayCheck::Fresh => {}
                    ReplayCheck::Replayed(response) => return Ok(response),
                    ReplayCheck::Conflict(fault) => return Err(fault),
                }
            }
            let response = handler.action(request.clone())?;
            let mut replay = self.replay.lock().map_err(|_| {
                HostSessionFault::Internal("action replay cache is poisoned".into())
            })?;
            replay.record(&scope, request, response.clone());
            Ok(response)
        })();
        match outcome {
            Ok(response) => {
                self.audit_host_session(header, remote, session_id.as_deref(), "ok");
                ok_exchange(header, Some(response))
            }
            Err(fault) => {
                self.audit_host_session(
                    header,
                    remote,
                    session_id.as_deref(),
                    fault.code().as_str(),
                );
                Ok(error_exchange_with_body(header, fault.body()))
            }
        }
    }

    /// Enforcement point for the paired-peer allowlist. Legacy operations keep
    /// their trust-group/epoch check only; host session operations additionally
    /// require the peer to be paired when the host has a peer list.
    fn authorize_host_session(&self, remote: EndpointId) -> Result<(), HostSessionFault> {
        let Some(allowed) = self.config.allowed_peer_endpoint_ids.as_ref() else {
            return Ok(());
        };
        let remote = remote.to_string();
        if allowed.iter().any(|entry| entry == &remote) {
            Ok(())
        } else {
            Err(HostSessionFault::Unauthorized(
                "peer is not in this host's paired allowlist".into(),
            ))
        }
    }

    fn host_session_handler(&self) -> Result<&Arc<dyn HostSessionHandler>, HostSessionFault> {
        self.host_sessions.as_ref().ok_or_else(|| {
            HostSessionFault::Unsupported(
                "host session operations are not enabled on this host".into(),
            )
        })
    }

    fn audit_host_session(
        &self,
        header: &ReplicaRpcHeader,
        remote: EndpointId,
        session_id: Option<&str>,
        outcome: &str,
    ) {
        let remote_endpoint = remote.to_string();
        let audit = HostSessionAudit {
            operation: header.operation.as_str(),
            host_device_id: &self.config.device_id,
            remote_endpoint: &remote_endpoint,
            session_id,
            outcome,
        };
        info!("host session audit {}", audit.render());
    }
}

fn ok_exchange<B: Serialize>(
    request: &ReplicaRpcHeader,
    body: Option<B>,
) -> Result<MeshTransportExchange, ReplicaRpcError> {
    let header = request.response_for().encode()?;
    let body = match body {
        Some(value) => Some(serde_json::to_vec(&value)?),
        None => None,
    };
    Ok(MeshTransportExchange { header, body })
}

fn error_exchange(request: &ReplicaRpcHeader, code: &str) -> MeshTransportExchange {
    MeshTransportExchange {
        header: request
            .error_for(code)
            .encode()
            .unwrap_or_else(|_| b"{}".to_vec()),
        body: None,
    }
}

/// Reject a request with a structured host session error body when the
/// operation belongs to the host session contract, else keep the legacy
/// opaque error code.
fn reject_or_error(
    request: &ReplicaRpcHeader,
    legacy_code: &str,
    body: HostSessionErrorBody,
) -> MeshTransportExchange {
    if matches!(
        request.operation,
        ReplicaRpcOperation::HostSessionQuery | ReplicaRpcOperation::HostSessionAction
    ) {
        error_exchange_with_body(request, body)
    } else {
        error_exchange(request, legacy_code)
    }
}

fn error_exchange_with_body(
    request: &ReplicaRpcHeader,
    body: HostSessionErrorBody,
) -> MeshTransportExchange {
    let header = request.error_for(body.code.as_str());
    MeshTransportExchange {
        header: header.encode().unwrap_or_else(|_| b"{}".to_vec()),
        body: serde_json::to_vec(&body).ok(),
    }
}

fn map_exchange_error(error: MeshIrohError) -> ReplicaRpcError {
    match error {
        MeshIrohError::Timeout => {
            ReplicaRpcError::Unreachable("timed out waiting for peer response".into())
        }
        MeshIrohError::Iroh(message) => ReplicaRpcError::Unreachable(message),
        MeshIrohError::Io(error) => ReplicaRpcError::Unreachable(error.to_string()),
        other => ReplicaRpcError::Runtime(other.to_string()),
    }
}

fn decode_body<T: serde::de::DeserializeOwned>(
    body: Option<Vec<u8>>,
) -> Result<T, ReplicaRpcError> {
    let bytes = body.ok_or_else(|| ReplicaRpcError::Invalid("missing body".into()))?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn decode_required_body<T: serde::de::DeserializeOwned>(
    body: Option<&[u8]>,
) -> Result<T, ReplicaRpcError> {
    let bytes = body.ok_or_else(|| ReplicaRpcError::Invalid("missing body".into()))?;
    Ok(serde_json::from_slice(bytes)?)
}

fn synced_message(row: MessageRow) -> SyncedMessage {
    SyncedMessage {
        id: row.id,
        room_id: row.room_id,
        author_member_id: row.author_member_id,
        author_nick: row.author_nick,
        text: row.text,
        ts: row.ts,
        reply_to_message_id: row.reply_to_message_id,
        target_member_ids_json: row.target_member_ids_json,
        attachments_json: row.attachments_json,
    }
}

fn message_row(message: &SyncedMessage) -> MessageRow {
    MessageRow {
        id: message.id.clone(),
        room_id: message.room_id.clone(),
        author_member_id: message.author_member_id.clone(),
        author_nick: message.author_nick.clone(),
        text: message.text.clone(),
        ts: message.ts,
        reply_to_message_id: message.reply_to_message_id.clone(),
        target_member_ids_json: message.target_member_ids_json.clone(),
        attachments_json: message.attachments_json.clone(),
    }
}
