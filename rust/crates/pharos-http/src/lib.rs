//! RFC-007 Stream S4 — HTTP/WS API layer.
//!
//! Mounts `pharos-api` routes and DTOs. Handlers call S1 (Thread) / S2 (Session)
//! service traits. Until those streams land real implementations, use the
//! clearly named **fake** services in [`services::fake`].

pub mod approvals;
pub mod error;
pub mod router;
pub mod services;
pub mod state;
pub mod ws;

pub use approvals::{APPROVALS_ROUTE, ApprovalsQuery, list_approvals};
pub use router::api_router;
pub use services::{
    ApprovalService, EventBus, EventSubscriber, FakeEventBus, FakeSessionService,
    FakeThreadService, FileApprovalService, InMemoryApprovalService, PendingApprovalListResponse,
    PendingApprovalView, ResolveApprovalResponse, SessionService, ThreadService,
};
pub use state::AppState;
