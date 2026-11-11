//! HITL / human-proxy hooks for `pharos-meshd` (RFC-007 S2).
//!
//! Merge captain: `mod hitl_bridge;` — see `docs/wiring-session-hitl.md`.
//! Full HITL bridge lives in `pharos-hitl`; this module only documents the
//! daemon integration point.

#![allow(dead_code)]

pub fn describe_wiring() -> &'static str {
    "mod hitl_bridge; // captain: HitlBridge + CodexHitlClient for deferred approvals"
}
