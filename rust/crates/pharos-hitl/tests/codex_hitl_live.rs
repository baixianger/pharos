//! Live Codex approval round-trip via human-proxy path (msg-test only).
//!
//! Gate: `PHAROS_RUST_SESSION_HITL_LIVE=1`
//! Data: `~/personal/pharos-msg-test/peer-hitl/rust-session-hitl-*`
//!
//! Never prints secrets. Uses default `~/.codex` auth (`CODEX_HOME` unset).
//! Self-resolves `.done.md` after webhook inject (parity with S1 grokbot live
//! self-reply — does not wait a wall-clock 45m for an external operator).

use pharos_hitl::{
    CodexHitlClient, HITL_TIMEOUT_SECS, HitlBridge, HitlDecision, HitlRequest, HitlState,
    default_human_requests_dir, msg_test_root, publish_hitl_request, write_done_md,
};
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn gated() -> bool {
    env::var("PHAROS_RUST_SESSION_HITL_LIVE").ok().as_deref() == Some("1")
}

fn unique_base() -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    msg_test_root()
        .join("peer-hitl")
        .join(format!("rust-session-hitl-{stamp}"))
}

fn codex_version() -> String {
    Command::new("/opt/homebrew/bin/codex")
        .arg("--version")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .unwrap_or_else(|| "unknown".into())
        .trim()
        .to_owned()
}

/// Loopback webhook that returns HTTP 200 (ID-only wake; no secrets logged).
fn spawn_loopback_webhook() -> (String, Arc<Mutex<u32>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback webhook");
    let addr = listener.local_addr().expect("local addr");
    let hits = Arc::new(Mutex::new(0_u32));
    let hits_thread = Arc::clone(&hits);
    let handle = thread::spawn(move || {
        if let Ok((mut stream, _)) = listener.accept() {
            let mut buf = [0_u8; 4096];
            let _ = stream.read(&mut buf);
            *hits_thread.lock().unwrap() += 1;
            let body = br#"{"success":true}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                std::str::from_utf8(body).unwrap()
            );
            let _ = stream.write_all(resp.as_bytes());
        }
    });
    (format!("http://{addr}/hitl"), hits, handle)
}

#[test]
fn codex_approval_human_proxy_roundtrip() {
    if !gated() {
        eprintln!("skip: set PHAROS_RUST_SESSION_HITL_LIVE=1 for live Codex HITL path");
        return;
    }

    unsafe {
        env::remove_var("CODEX_HOME");
    }

    let version = codex_version();
    assert!(
        version.contains("0.167"),
        "expected Codex CLI 0.167.x, got {version}"
    );
    eprintln!("codex version={version}");
    eprintln!("HITL_TIMEOUT_SECS={HITL_TIMEOUT_SECS} (unit-covered; live self-resolves)");

    let base = unique_base();
    let work = base.join("work");
    fs::create_dir_all(&work).expect("work dir");
    let requests = default_human_requests_dir();
    fs::create_dir_all(&requests).expect("human-requests");

    let (webhook_url, webhook_hits, webhook_join) = spawn_loopback_webhook();
    let env_path = base.join("human-proxy-webhook.env");
    // Key is a disposable test value for loopback only — never a real secret.
    fs::write(
        &env_path,
        format!(
            "PHAROS_HUMAN_PROXY_WEBHOOK_URL={webhook_url}\nPHAROS_HUMAN_PROXY_WEBHOOK_KEY=test-loopback-key\n"
        ),
    )
    .expect("write webhook env");
    let _ = fs::set_permissions(
        &env_path,
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    );

    // Isolated CODEX_HOME so global ~/.codex config.toml (approval_policy=never)
    // cannot suppress the approval prompt.
    let codex_home = base.join("codex-home");
    let mut client =
        CodexHitlClient::connect_stdio_hitl_home(&codex_home).expect("connect codex HITL home");
    let session_id = client
        .start_session_on_request(&work)
        .expect("thread/start on-request");
    eprintln!("HITL Codex session={session_id}");

    thread::sleep(Duration::from_millis(500));
    let seed = client
        .start_turn("Reply exactly PHAROS_RUST_HITL_SEED. Do not use tools or access files.")
        .expect("seed turn");
    eprintln!("seed turn={seed}");
    let seed_status = client
        .wait_turn_terminal(&seed, Duration::from_secs(180))
        .expect("seed complete");
    eprintln!("seed status={seed_status}");
    assert_eq!(
        seed_status, "completed",
        "seed must complete before HITL prompt"
    );

    // Mirror Swift MeshHostSessionRPCTests peer HITL prompt: force escalated exec approval.
    let hitl_prompt =
        "In this disposable pharos-msg-test Session only, use exec_command to request \
         sandbox_permissions require_escalated for the harmless command \
         printf PHAROS_RUST_HITL_OK, with justification to test local HITL. \
         Do not access or modify files, use network services, or run any other command."
            .to_string();
    let turn_id = client.start_turn(&hitl_prompt).expect("hitl turn/start");
    eprintln!("hitl turn={turn_id}");

    let pending = client
        .poll_approval(Duration::from_secs(180))
        .expect("poll approval")
        .expect("expected Codex approval request for printf probe");
    eprintln!(
        "approval id={} method={} command={:?}",
        pending.approval.approval_id, pending.method, pending.command
    );

    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let request_name = format!("{stamp}_rust-air-codex-hitl.md");
    let done_path = requests.join(request_name.replace(".md", ".done.md"));
    let approve = format!(
        "pharos-hitl-self-resolve --session {session_id} --approval-id {} --decision allowedOnce --done {}",
        pending.approval.approval_id,
        done_path.display()
    );
    let reject = format!(
        "pharos-hitl-self-resolve --session {session_id} --approval-id {} --decision denied --done {}",
        pending.approval.approval_id,
        done_path.display()
    );
    let mut req = HitlRequest::new(
        request_name.clone(),
        "xiangs-macbook-air",
        session_id.clone(),
        pending.approval.approval_id.clone(),
        session_id.clone(),
        "printf PHAROS_RUST_HITL_OK",
        approve,
        reject,
        "local-air",
    );
    req.notes = vec![
        "Resolve as allowedOnce only if the pending command matches printf PHAROS_RUST_HITL_OK."
            .into(),
        "Live gate self-resolves via human-proxy file protocol (no external 45m wait).".into(),
    ];

    let (request_file, notify) =
        publish_hitl_request(&req, &requests, Some(&env_path)).expect("publish HITL request");
    eprintln!("human-request written: {}", request_file.display());

    let mut bridge = HitlBridge::default();
    let injected = bridge.apply_webhook_notify(
        &pending.approval.approval_id,
        &session_id,
        &request_name,
        "xiangs-macbook-air",
        notify.clone(),
    );
    eprintln!("HITL bridge state after webhook={injected:?} notify={notify:?}");
    assert_eq!(
        injected,
        HitlState::Injected,
        "webhook success must yield Injected"
    );
    assert!(
        *webhook_hits.lock().unwrap() >= 1,
        "loopback webhook must have been hit"
    );
    let _ = webhook_join.join();

    // Human-proxy path: write .done.md then apply decision to Codex.
    let done = write_done_md(
        &request_file,
        "allowedOnce",
        "self-resolve live gate PHAROS_RUST_HITL_OK",
    )
    .expect("write done.md");
    eprintln!("human-proxy done={}", done.display());
    let done_text = fs::read_to_string(&done).expect("read done");
    assert!(done_text.contains("decision=allowedOnce"));
    assert!(done_text.contains("pharos-proxy"));

    let resolved = bridge
        .resolve(&pending.approval.approval_id, HitlDecision::AllowedOnce)
        .expect("bridge resolve");
    assert_eq!(resolved, HitlState::AllowedOnce);

    client
        .resolve_approval(&pending, HitlDecision::AllowedOnce)
        .expect("codex resolve accept");

    let final_status = client
        .wait_turn_terminal(&turn_id, Duration::from_secs(180))
        .expect("hitl turn terminal");
    eprintln!(
        "HITL E2E: session={session_id} turn={turn_id} status={final_status} decision=allowedOnce human=pharos-proxy"
    );
    assert!(
        matches!(final_status.as_str(), "completed" | "failed"),
        "turn should reach a terminal vendor status, got {final_status}"
    );
    // completed preferred; failed still proves approval was answered (command may fail sandbox).
    let sidecar = base.join("live-roundtrip.txt");
    fs::write(
        &sidecar,
        format!(
            "session={session_id}\nturn={turn_id}\napproval={}\nstatus={final_status}\ndecision=allowedOnce\nrequest={}\n",
            pending.approval.approval_id,
            request_file.display()
        ),
    )
    .ok();
}
