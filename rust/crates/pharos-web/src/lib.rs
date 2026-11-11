//! RFC-007 Stream S4 — compose HTTP/WS API with static Web UI assets.
//!
//! Static root is a copy of `Sources/Pharos/Resources/WebCanvas` into repo
//! `webui/` (Swift copies are not edited by this stream).
//!
//! The `pharos-web` binary serves **real** S1/S2 services by default through
//! `pharos_http::services::build_real_app_state` (durable Thread store +
//! explicitly configured session adapter). [`fake_app_state`] remains for the
//! explicit `--fake` offline mode and the S4 acceptance tests; nothing here
//! silently substitutes fakes for real data.
//!
//! When non-loopback binds are used, [`app_router_with_token`] /
//! [`serve_with_token`] require a bearer token on API routes and
//! [`validate_bind`] refuses unauthenticated public binds.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use axum::{Router, response::Redirect, routing::get};
use pharos_http::{AppState, EventBus, FakeSessionService, FakeThreadService, api_router};
use pharos_store_schema::paths::WEBUI_DIR;
use tower_http::services::{ServeDir, ServeFile};
use tracing::info;

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

/// Construct AppState wired to **fake** S1/S2 services.
///
/// Only used by the explicit `--fake` offline mode and S4 acceptance tests;
/// the default binary uses `build_real_app_state` instead.
pub fn fake_app_state() -> AppState {
    let events = EventBus::new(64);
    let threads = Arc::new(FakeThreadService::new(events.clone()));
    let sessions = Arc::new(FakeSessionService::new(events.clone()));
    AppState::new(threads, sessions, events)
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

/// Default on-disk root for durable data (Thread replica, goals, sessions).
///
/// Order:
/// 1. `PHAROS_WEB_DATA_DIR` env override
/// 2. macOS: `~/Library/Application Support/Pharos`
/// 3. other Unix: `$XDG_DATA_HOME/pharos`, else `~/.local/share/pharos`
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
            "HOME is not set and PHAROS_WEB_DATA_DIR was not provided; \
             set --data-dir/PHAROS_WEB_DATA_DIR"
                .to_string()
        })
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
/// without auth, even if a caller skipped [`validate_bind`].
pub async fn serve_with_token(
    addr: SocketAddr,
    webui_dir: PathBuf,
    state: AppState,
    token: Option<AuthToken>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    validate_bind(addr, token.as_ref())?;
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

    // --- default_data_dir --------------------------------------------------

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
    async fn no_token_router_is_unchanged() {
        let webui_dir = Path::new("/nonexistent-webui-for-router-test");
        let app = app_router_with_token(fake_app_state(), webui_dir, None);
        let (status, _) = call(app, request("/api/v1/threads", None)).await;
        assert_eq!(status, StatusCode::OK);
    }
}
