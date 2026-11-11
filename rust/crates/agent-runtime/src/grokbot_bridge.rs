//! Grokbot bridge hooks for `pharos-meshd` (RFC-007 S1).
//!
//! Merge captain: `mod grokbot_bridge;` — see `docs/wiring-cli-thread.md`.
//! Runtime poll loop lives in `pharos-grokbot` / `pharos` CLI `grokbot serve`.

#![allow(dead_code)]

pub fn describe_wiring() -> &'static str {
    "mod grokbot_bridge; // captain: optional spawn of GrokbotThreadBridge beside Runtime"
}
