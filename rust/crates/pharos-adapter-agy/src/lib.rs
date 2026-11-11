//! Pharos Agy adapter (RFC-007 stream S5c).
//!
//! Provides:
//! - [`SessionAdapter`] / [`DeliveryWorker`] traits (**mirrored** from S5a
//!   `pharos-codex-adapter`; contract-bump proposal for Phase 0.x)
//! - [`AgySessionAdapter`] over Antigravity CLI ACP (`agy acp --stdio`)

pub mod agy;
pub mod delivery;
pub mod error;
pub mod resolve;
pub mod session;
pub mod transport;

pub use agy::{AgySessionAdapter, msg_test_root};
pub use delivery::{DeliveryDispatchResult, DeliveryJob, DeliveryWorker, format_delivery_prompt};
pub use error::AdapterError;
pub use resolve::resolve_agy_executable;
pub use session::{
    InterruptOutcome, PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn,
    TurnOutcome, TurnStatus,
};
pub use transport::{AcpSpawnOptions, AcpTransport};
