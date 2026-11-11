//! Durable Thread ↔ session bindings store.
//!
//! One member of a Thread can be bound to exactly one live Session; the binding
//! is read by delivery routing surfaces and by the thread member list. The
//! store is a single versioned JSON document under the Host data dir:
//!
//! ```text
//! <data-dir>/thread-bindings.json
//! {"version":1,"bindings":[{threadId,member,sessionId,agentType?,boundAt}]}
//! ```
//!
//! Guarantees:
//! - upsert is a full replace keyed by `(threadId, member)`; `boundAt` is
//!   assigned once (unless the caller supplies one) and refreshed on rebind.
//! - every mutation is persisted atomically; a crash never loses the previous
//!   document (see [`super::persist`]).
//! - a corrupt / truncated / wrong-version file is a hard error on open — it is
//!   never silently reset (that would fake a clean routing state).
//! - on-disk ordering is deterministic (`threadId`, then `member`) so diffs and
//!   tests are stable.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use super::persist::{StoreError, now_rfc3339, read_versioned_store, write_json_atomic};

/// File name inside the Host data dir.
pub const THREAD_BINDINGS_FILE: &str = "thread-bindings.json";

/// On-disk envelope version. Bump on incompatible layout changes.
pub const THREAD_BINDINGS_STORE_VERSION: u32 = 1;

/// One Thread member → session binding (wire shape of the contract).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadBinding {
    pub thread_id: String,
    pub member: String,
    pub session_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_type: Option<String>,
    /// RFC3339 timestamp of the bind/rebind.
    pub bound_at: String,
}

impl ThreadBinding {
    /// Build a binding with a fresh `boundAt` timestamp.
    pub fn new(
        thread_id: impl Into<String>,
        member: impl Into<String>,
        session_id: impl Into<String>,
        agent_type: Option<String>,
    ) -> Self {
        Self {
            thread_id: thread_id.into(),
            member: member.into(),
            session_id: session_id.into(),
            agent_type,
            bound_at: now_rfc3339(),
        }
    }

    /// Compact `{threadId, sessionId}` view used inside a member settings view.
    pub fn view(&self) -> ThreadBindingView {
        ThreadBindingView {
            thread_id: self.thread_id.clone(),
            session_id: self.session_id.clone(),
        }
    }
}

/// `{threadId, sessionId}` pair embedded in `GET /api/v1/members/{memberId}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadBindingView {
    pub thread_id: String,
    pub session_id: String,
}

/// Store surface mounted on [`crate::state::AppState`].
///
/// Handlers validate Thread/session existence and membership through the Thread
/// / Session services; this store only owns the durable mapping itself.
#[async_trait]
pub trait ThreadBindingService: Send + Sync {
    /// All bindings of a Thread, deterministic (`member` order). Unknown Thread
    /// ids simply have no bindings.
    async fn list(&self, thread_id: &str) -> Result<Vec<ThreadBinding>, StoreError>;

    /// One binding, `None` when the pair is unbound.
    async fn get(&self, thread_id: &str, member: &str)
    -> Result<Option<ThreadBinding>, StoreError>;

    /// Create or replace the `(threadId, member)` binding. Returns the stored
    /// record (with `boundAt` filled in when the caller left it empty).
    async fn upsert(&self, binding: ThreadBinding) -> Result<ThreadBinding, StoreError>;

    /// Remove a binding. `true` when a record existed.
    async fn remove(&self, thread_id: &str, member: &str) -> Result<bool, StoreError>;

    /// All bindings for one member (ordered by `threadId`).
    async fn for_member(&self, member: &str) -> Result<Vec<ThreadBinding>, StoreError>;
}

type BindingMap = BTreeMap<(String, String), ThreadBinding>;

fn key(thread_id: &str, member: &str) -> (String, String) {
    (thread_id.to_string(), member.to_string())
}

fn validate(binding: &ThreadBinding) -> Result<(), StoreError> {
    if binding.thread_id.trim().is_empty() {
        return Err(StoreError::invalid("threadId must not be empty"));
    }
    if binding.member.trim().is_empty() {
        return Err(StoreError::invalid("member must not be empty"));
    }
    if binding.session_id.trim().is_empty() {
        return Err(StoreError::invalid("sessionId must not be empty"));
    }
    Ok(())
}

/// Insert/replace a validated binding, assigning `boundAt` when missing.
fn apply_upsert(
    map: &mut BindingMap,
    mut binding: ThreadBinding,
) -> Result<ThreadBinding, StoreError> {
    validate(&binding)?;
    if binding.bound_at.trim().is_empty() {
        binding.bound_at = now_rfc3339();
    }
    map.insert(key(&binding.thread_id, &binding.member), binding.clone());
    Ok(binding)
}

fn entries(map: &BindingMap) -> Vec<ThreadBinding> {
    map.values().cloned().collect()
}

fn bindings_file(map: &BindingMap) -> BindingsFile {
    BindingsFile {
        version: THREAD_BINDINGS_STORE_VERSION,
        bindings: entries(map),
    }
}

fn load_map(path: &Path) -> Result<BindingMap, StoreError> {
    let Some(file) =
        read_versioned_store::<BindingsFile>(path, THREAD_BINDINGS_STORE_VERSION, |file| {
            file.version
        })?
    else {
        return Ok(BindingMap::new());
    };
    let mut map = BindingMap::new();
    for binding in file.bindings {
        validate(&binding)?;
        let pair = key(&binding.thread_id, &binding.member);
        if map.insert(pair.clone(), binding).is_some() {
            return Err(StoreError::corrupt(
                path,
                format!(
                    "duplicate binding for threadId {:?} member {:?}",
                    pair.0, pair.1
                ),
            ));
        }
    }
    Ok(map)
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BindingsFile {
    version: u32,
    bindings: Vec<ThreadBinding>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    // A poisoned mutex means a panic while mutating; the JSON file is the
    // source of truth and is rewritten atomically, so recover the guard.
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// In-memory store (default for tests / fake mode).
#[derive(Debug, Default)]
pub struct InMemoryThreadBindingService {
    map: Mutex<BindingMap>,
}

impl InMemoryThreadBindingService {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl ThreadBindingService for InMemoryThreadBindingService {
    async fn list(&self, thread_id: &str) -> Result<Vec<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        let mut items: Vec<ThreadBinding> = map
            .values()
            .filter(|binding| binding.thread_id == thread_id)
            .cloned()
            .collect();
        items.sort_by(|left, right| left.member.cmp(&right.member));
        Ok(items)
    }

    async fn get(
        &self,
        thread_id: &str,
        member: &str,
    ) -> Result<Option<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        Ok(map.get(&key(thread_id, member)).cloned())
    }

    async fn upsert(&self, binding: ThreadBinding) -> Result<ThreadBinding, StoreError> {
        let mut map = lock(&self.map);
        apply_upsert(&mut map, binding)
    }

    async fn remove(&self, thread_id: &str, member: &str) -> Result<bool, StoreError> {
        let mut map = lock(&self.map);
        Ok(map.remove(&key(thread_id, member)).is_some())
    }

    async fn for_member(&self, member: &str) -> Result<Vec<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        let mut items: Vec<ThreadBinding> = map
            .values()
            .filter(|binding| binding.member == member)
            .cloned()
            .collect();
        items.sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
        Ok(items)
    }
}

/// File-backed store: bindings survive restarts.
#[derive(Debug)]
pub struct FileThreadBindingService {
    path: PathBuf,
    map: Mutex<BindingMap>,
}

impl FileThreadBindingService {
    /// Open (or create on first write) the store at `path` (the
    /// `<data-dir>/thread-bindings.json` file). A corrupt file is an error.
    pub fn open(path: impl Into<PathBuf>) -> Result<Self, StoreError> {
        let path = path.into();
        let map = load_map(&path)?;
        Ok(Self {
            path,
            map: Mutex::new(map),
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn persist(&self, map: &BindingMap) -> Result<(), StoreError> {
        write_json_atomic(&self.path, &bindings_file(map))
    }
}

#[async_trait]
impl ThreadBindingService for FileThreadBindingService {
    async fn list(&self, thread_id: &str) -> Result<Vec<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        let mut items: Vec<ThreadBinding> = map
            .values()
            .filter(|binding| binding.thread_id == thread_id)
            .cloned()
            .collect();
        items.sort_by(|left, right| left.member.cmp(&right.member));
        Ok(items)
    }

    async fn get(
        &self,
        thread_id: &str,
        member: &str,
    ) -> Result<Option<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        Ok(map.get(&key(thread_id, member)).cloned())
    }

    async fn upsert(&self, binding: ThreadBinding) -> Result<ThreadBinding, StoreError> {
        let mut map = lock(&self.map);
        let stored = apply_upsert(&mut map, binding)?;
        self.persist(&map)?;
        Ok(stored)
    }

    async fn remove(&self, thread_id: &str, member: &str) -> Result<bool, StoreError> {
        let mut map = lock(&self.map);
        let removed = map.remove(&key(thread_id, member)).is_some();
        if removed {
            self.persist(&map)?;
        }
        Ok(removed)
    }

    async fn for_member(&self, member: &str) -> Result<Vec<ThreadBinding>, StoreError> {
        let map = lock(&self.map);
        let mut items: Vec<ThreadBinding> = map
            .values()
            .filter(|binding| binding.member == member)
            .cloned()
            .collect();
        items.sort_by(|left, right| left.thread_id.cmp(&right.thread_id));
        Ok(items)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn binding(thread: &str, member: &str, session: &str) -> ThreadBinding {
        ThreadBinding::new(thread, member, session, Some("codex".into()))
    }

    async fn exercise_service(service: &dyn ThreadBindingService) {
        service
            .upsert(binding("t1", "human", "s1"))
            .await
            .expect("upsert human");
        service
            .upsert(binding("t1", "grokbot", "s2"))
            .await
            .expect("upsert grokbot");
        service
            .upsert(binding("t2", "human", "s3"))
            .await
            .expect("upsert other thread");

        let listed = service.list("t1").await.expect("list");
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].member, "grokbot");
        assert_eq!(listed[1].member, "human");

        let fetched = service
            .get("t1", "human")
            .await
            .expect("get")
            .expect("present");
        assert_eq!(fetched.session_id, "s1");
        assert_eq!(fetched.agent_type.as_deref(), Some("codex"));
        assert!(!fetched.bound_at.is_empty());

        // Rebind replaces the session id for the same pair.
        service
            .upsert(binding("t1", "human", "s4"))
            .await
            .expect("rebind");
        assert_eq!(
            service
                .get("t1", "human")
                .await
                .expect("get")
                .expect("present")
                .session_id,
            "s4"
        );
        assert_eq!(service.list("t1").await.expect("list").len(), 2);

        let member_bindings = service.for_member("human").await.expect("for member");
        assert_eq!(member_bindings.len(), 2);
        assert_eq!(member_bindings[0].thread_id, "t1");
        assert_eq!(member_bindings[1].thread_id, "t2");

        assert!(service.remove("t1", "human").await.expect("remove"));
        assert!(!service.remove("t1", "human").await.expect("remove again"));
        assert!(service.get("t1", "human").await.expect("get").is_none());
        assert_eq!(
            service.for_member("human").await.expect("for member").len(),
            1
        );
    }

    #[tokio::test]
    async fn in_memory_store_round_trips() {
        let service = InMemoryThreadBindingService::new();
        exercise_service(&service).await;
    }

    #[tokio::test]
    async fn blank_fields_are_rejected() {
        let service = InMemoryThreadBindingService::new();
        for bad in [
            ThreadBinding::new("", "human", "s1", None),
            ThreadBinding::new("t1", "", "s1", None),
            ThreadBinding::new("t1", "human", "   ", None),
        ] {
            let error = service
                .upsert(bad)
                .await
                .expect_err("blank field must fail");
            assert!(matches!(error, StoreError::Invalid { .. }), "{error}");
        }
        assert!(service.list("t1").await.expect("list").is_empty());
    }

    #[tokio::test]
    async fn file_store_survives_reopen_and_remove_persists() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(THREAD_BINDINGS_FILE);
        {
            let service = FileThreadBindingService::open(&path).expect("open");
            service
                .upsert(binding("t1", "human", "s1"))
                .await
                .expect("upsert");
            service
                .upsert(binding("t1", "grokbot", "s2"))
                .await
                .expect("upsert");
        }
        // File is materialized with the documented envelope shape.
        let raw = std::fs::read_to_string(&path).expect("read");
        let json: serde_json::Value = serde_json::from_str(&raw).expect("json");
        assert_eq!(json["version"], 1);
        assert_eq!(json["bindings"].as_array().expect("bindings").len(), 2);
        assert_eq!(json["bindings"][0]["threadId"], "t1");

        let reopened = FileThreadBindingService::open(&path).expect("reopen");
        assert_eq!(reopened.list("t1").await.expect("list").len(), 2);
        assert_eq!(
            reopened
                .get("t1", "grokbot")
                .await
                .expect("get")
                .expect("present")
                .session_id,
            "s2"
        );
        assert!(reopened.remove("t1", "human").await.expect("remove"));
        drop(reopened);

        let reopened_again = FileThreadBindingService::open(&path).expect("reopen again");
        assert!(
            reopened_again
                .get("t1", "human")
                .await
                .expect("get")
                .is_none()
        );
        assert_eq!(reopened_again.list("t1").await.expect("list").len(), 1);
    }

    #[tokio::test]
    async fn missing_file_opens_as_empty_store_and_first_write_creates_it() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nested").join(THREAD_BINDINGS_FILE);
        let service = FileThreadBindingService::open(&path).expect("open");
        assert!(service.list("t1").await.expect("list").is_empty());
        assert!(!path.exists(), "open must not write an empty store");
        service
            .upsert(binding("t1", "human", "s1"))
            .await
            .expect("upsert");
        assert!(path.is_file());
    }

    #[tokio::test]
    async fn upsert_fills_missing_bound_at() {
        let service = InMemoryThreadBindingService::new();
        let mut raw = binding("t1", "human", "s1");
        raw.bound_at.clear();
        let stored = service.upsert(raw).await.expect("upsert");
        assert!(!stored.bound_at.is_empty());
        assert!(stored.bound_at.ends_with('Z'));
    }

    #[test]
    fn corrupt_or_wrong_version_file_is_a_hard_error() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(THREAD_BINDINGS_FILE);
        std::fs::write(&path, b"{ not json").expect("write corrupt");
        assert!(matches!(
            FileThreadBindingService::open(&path),
            Err(StoreError::Corrupt { .. })
        ));
        assert_eq!(
            std::fs::read(&path).expect("read"),
            b"{ not json".to_vec(),
            "corrupt bytes must be preserved"
        );
        std::fs::write(&path, br#"{"version":9,"bindings":[]}"#).expect("write version");
        assert!(matches!(
            FileThreadBindingService::open(&path),
            Err(StoreError::Corrupt { .. })
        ));
    }

    #[test]
    fn duplicate_file_records_are_corrupt() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join(THREAD_BINDINGS_FILE);
        std::fs::write(
            &path,
            br#"{"version":1,"bindings":[
                {"threadId":"t1","member":"human","sessionId":"s1","boundAt":"2026-11-11T10:00:00Z"},
                {"threadId":"t1","member":"human","sessionId":"s2","boundAt":"2026-11-11T10:00:01Z"}
            ]}"#,
        )
        .expect("write duplicates");
        assert!(matches!(
            FileThreadBindingService::open(&path),
            Err(StoreError::Corrupt { .. })
        ));
    }
}
