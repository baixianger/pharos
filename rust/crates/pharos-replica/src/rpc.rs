//! Peer RPC header/body types for ReplicaHandle.
//!
//! Operation IDs come from `pharos-protocol::ReplicaRpcOperation`. Disposition
//! uses the Phase 0 contract (`request`/`response`/`error` camelCase). Note:
//! live Swift MeshReplicaRPC still uses `success`/`failure` — a contract bump
//! would be required for bit-identical Swift wire interop; Rust↔Rust XHOST uses
//! these Phase 0 names.

use pharos_protocol::host_session::HostSessionErrorCode;
use pharos_protocol::{
    AGENT_RUNTIME_PROTOCOL_VERSION, AGENT_RUNTIME_SERVICE, HOST_RUNTIME_ALLOWED_METHODS,
    ReplicaRpcDisposition, ReplicaRpcOperation, runtime_methods,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum ReplicaRpcError {
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("invalid rpc: {0}")]
    Invalid(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("runtime: {0}")]
    Runtime(String),
    #[error("store: {0}")]
    Store(String),
    /// Structured host session failure reported by the target host.
    #[error("host session {}: {message}", code.as_str())]
    HostSession {
        code: HostSessionErrorCode,
        message: String,
    },
    /// The peer could not be reached at the transport level (offline/timeout).
    #[error("peer unreachable: {0}")]
    Unreachable(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaRpcHeader {
    pub version: u32,
    pub request_id: Uuid,
    pub operation: ReplicaRpcOperation,
    pub trust_group_id: String,
    pub membership_epoch: u64,
    pub disposition: ReplicaRpcDisposition,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

impl ReplicaRpcHeader {
    pub fn request(
        operation: ReplicaRpcOperation,
        trust_group_id: impl Into<String>,
        membership_epoch: u64,
    ) -> Self {
        Self {
            version: 1,
            request_id: Uuid::new_v4(),
            operation,
            trust_group_id: trust_group_id.into(),
            membership_epoch,
            disposition: ReplicaRpcDisposition::Request,
            error_code: None,
        }
    }

    pub fn response_for(&self) -> Self {
        Self {
            version: self.version,
            request_id: self.request_id,
            operation: self.operation,
            trust_group_id: self.trust_group_id.clone(),
            membership_epoch: self.membership_epoch,
            disposition: ReplicaRpcDisposition::Response,
            error_code: None,
        }
    }

    pub fn error_for(&self, code: impl Into<String>) -> Self {
        Self {
            version: self.version,
            request_id: self.request_id,
            operation: self.operation,
            trust_group_id: self.trust_group_id.clone(),
            membership_epoch: self.membership_epoch,
            disposition: ReplicaRpcDisposition::Error,
            error_code: Some(code.into()),
        }
    }

    pub fn encode(&self) -> Result<Vec<u8>, ReplicaRpcError> {
        Ok(serde_json::to_vec(self)?)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, ReplicaRpcError> {
        Ok(serde_json::from_slice(bytes)?)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostRuntimeHello {
    pub host_device_id: String,
    pub service: String,
    pub protocol_version: u32,
    pub capabilities: Vec<String>,
}

impl HostRuntimeHello {
    pub fn local(host_device_id: impl Into<String>) -> Self {
        Self {
            host_device_id: host_device_id.into(),
            service: AGENT_RUNTIME_SERVICE.to_string(),
            protocol_version: AGENT_RUNTIME_PROTOCOL_VERSION,
            capabilities: vec![runtime_methods::DELIVERY_SUBMIT_MEMBER.to_string()],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostRuntimeCallRequest {
    pub host_device_id: String,
    pub jsonrpc_request: String,
}

impl HostRuntimeCallRequest {
    pub fn validate(&self) -> Result<(), ReplicaRpcError> {
        if self.host_device_id.is_empty() || self.jsonrpc_request.is_empty() {
            return Err(ReplicaRpcError::Invalid("empty host call".into()));
        }
        if self.jsonrpc_request.len() > 1024 * 1024 {
            return Err(ReplicaRpcError::Invalid("request too large".into()));
        }
        let value: serde_json::Value = serde_json::from_str(&self.jsonrpc_request)
            .map_err(|e| ReplicaRpcError::Invalid(format!("jsonrpc parse: {e}")))?;
        if value.get("jsonrpc").and_then(|v| v.as_str()) != Some("2.0") {
            return Err(ReplicaRpcError::Invalid("jsonrpc version".into()));
        }
        if value.get("id").is_none() {
            return Err(ReplicaRpcError::Invalid("jsonrpc id required".into()));
        }
        let method = value
            .get("method")
            .and_then(|v| v.as_str())
            .ok_or_else(|| ReplicaRpcError::Invalid("jsonrpc method required".into()))?;
        if !HOST_RUNTIME_ALLOWED_METHODS.contains(&method) {
            return Err(ReplicaRpcError::Unauthorized(format!(
                "method not allowlisted: {method}"
            )));
        }
        let params = value
            .get("params")
            .and_then(|v| v.as_object())
            .ok_or_else(|| ReplicaRpcError::Invalid("params object required".into()))?;
        let member = params
            .get("memberID")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let key = params
            .get("idempotencyKey")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if member.is_empty() || key.is_empty() {
            return Err(ReplicaRpcError::Invalid(
                "memberID and idempotencyKey required".into(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostRuntimeCallResponse {
    pub host_device_id: String,
    pub jsonrpc_response: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncedMessage {
    pub id: String,
    pub room_id: String,
    pub author_member_id: Option<String>,
    pub author_nick: String,
    pub text: String,
    pub ts: f64,
    pub reply_to_message_id: Option<String>,
    #[serde(default = "empty_json_array")]
    pub target_member_ids_json: String,
    #[serde(default = "empty_json_array")]
    pub attachments_json: String,
}

fn empty_json_array() -> String {
    "[]".into()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaSyncPullRequest {
    #[serde(default)]
    pub room_id: Option<String>,
    #[serde(default)]
    pub since_ts: f64,
    #[serde(default = "default_limit")]
    pub limit: i64,
}

fn default_limit() -> i64 {
    256
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaSyncPullResponse {
    pub messages: Vec<SyncedMessage>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaSyncPushRequest {
    pub messages: Vec<SyncedMessage>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplicaSyncPushResponse {
    pub applied: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use pharos_protocol::ReplicaRpcDisposition;

    #[test]
    fn header_roundtrip_uses_contract_disposition() {
        let header = ReplicaRpcHeader::request(ReplicaRpcOperation::HostRuntimeCall, "tg", 1);
        let bytes = header.encode().unwrap();
        let text = String::from_utf8(bytes.clone()).unwrap();
        assert!(text.contains("\"disposition\":\"request\""));
        let back = ReplicaRpcHeader::decode(&bytes).unwrap();
        assert_eq!(back.disposition, ReplicaRpcDisposition::Request);
        assert_eq!(back.operation, ReplicaRpcOperation::HostRuntimeCall);
    }

    #[test]
    fn host_runtime_call_allowlist() {
        let ok = HostRuntimeCallRequest {
            host_device_id: "h1".into(),
            jsonrpc_request: serde_json::json!({
                "jsonrpc": "2.0",
                "id": "1",
                "method": "delivery.submit-member",
                "params": {
                    "memberID": "m1",
                    "idempotencyKey": "k1",
                    "payload": "{}"
                }
            })
            .to_string(),
        };
        ok.validate().unwrap();

        let bad = HostRuntimeCallRequest {
            host_device_id: "h1".into(),
            jsonrpc_request: serde_json::json!({
                "jsonrpc": "2.0",
                "id": "1",
                "method": "delivery.submit",
                "params": { "memberID": "m1", "idempotencyKey": "k1" }
            })
            .to_string(),
        };
        assert!(bad.validate().is_err());
    }
}
