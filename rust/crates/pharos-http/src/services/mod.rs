//! S1/S2 service traits consumed by HTTP handlers.
//!
//! Real implementations land in other streams. This crate ships
//! [`fake`] implementations labeled as such for S4 acceptance tests.

mod event_bus;
pub mod fake;
mod session;
mod thread;

pub use event_bus::{EventBus, EventSubscriber};
pub use fake::{FakeEventBus, FakeSessionService, FakeThreadService};
pub use session::SessionService;
pub use thread::ThreadService;
