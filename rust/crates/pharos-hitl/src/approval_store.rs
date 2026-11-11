//! Durable pending-approval store.
//!
//! Browser clients lose live `ApprovalRequired` events on page reload / WS
//! reconnect. This module keeps the pending approval state machine in a JSON
//! file so a new process (or a fresh `AppState`) can list what is still
//! awaiting a human decision.
//!
//! Guarantees:
//! - `record` is an upsert: pending approvals can be refreshed (`approvalUpdated`)
//!   without losing their original creation time; a resolved approval is never
//!   resurrected by a late event.
//! - `resolve` is idempotent: the first decision wins, later decisions are
//!   reported as [`ResolveOutcome::AlreadyResolved`] with the effective decision.
//! - approvals expire after the 45 minute HITL timeout and are pruned lazily.
//! - writes are atomic (temp file + rename); a corrupt store is a hard error and
//!   is never silently reset (that would fake a clean state).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

use crate::pending::HITL_TIMEOUT_SECS;

/// On-disk envelope version. Bump on incompatible layout changes.
pub const APPROVAL_STORE_VERSION: u32 = 1;

/// Resolved / expired records older than this are removed on prune (24h).
pub const RESOLVED_RETENTION_SECS: i64 = 24 * 60 * 60;

/// Wall clock abstraction so expiry can be tested without sleeping.
pub trait WallClock: Send + Sync + 'static {
    fn now(&self) -> OffsetDateTime;
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SystemWallClock;

impl WallClock for SystemWallClock {
    fn now(&self) -> OffsetDateTime {
        OffsetDateTime::now_utc()
    }
}

#[derive(Debug, Error)]
pub enum ApprovalStoreError {
    #[error("invalid approval: {0}")]
    Invalid(String),
    #[error("approval store io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("approval store data is corrupt: {detail}")]
    Corrupt { detail: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum StoredApprovalState {
    Pending,
    Resolved,
    Expired,
}

impl StoredApprovalState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Resolved => "resolved",
            Self::Expired => "expired",
        }
    }
}

/// One approval record as persisted in the store (API `camelCase` JSON).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredApproval {
    pub approval_id: String,
    pub session_id: String,
    pub kind: ApprovalKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_choices: Option<Vec<String>>,
    pub state: StoredApprovalState,
    pub created_at: String,
    pub expires_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decision: Option<ApprovalDecision>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolved_at: Option<String>,
}

impl StoredApproval {
    pub fn is_pending(&self) -> bool {
        self.state == StoredApprovalState::Pending
    }

    pub fn state_str(&self) -> &'static str {
        self.state.as_str()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordOutcome {
    /// A new pending approval was stored.
    Inserted,
    /// An existing pending (or expired, re-announced) approval was refreshed.
    Refreshed,
    /// A resolved approval with the same id was left untouched.
    IgnoredResolved,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResolveOutcome {
    /// The pending approval took this decision now.
    Resolved(StoredApproval),
    /// The approval was already resolved; `decision` is the effective one.
    AlreadyResolved(StoredApproval),
    /// The approval is past its 45m window.
    Expired(StoredApproval),
    /// No approval with this id is known (or it was pruned).
    NotFound,
}

impl ResolveOutcome {
    pub fn record(&self) -> Option<&StoredApproval> {
        match self {
            Self::Resolved(record) | Self::AlreadyResolved(record) | Self::Expired(record) => {
                Some(record)
            }
            Self::NotFound => None,
        }
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PruneReport {
    pub expired: usize,
    pub pruned: usize,
    pub changed: bool,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreFile {
    version: u32,
    approvals: Vec<StoredApproval>,
}

fn format_timestamp(ts: OffsetDateTime) -> Result<String, ApprovalStoreError> {
    ts.format(&Rfc3339)
        .map_err(|err| ApprovalStoreError::Invalid(format!("timestamp format: {err}")))
}

fn parse_timestamp(raw: &str) -> Result<OffsetDateTime, ApprovalStoreError> {
    OffsetDateTime::parse(raw, &Rfc3339).map_err(|err| ApprovalStoreError::Corrupt {
        detail: format!("bad timestamp {raw:?}: {err}"),
    })
}

/// Pure in-memory approval state machine (no IO). Shared by the file store and
/// by the HTTP layer's in-memory default service.
#[derive(Debug)]
pub struct ApprovalRegistry<C: WallClock = SystemWallClock> {
    clock: C,
    timeout: time::Duration,
    approvals: BTreeMap<String, StoredApproval>,
}

impl<C: WallClock> ApprovalRegistry<C> {
    pub fn new(clock: C, timeout: time::Duration) -> Self {
        Self {
            clock,
            timeout,
            approvals: BTreeMap::new(),
        }
    }

    pub(crate) fn from_entries(
        clock: C,
        timeout: time::Duration,
        entries: impl IntoIterator<Item = StoredApproval>,
    ) -> Self {
        let mut approvals = BTreeMap::new();
        for entry in entries {
            approvals.insert(entry.approval_id.clone(), entry);
        }
        Self {
            clock,
            timeout,
            approvals,
        }
    }

    /// All records ordered by approval id (deterministic on-disk layout).
    pub fn entries(&self) -> Vec<StoredApproval> {
        self.approvals.values().cloned().collect()
    }

    /// Store (or refresh) a pending approval announced by an adapter/session.
    pub fn record(
        &mut self,
        request: &ApprovalRequest,
    ) -> Result<RecordOutcome, ApprovalStoreError> {
        if request.approval_id.trim().is_empty() {
            return Err(ApprovalStoreError::Invalid(
                "approval id must not be empty".into(),
            ));
        }
        if request.session_id.trim().is_empty() {
            return Err(ApprovalStoreError::Invalid(
                "approval session id must not be empty".into(),
            ));
        }
        let now = self.clock.now();
        if let Some(existing) = self.approvals.get_mut(&request.approval_id) {
            if existing.state == StoredApprovalState::Resolved {
                return Ok(RecordOutcome::IgnoredResolved);
            }
            existing.session_id = request.session_id.clone();
            existing.kind = request.kind.clone();
            existing.available_choices = request.available_choices.clone();
            if existing.state == StoredApprovalState::Expired {
                // Upstream re-announced it: start a fresh 45m window.
                existing.state = StoredApprovalState::Pending;
                existing.created_at = format_timestamp(now)?;
                existing.expires_at = format_timestamp(now + self.timeout)?;
                existing.decision = None;
                existing.resolved_at = None;
            }
            return Ok(RecordOutcome::Refreshed);
        }
        let record = StoredApproval {
            approval_id: request.approval_id.clone(),
            session_id: request.session_id.clone(),
            kind: request.kind.clone(),
            available_choices: request.available_choices.clone(),
            state: StoredApprovalState::Pending,
            created_at: format_timestamp(now)?,
            expires_at: format_timestamp(now + self.timeout)?,
            decision: None,
            resolved_at: None,
        };
        self.approvals.insert(record.approval_id.clone(), record);
        Ok(RecordOutcome::Inserted)
    }

    /// Mark stale pending approvals expired and drop very old terminal records.
    pub fn prune(&mut self) -> Result<PruneReport, ApprovalStoreError> {
        let now = self.clock.now();
        let retention = time::Duration::seconds(RESOLVED_RETENTION_SECS);
        let mut report = PruneReport::default();
        let mut remove = Vec::new();
        for record in self.approvals.values_mut() {
            match record.state {
                StoredApprovalState::Pending => {
                    let expires = parse_timestamp(&record.expires_at).map_err(|err| {
                        ApprovalStoreError::Corrupt {
                            detail: format!("approval {}: {err}", record.approval_id),
                        }
                    })?;
                    if now >= expires {
                        record.state = StoredApprovalState::Expired;
                        report.expired += 1;
                        report.changed = true;
                    }
                }
                StoredApprovalState::Resolved => {
                    let resolved_at = match &record.resolved_at {
                        Some(raw) => parse_timestamp(raw)?,
                        None => parse_timestamp(&record.expires_at)?,
                    };
                    if now - resolved_at >= retention {
                        remove.push(record.approval_id.clone());
                    }
                }
                StoredApprovalState::Expired => {
                    let expires = parse_timestamp(&record.expires_at)?;
                    if now - expires >= retention {
                        remove.push(record.approval_id.clone());
                    }
                }
            }
        }
        for id in remove {
            self.approvals.remove(&id);
            report.pruned += 1;
            report.changed = true;
        }
        Ok(report)
    }

    /// Pending records, optionally filtered by session, oldest first.
    pub fn collect_pending(&self, session_id: Option<&str>) -> Vec<StoredApproval> {
        let mut items: Vec<StoredApproval> = self
            .approvals
            .values()
            .filter(|record| record.is_pending())
            .filter(|record| match session_id {
                Some(session) => record.session_id == session,
                None => true,
            })
            .cloned()
            .collect();
        items.sort_by(|left, right| {
            left.created_at
                .cmp(&right.created_at)
                .then_with(|| left.approval_id.cmp(&right.approval_id))
        });
        items
    }

    /// Look up one record (pruning first so callers see honest expiry).
    pub fn get(&mut self, approval_id: &str) -> Result<Option<StoredApproval>, ApprovalStoreError> {
        self.prune()?;
        Ok(self.approvals.get(approval_id).cloned())
    }

    /// Apply a human decision idempotently: the first decision wins.
    pub fn resolve(
        &mut self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ResolveOutcome, ApprovalStoreError> {
        if approval_id.trim().is_empty() {
            return Err(ApprovalStoreError::Invalid(
                "approval id must not be empty".into(),
            ));
        }
        let now = self.clock.now();
        let Some(record) = self.approvals.get_mut(approval_id) else {
            return Ok(ResolveOutcome::NotFound);
        };
        match record.state {
            StoredApprovalState::Resolved => {
                return Ok(ResolveOutcome::AlreadyResolved(record.clone()));
            }
            StoredApprovalState::Expired => return Ok(ResolveOutcome::Expired(record.clone())),
            StoredApprovalState::Pending => {}
        }
        let expires = parse_timestamp(&record.expires_at)?;
        if now >= expires {
            record.state = StoredApprovalState::Expired;
            return Ok(ResolveOutcome::Expired(record.clone()));
        }
        record.state = StoredApprovalState::Resolved;
        record.decision = Some(decision);
        record.resolved_at = Some(format_timestamp(now)?);
        Ok(ResolveOutcome::Resolved(record.clone()))
    }

    /// Undo a decision whose adapter/session dispatch failed, so the approval
    /// stays retryable instead of being silently consumed. First-wins decisions
    /// that already reached the adapter are not affected (callers only revert
    /// their own failed dispatch).
    pub fn revert_resolution(&mut self, approval_id: &str) -> Result<bool, ApprovalStoreError> {
        let Some(record) = self.approvals.get_mut(approval_id) else {
            return Ok(false);
        };
        if record.state != StoredApprovalState::Resolved {
            return Ok(false);
        }
        let now = self.clock.now();
        record.decision = None;
        record.resolved_at = None;
        let expires = parse_timestamp(&record.expires_at)?;
        record.state = if now >= expires {
            StoredApprovalState::Expired
        } else {
            StoredApprovalState::Pending
        };
        Ok(true)
    }

    /// Remove a withdrawn approval entirely. Returns whether it existed.
    pub fn withdraw(&mut self, approval_id: &str) -> bool {
        self.approvals.remove(approval_id).is_some()
    }
}

/// File-backed approval store. Cheap to clone-never: wrap in `Arc` at wiring.
#[derive(Debug)]
pub struct PendingApprovalStore<C: WallClock = SystemWallClock> {
    path: PathBuf,
    registry: Mutex<ApprovalRegistry<C>>,
}

impl PendingApprovalStore<SystemWallClock> {
    /// Open (or create on first write) the store at `path` with the 45m timeout.
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, ApprovalStoreError> {
        Self::open_with(
            path,
            SystemWallClock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
    }
}

impl<C: WallClock> PendingApprovalStore<C> {
    /// Open the store with an injectable clock / timeout (tests, expiry probes).
    pub fn open_with(
        path: impl Into<PathBuf>,
        clock: C,
        timeout: time::Duration,
    ) -> Result<Self, ApprovalStoreError> {
        let path = path.into();
        let entries = load_entries(&path)?;
        let registry = ApprovalRegistry::from_entries(clock, timeout, entries);
        let store = Self {
            path,
            registry: Mutex::new(registry),
        };
        // Lazily expire / prune stale records on open; keep the file honest.
        store.prune()?;
        Ok(store)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn lock(&self) -> MutexGuard<'_, ApprovalRegistry<C>> {
        // A poisoned mutex means a panic while mutating; the JSON file is the
        // source of truth and is rewritten atomically, so recover the guard.
        self.registry
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn record(&self, request: &ApprovalRequest) -> Result<RecordOutcome, ApprovalStoreError> {
        let mut registry = self.lock();
        let outcome = registry.record(request)?;
        if outcome != RecordOutcome::IgnoredResolved {
            self.persist(&registry)?;
        }
        Ok(outcome)
    }

    pub fn list_pending(
        &self,
        session_id: Option<&str>,
    ) -> Result<Vec<StoredApproval>, ApprovalStoreError> {
        let mut registry = self.lock();
        let report = registry.prune()?;
        let items = registry.collect_pending(session_id);
        if report.changed {
            self.persist(&registry)?;
        }
        Ok(items)
    }

    pub fn get(&self, approval_id: &str) -> Result<Option<StoredApproval>, ApprovalStoreError> {
        let mut registry = self.lock();
        let report = registry.prune()?;
        let record = registry.get(approval_id)?;
        if report.changed {
            self.persist(&registry)?;
        }
        Ok(record)
    }

    pub fn resolve(
        &self,
        approval_id: &str,
        decision: ApprovalDecision,
    ) -> Result<ResolveOutcome, ApprovalStoreError> {
        let mut registry = self.lock();
        let outcome = registry.resolve(approval_id, decision)?;
        if matches!(
            outcome,
            ResolveOutcome::Resolved(_) | ResolveOutcome::Expired(_)
        ) {
            self.persist(&registry)?;
        }
        Ok(outcome)
    }

    pub fn revert_resolution(&self, approval_id: &str) -> Result<bool, ApprovalStoreError> {
        let mut registry = self.lock();
        let reverted = registry.revert_resolution(approval_id)?;
        if reverted {
            self.persist(&registry)?;
        }
        Ok(reverted)
    }

    pub fn withdraw(&self, approval_id: &str) -> Result<bool, ApprovalStoreError> {
        let mut registry = self.lock();
        let removed = registry.withdraw(approval_id);
        if removed {
            self.persist(&registry)?;
        }
        Ok(removed)
    }

    pub fn prune(&self) -> Result<PruneReport, ApprovalStoreError> {
        let mut registry = self.lock();
        let report = registry.prune()?;
        if report.changed {
            self.persist(&registry)?;
        }
        Ok(report)
    }

    fn persist(&self, registry: &ApprovalRegistry<C>) -> Result<(), ApprovalStoreError> {
        let file = StoreFile {
            version: APPROVAL_STORE_VERSION,
            approvals: registry.entries(),
        };
        let bytes =
            serde_json::to_vec_pretty(&file).map_err(|err| ApprovalStoreError::Corrupt {
                detail: format!("serialize approval store: {err}"),
            })?;
        if let Some(parent) = self.path.parent().filter(|p| !p.as_os_str().is_empty()) {
            fs::create_dir_all(parent).map_err(|source| ApprovalStoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        let tmp = self
            .path
            .with_extension(format!("tmp.{}", std::process::id()));
        {
            use std::io::Write;

            let mut file = fs::File::create(&tmp).map_err(|source| ApprovalStoreError::Io {
                path: tmp.clone(),
                source,
            })?;
            file.write_all(&bytes)
                .map_err(|source| ApprovalStoreError::Io {
                    path: tmp.clone(),
                    source,
                })?;
            // Flush to disk before the atomic rename so a crash cannot leave the
            // target pointing at empty/partial data.
            file.sync_all().map_err(|source| ApprovalStoreError::Io {
                path: tmp.clone(),
                source,
            })?;
        }
        fs::rename(&tmp, &self.path).map_err(|source| ApprovalStoreError::Io {
            path: self.path.clone(),
            source,
        })
    }
}

fn load_entries(path: &Path) -> Result<Vec<StoredApproval>, ApprovalStoreError> {
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(source) => {
            return Err(ApprovalStoreError::Io {
                path: path.to_path_buf(),
                source,
            });
        }
    };
    if bytes.iter().all(u8::is_ascii_whitespace) {
        // An existing but empty store file is not a fresh store: refusing to
        // guess avoids silently discarding a truncated record set.
        return Err(ApprovalStoreError::Corrupt {
            detail: format!("{}: store file is empty", path.display()),
        });
    }
    let file: StoreFile =
        serde_json::from_slice(&bytes).map_err(|err| ApprovalStoreError::Corrupt {
            detail: format!("{}: {err}", path.display()),
        })?;
    if file.version != APPROVAL_STORE_VERSION {
        return Err(ApprovalStoreError::Corrupt {
            detail: format!(
                "{}: unsupported store version {} (expected {APPROVAL_STORE_VERSION})",
                path.display(),
                file.version
            ),
        });
    }
    Ok(file.approvals)
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use pharos_api::{ApprovalDecision, ApprovalKind, ApprovalRequest};
    use serde_json::json;
    use tempfile::TempDir;

    use super::*;

    #[derive(Debug, Clone)]
    struct TestClock(Arc<Mutex<OffsetDateTime>>);

    impl TestClock {
        fn new() -> Self {
            Self(Arc::new(Mutex::new(
                OffsetDateTime::parse("2026-11-11T10:00:00Z", &Rfc3339).expect("fixed time"),
            )))
        }

        fn advance(&self, delta: time::Duration) {
            let mut guard = self.0.lock().expect("clock");
            *guard += delta;
        }
    }

    impl WallClock for TestClock {
        fn now(&self) -> OffsetDateTime {
            *self.0.lock().expect("clock")
        }
    }

    fn approval(id: &str) -> ApprovalRequest {
        ApprovalRequest {
            approval_id: id.to_string(),
            session_id: "session-1".to_string(),
            kind: ApprovalKind::ToolPermission {
                tool_name: "shell".to_string(),
                params: json!({ "command": "printf ok" }),
                explanation: None,
            },
            available_choices: Some(vec!["allowedOnce".into(), "rejected".into()]),
        }
    }

    fn temp_store(clock: TestClock) -> (TempDir, PathBuf) {
        let dir = TempDir::new().expect("tempdir");
        let path = dir.path().join("pending-approvals.json");
        let _ = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open store");
        (dir, path)
    }

    #[test]
    fn pending_approval_survives_reopen() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        {
            let store = PendingApprovalStore::open_with(
                &path,
                clock.clone(),
                time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
            )
            .expect("open");
            assert_eq!(
                store.record(&approval("a1")).expect("record"),
                RecordOutcome::Inserted
            );
        }
        // "Restart": a brand new store instance reading the same file.
        let reopened = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("reopen");
        let pending = reopened.list_pending(None).expect("list");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].approval_id, "a1");
        assert_eq!(pending[0].state, StoredApprovalState::Pending);
        assert_eq!(pending[0].available_choices.as_ref().map(Vec::len), Some(2));
    }

    #[test]
    fn resolve_is_idempotent_and_keeps_first_decision() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        let first = store
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .expect("first resolve");
        let ResolveOutcome::Resolved(record) = first else {
            panic!("first resolve must take effect, got {first:?}");
        };
        assert_eq!(record.decision, Some(ApprovalDecision::AllowedOnce));

        // Second decision (even a different one) must not take effect.
        let second = store
            .resolve("a1", ApprovalDecision::Rejected)
            .expect("second resolve");
        let ResolveOutcome::AlreadyResolved(record) = second else {
            panic!("second resolve must be AlreadyResolved, got {second:?}");
        };
        assert_eq!(record.decision, Some(ApprovalDecision::AllowedOnce));
        assert!(store.list_pending(None).expect("list").is_empty());

        // And the resolved state is durable across a reopen.
        let reopened = PendingApprovalStore::open_with(
            &path,
            TestClock::new(),
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("reopen");
        assert!(reopened.list_pending(None).expect("list").is_empty());
        assert!(matches!(
            reopened
                .resolve("a1", ApprovalDecision::Rejected)
                .expect("resolve"),
            ResolveOutcome::AlreadyResolved(_)
        ));
    }

    #[test]
    fn late_event_does_not_resurrect_resolved_approval() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        store
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .expect("resolve");
        assert_eq!(
            store.record(&approval("a1")).expect("late event"),
            RecordOutcome::IgnoredResolved
        );
        assert!(store.list_pending(None).expect("list").is_empty());
    }

    #[test]
    fn pending_approval_expires_after_45_minutes() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock.clone(),
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        clock.advance(time::Duration::seconds(HITL_TIMEOUT_SECS as i64 + 1));
        assert!(store.list_pending(None).expect("list").is_empty());
        let outcome = store
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .expect("resolve");
        assert!(
            matches!(outcome, ResolveOutcome::Expired(_)),
            "expected Expired, got {outcome:?}"
        );
    }

    #[test]
    fn re_announced_expired_approval_starts_new_window() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock.clone(),
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        clock.advance(time::Duration::seconds(HITL_TIMEOUT_SECS as i64 + 1));
        assert!(store.list_pending(None).expect("list").is_empty());
        assert_eq!(
            store.record(&approval("a1")).expect("re-announce"),
            RecordOutcome::Refreshed
        );
        assert_eq!(store.list_pending(None).expect("list").len(), 1);
    }

    #[test]
    fn corrupt_store_file_is_an_error_not_a_reset() {
        let dir = TempDir::new().expect("tempdir");
        let path = dir.path().join("pending-approvals.json");
        fs::write(&path, b"{ this is not json").expect("write corrupt");
        let error = PendingApprovalStore::open(&path).expect_err("must fail");
        assert!(matches!(error, ApprovalStoreError::Corrupt { .. }));
        // The corrupt bytes are left intact for inspection, not overwritten.
        assert_eq!(
            fs::read(&path).expect("read").as_slice(),
            b"{ this is not json".as_slice()
        );
    }

    #[test]
    fn unsupported_store_version_is_corrupt() {
        let dir = TempDir::new().expect("tempdir");
        let path = dir.path().join("pending-approvals.json");
        fs::write(&path, br#"{"version":99,"approvals":[]}"#).expect("write");
        let error = PendingApprovalStore::open(&path).expect_err("must fail");
        assert!(matches!(error, ApprovalStoreError::Corrupt { .. }));
    }

    #[test]
    fn empty_store_file_is_corrupt_not_a_silent_fresh_store() {
        let dir = TempDir::new().expect("tempdir");
        let path = dir.path().join("pending-approvals.json");
        fs::write(&path, b"  \n\t ").expect("write empty-ish file");
        let error = PendingApprovalStore::open(&path).expect_err("must fail");
        assert!(matches!(error, ApprovalStoreError::Corrupt { .. }));
        // A missing file is still a legitimate fresh store.
        let fresh = PendingApprovalStore::open(dir.path().join("missing.json")).expect("fresh");
        assert!(fresh.list_pending(None).expect("list").is_empty());
    }

    #[test]
    fn withdraw_removes_record() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        assert!(store.withdraw("a1").expect("withdraw"));
        assert!(!store.withdraw("a1").expect("second withdraw"));
        assert!(store.list_pending(None).expect("list").is_empty());
        assert!(matches!(
            store
                .resolve("a1", ApprovalDecision::AllowedOnce)
                .expect("resolve"),
            ResolveOutcome::NotFound
        ));
    }

    #[test]
    fn old_resolved_records_are_pruned_but_recent_ones_kept() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock.clone(),
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        store
            .resolve("a1", ApprovalDecision::Rejected)
            .expect("resolve");
        clock.advance(time::Duration::seconds(RESOLVED_RETENTION_SECS + 1));
        let report = store.prune().expect("prune");
        assert_eq!(report.pruned, 1);
        assert!(store.list_pending(None).expect("list").is_empty());
    }

    #[test]
    fn session_filter_only_returns_matching_approvals() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        let mut other = approval("a2");
        other.session_id = "session-2".to_string();
        store.record(&other).expect("record other");
        let filtered = store.list_pending(Some("session-2")).expect("list");
        assert_eq!(filtered.len(), 1);
        assert_eq!(filtered[0].approval_id, "a2");
        assert_eq!(store.list_pending(None).expect("all").len(), 2);
    }
    #[test]
    fn failed_dispatch_revert_keeps_approval_retryable() {
        let clock = TestClock::new();
        let (_dir, path) = temp_store(clock.clone());
        let store = PendingApprovalStore::open_with(
            &path,
            clock,
            time::Duration::seconds(HITL_TIMEOUT_SECS as i64),
        )
        .expect("open");
        store.record(&approval("a1")).expect("record");
        store
            .resolve("a1", ApprovalDecision::AllowedOnce)
            .expect("resolve");
        // The adapter/session dispatch failed afterwards: undo the decision.
        assert!(store.revert_resolution("a1").expect("revert"));
        let pending = store.list_pending(None).expect("list");
        assert_eq!(pending.len(), 1, "reverted approval must be retryable");
        assert_eq!(pending[0].state, StoredApprovalState::Pending);
        // Reverting a still-pending or unknown approval is a no-op.
        assert!(!store.revert_resolution("a1").expect("second revert"));
        assert!(!store.revert_resolution("missing").expect("unknown revert"));
        // The retry can take effect and is durable.
        let outcome = store
            .resolve("a1", ApprovalDecision::Rejected)
            .expect("retry resolve");
        assert!(matches!(outcome, ResolveOutcome::Resolved(_)));
    }
}
