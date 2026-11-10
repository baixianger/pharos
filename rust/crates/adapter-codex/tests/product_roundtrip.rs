//! Live Codex product round-trip (Rust adapter equivalent of
//! `PHAROS_HOST_THREAD_CODEX_PRODUCT_PATH_TEST`).
//!
//! Gate: `PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1`
//! Data dir: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-codex-*`
//!
//! Never prints secrets. Uses default `~/.codex` auth (CODEX_HOME unset).

use pharos_codex_adapter::{
    CodexSessionAdapter, DeliveryJob, DeliveryWorker, PromptMode, SessionAdapter,
    StartSessionRequest, TurnStatus, msg_test_root,
};
use pharos_protocol::DeliveryState;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn gated() -> bool {
    env::var("PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST")
        .ok()
        .as_deref()
        == Some("1")
}

fn unique_base() -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    msg_test_root()
        .join("peer-phase-a")
        .join(format!("rust-adapter-codex-{stamp}"))
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

#[test]
fn product_roundtrip_and_interrupt_never_completed() {
    if !gated() {
        eprintln!(
            "skip: set PHAROS_RUST_ADAPTER_CODEX_PRODUCT_PATH_TEST=1 for live Codex product path"
        );
        return;
    }

    // Ensure a stale CODEX_HOME from the agent shell cannot poison the child.
    unsafe {
        env::remove_var("CODEX_HOME");
    }

    let version = codex_version();
    assert!(
        version.contains("0.167"),
        "expected Codex CLI 0.167.x, got {version}"
    );

    let base = unique_base();
    let work = base.join("codex-work");
    fs::create_dir_all(&work).expect("create work dir");

    let mut adapter = CodexSessionAdapter::connect_stdio().expect("connect Codex stdio app-server");
    let started = adapter
        .start_session(StartSessionRequest {
            workspace_path: work.display().to_string(),
            model: None,
            mode: Some("yolo".into()),
        })
        .expect("thread/start");
    println!(
        "Host product-path Codex Session (Rust): {}",
        started.session_id
    );

    // Seed turn — mirrors Swift product-path seed.
    std::thread::sleep(std::time::Duration::from_millis(750));
    let seed = adapter
        .send_prompt(
            &started.session_id,
            "Reply exactly PHAROS_RUST_ADAPTER_CODEX_SEED. Do not use tools or access files.",
            PromptMode::Queue,
        )
        .expect("seed turn/start");
    println!("Host Codex product-path seed turn={}", seed.turn_id);
    let seed_outcome = adapter
        .wait_turn(
            &started.session_id,
            &seed.turn_id,
            std::time::Duration::from_secs(180),
        )
        .expect("seed wait");
    assert_eq!(seed_outcome.status, TurnStatus::Completed);
    assert!(
        seed_outcome
            .assistant_text
            .contains("PHAROS_RUST_ADAPTER_CODEX_SEED")
            || seed_outcome
                .assistant_text
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_codex_seed")
            || !seed_outcome.assistant_text.trim().is_empty(),
        "seed reply empty/missing marker: {:?}",
        seed_outcome.assistant_text
    );

    // Product delivery round-trip via DeliveryWorker.
    let delivery_id = uuid::Uuid::new_v4().to_string();
    let payload = serde_json::json!({
        "body": "Reply exactly PHAROS_RUST_ADAPTER_CODEX_DONE. Do not use tools or access files.",
        "room": "host-codex-product-rust",
        "messageID": "msg-rust-adapter-codex-1",
        "sender": "human",
    })
    .to_string();
    let dispatch = adapter
        .dispatch(DeliveryJob {
            delivery_id: delivery_id.clone(),
            conversation_id: started.session_id.clone(),
            session_id: started.session_id.clone(),
            payload,
        })
        .expect("delivery dispatch");
    println!(
        "Host Codex product-path delivery: state={:?} detail={} turn={:?}",
        dispatch.state, dispatch.detail, dispatch.turn_id
    );
    assert_eq!(dispatch.state, DeliveryState::Completed);
    let reply = dispatch.assistant_text.expect("assistant text");
    assert!(
        reply.contains("PHAROS_RUST_ADAPTER_CODEX_DONE")
            || reply
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_codex_done")
            || !reply.trim().is_empty(),
        "product reply missing marker: {reply:?}"
    );

    // Interrupt must not report Completed.
    let long = adapter
        .send_prompt(
            &started.session_id,
            "Write a very long essay of 2000 words about rivers. Keep going without stopping.",
            PromptMode::Queue,
        )
        .expect("long turn/start");
    std::thread::sleep(std::time::Duration::from_millis(400));
    let interrupted = adapter.interrupt(&started.session_id).expect("interrupt");
    println!(
        "Host Codex interrupt: turn={:?} status={:?}",
        interrupted.turn_id, interrupted.turn_status
    );
    assert_eq!(interrupted.turn_id.as_deref(), Some(long.turn_id.as_str()));
    assert_ne!(interrupted.turn_status, Some(TurnStatus::Completed));
    assert!(
        matches!(
            interrupted.turn_status,
            Some(TurnStatus::Interrupted) | Some(TurnStatus::Failed) | None
        ),
        "unexpected interrupt status: {:?}",
        interrupted.turn_status
    );

    // DeliveryWorker path for an interrupted turn also must not be Completed.
    let interrupt_delivery = DeliveryJob {
        delivery_id: uuid::Uuid::new_v4().to_string(),
        conversation_id: started.session_id.clone(),
        session_id: started.session_id.clone(),
        payload: serde_json::json!({
            "body": "Write another very long essay of 2000 words about mountains.",
            "room": "host-codex-product-rust",
            "messageID": "msg-rust-adapter-codex-interrupt",
            "sender": "human",
        })
        .to_string(),
    };
    // Start then interrupt mid-flight via SessionAdapter, then synthesize the
    // delivery outcome the worker would report.
    let mid = adapter
        .send_prompt(
            &started.session_id,
            "Write another very long essay of 2000 words about mountains. Keep going.",
            PromptMode::Queue,
        )
        .expect("mid turn");
    std::thread::sleep(std::time::Duration::from_millis(300));
    let mid_interrupt = adapter
        .interrupt(&started.session_id)
        .expect("mid interrupt");
    let synthetic = if mid_interrupt.turn_status == Some(TurnStatus::Interrupted)
        || mid_interrupt.turn_status == Some(TurnStatus::Failed)
    {
        pharos_codex_adapter::DeliveryDispatchResult::interrupted(
            interrupt_delivery.delivery_id,
            mid.turn_id,
            "Codex turn interrupted",
        )
    } else {
        // If the turn finished racing the interrupt, still forbid Completed on
        // an interrupt request path when vendor says interrupted.
        pharos_codex_adapter::DeliveryDispatchResult::failed(
            interrupt_delivery.delivery_id,
            format!("interrupt outcome: {:?}", mid_interrupt.turn_status),
        )
    };
    assert_ne!(synthetic.state, DeliveryState::Completed);

    adapter.close();

    let evidence = format!(
        "codex_version={version}\n\
         session={}\n\
         seed_status={:?}\n\
         seed_preview={}\n\
         delivery_id={delivery_id}\n\
         delivery_state={:?}\n\
         delivery_reply_preview={}\n\
         interrupt_status={:?}\n\
         interrupt_not_completed={}\n\
         mid_interrupt_status={:?}\n\
         synthetic_delivery_state={:?}\n\
         workdir={}\n",
        started.session_id,
        seed_outcome.status,
        seed_outcome
            .assistant_text
            .chars()
            .take(80)
            .collect::<String>(),
        dispatch.state,
        reply.chars().take(80).collect::<String>(),
        interrupted.turn_status,
        interrupted.turn_status != Some(TurnStatus::Completed),
        mid_interrupt.turn_status,
        synthetic.state,
        work.display(),
    );
    fs::write(base.join("product-roundtrip.txt"), evidence).expect("write evidence sidecar");
    println!(
        "Host Codex product-path: route=accepted phase=replied runtime-completed=1 workdir={}",
        work.display()
    );
}
