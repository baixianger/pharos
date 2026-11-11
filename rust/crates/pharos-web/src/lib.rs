//! RFC-007 Stream S4 — compose HTTP/WS API with static Web UI assets.
//!
//! Static root is a copy of `Sources/Pharos/Resources/WebCanvas` into repo
//! `webui/` (Swift copies are not edited by this stream).

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::{Router, response::Redirect, routing::get};
use pharos_http::{
    AppState, ApprovalService, EventBus, FakeSessionService, FakeThreadService,
    FileApprovalService, InMemoryApprovalService, api_router,
};
use pharos_store_schema::paths::WEBUI_DIR;
use tower_http::services::{ServeDir, ServeFile};
use tracing::{info, warn};

/// Durable pending-approval store file name inside the Host data dir.
pub const PENDING_APPROVALS_FILE: &str = "pending-approvals.json";

/// Resolve the static Web UI directory.
///
/// Order:
/// 1. `PHAROS_WEBUI_DIR` env (or explicit override)
/// 2. `./webui` relative to current working directory
/// 3. walk up from CWD looking for `webui/index.html` (dev convenience)
pub fn resolve_webui_dir(explicit: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return validate_webui(path);
    }
    if let Ok(from_env) = std::env::var("PHAROS_WEBUI_DIR") {
        return validate_webui(PathBuf::from(from_env));
    }
    let cwd = std::env::current_dir().map_err(|e| e.to_string())?;
    let direct = cwd.join(WEBUI_DIR);
    if direct.join("index.html").is_file() {
        return Ok(direct);
    }
    let mut cursor = cwd.as_path();
    loop {
        let candidate = cursor.join(WEBUI_DIR);
        if candidate.join("index.html").is_file() {
            return Ok(candidate);
        }
        match cursor.parent() {
            Some(parent) => cursor = parent,
            None => break,
        }
    }
    Err(format!(
        "webui not found (looked for {WEBUI_DIR}/index.html under cwd and parents; set PHAROS_WEBUI_DIR)"
    ))
}

fn validate_webui(path: PathBuf) -> Result<PathBuf, String> {
    if path.join("index.html").is_file() {
        Ok(path)
    } else {
        Err(format!("webui dir {} missing index.html", path.display()))
    }
}

/// Resolve the Host data dir (explicit override > `PHAROS_DATA_DIR` > home default).
///
/// The approval store lives here so pending HITL approvals survive restarts.
pub fn resolve_data_dir(explicit: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return Ok(path);
    }
    if let Ok(from_env) = std::env::var("PHAROS_DATA_DIR") {
        if !from_env.trim().is_empty() {
            return Ok(PathBuf::from(from_env));
        }
    }
    let home = std::env::var("HOME")
        .map_err(|_| "cannot resolve data dir: HOME unset (pass --data-dir or PHAROS_DATA_DIR)")?;
    let home = PathBuf::from(home);
    if cfg!(target_os = "macos") {
        Ok(home.join("Library/Application Support/Pharos"))
    } else {
        Ok(home.join(".local/state/pharos"))
    }
}

/// Construct `AppState` with an explicit approval service + fake S1/S2 services.
pub fn app_state_with_approvals(approvals: Arc<dyn ApprovalService>) -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    AppState::with_approvals(threads, sessions, events, approvals)
}

/// Construct AppState wired to **fake** S1/S2 services and an in-memory
/// approval snapshot (S4 acceptance default; approvals do not survive restart).
pub fn fake_app_state() -> AppState {
    app_state_with_approvals(Arc::new(InMemoryApprovalService::new()))
}

/// Construct AppState whose pending approvals are persisted in `data_dir`.
///
/// Errors (unwritable dir, corrupt store) are surfaced instead of silently
/// falling back to memory — a faked "persisted" success is worse than a failure.
pub fn persistent_app_state(data_dir: &Path) -> Result<AppState, String> {
    std::fs::create_dir_all(data_dir)
        .map_err(|err| format!("create data dir {}: {err}", data_dir.display()))?;
    let store_path = data_dir.join(PENDING_APPROVALS_FILE);
    let approvals = FileApprovalService::open(&store_path)
        .map_err(|err| format!("open pending approval store {}: {err}", store_path.display()))?;
    info!(
        store = %store_path.display(),
        "pending approvals persisted to disk"
    );
    Ok(app_state_with_approvals(Arc::new(approvals)))
}

/// Build the full app router: API + static files from `webui_dir`.
pub fn app_router(state: AppState, webui_dir: &Path) -> Router {
    let index = webui_dir.join("index.html");
    let static_files = ServeDir::new(webui_dir).append_index_html_on_directories(true);
    let fallback = ServeFile::new(index);

    api_router(state)
        .route(
            "/",
            get(|| async { Redirect::temporary("/workspace.html") }),
        )
        .fallback_service(static_files.fallback(fallback))
}

/// Bind and serve until the future is cancelled / process exits.
///
/// Also starts the approval event tap so adapter/session approval events are
/// persisted and recoverable by a reloaded browser.
pub async fn serve(
    addr: SocketAddr,
    webui_dir: PathBuf,
    state: AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let _approval_tap = state.spawn_approval_tap();
    let app = app_router(state, &webui_dir);
    info!(%addr, webui = %webui_dir.display(), "pharos-web listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

/// Spawn a server on an ephemeral port; returns the bound address.
pub async fn serve_ephemeral(
    webui_dir: PathBuf,
    state: AppState,
) -> Result<(SocketAddr, tokio::task::JoinHandle<()>), Box<dyn std::error::Error + Send + Sync>> {
    let _approval_tap = state.spawn_approval_tap();
    let listener = tokio::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))).await?;
    let addr = listener.local_addr()?;
    let app = app_router(state, &webui_dir);
    let handle = tokio::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            tracing::error!(?err, "pharos-web serve error");
        }
    });
    Ok((addr, handle))
}

/// Warn once that S1/S2 serviced by this binary are fakes (honesty in logs).
pub fn warn_fake_services() {
    warn!("pharos-web using FakeThreadService + FakeSessionService (S1/S2 not wired yet)");
}
