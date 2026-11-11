//! `pharos-web` — S4 static Web UI + HTTP/WS API binary.
//!
//! By default the binary serves **real** durable S1/S2 services built through
//! `pharos_http::services::build_real_app_state` (Thread replica under
//! `--data-dir`, optional live Session adapter via `--session-adapter`).
//! `--fake` is an explicit, logged opt-in to the in-memory fixture services.
//!
//! Non-loopback binds require `--token` / `PHAROS_WEB_TOKEN`; the API then
//! requires a bearer token while the static page and `/health` stay reachable.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;
use pharos_http::services::{RealOptions, SessionAdapterChoice, build_real_app_state};
use pharos_web::AuthToken;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "pharos-web",
    about = "Pharos S4 web server (HTTP/WS + static UI)"
)]
struct Args {
    /// Listen address (default 127.0.0.1:8787). Non-loopback binds require a token.
    #[arg(long, env = "PHAROS_WEB_ADDR", default_value = "127.0.0.1:8787")]
    addr: SocketAddr,

    /// Static Web UI root (copy of WebCanvas). Overrides PHAROS_WEBUI_DIR.
    #[arg(long, env = "PHAROS_WEBUI_DIR")]
    webui_dir: Option<PathBuf>,

    /// Durable data dir (Thread replica + goals). Default: platform app-data dir.
    #[arg(long, env = "PHAROS_WEB_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// Use in-memory *fake* S1/S2 services instead of the real durable backend.
    /// Data is NOT persisted; logs a warning at startup.
    #[arg(long)]
    fake: bool,

    /// Bearer token required on API routes. Also PHAROS_WEB_TOKEN.
    #[arg(long, env = "PHAROS_WEB_TOKEN")]
    token: Option<String>,

    /// Live vendor Session adapter: `none` or `codex` (default `none`).
    #[arg(long, env = "PHAROS_WEB_SESSION_ADAPTER", default_value = "none")]
    session_adapter: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse()?))
        .init();

    let args = Args::parse();
    let webui_dir = pharos_web::resolve_webui_dir(args.webui_dir)?;

    let data_dir = match args.data_dir {
        Some(data_dir) => data_dir,
        None => pharos_web::default_data_dir()?,
    };

    // A blank token is a configuration error, not "no auth".
    let token = match args.token.as_deref() {
        Some(raw) => {
            Some(AuthToken::new(raw).map_err(|error| format!("invalid --token: {error}"))?)
        }
        None => None,
    };

    pharos_web::validate_bind(args.addr, token.as_ref())?;
    if !args.addr.ip().is_loopback() && token.is_some() {
        tracing::warn!(
            addr = %args.addr,
            "pharos-web binding a non-loopback address; API requires the bearer token"
        );
    }
    if args.addr.ip().is_unspecified() {
        tracing::warn!(
            addr = %args.addr,
            "pharos-web binding 0.0.0.0/::; make sure the token is only shared over a trusted network"
        );
    }

    let session_adapter = SessionAdapterChoice::parse(&args.session_adapter)?;

    let state = if args.fake {
        tracing::warn!(
            data_dir = %data_dir.display(),
            "pharos-web --fake: using in-memory FakeThreadService + FakeSessionService; data will NOT persist"
        );
        pharos_web::fake_app_state()
    } else {
        tracing::info!(
            data_dir = %data_dir.display(),
            session_adapter = session_adapter.as_str(),
            "pharos-web using real durable S1/S2 services"
        );
        build_real_app_state(
            RealOptions::new(data_dir.clone()).with_session_adapter(session_adapter),
        )
        .map_err(|error| {
            format!(
                "failed to open real backend under {}: {error}",
                data_dir.display()
            )
        })?
    };

    tracing::info!(
        addr = %args.addr,
        webui = %webui_dir.display(),
        data_dir = %data_dir.display(),
        fake = args.fake,
        auth = token.is_some(),
        "pharos-web listening"
    );

    pharos_web::serve_with_token(args.addr, webui_dir, state, token).await
}
