//! Session service for RFC-007 stream S2.
//!
//! Consumes vendor drivers as [`pharos_codex_adapter::SessionAdapter`] (`dyn`).
//! Emits [`pharos_api::ClientEvent`] shapes for S4 WS bridging.

mod error;
mod events;
mod service;

pub use error::SessionError;
pub use events::{
    EventSink, RecordingEventSink, emit_approval_required, emit_approval_resolved, emit_progress,
};
pub use service::{AdapterSessionService, SessionService};
