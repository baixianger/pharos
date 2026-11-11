//! RFC-007 Stream S4 — compose HTTP/WS API with static Web UI assets.
//!
//! Static root is a copy of `Sources/Pharos/Resources/WebCanvas` into repo
//! `webui/` (Swift copies are not edited by this stream).

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::{Router, response::Redirect, routing::get};
use pharos_http::{AppState, EventBus, FakeSessionService, FakeThreadService, api_router};
use pharos_store_schema::paths::WEBUI_DIR;
use tower_http::services::{ServeDir, ServeFile};
use tracing::info;

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

/// Construct AppState wired to **fake** S1/S2 services (S4 acceptance default).
pub fn fake_app_state() -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    AppState::new(threads, sessions, events)
}

/// Bind and serve until the future is cancelled / process exits.
pub async fn serve(
    addr: SocketAddr,
    webui_dir: PathBuf,
    state: AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
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
