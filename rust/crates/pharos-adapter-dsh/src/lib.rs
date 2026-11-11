//! Pharos DSH adapter (RFC-007 stream S5b).
//!
//! Thin client over an isolated `dsh web` Host (HTTP + journal poll), implementing
//! the shared [`SessionAdapter`] / [`DeliveryWorker`] traits currently defined in
//! `pharos-codex-adapter` (contract-bump proposal: promote those traits).
//!
//! Honesty boundary: the adapter only reports a terminal turn it observed; it
//! never posts the room reply itself and never reports `delivered`. The actual
//! `delivery.poll` -> `agent.followup` -> `delivery.ack` loop lives in the DSH
//! plugin (`integrations/dsh-plugin-pharos`), and the Codex final-answer relay
//! lives in `pharos-agent-runtime` (`reply_sink.rs`).

mod adapter;
mod history;
mod host;
mod transport;

pub use adapter::{DshSessionAdapter, RUNTIME_DRIVER_CAPABILITIES, msg_test_root};
pub use history::{TurnRecord, parse_turns};
pub use host::{DshHost, DshHostConfig, prepare_isolated_home};
pub use transport::DshHttpTransport;

// Re-export the shared adapter surface S2 will consume (current location).
pub use pharos_codex_adapter::{
    AdapterError, DeliveryDispatchResult, DeliveryJob, DeliveryWorker, InterruptOutcome,
    PromptMode, SessionAdapter, StartSessionRequest, StartedSession, StartedTurn, TurnOutcome,
    TurnStatus, format_delivery_prompt,
};
