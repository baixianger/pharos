//! RFC-007 Stream S4 — HTTP/WS API layer.
//!
//! Mounts `pharos-api` routes and DTOs. Handlers call S1 (Thread) / S2 (Session)
//! service traits. The default `pharos-web` binary wires the real durable
//! backends ([`services::build_real_app_state`]); the clearly named **fake**
//! services in [`services::fake`] remain for tests and the explicit `--fake`
//! flag. Pending-approval snapshots are durable via [`FileApprovalService`]
//! regardless of which backend mode is selected.

pub mod approvals;
pub mod error;
pub mod router;
pub mod services;
pub mod state;
pub mod ws;

pub use approvals::{APPROVALS_ROUTE, ApprovalsQuery, list_approvals};
pub use router::api_router;
pub use services::{
    ApprovalService, CreateSessionRequest, CreateThreadRequest, EventBus, EventSubscriber,
    FakeEventBus, FakeSessionService, FakeThreadService, FileApprovalService,
    InMemoryApprovalService, PendingApprovalListResponse, PendingApprovalView, RealOptions,
    RealServiceError, RealSessionService, RealThreadService, ResolveApprovalResponse,
    SessionAdapterChoice, SessionService, ThreadService, build_real_app_state,
};
pub use state::AppState;
