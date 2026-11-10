//! `ReplicaHandle` — Peer RPC + local replica mutations for other streams.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use pharos_iroh::{EndpointAddr, EndpointId, MeshIrohEndpoint, MeshTransportExchange, PeerDial};
use pharos_protocol::ReplicaRpcOperation;
use serde::Serialize;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::rpc::{
    HostRuntimeCallRequest, HostRuntimeCallResponse, HostRuntimeHello, ReplicaRpcError,
    ReplicaRpcHeader, ReplicaSyncPullRequest, ReplicaSyncPullResponse, ReplicaSyncPushRequest,
    ReplicaSyncPushResponse, SyncedMessage,
};
use crate::runtime_client::RuntimeClient;
use crate::store::{MessageRow, ReplicaStore};

#[derive(Debug, Clone)]
pub struct ReplicaHandleConfig {
    pub data_dir: PathBuf,
    pub device_id: String,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    /// Optional local agent-runtime Unix socket for host.runtime.call forwarding.
    pub runtime_socket: Option<PathBuf>,
    /// Disable iroh relays (LAN / loopback smoke).
    pub relay_disabled: bool,
}

/// Process-local handle exposing replica store + Peer RPC over iroh.
pub struct ReplicaHandle {
    store: Arc<Mutex<ReplicaStore>>,
    endpoint: MeshIrohEndpoint,
    config: ReplicaHandleConfig,
    runtime: Option<RuntimeClient>,
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
        let handle = Arc::new(Self {
            store: Arc::new(Mutex::new(store)),
            endpoint,
            config,
            runtime,
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
        HostRuntimeHello::local(&self.config.device_id)
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

    pub async fn shutdown(self: Arc<Self>) -> Result<(), ReplicaRpcError> {
        // Endpoint shutdown requires ownership; Arc makes this best-effort.
        // Callers in smoke tests drop processes instead.
        let _ = self;
        Ok(())
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
            .map_err(|e| ReplicaRpcError::Runtime(e.to_string()))?;
        let response_header = ReplicaRpcHeader::decode(&response.header)?;
        if response_header.disposition == pharos_protocol::ReplicaRpcDisposition::Error {
            return Err(ReplicaRpcError::Runtime(
                response_header
                    .error_code
                    .unwrap_or_else(|| "peer-error".into()),
            ));
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
            return Ok(error_exchange(&header, "trust-group-mismatch"));
        }
        if header.membership_epoch != self.config.membership_epoch {
            return Ok(error_exchange(&header, "membership-epoch-mismatch"));
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
            ReplicaRpcOperation::HostSessionQuery | ReplicaRpcOperation::HostSessionAction => {
                Ok(error_exchange(&header, "unsupported-operation"))
            }
        }
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
