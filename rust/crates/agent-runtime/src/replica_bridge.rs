//! Replica / Peer RPC bridge hooks for `pharos-meshd` (RFC-007 S3).
//!
//! This module stays deliberately thin: it mirrors the frozen allowlists the
//! daemon advertises/serves. The actual Peer RPC transport lives in
//! [`pharos_replica::ReplicaHandle`], wired by [`crate::mesh_bridge`].
//!
//! Cross-host sessions are *not* a closed Thread loop: a Host only answers
//! `host.session.query.v1` / `host.session.action.v1` through the local
//! SessionService. Any Thread closed loop belongs to
//! `integrations/dsh-plugin-pharos`.

#![allow(dead_code)]

use pharos_protocol::host_session::{ACTION_CAPABILITY, QUERY_CAPABILITY};

/// Methods allowlisted for Peer `host.runtime.call.v1`.
pub const HOST_RUNTIME_ALLOWED_METHODS: &[&str] = pharos_protocol::HOST_RUNTIME_ALLOWED_METHODS;

/// Capabilities advertised by a Host that serves cross-host session RPCs
/// (`host.runtime.hello.v1`). Kept in sync with the wire contract in
/// `pharos_protocol::host_session`.
pub const HOST_SESSION_CAPABILITIES: &[&str] = &[QUERY_CAPABILITY, ACTION_CAPABILITY];

/// Operations served by [`crate::mesh_bridge`] when the daemon is configured
/// with `--mesh-data-dir`.
pub const HOST_SESSION_OPERATIONS: &[&str] = &["host.session.query.v1", "host.session.action.v1"];

pub fn describe_wiring() -> &'static str {
    "mod replica_bridge; // mirrors Peer allowlists; ReplicaHandle wired by mesh_bridge (host.runtime.call + host.session.*)"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlists_mirror_the_frozen_protocol_contract() {
        assert_eq!(
            HOST_RUNTIME_ALLOWED_METHODS,
            pharos_protocol::HOST_RUNTIME_ALLOWED_METHODS
        );
        assert!(HOST_RUNTIME_ALLOWED_METHODS.contains(&"delivery.submit-member"));
        assert!(HOST_SESSION_CAPABILITIES.contains(&"host-session-query-v1"));
        assert!(HOST_SESSION_CAPABILITIES.contains(&"host-session-action-v1"));
        assert_eq!(HOST_SESSION_OPERATIONS.len(), 2);
    }

    #[test]
    fn describe_wiring_mentions_replica_handle() {
        assert!(describe_wiring().contains("ReplicaHandle"));
    }
}
