//! Integration gate for the `integrate-dsh3` merge.
//!
//! Two requirements that only make sense once the HITL-persistence and
//! real-session streams are merged:
//!
//! 1. In the **real** (non `--fake`) backend mode, a pending HITL approval is
//!    durable: after the server is stopped and a fresh `AppState` is opened on
//!    the same data dir, `GET /api/v1/approvals?state=pending` still lists it.
//! 2. When the server is bound to a non-loopback address with a token, the
//!    approvals routes require `Authorization: Bearer …` (401 without it, 200
//!    with it), while `/health` stays unauthenticated.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use pharos_api::{ApprovalKind, ApprovalRequest, ClientEvent};
use pharos_http::services::SessionAdapterChoice;
use pharos_web::{
    AuthToken, PENDING_APPROVALS_FILE, real_app_state, resolve_webui_dir, serve_ephemeral,
    serve_with_token,
};
use serde_json::{Value, json};
use tempfile::TempDir;

const APPROVAL_ID: &str = "integrate-dsh3-real-pending";
const SESSION_ID: &str = "real-session-1";

fn webui() -> PathBuf {
    resolve_webui_dir(None).expect("webui/ must exist at repo root")
}

fn approval(approval_id: &str) -> ApprovalRequest {
    ApprovalRequest {
        approval_id: approval_id.to_string(),
        session_id: SESSION_ID.to_string(),
        kind: ApprovalKind::ToolPermission {
            tool_name: "shell".to_string(),
            params: json!({ "command": "printf PHAROS_INTEGRATE_DSH3_OK" }),
            explanation: Some("merge gate pending approval".to_string()),
        },
        available_choices: Some(vec!["allowedOnce".to_string(), "rejected".to_string()]),
    }
}

async fn snapshot(base: &str) -> Value {
    reqwest::get(format!("{base}/api/v1/approvals?state=pending"))
        .await
        .expect("snapshot request")
        .error_for_status()
        .expect("snapshot status")
        .json()
        .await
        .expect("snapshot json")
}

fn real_state_with_retry(data_dir: &std::path::Path) -> pharos_http::AppState {
    // A just-aborted server task can still hold the SQLite files for a moment;
    // retry the reopen instead of flaking on OS-level lock release.
    let mut last_error = String::new();
    for attempt in 0..40 {
        match real_app_state(data_dir, SessionAdapterChoice::None) {
            Ok(state) => return state,
            Err(error) => {
                last_error = error;
                if attempt + 1 < 40 {
                    std::thread::sleep(Duration::from_millis(50));
                }
            }
        }
    }
    panic!(
        "reopening real state at {} failed after retries: {last_error}",
        data_dir.display()
    );
}

#[tokio::test]
async fn real_mode_pending_approval_survives_restart() {
    let dir = TempDir::new().expect("tempdir");

    // --- First "process": real durable S1/S2 + durable approval store -------
    let state = real_app_state(dir.path(), SessionAdapterChoice::None).expect("first real state");
    // The real backend must be in use, not the fake fixture services.
    assert!(dir.path().join("mesh/replica.sqlite3").is_file());
    assert!(dir.path().join("mesh/goals.sqlite3").is_file());

    let events = state.events.clone();
    let (addr, handle) = serve_ephemeral(webui(), state).await.expect("first server");
    let base = format!("http://{addr}");
    events.publish(ClientEvent::ApprovalRequired {
        approval: approval(APPROVAL_ID),
    });
    tokio::time::sleep(Duration::from_millis(150)).await;

    let listed = snapshot(&base).await;
    let list = listed["approvals"].as_array().expect("approvals array");
    assert_eq!(
        list.len(),
        1,
        "approval tap must persist the pending approval"
    );
    assert_eq!(list[0]["approvalId"], APPROVAL_ID);
    assert_eq!(list[0]["sessionId"], SESSION_ID);
    assert_eq!(list[0]["state"], "pending");
    // The approval tap materialized the durable store inside the same data dir.
    assert!(dir.path().join(PENDING_APPROVALS_FILE).is_file());

    // --- Restart: fresh AppState from the same data dir ---------------------
    handle.abort();
    tokio::time::sleep(Duration::from_millis(150)).await;

    let restarted = real_state_with_retry(dir.path());
    let (addr, handle) = serve_ephemeral(webui(), restarted)
        .await
        .expect("restarted server");
    let base = format!("http://{addr}");

    let after_restart = snapshot(&base).await;
    let list = after_restart["approvals"]
        .as_array()
        .expect("approvals array");
    assert_eq!(
        list.len(),
        1,
        "pending approval must survive a restart in real (non --fake) mode"
    );
    assert_eq!(list[0]["approvalId"], APPROVAL_ID);
    assert_eq!(list[0]["state"], "pending");

    // The single data dir also holds the real Thread replica: no separate
    // data-dir flag was introduced for approvals.
    assert!(dir.path().join("mesh/replica.sqlite3").is_file());

    handle.abort();
}

/// Reserve a free non-loopback port, then let `serve_with_token` bind it.
fn reserve_non_loopback_addr() -> SocketAddr {
    let probe = std::net::TcpListener::bind("0.0.0.0:0").expect("probe bind");
    let addr = probe.local_addr().expect("probe addr");
    drop(probe);
    assert!(
        !addr.ip().is_loopback(),
        "test requires a non-loopback wildcard bind"
    );
    addr
}

#[tokio::test]
async fn approvals_routes_require_bearer_on_non_loopback_bind() {
    let dir = TempDir::new().expect("tempdir");
    let state = real_app_state(dir.path(), SessionAdapterChoice::None).expect("real state");
    let token = AuthToken::new("integrate-dsh3-token").expect("token");
    let addr = reserve_non_loopback_addr();

    // Without a token a public bind is refused outright (defense in depth).
    assert!(
        pharos_web::validate_bind(addr, None).is_err(),
        "non-loopback bind without a token must be refused"
    );

    let server = tokio::spawn(serve_with_token(addr, webui(), state, Some(token.clone())));
    let base = format!("http://127.0.0.1:{}", addr.port());

    // Wait for the listener to come up.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .expect("client");
    let mut up = false;
    for _ in 0..100 {
        if client.get(format!("{base}/health")).send().await.is_ok() {
            up = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(up, "server did not start on {base}");

    // /health stays public even with a token configured.
    let health = client
        .get(format!("{base}/health"))
        .send()
        .await
        .expect("health");
    assert_eq!(health.status(), reqwest::StatusCode::OK);

    // Approvals snapshot is protected by the bearer layer.
    let unauthenticated = client
        .get(format!("{base}/api/v1/approvals?state=pending"))
        .send()
        .await
        .expect("unauth approvals");
    assert_eq!(
        unauthenticated.status(),
        reqwest::StatusCode::UNAUTHORIZED,
        "approvals route must require a bearer token on a non-loopback bind"
    );

    let authenticated = client
        .get(format!("{base}/api/v1/approvals?state=pending"))
        .bearer_auth(token.as_str())
        .send()
        .await
        .expect("auth approvals");
    assert_eq!(authenticated.status(), reqwest::StatusCode::OK);

    // Resolving an approval is protected too (same API-layer coverage).
    let resolve_unauthenticated = client
        .post(format!("{base}/api/v1/sessions/{SESSION_ID}/approval"))
        .json(&json!({ "approvalId": APPROVAL_ID, "decision": "rejected" }))
        .send()
        .await
        .expect("unauth resolve");
    assert_eq!(
        resolve_unauthenticated.status(),
        reqwest::StatusCode::UNAUTHORIZED
    );

    server.abort();
}
