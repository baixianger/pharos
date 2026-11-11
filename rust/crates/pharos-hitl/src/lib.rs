//! Human-proxy HITL for RFC-007 stream S2.
//!
//! Honest states (unit gate):
//! - webhook HTTP 2xx → [`HitlState::Injected`]
//! - resolve `allowedOnce` / `denied` → terminal decision
//! - 45 minutes without resolve → [`HitlState::Failed`]
//!
//! Live Codex approvals use a **deferred** stdio client (does not auto-accept).
//! Interface issue: `pharos-codex-adapter` stdio transport currently auto-accepts
//! server approval requests and hardcodes `approvalPolicy=never` — see handoff.

mod approval_store;
mod channel;
mod codex_hitl;
mod decision;
mod error;
mod pending;
mod webhook;

pub use approval_store::{
    APPROVAL_STORE_VERSION, ApprovalRegistry, ApprovalStoreError, PendingApprovalStore,
    PruneReport, RESOLVED_RETENTION_SECS, RecordOutcome, ResolveOutcome, StoredApproval,
    StoredApprovalState, SystemWallClock, WallClock,
};
pub use channel::{
    HitlRequest, default_human_requests_dir, msg_test_root, publish_hitl_request, request_markdown,
    write_done_md, write_hitl_request,
};
pub use codex_hitl::{CodexHitlClient, PendingCodexApproval, prepare_hitl_codex_home};
pub use decision::{QuestionnaireAnswer, StoredDecision, validate_decision};
pub use error::HitlError;
pub use pending::{
    HITL_TIMEOUT_SECS, HitlBridge, HitlDecision, HitlPending, HitlState, InstantClock, SystemClock,
};
pub use webhook::{
    NotifyResult, WebhookConfig, default_webhook_env_path, load_webhook_config, notify_hitl_request,
};
