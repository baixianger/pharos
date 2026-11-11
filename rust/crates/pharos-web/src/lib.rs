//! RFC-007 Stream S4 — compose HTTP/WS API with static Web UI assets.
//!
//! Static root is a copy of `Sources/Pharos/Resources/WebCanvas` into repo
//! `webui/` (Swift copies are not edited by this stream).
//!
//! The `pharos-web` binary serves **real** S1/S2 services by default through
//! [`real_app_state`] (`pharos_http::services::build_real_app_state`: durable
//! Thread replica + explicitly configured session adapter). [`fake_app_state`]
//! remains for the explicit `--fake` offline mode and the S4 acceptance tests;
//! nothing here silently substitutes fakes for real data.
//!
//! Pending HITL approvals are **always** durable: both the real and the fake
//! backend modes persist them in `<data-dir>/pending-approvals.json` via
//! [`pharos_http::FileApprovalService`], and [`serve`] / [`serve_with_token`]
//! start [`AppState::spawn_approval_tap`] so approval lifecycle events reach
//! that store and survive a reload/restart.
//!
//! When non-loopback binds are used, [`app_router_with_token`] /
//! [`serve_with_token`] require a bearer token on API routes and
//! [`validate_bind`] refuses unauthenticated public binds.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::{Router, response::Redirect, routing::get};
use pharos_http::services::{
    AttachmentService, FileAttachmentService, FileMemberSettingsService, FileThreadBindingService,
    MemberSettingsService, RealOptions, SessionAdapterChoice, THREAD_BINDINGS_FILE,
    ThreadBindingService, build_real_app_state,
};
use pharos_http::{
    AppState, ApprovalService, EventBus, FakeSessionService, FakeThreadService,
    FileApprovalService, InMemoryApprovalService, api_router,
};
use pharos_store_schema::paths::WEBUI_DIR;
use tower_http::services::{ServeDir, ServeFile};
use tracing::{info, warn};

/// Durable pending-approval store file name inside the Host data dir.
pub const PENDING_APPROVALS_FILE: &str = "pending-approvals.json";

pub mod auth;

pub use auth::{AuthToken, require_bearer, with_bearer_auth};

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

/// Resolve the single Host data dir.
///
/// Order (first wins):
/// 1. explicit `--data-dir`
/// 2. `PHAROS_WEB_DATA_DIR` (primary env, owned by this stream)
/// 3. `PHAROS_DATA_DIR` (legacy/compat env from the HITL stream)
/// 4. platform default: macOS `~/Library/Application Support/Pharos`,
///    other Unix `$XDG_DATA_HOME/pharos` or `~/.local/share/pharos`.
///
/// The Thread replica (`mesh/replica.sqlite3`), goals (`mesh/goals.sqlite3`)
/// and `pending-approvals.json` all live under this one directory.
pub fn resolve_data_dir(explicit: Option<PathBuf>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return Ok(path);
    }
    default_data_dir()
}

/// Default on-disk root for durable data (Thread replica, goals, approvals).
///
/// `PHAROS_WEB_DATA_DIR` wins over the legacy `PHAROS_DATA_DIR`; see
/// [`resolve_data_dir`] for the full order.
pub fn default_data_dir() -> Result<PathBuf, String> {
    data_dir_from(|key| std::env::var_os(key))
}

fn data_dir_from(get: impl Fn(&str) -> Option<std::ffi::OsString>) -> Result<PathBuf, String> {
    if let Some(raw) = get("PHAROS_WEB_DATA_DIR") {
        let path = PathBuf::from(raw);
        if path.as_os_str().is_empty() {
            return Err("PHAROS_WEB_DATA_DIR is set but empty".to_string());
        }
        return Ok(path);
    }
    // Legacy name from the pending-approval persistence stream; kept so
    // existing daemon/launchd wiring keeps working. The primary env above wins.
    if let Some(raw) = get("PHAROS_DATA_DIR") {
        let path = PathBuf::from(raw);
        if path.as_os_str().is_empty() {
            return Err("PHAROS_DATA_DIR is set but empty".to_string());
        }
        return Ok(path);
    }

    #[cfg(target_os = "macos")]
    {
        let home = require_home(get("HOME"))?;
        Ok(home
            .join("Library")
            .join("Application Support")
            .join("Pharos"))
    }

    #[cfg(not(target_os = "macos"))]
    {
        if let Some(xdg) = get("XDG_DATA_HOME").filter(|value| !value.is_empty()) {
            return Ok(PathBuf::from(xdg).join("pharos"));
        }
        let home = require_home(get("HOME"))?;
        Ok(home.join(".local").join("share").join("pharos"))
    }
}

fn require_home(home: Option<std::ffi::OsString>) -> Result<PathBuf, String> {
    home.filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .ok_or_else(|| {
            "HOME is not set and PHAROS_WEB_DATA_DIR/PHAROS_DATA_DIR was not provided; \
             set --data-dir/PHAROS_WEB_DATA_DIR"
                .to_string()
        })
}

/// Open the durable pending-approval store inside `data_dir`.
///
/// A corrupt or unreadable store is surfaced as an error instead of silently
/// falling back to memory — a faked "persisted" success is worse than a
/// failure. Never rewrites/truncates existing bytes on open.
fn open_approval_store(data_dir: &Path) -> Result<FileApprovalService, String> {
    std::fs::create_dir_all(data_dir)
        .map_err(|err| format!("create data dir {}: {err}", data_dir.display()))?;
    let store_path = data_dir.join(PENDING_APPROVALS_FILE);
    let approvals = FileApprovalService::open(&store_path).map_err(|err| {
        format!(
            "open pending approval store {}: {err}",
            store_path.display()
        )
    })?;
    info!(
        store = %store_path.display(),
        "pending approvals persisted to disk"
    );
    Ok(approvals)
}

/// Construct `AppState` with an explicit approval service + fake S1/S2 services.
pub fn app_state_with_approvals(approvals: Arc<dyn ApprovalService>) -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    AppState::with_approvals(threads, sessions, events, approvals)
}

/// Construct AppState wired to **fake** S1/S2 services and an in-memory
/// approval snapshot (S4 acceptance tests only; the `--fake` binary mode uses
/// [`persistent_app_state`] so approvals stay durable).
pub fn fake_app_state() -> AppState {
    app_state_with_approvals(Arc::new(InMemoryApprovalService::new()))
}

/// Open the durable web-endpoint stores (bindings / member settings + avatars /
/// attachments) under `data_dir`.
///
/// A corrupt or unreadable store is surfaced as an error instead of silently
/// falling back to memory or an empty store: a faked "persisted" success is
/// worse than a failure. Never rewrites/truncates existing bytes on open.
fn open_web_stores(
    data_dir: &Path,
) -> Result<
    (
        Arc<dyn ThreadBindingService>,
        Arc<dyn MemberSettingsService>,
        Arc<dyn AttachmentService>,
    ),
    String,
> {
    std::fs::create_dir_all(data_dir)
        .map_err(|err| format!("create data dir {}: {err}", data_dir.display()))?;
    let bindings =
        FileThreadBindingService::open(data_dir.join(THREAD_BINDINGS_FILE)).map_err(|err| {
            format!(
                "open thread bindings store under {}: {err}",
                data_dir.display()
            )
        })?;
    let members = FileMemberSettingsService::open_in(data_dir).map_err(|err| {
        format!(
            "open member settings store under {}: {err}",
            data_dir.display()
        )
    })?;
    let attachments = FileAttachmentService::open_in(data_dir)
        .map_err(|err| format!("open attachments store under {}: {err}", data_dir.display()))?;
    Ok((Arc::new(bindings), Arc::new(members), Arc::new(attachments)))
}

/// Construct AppState wired to **fake** S1/S2 services whose pending approvals
/// AND web-endpoint stores (bindings / member settings / avatars / attachments)
/// are persisted in `data_dir` (used by the explicit `--fake` binary mode).
///
/// The fake Thread/Session state remains in memory; everything the web-endpoint
/// routes persist is durable across restarts, exactly like the real mode.
pub fn persistent_app_state(data_dir: &Path) -> Result<AppState, String> {
    let approvals = open_approval_store(data_dir)?;
    let (bindings, members, attachments) = open_web_stores(data_dir)?;
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    Ok(AppState::with_extras(
        threads,
        sessions,
        events,
        Arc::new(approvals),
        bindings,
        members,
        attachments,
    ))
}

/// Construct AppState wired to the **real** durable S1/S2 backends plus the
/// durable pending-approval store, all under `data_dir`.
///
/// This is the default `pharos-web` mode (the binary's `--fake` flag opts out
/// of the real S1/S2 services, not out of approval persistence).
pub fn real_app_state(data_dir: &Path, adapter: SessionAdapterChoice) -> Result<AppState, String> {
    let approvals = open_approval_store(data_dir)?;
    let state = build_real_app_state(RealOptions::new(data_dir).with_session_adapter(adapter))
        .map_err(|error| {
            format!(
                "failed to open real backend under {}: {error}",
                data_dir.display()
            )
        })?;
    // Rebuild with the durable approval service while keeping the real
    // S1/S2 services, the file-backed web-endpoint stores and the shared event
    // bus.
    Ok(AppState::with_extras(
        state.threads,
        state.sessions,
        state.events,
        Arc::new(approvals),
        state.bindings,
        state.members,
        state.attachments,
    ))
}

/// Build the full app router: API + static files from `webui_dir`, no auth.
pub fn app_router(state: AppState, webui_dir: &Path) -> Router {
    app_router_with_token(state, webui_dir, None)
}

/// Build the full app router, requiring `token` on API routes when set.
///
/// The bearer layer is applied only to the API router's routes; static Web UI
/// assets are served by a fallback outside the layer, so the page itself always
/// loads and can surface a 401 from its API calls. `/health` stays
/// unauthenticated (see [`auth::require_bearer`]) so liveness can be probed
/// before a token is supplied. With `token = None` this is identical to
/// [`app_router`].
///
/// The layer covers **all** API routes, including
/// `GET /api/v1/approvals` and `POST /api/v1/sessions/{id}/approval`.
pub fn app_router_with_token(
    state: AppState,
    webui_dir: &Path,
    token: Option<AuthToken>,
) -> Router {
    let index = webui_dir.join("index.html");
    let static_files = ServeDir::new(webui_dir).append_index_html_on_directories(true);
    let fallback = ServeFile::new(index);

    let api = api_router(state);
    let api = match token {
        Some(token) => with_bearer_auth(api, token),
        None => api,
    };

    // Added after the auth layer on purpose: the redirect and the static
    // fallback must not require a token.
    api.route(
        "/",
        get(|| async { Redirect::temporary("/workspace.html") }),
    )
    .fallback_service(static_files.fallback(fallback))
}

/// Refuse non-loopback binds unless a token is configured.
///
/// `0.0.0.0` / `::` (and any routable address) would expose the API beyond the
/// local machine; without a token that is always a misconfiguration. Called by
/// the CLI for a fast, clear error and again by [`serve_with_token`] as
/// defense in depth.
pub fn validate_bind(addr: SocketAddr, token: Option<&AuthToken>) -> Result<(), String> {
    if addr.ip().is_loopback() || token.is_some() {
        return Ok(());
    }
    Err(format!(
        "refusing to bind non-loopback address {addr} without a token; \
         pass --token/PHAROS_WEB_TOKEN or bind a loopback address"
    ))
}

/// Bind and serve until the future is cancelled / process exits (no auth).
pub async fn serve(
    addr: SocketAddr,
    webui_dir: PathBuf,
    state: AppState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    serve_with_token(addr, webui_dir, state, None).await
}

/// Bind and serve with an optional API bearer token.
///
/// Re-validates the bind address so a non-loopback listener can never start
/// without auth, even if a caller skipped [`validate_bind`]. Also starts the
/// approval event tap so adapter/session approval events are persisted and
/// recoverable by a reloaded browser.
pub async fn serve_with_token(
    addr: SocketAddr,
    webui_dir: PathBuf,
    state: AppState,
    token: Option<AuthToken>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_bind(addr, token.as_ref())?;
    let _approval_tap = state.spawn_approval_tap();
    let app = app_router_with_token(state, &webui_dir, token);
    info!(%addr, webui = %webui_dir.display(), "pharos-web listening");
    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

/// Spawn a server on an ephemeral loopback port; returns the bound address.
pub async fn serve_ephemeral(
    webui_dir: PathBuf,
    state: AppState,
) -> Result<(SocketAddr, tokio::task::JoinHandle<()>), Box<dyn std::error::Error + Send + Sync>> {
    serve_ephemeral_with_token(webui_dir, state, None).await
}

/// Spawn a server on an ephemeral loopback port with an optional bearer token.
pub async fn serve_ephemeral_with_token(
    webui_dir: PathBuf,
    state: AppState,
    token: Option<AuthToken>,
) -> Result<(SocketAddr, tokio::task::JoinHandle<()>), Box<dyn std::error::Error + Send + Sync>> {
    let _approval_tap = state.spawn_approval_tap();
    let listener = tokio::net::TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0))).await?;
    let addr = listener.local_addr()?;
    let app = app_router_with_token(state, &webui_dir, token);
    let handle = tokio::spawn(async move {
        if let Err(err) = axum::serve(listener, app).await {
            tracing::error!(?err, "pharos-web serve error");
        }
    });
    Ok((addr, handle))
}

/// Warn that the in-memory S1/S2 fakes are in use (honesty in logs).
///
/// Pending HITL approvals are still durable in `--fake` mode; only Thread /
/// Session data is in-memory.
pub fn warn_fake_services() {
    warn!(
        "pharos-web using FakeThreadService + FakeSessionService (S1/S2 fake mode); \
         pending approvals are still persisted to disk"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::ffi::OsString;

    use axum::body::to_bytes;
    use axum::http::{Request, StatusCode, header};
    use tower::ServiceExt;

    fn env_map(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let map: HashMap<String, OsString> = pairs
            .iter()
            .map(|(key, value)| ((*key).to_string(), OsString::from(value)))
            .collect();
        move |key| map.get(key).cloned()
    }

    fn addr(raw: &str) -> SocketAddr {
        raw.parse().expect("test addr")
    }

    // --- validate_bind -----------------------------------------------------

    #[test]
    fn validate_bind_allows_loopback_without_token() {
        assert!(validate_bind(addr("127.0.0.1:8787"), None).is_ok());
        assert!(validate_bind(addr("127.0.0.5:1"), None).is_ok());
        assert!(validate_bind(addr("[::1]:8787"), None).is_ok());
    }

    #[test]
    fn validate_bind_rejects_public_binds_without_token() {
        for raw in ["0.0.0.0:8787", "[::]:8787", "192.168.1.20:8787"] {
            assert!(
                validate_bind(addr(raw), None).is_err(),
                "{raw} must be refused without a token"
            );
        }
    }

    #[test]
    fn validate_bind_allows_public_bind_with_token() {
        let token = AuthToken::new("tok").expect("token");
        for raw in ["0.0.0.0:8787", "[::]:8787", "192.168.1.20:8787"] {
            assert!(
                validate_bind(addr(raw), Some(&token)).is_ok(),
                "{raw} must be allowed with a token"
            );
        }
    }

    // --- default data dir --------------------------------------------------

    #[test]
    fn data_dir_env_override_wins() {
        let dir = data_dir_from(env_map(&[(
            "PHAROS_WEB_DATA_DIR",
            "/tmp/custom-pharos-data",
        )]))
        .expect("override");
        assert_eq!(dir, PathBuf::from("/tmp/custom-pharos-data"));
    }

    #[test]
    fn data_dir_blank_override_is_an_error() {
        assert!(data_dir_from(env_map(&[("PHAROS_WEB_DATA_DIR", "")])).is_err());
        assert!(data_dir_from(env_map(&[("PHAROS_DATA_DIR", "")])).is_err());
    }

    #[test]
    fn legacy_pharos_data_dir_is_still_honored() {
        let dir = data_dir_from(env_map(&[("PHAROS_DATA_DIR", "/legacy/pharos")])).expect("legacy");
        assert_eq!(dir, PathBuf::from("/legacy/pharos"));
    }

    #[test]
    fn primary_web_data_dir_beats_legacy_data_dir() {
        let dir = data_dir_from(env_map(&[
            ("PHAROS_WEB_DATA_DIR", "/primary/pharos"),
            ("PHAROS_DATA_DIR", "/legacy/pharos"),
        ]))
        .expect("primary");
        assert_eq!(dir, PathBuf::from("/primary/pharos"));
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn data_dir_uses_xdg_then_home_on_linux() {
        let xdg = data_dir_from(env_map(&[
            ("XDG_DATA_HOME", "/tmp/xdg-home"),
            ("HOME", "/home/pai"),
        ]))
        .expect("xdg");
        assert_eq!(xdg, PathBuf::from("/tmp/xdg-home/pharos"));

        let home = data_dir_from(env_map(&[("HOME", "/home/pai")])).expect("home");
        assert_eq!(home, PathBuf::from("/home/pai/.local/share/pharos"));

        assert!(data_dir_from(env_map(&[])).is_err());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn data_dir_uses_application_support_on_macos() {
        let home = data_dir_from(env_map(&[("HOME", "/Users/pai")])).expect("home");
        assert_eq!(
            home,
            PathBuf::from("/Users/pai/Library/Application Support/Pharos")
        );
        assert!(data_dir_from(env_map(&[])).is_err());
    }

    #[test]
    fn default_data_dir_reads_pharos_web_data_dir_env() {
        let previous = std::env::var_os("PHAROS_WEB_DATA_DIR");
        let expected = std::env::temp_dir().join("pharos-web-data-dir-env-test");
        // SAFETY: this is the only test in this binary that reads or writes
        // PHAROS_WEB_DATA_DIR (the other data-dir tests use the injected
        // lookup helper), and the original value is restored below.
        unsafe { std::env::set_var("PHAROS_WEB_DATA_DIR", &expected) };
        let resolved = default_data_dir();
        match previous {
            Some(value) => unsafe { std::env::set_var("PHAROS_WEB_DATA_DIR", value) },
            None => unsafe { std::env::remove_var("PHAROS_WEB_DATA_DIR") },
        }
        assert_eq!(resolved.expect("env override"), expected);
    }

    // --- backend construction ---------------------------------------------

    fn pending_approval(id: &str) -> pharos_api::ApprovalRequest {
        pharos_api::ApprovalRequest {
            approval_id: id.to_string(),
            session_id: "session-1".to_string(),
            kind: pharos_api::ApprovalKind::ToolPermission {
                tool_name: "shell".to_string(),
                params: serde_json::json!({ "command": "true" }),
                explanation: None,
            },
            available_choices: Some(vec!["allowedOnce".to_string(), "rejected".to_string()]),
        }
    }

    #[tokio::test]
    async fn real_app_state_persists_approval_store_next_to_real_backends() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state = real_app_state(dir.path(), SessionAdapterChoice::None).expect("real state");
        assert!(dir.path().join("mesh/replica.sqlite3").is_file());
        assert!(dir.path().join("mesh/goals.sqlite3").is_file());
        state
            .approvals
            .record(pending_approval("real-mode-1"))
            .await
            .expect("record approval");
        // The store file is materialized by the first durable write.
        assert!(dir.path().join(PENDING_APPROVALS_FILE).is_file());
        assert_eq!(
            state
                .approvals
                .list_pending(None)
                .await
                .expect("list pending")
                .len(),
            1
        );
        drop(state);

        // Reopen: real S1/S2 backends + the same durable approval store.
        let reopened =
            real_app_state(dir.path(), SessionAdapterChoice::None).expect("reopened real state");
        let pending = reopened
            .approvals
            .list_pending(None)
            .await
            .expect("list after reopen");
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].approval_id, "real-mode-1");
    }

    #[tokio::test]
    async fn fake_mode_still_persists_pending_approvals() {
        let dir = tempfile::tempdir().expect("tempdir");
        let state = persistent_app_state(dir.path()).expect("fake+durable state");
        state
            .approvals
            .record(pending_approval("fake-mode-1"))
            .await
            .expect("record approval");
        assert!(dir.path().join(PENDING_APPROVALS_FILE).is_file());
        // In-memory fake S1/S2 services; approvals are durable across reopen.
        drop(state);
        let reopened = persistent_app_state(dir.path()).expect("reopened fake state");
        assert_eq!(
            reopened
                .approvals
                .list_pending(None)
                .await
                .expect("list after reopen")
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn fake_mode_persists_web_stores_across_restart() {
        use pharos_http::services::{MemberSettingsPatch, ThreadBinding, UploadedAttachment};

        let dir = tempfile::tempdir().expect("tempdir");
        {
            let state = persistent_app_state(dir.path()).expect("fake+durable state");
            state
                .bindings
                .upsert(ThreadBinding::new(
                    "thread-1",
                    "human",
                    "fake-session-1",
                    None,
                ))
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
                .expect("patch member");
            state
                .attachments
                .create(
                    "fake-session-1",
                    UploadedAttachment {
                        filename: "notes.txt".into(),
                        content_type: "text/plain".into(),
                        bytes: b"persisted".to_vec(),
                    },
                )
                .await
                .expect("attachment");
        }
        assert!(dir.path().join("thread-bindings.json").is_file());
        assert!(dir.path().join("member-settings.json").is_file());
        assert!(dir.path().join("attachments").join("index.json").is_file());

        let reopened = persistent_app_state(dir.path()).expect("reopened fake state");
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
        let attachments = reopened
            .attachments
            .list_for_session("fake-session-1")
            .await
            .expect("list attachments");
        assert_eq!(attachments.len(), 1);
        let bytes = reopened
            .attachments
            .read(&attachments[0].attachment_id)
            .await
            .expect("read attachment")
            .expect("present");
        assert_eq!(bytes, b"persisted".to_vec());
    }

    #[tokio::test]
    async fn real_mode_persists_web_stores_across_restart() {
        use pharos_http::services::{MemberSettingsPatch, ThreadBinding, UploadedAttachment};

        let dir = tempfile::tempdir().expect("tempdir");
        {
            let state = real_app_state(dir.path(), SessionAdapterChoice::None).expect("real state");
            state
                .bindings
                .upsert(ThreadBinding::new("thread-1", "grokbot", "session-1", None))
                .await
                .expect("bind");
            state
                .members
                .patch(
                    "grokbot",
                    MemberSettingsPatch {
                        display_name: Some("Grok".into()),
                        ..MemberSettingsPatch::default()
                    },
                )
                .await
                .expect("patch member");
            state
                .attachments
                .create(
                    "session-1",
                    UploadedAttachment {
                        filename: "data.json".into(),
                        content_type: "application/json".into(),
                        bytes: b"{}".to_vec(),
                    },
                )
                .await
                .expect("attachment");
        }
        let reopened =
            real_app_state(dir.path(), SessionAdapterChoice::None).expect("reopened real state");
        assert!(
            reopened
                .bindings
                .get("thread-1", "grokbot")
                .await
                .expect("get binding")
                .is_some()
        );
        assert_eq!(
            reopened
                .members
                .get("grokbot")
                .await
                .expect("get member")
                .display_name,
            Some("Grok".to_string())
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
    fn corrupt_web_store_is_an_error_in_both_modes() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join("member-settings.json"), b"{ not json")
            .expect("write corrupt");
        assert!(persistent_app_state(dir.path()).is_err());
        assert!(real_app_state(dir.path(), SessionAdapterChoice::None).is_err());
        assert_eq!(
            std::fs::read(dir.path().join("member-settings.json")).expect("read"),
            b"{ not json".to_vec(),
            "corrupt bytes must be preserved for inspection"
        );
    }

    #[test]
    fn corrupt_approval_store_is_an_error_in_both_modes() {
        let dir = tempfile::tempdir().expect("tempdir");
        std::fs::write(dir.path().join(PENDING_APPROVALS_FILE), b"{ not json")
            .expect("write corrupt");
        assert!(persistent_app_state(dir.path()).is_err());
        assert!(real_app_state(dir.path(), SessionAdapterChoice::None).is_err());
        assert_eq!(
            std::fs::read(dir.path().join(PENDING_APPROVALS_FILE)).expect("read"),
            b"{ not json".to_vec(),
            "corrupt bytes must be preserved for inspection"
        );
    }

    // --- router wiring -----------------------------------------------------

    async fn call(app: Router, request: Request<axum::body::Body>) -> (StatusCode, String) {
        let response = app.oneshot(request).await.expect("router call");
        let status = response.status();
        let body = to_bytes(response.into_body(), usize::MAX)
            .await
            .expect("body");
        (status, String::from_utf8_lossy(&body).into_owned())
    }

    fn request(uri: &str, bearer: Option<&str>) -> Request<axum::body::Body> {
        let mut builder = Request::builder().uri(uri);
        if let Some(bearer) = bearer {
            builder = builder.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
        }
        builder.body(axum::body::Body::empty()).expect("request")
    }

    #[tokio::test]
    async fn token_protects_api_routes_but_not_health_or_static() {
        let webui_dir = Path::new("/nonexistent-webui-for-router-test");
        let token = AuthToken::new("router-token").expect("token");
        let app = app_router_with_token(fake_app_state(), webui_dir, Some(token));

        let (status, body) = call(app.clone(), request("/api/v1/threads", None)).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert!(body.contains("unauthorized"));

        let (status, _) = call(app.clone(), request("/health", None)).await;
        assert_eq!(status, StatusCode::OK);

        let (status, _) = call(app, request("/api/v1/threads", Some("router-token"))).await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn token_also_protects_the_approvals_snapshot_route() {
        let webui_dir = Path::new("/nonexistent-webui-for-router-test");
        let token = AuthToken::new("router-token").expect("token");
        let app = app_router_with_token(fake_app_state(), webui_dir, Some(token));

        let (status, _) = call(
            app.clone(),
            request("/api/v1/approvals?state=pending", None),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let (status, _) = call(
            app,
            request("/api/v1/approvals?state=pending", Some("router-token")),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
    }

    #[tokio::test]
    async fn no_token_router_is_unchanged() {
        let webui_dir = Path::new("/nonexistent-webui-for-router-test");
        let app = app_router_with_token(fake_app_state(), webui_dir, None);
        let (status, _) = call(app, request("/api/v1/threads", None)).await;
        assert_eq!(status, StatusCode::OK);
    }
}
