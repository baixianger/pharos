//! Compose the real S1/S2 backends into the S4 [`AppState`].
//!
//! Used by the `pharos-web` binary by default; `--fake` keeps the in-memory
//! fakes for explicit offline demos and tests.
//!
//! Data layout under the Host data dir (PHASE0 conventions):
//!
//! ```text
//! <data-dir>/
//!   mesh/replica.sqlite3    # rooms / memberships / messages (pharos-thread)
//!   mesh/goals.sqlite3      # session_goals / session_todos (pharos-goals)
//!   thread-bindings.json    # durable Thread <-> session bindings
//!   member-settings.json    # durable member settings
//!   avatars/<sha256>.<ext>  # raw avatar bytes
//!   attachments/index.json  # durable attachment metadata
//!   attachments/<id>        # raw attachment bytes
//! ```
//!
//! The web-endpoint stores are file-backed here: `--fake` mode still persists
//! them through `pharos_web::persistent_app_state` (only S1/S2 are fake).

use std::path::PathBuf;
use std::sync::Arc;

use crate::services::{
    AttachmentService, EventBus, FileAttachmentService, FileMemberSettingsService,
    FileThreadBindingService, InMemoryApprovalService, MemberSettingsService, RealSessionService,
    RealThreadService, SessionService, StoreError, THREAD_BINDINGS_FILE, ThreadBindingService,
    ThreadService,
};
use crate::state::AppState;

/// Which vendor adapter the real Session service should use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SessionAdapterChoice {
    /// Do not spawn a vendor process: session reads are empty and live actions
    /// return an explicit `operationFailed` error.
    #[default]
    None,
    /// Live Codex App Server sessions (`codex` CLI on PATH).
    Codex,
}

impl SessionAdapterChoice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Codex => "codex",
        }
    }

    /// Parse a CLI/env value (`none` | `codex`).
    pub fn parse(raw: &str) -> Result<Self, String> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "" | "none" => Ok(Self::None),
            "codex" => Ok(Self::Codex),
            other => Err(format!(
                "unsupported session adapter {other:?} (expected none|codex)"
            )),
        }
    }
}

/// Options for [`build_real_app_state`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RealOptions {
    /// Host data dir root (created if missing).
    pub data_dir: PathBuf,
    /// Live vendor adapter for Sessions (default: none).
    pub session_adapter: SessionAdapterChoice,
}

impl RealOptions {
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        Self {
            data_dir: data_dir.into(),
            session_adapter: SessionAdapterChoice::None,
        }
    }

    pub fn with_session_adapter(mut self, adapter: SessionAdapterChoice) -> Self {
        self.session_adapter = adapter;
        self
    }
}

/// Failure to open the real backends.
#[derive(Debug, thiserror::Error)]
pub enum RealServiceError {
    #[error("data dir: {0}")]
    DataDir(String),
    #[error("thread store: {0}")]
    Thread(#[from] pharos_thread::ThreadError),
    #[error("goals store: {0}")]
    Goals(#[from] pharos_goals::GoalsError),
    #[error("session adapter: {0}")]
    Adapter(String),
    #[error("web endpoint store: {0}")]
    Store(#[from] StoreError),
}

/// Open the durable S1/S2 stores under `options.data_dir` and wire them into
/// [`AppState`]. Fake services are never used here.
pub fn build_real_app_state(options: RealOptions) -> Result<AppState, RealServiceError> {
    let data_dir = options.data_dir;
    let mesh_dir = data_dir.join(pharos_store_schema::paths::MESH_DIR);
    std::fs::create_dir_all(&mesh_dir).map_err(|error| {
        RealServiceError::DataDir(format!("create {}: {error}", mesh_dir.display()))
    })?;

    let events = EventBus::new(256);

    let thread_db = mesh_dir.join(pharos_store_schema::paths::REPLICA_DB);
    let store = pharos_thread::SqliteThreadStore::open(&thread_db)?;
    let threads: Arc<dyn ThreadService> =
        Arc::new(RealThreadService::new(Arc::new(store), events.clone()));

    let goals = pharos_goals::open_goals_db(&mesh_dir)?;
    let sessions: Arc<dyn SessionService> = match options.session_adapter {
        SessionAdapterChoice::None => {
            Arc::new(RealSessionService::unconfigured(goals, events.clone()))
        }
        SessionAdapterChoice::Codex => {
            let adapter = pharos_codex_adapter::CodexSessionAdapter::connect_stdio()
                .map_err(|error| RealServiceError::Adapter(error.to_string()))?;
            Arc::new(RealSessionService::with_live_adapter(
                Box::new(adapter),
                goals,
                events.clone(),
                "codex",
            ))
        }
    };

    // File-backed web-endpoint stores under the same Host data dir. Opening a
    // corrupt store is a hard error (never a silent reset).
    let bindings: Arc<dyn ThreadBindingService> = Arc::new(FileThreadBindingService::open(
        data_dir.join(THREAD_BINDINGS_FILE),
    )?);
    let members: Arc<dyn MemberSettingsService> =
        Arc::new(FileMemberSettingsService::open_in(&data_dir)?);
    let attachments: Arc<dyn AttachmentService> =
        Arc::new(FileAttachmentService::open_in(&data_dir)?);

    Ok(AppState::with_extras(
        threads,
        sessions,
        events,
        // `pharos-web`'s real_app_state replaces this with the durable file
        // approval store; the HTTP crate itself stays data-dir agnostic here.
        Arc::new(InMemoryApprovalService::new()),
        bindings,
        members,
        attachments,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_adapter_choice_parses() {
        assert_eq!(
            SessionAdapterChoice::parse("none").unwrap(),
            SessionAdapterChoice::None
        );
        assert_eq!(
            SessionAdapterChoice::parse(" Codex ").unwrap(),
            SessionAdapterChoice::Codex
        );
        assert_eq!(
            SessionAdapterChoice::parse("").unwrap(),
            SessionAdapterChoice::None
        );
        assert!(SessionAdapterChoice::parse("agy").is_err());
        assert_eq!(SessionAdapterChoice::default(), SessionAdapterChoice::None);
        assert_eq!(SessionAdapterChoice::Codex.as_str(), "codex");
    }

    #[test]
    fn build_real_state_persists_threads_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let options = RealOptions::new(dir.path());
        let state = build_real_app_state(options.clone()).unwrap();
        assert!(dir.path().join("mesh/replica.sqlite3").is_file());
        assert!(dir.path().join("mesh/goals.sqlite3").is_file());
        drop(state);

        // Rebuilding from the same data dir opens the same durable files.
        let reopened = build_real_app_state(options).unwrap();
        drop(reopened);
    }

    #[tokio::test]
    async fn build_real_state_wires_file_backed_web_stores() {
        use crate::services::{MemberSettingsPatch, ThreadBinding, UploadedAttachment};

        let dir = tempfile::tempdir().unwrap();
        let options = RealOptions::new(dir.path());
        {
            let state = build_real_app_state(options.clone()).unwrap();
            state
                .bindings
                .upsert(ThreadBinding::new("thread-1", "human", "session-1", None))
                .await
                .expect("bind");
            state
                .members
                .patch(
                    "human",
                    MemberSettingsPatch {
                        display_name: Some("Pai".into()),
                        avatar_shape: Some("circle".into()),
                        ..MemberSettingsPatch::default()
                    },
                )
                .await
                .expect("member patch");
            state
                .attachments
                .create(
                    "session-1",
                    UploadedAttachment {
                        filename: "notes.txt".into(),
                        content_type: "text/plain".into(),
                        bytes: b"hello".to_vec(),
                    },
                )
                .await
                .expect("attachment");
        }
        // The stores materialize their files under the data dir on first write.
        assert!(dir.path().join("thread-bindings.json").is_file());
        assert!(dir.path().join("member-settings.json").is_file());
        assert!(dir.path().join("attachments").join("index.json").is_file());

        let reopened = build_real_app_state(options).unwrap();
        assert!(
            reopened
                .bindings
                .get("thread-1", "human")
                .await
                .expect("get binding")
                .is_some()
        );
        assert_eq!(
            reopened
                .members
                .get("human")
                .await
                .expect("get member")
                .display_name,
            Some("Pai".to_string())
        );
        assert_eq!(
            reopened
                .attachments
                .list_for_session("session-1")
                .await
                .expect("list attachments")
                .len(),
            1
        );
    }

    #[test]
    fn corrupt_web_store_fails_build_real_app_state() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("thread-bindings.json"), b"{ not json")
            .expect("write corrupt");
        let error = match build_real_app_state(RealOptions::new(dir.path())) {
            Ok(_) => panic!("corrupt web store must be a hard error"),
            Err(error) => error,
        };
        assert!(
            matches!(error, RealServiceError::Store(_)),
            "corrupt web store must be a hard error, got {error:?}"
        );
        assert_eq!(
            std::fs::read(dir.path().join("thread-bindings.json")).expect("read"),
            b"{ not json".to_vec(),
            "corrupt bytes must be preserved"
        );
    }
}
