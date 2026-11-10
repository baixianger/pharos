//! Session service hooks for `pharos-meshd` (RFC-007 S2).
//!
//! Merge captain: `mod session_service;` — see `docs/wiring-session-hitl.md`.
//! Full `SessionService` lives in `pharos-session`; this module only documents
//! the daemon integration point.

#![allow(dead_code)]

pub fn describe_wiring() -> &'static str {
    "mod session_service; // captain: AdapterSessionService over dyn SessionAdapter + GoalsStore"
}
