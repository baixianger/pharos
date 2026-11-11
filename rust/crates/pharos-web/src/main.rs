//! `pharos-web` — S4 static Web UI + HTTP/WS API binary.
//!
//! By default the binary serves **real** durable S1/S2 services built through
//! `pharos_http::services::build_real_app_state` (Thread replica under
//! `--data-dir`, optional live Session adapter via `--session-adapter`).
//! `--fake` is an explicit, logged opt-in to the in-memory fixture Thread /
//! Session services; pending HITL approvals are **still persisted** to
//! `<data-dir>/pending-approvals.json` in both modes.
//!
//! Non-loopback binds require `--token` / `PHAROS_WEB_TOKEN`; the API then
//! requires a bearer token while the static page and `/health` stay reachable.
//!
//! Data dir env priority: `--data-dir` > `PHAROS_WEB_DATA_DIR` (primary) >
//! `PHAROS_DATA_DIR` (legacy compat) > platform default.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;
use pharos_http::services::SessionAdapterChoice;
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

    /// Host data dir (Thread replica + goals + pending-approvals.json).
    /// Primary env: PHAROS_WEB_DATA_DIR; legacy PHAROS_DATA_DIR still honored.
    #[arg(long, env = "PHAROS_WEB_DATA_DIR")]
    data_dir: Option<PathBuf>,

    /// Use in-memory *fake* Thread/Session services instead of the real durable
    /// backend. Pending HITL approvals are still persisted to `--data-dir`.
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

    // Single data dir for Thread replica, goals and the pending-approval store.
    // `--data-dir`/PHAROS_WEB_DATA_DIR win; PHAROS_DATA_DIR is legacy compat.
    let data_dir = pharos_web::resolve_data_dir(args.data_dir)?;

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
        if args.session_adapter != "none" {
            tracing::warn!(
                session_adapter = %args.session_adapter,
                "pharos-web --fake: --session-adapter is ignored (fake in-memory sessions are used)"
            );
        }
        tracing::warn!(
            data_dir = %data_dir.display(),
            "pharos-web --fake: using in-memory FakeThreadService + FakeSessionService; \
             Thread/Session data will NOT persist (pending approvals still persist)"
        );
        pharos_web::warn_fake_services();
        pharos_web::persistent_app_state(&data_dir)?
    } else {
        tracing::info!(
            data_dir = %data_dir.display(),
            session_adapter = session_adapter.as_str(),
            "pharos-web using real durable S1/S2 services"
        );
        pharos_web::real_app_state(&data_dir, session_adapter)?
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
