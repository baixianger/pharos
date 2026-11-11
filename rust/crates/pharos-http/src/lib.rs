//! RFC-007 Stream S4 — HTTP/WS API layer.
//!
//! Mounts `pharos-api` routes and DTOs. Handlers call S1 (Thread) / S2 (Session)
//! service traits. The default `pharos-web` binary wires the real durable
//! backends ([`services::build_real_app_state`]); the clearly named **fake**
//! services in [`services::fake`] remain for tests and the explicit `--fake`
//! flag.

pub mod error;
pub mod router;
pub mod services;
pub mod state;
pub mod ws;

pub use router::api_router;
pub use services::{
    CreateSessionRequest, CreateThreadRequest, EventBus, EventSubscriber, FakeEventBus,
    FakeSessionService, FakeThreadService, RealOptions, RealServiceError, RealSessionService,
    RealThreadService, SessionAdapterChoice, SessionService, ThreadService, build_real_app_state,
};
pub use state::AppState;
