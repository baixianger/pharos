//! Mesh node + trust-group pairing for RFC-007 S3.
//!
//! Exposes helpers used by `pharos-mesh-node` and by agent-runtime wiring snippets.

mod pairing;

pub use pairing::{
    IssueInvitationArgs, PairingError, TrustAcceptance, TrustInvitation, accept_invitation,
    decode_ticket, encode_ticket, issue_invitation, verify_acceptance,
};
pub use pharos_iroh::{EndpointAddr, EndpointId, PHAROS_MESH_ALPN, PeerDial};
pub use pharos_replica::{
    HostRuntimeCallRequest, HostRuntimeCallResponse, HostRuntimeHello, HostSessionFault,
    HostSessionHandler, ReplicaHandle, ReplicaHandleConfig, ReplicaSyncPullRequest,
    ReplicaSyncPushRequest, SyncedMessage,
};

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum MeshError {
    #[error("pairing: {0}")]
    Pairing(#[from] PairingError),
    #[error("replica: {0}")]
    Replica(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshNodeIdentity {
    pub device_id: String,
    pub display_name: String,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    pub signing_public_key_b64: String,
    pub roles: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeshPeerRecord {
    pub device_id: String,
    pub endpoint_id: String,
    pub display_name: String,
    pub roles: Vec<String>,
    #[serde(default)]
    pub endpoint_addr_json: Option<String>,
}

/// Initialize a new trust group + device identity under `data_dir`.
pub fn init_node(
    data_dir: &std::path::Path,
    display_name: &str,
) -> Result<(MeshNodeIdentity, ed25519_dalek::SigningKey), MeshError> {
    std::fs::create_dir_all(data_dir)?;
    let signing = ed25519_dalek::SigningKey::generate(&mut rand::rngs::OsRng);
    let device_id = uuid::Uuid::new_v4().to_string();
    let trust_group_id = uuid::Uuid::new_v4().to_string();
    let identity = MeshNodeIdentity {
        device_id: device_id.clone(),
        display_name: display_name.to_string(),
        trust_group_id: trust_group_id.clone(),
        membership_epoch: 1,
        signing_public_key_b64: base64::Engine::encode(
            &base64::engine::general_purpose::STANDARD,
            signing.verifying_key().as_bytes(),
        ),
        roles: vec!["controller".into(), "host".into(), "replica".into()],
    };
    std::fs::write(
        data_dir.join("node-identity.json"),
        serde_json::to_vec_pretty(&identity)?,
    )?;
    std::fs::write(data_dir.join("signing.key"), signing.to_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(
            data_dir.join("signing.key"),
            std::fs::Permissions::from_mode(0o600),
        );
    }
    let store = pharos_replica::ReplicaStore::open(data_dir)
        .map_err(|e| MeshError::Replica(e.to_string()))?;
    store
        .upsert_trust_group(&trust_group_id, 1, "{}")
        .map_err(|e| MeshError::Replica(e.to_string()))?;
    store
        .upsert_device_identity(
            &device_id,
            &identity.signing_public_key_b64,
            &serde_json::json!({
                "displayName": display_name,
                "roles": identity.roles,
            })
            .to_string(),
        )
        .map_err(|e| MeshError::Replica(e.to_string()))?;
    Ok((identity, signing))
}

pub fn load_identity(data_dir: &std::path::Path) -> Result<MeshNodeIdentity, MeshError> {
    let bytes = std::fs::read(data_dir.join("node-identity.json"))?;
    Ok(serde_json::from_slice(&bytes)?)
}

pub fn load_signing_key(
    data_dir: &std::path::Path,
) -> Result<ed25519_dalek::SigningKey, MeshError> {
    let bytes = std::fs::read(data_dir.join("signing.key"))?;
    if bytes.len() != 32 {
        return Err(MeshError::Replica(format!(
            "signing.key must be 32 bytes, got {}",
            bytes.len()
        )));
    }
    let mut key = [0u8; 32];
    key.copy_from_slice(&bytes);
    Ok(ed25519_dalek::SigningKey::from_bytes(&key))
}

pub fn save_peer(data_dir: &std::path::Path, peer: &MeshPeerRecord) -> Result<(), MeshError> {
    let path = data_dir.join("peers.json");
    let mut peers: Vec<MeshPeerRecord> = if path.exists() {
        serde_json::from_slice(&std::fs::read(&path)?)?
    } else {
        Vec::new()
    };
    peers.retain(|p| p.device_id != peer.device_id);
    peers.push(peer.clone());
    std::fs::write(path, serde_json::to_vec_pretty(&peers)?)?;
    Ok(())
}

pub fn load_peers(data_dir: &std::path::Path) -> Result<Vec<MeshPeerRecord>, MeshError> {
    let path = data_dir.join("peers.json");
    if !path.exists() {
        return Ok(Vec::new());
    }
    Ok(serde_json::from_slice(&std::fs::read(path)?)?)
}

/// Paired-peer endpoint IDs recorded in `peers.json`.
///
/// Used as the host session allowlist: once a Host has paired peers, only they
/// may query/act on its sessions. An absent/empty peer list keeps the legacy
/// trust-group + membership-epoch authorization.
pub fn paired_peer_endpoint_ids(
    data_dir: &std::path::Path,
) -> Result<Option<Vec<String>>, MeshError> {
    let peers = load_peers(data_dir)?;
    let ids: Vec<String> = peers
        .into_iter()
        .map(|peer| peer.endpoint_id)
        .filter(|id| !id.is_empty())
        .collect();
    Ok(if ids.is_empty() { None } else { Some(ids) })
}

pub async fn open_handle(
    data_dir: PathBuf,
    runtime_socket: Option<PathBuf>,
    relay_disabled: bool,
) -> Result<Arc<ReplicaHandle>, MeshError> {
    open_handle_with_host_sessions(data_dir, runtime_socket, relay_disabled, None).await
}

/// Open a replica handle that also serves cross-host session queries/actions
/// through `handler` to the local SessionService.
pub async fn open_handle_with_host_sessions(
    data_dir: PathBuf,
    runtime_socket: Option<PathBuf>,
    relay_disabled: bool,
    handler: Option<Arc<dyn HostSessionHandler>>,
) -> Result<Arc<ReplicaHandle>, MeshError> {
    let identity = load_identity(&data_dir)?;
    let allowed_peer_endpoint_ids = paired_peer_endpoint_ids(&data_dir)?;
    ReplicaHandle::open(ReplicaHandleConfig {
        data_dir,
        device_id: identity.device_id,
        trust_group_id: identity.trust_group_id,
        membership_epoch: identity.membership_epoch,
        runtime_socket,
        relay_disabled,
        host_session_handler: handler,
        allowed_peer_endpoint_ids,
    })
    .await
    .map_err(|e| MeshError::Replica(e.to_string()))
}
