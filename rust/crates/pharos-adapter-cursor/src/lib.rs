//! Pharos Cursor `agent` CLI adapter (RFC-007 stream S5d).
//!
//! Drives the public Cursor CLI in headless `--print` / `stream-json` mode.
//! Does **not** read `~/.cursor` private databases, GUI state, or tokens.
//!
//! Implements [`SessionAdapter`] / [`DeliveryWorker`] from
//! `pharos-codex-adapter` (current trait home until a Phase 0.x contract bump).

pub mod cli;
pub mod cursor;
pub mod resolve;

pub use cursor::{CursorSessionAdapter, msg_test_root, unsupported_list_chats};
pub use resolve::resolve_agent_executable;

pub use pharos_codex_adapter::{
    AdapterError, DeliveryDispatchResult, DeliveryJob, DeliveryWorker, InterruptOutcome,
    PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn, TurnOutcome,
    TurnStatus, format_delivery_prompt,
};
