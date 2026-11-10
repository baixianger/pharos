//! `pharos-web` — S4 static Web UI + HTTP/WS API binary.
//!
//! Default services are **fake** stand-ins for S1/S2 until those streams wire
//! real traits into the merge captain's `pharos-meshd` process.

use std::net::SocketAddr;
use std::path::PathBuf;

use clap::Parser;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(
    name = "pharos-web",
    about = "Pharos S4 web server (HTTP/WS + static UI)"
)]
struct Args {
    /// Listen address (default 127.0.0.1:8787).
    #[arg(long, env = "PHAROS_WEB_ADDR", default_value = "127.0.0.1:8787")]
    addr: SocketAddr,

    /// Static Web UI root (copy of WebCanvas). Overrides PHAROS_WEBUI_DIR.
    #[arg(long, env = "PHAROS_WEBUI_DIR")]
    webui_dir: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse()?))
        .init();

    let args = Args::parse();
    let webui_dir = pharos_web::resolve_webui_dir(args.webui_dir)?;
    let state = pharos_web::fake_app_state();
    tracing::warn!("pharos-web using FakeThreadService + FakeSessionService (S1/S2 not wired yet)");
    pharos_web::serve(args.addr, webui_dir, state).await
}
