//! Session service for RFC-007 stream S2.
//!
//! Consumes vendor drivers as [`pharos_codex_adapter::SessionAdapter`] (`dyn`).
//! Emits [`pharos_api::ClientEvent`] shapes for S4 WS bridging.
//!
//! Cross-host (mesh) support:
//! - [`host_bridge`] — callee side: serves another host's `host.session.*`
//!   queries/actions from the local [`SessionService`].
//! - [`remote`] — caller side: [`MeshRemoteHostSessionSource`] queries/actions
//!   another host over the Peer RPC contract and namespaces its session ids as
//!   `peer:<host>:<session>`.

mod error;
mod events;
pub mod host_bridge;
pub mod remote;
mod service;

pub use error::SessionError;
pub use events::{
    EventSink, RecordingEventSink, emit_approval_required, emit_approval_resolved, emit_progress,
};
pub use host_bridge::SessionServiceHostHandler;
pub use remote::{
    MeshRemoteHostSessionSource, REMOTE_SESSION_PREFIX, RemoteSessionSource, is_remote_session_id,
    remote_session_id, split_remote_session_id,
};
pub use service::{AdapterSessionService, SessionService};
