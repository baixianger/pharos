//! Replica / Peer RPC bridge hooks for `pharos-meshd` (RFC-007 S3).
//!
//! Merge captain: `mod replica_bridge;` then expose host.runtime.call forwarding
//! through `ReplicaHandle` once `pharos-replica` is a workspace dependency of
//! this binary. See `docs/wiring-mesh-iroh.md`.

#![allow(dead_code)]

/// Methods allowlisted for Peer `host.runtime.call.v1` (mirrors
/// `pharos_protocol::HOST_RUNTIME_ALLOWED_METHODS`).
pub const HOST_RUNTIME_ALLOWED_METHODS: &[&str] = &["delivery.submit-member"];

pub fn describe_wiring() -> &'static str {
    "mod replica_bridge; // captain: forward Peer host.runtime.call → Registry::invoke"
}
