//! RFC-007 Phase 0 protocol contracts shared by all parallel streams.
//!
//! Streams must depend on these type IDs instead of inventing ad-hoc strings.
//! Bumping anything here requires a Phase 0.x contract bump (`CONTRACTS_VERSION`).

use serde::{Deserialize, Serialize};

/// Cross-Host Session query/action wire bodies (`host.session.query.v1` /
/// `host.session.action.v1`). Additive: payloads carry their own version.
pub mod host_session;

/// Frozen contract semver for this Phase 0 tag (`rust-contracts-0.1.0`).
pub const CONTRACTS_VERSION: &str = "0.1.0";

/// Agent Runtime JSON-RPC service name (Swift `AgentRuntimeProtocol.service`).
pub const AGENT_RUNTIME_SERVICE: &str = "me.pai.pharos.agent-runtime";

/// Agent Runtime protocol integer version.
pub const AGENT_RUNTIME_PROTOCOL_VERSION: u32 = 1;

// ---------------------------------------------------------------------------
// Runtime delivery & session state (Swift AgentContracts)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DeliveryState {
    Queued,
    Accepted,
    Injected,
    Consumed,
    Completed,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeOwnership {
    Managed,
    Attached,
    External,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionPresence {
    Connecting,
    Online,
    Offline,
    Stale,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionActivity {
    Unknown,
    Idle,
    Running,
    Stopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionAttention {
    None,
    WaitingForInput,
    WaitingForApproval,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionPersistence {
    Ephemeral,
    Persistent,
    Archived,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionStateSource {
    NativeProtocol,
    StructuredHook,
    Heartbeat,
    Inferred,
}

/// Runtime JSON-RPC methods used by bridges and Peer allowlists.
pub mod runtime_methods {
    pub const DRIVER_REGISTER: &str = "driver.register";
    pub const DRIVER_HEARTBEAT: &str = "driver.heartbeat";
    pub const CONVERSATION_REGISTER: &str = "conversation.register";
    pub const CONVERSATION_STATE: &str = "conversation.state";
    pub const DELIVERY_SUBMIT: &str = "delivery.submit";
    pub const DELIVERY_SUBMIT_MEMBER: &str = "delivery.submit-member";
    pub const DELIVERY_POLL: &str = "delivery.poll";
    pub const DELIVERY_ACK: &str = "delivery.ack";
    pub const RUNTIME_SNAPSHOT: &str = "runtime.snapshot";
    pub const LAUNCH_POLL: &str = "launch.poll";
    pub const LAUNCH_ACK: &str = "launch.ack";
}

/// Peer Host Runtime call allowlist (Swift `MeshReplicaRPC` host.runtime.call.v1).
pub const HOST_RUNTIME_ALLOWED_METHODS: &[&str] = &[runtime_methods::DELIVERY_SUBMIT_MEMBER];

// ---------------------------------------------------------------------------
// Mesh / replica RPC operation IDs
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ReplicaRpcOperation {
    #[serde(rename = "host.runtime.hello.v1")]
    HostRuntimeHello,
    #[serde(rename = "host.runtime.call.v1")]
    HostRuntimeCall,
    #[serde(rename = "replica.sync.pull.v1")]
    ReplicaSyncPull,
    #[serde(rename = "replica.sync.push.v1")]
    ReplicaSyncPush,
    #[serde(rename = "host.session.query.v1")]
    HostSessionQuery,
    #[serde(rename = "host.session.action.v1")]
    HostSessionAction,
}

impl ReplicaRpcOperation {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::HostRuntimeHello => "host.runtime.hello.v1",
            Self::HostRuntimeCall => "host.runtime.call.v1",
            Self::ReplicaSyncPull => "replica.sync.pull.v1",
            Self::ReplicaSyncPush => "replica.sync.push.v1",
            Self::HostSessionQuery => "host.session.query.v1",
            Self::HostSessionAction => "host.session.action.v1",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ReplicaRpcDisposition {
    Request,
    Response,
    Error,
}

// ---------------------------------------------------------------------------
// Thread receipts (client-facing mesh delivery honesty)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThreadReceiptState {
    Pending,
    Delivered,
    Consumed,
    UnverifiedFallback,
    DeliveryUncertain,
    DeliveryRejected,
    DeliveryMixed,
}

// ---------------------------------------------------------------------------
// Grokbot / human-proxy wake protocol (ID-only payloads)
// ---------------------------------------------------------------------------

pub mod grokbot {
    pub const MEMBER_ID: &str = "grokbot";
    pub const DISPLAY_NICK: &str = "Pharos";
    pub const AGENT_KIND: &str = "grokbot";
    /// Reply timeout after webhook inject (seconds).
    pub const REPLY_TIMEOUT_SECS: u64 = 45 * 60;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum WebhookKind {
    ThreadMention,
    HitlRequest,
}

/// Wake-only Thread mention (never carries message body or secrets).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadMentionWake {
    pub kind: WebhookKind,
    pub thread: String,
    pub message: String,
    pub from: String,
    pub host: String,
}

impl ThreadMentionWake {
    pub fn new(
        thread: impl Into<String>,
        message: impl Into<String>,
        from: impl Into<String>,
        host: impl Into<String>,
    ) -> Self {
        Self {
            kind: WebhookKind::ThreadMention,
            thread: thread.into(),
            message: message.into(),
            from: from.into(),
            host: host.into(),
        }
    }
}

// ---------------------------------------------------------------------------
// Adapter kind identifiers (S5 streams)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum AdapterKind {
    Codex,
    Dsh,
    Agy,
    Cursor,
    Grokbot,
}

impl AdapterKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Dsh => "dsh",
            Self::Agy => "agy",
            Self::Cursor => "cursor",
            Self::Grokbot => "grokbot",
        }
    }
}

// ---------------------------------------------------------------------------
// Wire event type IDs for mesh/runtime buses (not HTTP WS — see pharos-api)
// ---------------------------------------------------------------------------

pub mod wire_events {
    pub const DELIVERY_QUEUED: &str = "delivery.queued";
    pub const DELIVERY_ACKED: &str = "delivery.acked";
    pub const CONVERSATION_STATE: &str = "conversation.state";
    pub const MEMBER_PRESENCE: &str = "member.presence";
    pub const REPLICA_APPLIED: &str = "replica.applied";
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contracts_version_is_phase0() {
        assert_eq!(CONTRACTS_VERSION, "0.1.0");
    }

    #[test]
    fn thread_mention_is_id_only_shape() {
        let wake = ThreadMentionWake::new("t1", "m1", "human", "mini");
        let v = serde_json::to_value(&wake).unwrap();
        assert_eq!(v["kind"], "thread-mention");
        assert!(v.get("text").is_none());
        assert!(v.get("body").is_none());
    }

    #[test]
    fn delivery_state_roundtrip() {
        let raw = serde_json::to_string(&DeliveryState::Injected).unwrap();
        assert_eq!(raw, "\"injected\"");
        let back: DeliveryState = serde_json::from_str(&raw).unwrap();
        assert_eq!(back, DeliveryState::Injected);
    }
}
