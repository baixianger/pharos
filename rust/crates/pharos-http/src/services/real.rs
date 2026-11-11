//! Compose the real S1/S2 backends into the S4 [`AppState`].
//!
//! Used by the `pharos-web` binary by default; `--fake` keeps the in-memory
//! fakes for explicit offline demos and tests.
//!
//! Data layout under the Host data dir (PHASE0 conventions):
//!
//! ```text
//! <data-dir>/
//!   mesh/replica.sqlite3   # rooms / memberships / messages (pharos-thread)
//!   mesh/goals.sqlite3     # session_goals / session_todos (pharos-goals)
//! ```

use std::path::PathBuf;
use std::sync::Arc;

use crate::services::{
    EventBus, RealSessionService, RealThreadService, SessionService, ThreadService,
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

    Ok(AppState::new(threads, sessions, events))
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
}
