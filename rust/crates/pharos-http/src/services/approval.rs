//! Persistent approvals service: durable pending snapshot + idempotent decisions.
//!
//! The browser loses live `ApprovalRequired` events on reload / WebSocket
//! reconnect. [`ApprovalService`] exposes the durable pending set (backed by
//! `pharos-hitl`'s file store in production, in-memory by default) and records
//! decisions idempotently. Decisions decided elsewhere (adapter/session layer)
//! arrive through [`crate::state::AppState::spawn_approval_tap`].

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest, ClientEvent, PharosApiError};
use pharos_hitl::{
    ApprovalRegistry, ApprovalStoreError, HITL_TIMEOUT_SECS, PendingApprovalStore, RecordOutcome,
    ResolveOutcome, StoredApproval, SystemWallClock, WallClock,
};
use serde::{Deserialize, Serialize};
use time::Duration;

/// Wire view of one pending approval (flat shape front-ends can render directly).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingApprovalView {
    pub approval_id: String,
    pub session_id: String,
    pub kind: ApprovalKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_choices: Option<Vec<String>>,
    /// `pending` for every item served by the snapshot endpoint.
    pub state: String,
    /// RFC3339 creation timestamp.
    pub created_at: String,
    /// RFC3339 timestamp after which the approval expires (45m HITL window).
    pub expires_at: String,
}

impl From<StoredApproval> for PendingApprovalView {
    fn from(record: StoredApproval) -> Self {
        let state = record.state_str().to_string();
        Self {
            approval_id: record.approval_id,
            session_id: record.session_id,
            kind: record.kind,
            available_choices: record.available_choices,
            state,
            created_at: record.created_at,
            expires_at: record.expires_at,
        }
    }
}

/// `GET /api/v1/approvals?state=pending` response body.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PendingApprovalListResponse {
    pub approvals: Vec<PendingApprovalView>,
}

/// `POST /api/v1/sessions/{id}/approval` response body (additive to `{ok:true}`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveApprovalResponse {
    pub ok: bool,
    pub approval_id: String,
    pub state: String,
    pub decision: ApprovalDecision,
    /// True when an earlier decision already took effect (idempotent replay).
    pub already_resolved: bool,
}

/// Durable approval surface mounted by the HTTP layer.
#[async_trait]
pub trait ApprovalService: Send + Sync {
    /// Upsert an approval announced by a session/adapter (`ApprovalRequired` /
    /// `ApprovalUpdated`). Resolved approvals are never resurrected.
    async fn record(&self, approval: ApprovalRequest) -> Result<(), PharosApiError>;

    /// Pending approvals, optionally filtered by session, oldest first.
    async fn list_pending(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<PendingApprovalView>, PharosApiError>;

    /// Look up one approval (any state; `None` when unknown/pruned).
    async fn get(&self, approval_id: &str) -> Result<Option<PendingApprovalView>, PharosApiError>;

    /// Apply a decision idempotently. First decision wins; later calls return
    /// `already_resolved = true` with the effective decision.
    async fn resolve(
        &self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ResolveApprovalResponse, PharosApiError>;

    /// Undo a just-recorded decision when the downstream session/adapter
    /// dispatch failed, so the approval stays pending and retryable.
    async fn revert_decision(&self, approval_id: &str) -> Result<(), PharosApiError>;

    /// Drop a withdrawn approval.
    async fn withdraw(&self, approval_id: &str) -> Result<(), PharosApiError>;

    /// Persist a change announced on the WS event bus (see the approval tap).
    async fn apply_event(&self, event: &ClientEvent) -> Result<(), PharosApiError> {
        match event {
            ClientEvent::ApprovalRequired { approval }
            | ClientEvent::ApprovalUpdated { approval } => self.record(approval.clone()).await,
            ClientEvent::ApprovalResolved {
                approval_id,
                decision,
            } => match self.resolve(approval_id, *decision).await {
                // An event for an approval we never persisted is benign: there
                // is nothing for the snapshot to hide.
                Err(PharosApiError::ApprovalNotFound { .. }) => Ok(()),
                other => other.map(|_| ()),
            },
            ClientEvent::ApprovalWithdrawn { approval_id } => self.withdraw(approval_id).await,
            _ => Ok(()),
        }
    }
}

fn store_error(error: ApprovalStoreError) -> PharosApiError {
    PharosApiError::OperationFailed {
        message: error.to_string(),
    }
}

fn decision_of(record: &StoredApproval) -> ApprovalDecision {
    record.decision.unwrap_or(ApprovalDecision::Rejected)
}

fn resolve_response(record: StoredApproval, already_resolved: bool) -> ResolveApprovalResponse {
    ResolveApprovalResponse {
        ok: true,
        approval_id: record.approval_id.clone(),
        state: record.state_str().to_string(),
        decision: decision_of(&record),
        already_resolved,
    }
}

fn map_resolve_outcome(
    approval_id: &str,
    outcome: ResolveOutcome,
) -> Result<ResolveApprovalResponse, PharosApiError> {
    match outcome {
        ResolveOutcome::Resolved(record) => Ok(resolve_response(record, false)),
        ResolveOutcome::AlreadyResolved(record) => Ok(resolve_response(record, true)),
        ResolveOutcome::Expired(record) => Err(PharosApiError::Conflict {
            message: format!(
                "approval {} expired at {}",
                record.approval_id, record.expires_at
            ),
        }),
        ResolveOutcome::NotFound => Err(PharosApiError::ApprovalNotFound {
            id: approval_id.to_string(),
        }),
    }
}

fn default_timeout() -> Duration {
    Duration::seconds(HITL_TIMEOUT_SECS as i64)
}

/// In-memory default (used by `AppState::new` and by tests without a data dir).
#[derive(Debug)]
pub struct InMemoryApprovalService<C: WallClock = SystemWallClock> {
    registry: Mutex<ApprovalRegistry<C>>,
}

impl Default for InMemoryApprovalService {
    fn default() -> Self {
        Self::new()
    }
}

impl InMemoryApprovalService {
    pub fn new() -> Self {
        Self::with_clock(SystemWallClock)
    }
}

impl<C: WallClock> InMemoryApprovalService<C> {
    pub fn with_clock(clock: C) -> Self {
        Self {
            registry: Mutex::new(ApprovalRegistry::new(clock, default_timeout())),
        }
    }

    fn lock(&self) -> MutexGuard<'_, ApprovalRegistry<C>> {
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

#[async_trait]
impl<C: WallClock> ApprovalService for InMemoryApprovalService<C> {
    async fn record(&self, approval: ApprovalRequest) -> Result<(), PharosApiError> {
        self.lock().record(&approval).map_err(store_error)?;
        Ok(())
    }

    async fn list_pending(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<PendingApprovalView>, PharosApiError> {
        let mut registry = self.lock();
        registry.prune().map_err(store_error)?;
        Ok(registry
            .collect_pending(session_id.as_deref())
            .into_iter()
            .map(PendingApprovalView::from)
            .collect())
    }

    async fn get(&self, approval_id: &str) -> Result<Option<PendingApprovalView>, PharosApiError> {
        Ok(self
            .lock()
            .get(approval_id)
            .map_err(store_error)?
            .map(PendingApprovalView::from))
    }

    async fn resolve(
        &self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ResolveApprovalResponse, PharosApiError> {
        let outcome = self
            .lock()
            .resolve(approval_id, decision)
            .map_err(store_error)?;
        map_resolve_outcome(approval_id, outcome)
    }

    async fn revert_decision(&self, approval_id: &str) -> Result<(), PharosApiError> {
        self.lock()
            .revert_resolution(approval_id)
            .map_err(store_error)?;
        Ok(())
    }

    async fn withdraw(&self, approval_id: &str) -> Result<(), PharosApiError> {
        self.lock().withdraw(approval_id);
        Ok(())
    }
}

/// File-backed service: pending approvals survive restarts (via `pharos-hitl`).
#[derive(Debug)]
pub struct FileApprovalService<C: WallClock = SystemWallClock> {
    store: PendingApprovalStore<C>,
}

impl FileApprovalService<SystemWallClock> {
    /// Open the JSON store at `path` (5xx on unreadable/corrupt data).
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, ApprovalStoreError> {
        PendingApprovalStore::open(path).map(Self::from_store)
    }
}

impl<C: WallClock> FileApprovalService<C> {
    pub fn from_store(store: PendingApprovalStore<C>) -> Self {
        Self { store }
    }

    pub fn path(&self) -> &Path {
        self.store.path()
    }
}

#[async_trait]
impl<C: WallClock> ApprovalService for FileApprovalService<C> {
    async fn record(&self, approval: ApprovalRequest) -> Result<(), PharosApiError> {
        let outcome = self.store.record(&approval).map_err(store_error)?;
        if outcome == RecordOutcome::IgnoredResolved {
            tracing::debug!(
                approval_id = %approval.approval_id,
                "ignoring announcement for already-resolved approval"
            );
        }
        Ok(())
    }

    async fn list_pending(
        &self,
        session_id: Option<String>,
    ) -> Result<Vec<PendingApprovalView>, PharosApiError> {
        Ok(self
            .store
            .list_pending(session_id.as_deref())
            .map_err(store_error)?
            .into_iter()
            .map(PendingApprovalView::from)
            .collect())
    }

    async fn get(&self, approval_id: &str) -> Result<Option<PendingApprovalView>, PharosApiError> {
        Ok(self
            .store
            .get(approval_id)
            .map_err(store_error)?
            .map(PendingApprovalView::from))
    }

    async fn resolve(
        &self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ResolveApprovalResponse, PharosApiError> {
        let outcome = self
            .store
            .resolve(approval_id, decision)
            .map_err(store_error)?;
        map_resolve_outcome(approval_id, outcome)
    }

    async fn revert_decision(&self, approval_id: &str) -> Result<(), PharosApiError> {
        self.store
            .revert_resolution(approval_id)
            .map_err(store_error)?;
        Ok(())
    }

    async fn withdraw(&self, approval_id: &str) -> Result<(), PharosApiError> {
        self.store.withdraw(approval_id).map_err(store_error)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use pharos_api::ApprovalKind;
    use serde_json::json;

    use super::*;

    fn approval(id: &str, session: &str) -> ApprovalRequest {
        ApprovalRequest {
            approval_id: id.into(),
            session_id: session.into(),
            kind: ApprovalKind::ToolPermission {
                tool_name: "shell".into(),
                params: json!({ "command": "printf ok" }),
                explanation: Some("run a command".into()),
            },
            available_choices: Some(vec!["allowedOnce".into(), "rejected".into()]),
        }
    }

    #[tokio::test]
    async fn in_memory_service_snapshot_and_idempotent_resolve() {
        let service = InMemoryApprovalService::new();
        service.record(approval("a1", "s1")).await.expect("record");
        service.record(approval("a2", "s2")).await.expect("record");
        assert_eq!(service.list_pending(None).await.expect("list").len(), 2);
        let filtered = service
            .list_pending(Some("s2".into()))
            .await
            .expect("filtered");
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].approval_id, "a2");
        assert_eq!(filtered[0].state, "pending");

        let first = service
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .await
            .expect("first");
        assert!(!first.already_resolved);
        assert_eq!(first.state, "resolved");
        let second = service
            .resolve("a1", ApprovalDecision::Rejected)
            .await
            .expect("second");
        assert!(second.already_resolved);
        assert_eq!(second.decision, ApprovalDecision::AllowedOnce);
        assert_eq!(service.list_pending(None).await.expect("list").len(), 1);
    }

    #[tokio::test]
    async fn apply_event_records_and_withdraws() {
        let service = InMemoryApprovalService::new();
        service
            .apply_event(&ClientEvent::ApprovalRequired {
                approval: approval("a1", "s1"),
            })
            .await
            .expect("required");
        assert_eq!(service.list_pending(None).await.expect("list").len(), 1);
        service
            .apply_event(&ClientEvent::ApprovalWithdrawn {
                approval_id: "a1".into(),
            })
            .await
            .expect("withdrawn");
        assert!(service.list_pending(None).await.expect("list").is_empty());
    }

    #[tokio::test]
    async fn expired_resolve_is_a_conflict() {
        use std::sync::Arc;

        use time::OffsetDateTime;
        use time::format_description::well_known::Rfc3339;

        #[derive(Debug, Clone)]
        struct TestClock(Arc<Mutex<OffsetDateTime>>);
        impl WallClock for TestClock {
            fn now(&self) -> OffsetDateTime {
                *self.0.lock().expect("clock")
            }
        }

        let clock = TestClock(Arc::new(Mutex::new(
            OffsetDateTime::parse("2026-11-11T10:00:00Z", &Rfc3339).expect("time"),
        )));
        let service = InMemoryApprovalService::with_clock(clock.clone());
        service.record(approval("a1", "s1")).await.expect("record");
        *clock.0.lock().expect("clock") += Duration::seconds(HITL_TIMEOUT_SECS as i64 + 1);
        assert!(service.list_pending(None).await.expect("list").is_empty());
        let error = service
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .await
            .expect_err("expired resolve must fail");
        assert!(matches!(error, PharosApiError::Conflict { .. }));
    }
}
