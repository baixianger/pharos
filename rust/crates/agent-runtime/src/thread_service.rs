//! Thread service hooks for `pharos-meshd` (RFC-007 S1).
//!
//! Merge captain: `mod thread_service;` — see `docs/wiring-cli-thread.md`.
//! Full `ThreadService` lives in `pharos-thread`; this module only documents
//! the daemon integration point.

#![allow(dead_code)]

pub fn describe_wiring() -> &'static str {
    "mod thread_service; // captain: open pharos_thread::SqliteThreadStore from data-dir"
}
