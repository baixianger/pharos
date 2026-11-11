//! S1/S2 service traits consumed by HTTP handlers, plus the real
//! implementations used by the default `pharos-web` binary.
//!
//! - [`real`] — durable `pharos-thread` / `pharos-session` backed services
//!   (default binary wiring).
//! - [`fake`] — in-memory stand-ins, only used by tests or the explicit
//!   `--fake` flag; every type is named `Fake*` so they cannot be mistaken for
//!   production backends.

mod approval;
mod event_bus;
pub mod fake;
mod persist;
mod real;
mod real_session;
mod real_thread;
mod session;
mod thread;

pub use approval::{
    ApprovalService, ExtendedResolveApprovalResponse, FileApprovalService, InMemoryApprovalService,
    PendingApprovalListResponse, PendingApprovalView, ResolveApprovalDecisionRequest,
    ResolveApprovalResponse,
};
pub use event_bus::{EventBus, EventSubscriber};
pub use fake::{FakeEventBus, FakeSessionService, FakeThreadService};
pub use real::{RealOptions, RealServiceError, SessionAdapterChoice, build_real_app_state};
pub use real_session::RealSessionService;
pub use real_thread::RealThreadService;
pub use session::{
    ConfigModeOption, CreateSessionRequest, SESSION_MODES, SessionCapabilities, SessionConfigPatch,
    SessionConfigView, SessionLifecycleResponse, SessionService, UNSUPPORTED_FIELD_PREFIX,
    UNSUPPORTED_OPERATION_PREFIX, standard_modes, unsupported_field, unsupported_operation,
};
pub use thread::{CreateThreadRequest, ThreadService};
