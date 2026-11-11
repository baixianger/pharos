//! S1/S2 service traits consumed by HTTP handlers, plus the real
//! implementations used by the default `pharos-web` binary.
//!
//! - [`real`] — durable `pharos-thread` / `pharos-session` backed services
//!   (default binary wiring).
//! - [`fake`] — in-memory stand-ins, only used by tests or the explicit
//!   `--fake` flag; every type is named `Fake*` so they cannot be mistaken for
//!   production backends.

mod event_bus;
pub mod fake;
mod real;
mod real_session;
mod real_thread;
mod session;
mod thread;

pub use event_bus::{EventBus, EventSubscriber};
pub use fake::{FakeEventBus, FakeSessionService, FakeThreadService};
pub use real::{RealOptions, RealServiceError, SessionAdapterChoice, build_real_app_state};
pub use real_session::RealSessionService;
pub use real_thread::RealThreadService;
pub use session::{CreateSessionRequest, SessionService};
pub use thread::{CreateThreadRequest, ThreadService};
