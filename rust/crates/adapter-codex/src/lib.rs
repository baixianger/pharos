//! Pharos Codex adapter (RFC-007 stream S5a).
//!
//! Provides:
//! - [`SessionAdapter`] / [`DeliveryWorker`] traits (contract-bump proposal for S2)
//! - [`CodexSessionAdapter`] over Codex CLI App Server 0.167
//! - JSONL daemon-proxy bridge binary compatibility for `pharos-meshd`

pub mod codex;
pub mod delivery;
pub mod error;
pub mod resolve;
pub mod session;
pub mod transport;

pub use codex::{CodexSessionAdapter, msg_test_root, run_jsonl_daemon_proxy_bridge};
pub use delivery::{DeliveryDispatchResult, DeliveryJob, DeliveryWorker, format_delivery_prompt};
pub use error::AdapterError;
pub use session::{
    InterruptOutcome, PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn,
    TurnOutcome, TurnStatus,
};
pub use transport::{AppServerTransport, CodexTransport, DaemonProxyAppServer, StdioAppServer};
