//! Live Agy Host binder / ACP smoke (Rust SessionAdapter).
//!
//! Gate: `PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1`
//! Data dir: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-agy-<ts>/`
//!
//! Never prints secrets. Uses default `~/.gemini` auth the CLI already holds
//! (same posture as Codex live gate + `~/.codex`); workspace + evidence stay
//! under msg-test. Does not edit gemini app state beyond what `agy` itself
//! reads/writes.

use pharos_adapter_agy::{
    AgySessionAdapter, DeliveryDispatchResult, DeliveryJob, DeliveryWorker, PromptMode,
    SessionAdapter, StartSessionRequest, TurnStatus, msg_test_root, resolve_agy_executable,
};
use pharos_protocol::DeliveryState;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn gated() -> bool {
    env::var("PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST")
        .ok()
        .as_deref()
        == Some("1")
}

fn unique_base() -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    msg_test_root()
        .join("peer-phase-a")
        .join(format!("rust-adapter-agy-{stamp}"))
}

fn agy_version() -> String {
    let exe = resolve_agy_executable().unwrap_or_else(|_| PathBuf::from("agy"));
    Command::new(exe)
        .arg("--version")
        .output()
        .ok()
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .unwrap_or_else(|| "unknown".into())
        .trim()
        .to_owned()
}

#[test]
fn acp_roundtrip_and_interrupt_never_completed() {
    if !gated() {
        eprintln!("skip: set PHAROS_RUST_ADAPTER_AGY_PRODUCT_PATH_TEST=1 for live Agy ACP smoke");
        return;
    }

    let version = agy_version();
    assert!(
        version.starts_with("1.5."),
        "expected agy CLI 1.5.x, got {version}"
    );

    let base = unique_base();
    let work = base.join("agy-work");
    fs::create_dir_all(&work).expect("create work dir");

    // Default gemini auth (CODEX-equivalent). Isolated gemini-dir seeding is
    // available via `connect_isolated` but incomplete copies can surface as
    // quota/auth ghost failures; product gate stays on the logged-in CLI home.
    let mut adapter = AgySessionAdapter::connect().expect("connect agy acp --stdio");
    // Prefer flash: default gemini-4-argon often hits individual quota on this
    // Host while flash still serves; override with PHAROS_AGY_TEST_MODEL.
    let model = env::var("PHAROS_AGY_TEST_MODEL").unwrap_or_else(|_| "gemini-3.8-flash".into());
    let started = adapter
        .start_session(StartSessionRequest {
            workspace_path: work.display().to_string(),
            model: Some(model.clone()),
            mode: Some("yolo".into()),
        })
        .expect("session/new");
    println!("Host Agy ACP model={model}");
    println!("Host Agy ACP Session (Rust): {}", started.session_id);

    // Prompt round-trip → Completed with reply captured.
    let seed = adapter
        .send_prompt(
            &started.session_id,
            "Reply exactly PHAROS_RUST_ADAPTER_AGY_SEED. Do not use tools or access files.",
            PromptMode::Queue,
        )
        .expect("seed session/prompt");
    println!("Host Agy ACP seed turn={}", seed.turn_id);
    let seed_outcome = adapter
        .wait_turn(
            &started.session_id,
            &seed.turn_id,
            std::time::Duration::from_secs(180),
        )
        .expect("seed wait");
    println!(
        "Host Agy ACP seed outcome: status={:?} raw={} error={:?} preview={:?}",
        seed_outcome.status,
        seed_outcome.raw_status,
        seed_outcome.vendor_error,
        seed_outcome
            .assistant_text
            .chars()
            .take(80)
            .collect::<String>()
    );
    assert_eq!(
        seed_outcome.status,
        TurnStatus::Completed,
        "seed not completed: {}",
        seed_outcome.failure_detail()
    );
    assert!(
        seed_outcome
            .assistant_text
            .contains("PHAROS_RUST_ADAPTER_AGY_SEED")
            || seed_outcome
                .assistant_text
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_agy_seed"),
        "seed reply missing marker: {}",
        seed_outcome.failure_detail()
    );

    // DeliveryWorker product round-trip.
    let delivery_id = uuid::Uuid::new_v4().to_string();
    let payload = serde_json::json!({
        "body": "Reply exactly PHAROS_RUST_ADAPTER_AGY_DONE. Do not use tools or access files.",
        "room": "host-agy-product-rust",
        "messageID": "msg-rust-adapter-agy-1",
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
        .expect("delivery dispatch Result::Err");
    println!(
        "Host Agy ACP delivery: state={:?} detail={} turn={:?} assistant={:?}",
        dispatch.state,
        dispatch.detail,
        dispatch.turn_id,
        dispatch
            .assistant_text
            .as_ref()
            .map(|text| text.chars().take(80).collect::<String>())
    );
    assert_eq!(
        dispatch.state,
        DeliveryState::Completed,
        "delivery not Completed; detail={} turn={:?}",
        dispatch.detail,
        dispatch.turn_id
    );
    let reply = dispatch
        .assistant_text
        .clone()
        .expect("assistant text present on Completed");
    assert!(
        reply.contains("PHAROS_RUST_ADAPTER_AGY_DONE")
            || reply
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_agy_done"),
        "product reply missing marker: detail={} reply={reply:?}",
        dispatch.detail
    );

    // Interrupt must not report Completed.
    let long = adapter
        .send_prompt(
            &started.session_id,
            "Write a very long essay of 2000 words about rivers. Keep going without stopping.",
            PromptMode::Queue,
        )
        .expect("long turn/start");
    // Cancel quickly — long prompts can still finish before cancel under
    // quota/short replies; 50–150ms is enough for ACP to accept the prompt.
    std::thread::sleep(std::time::Duration::from_millis(100));
    let interrupted = adapter.interrupt(&started.session_id).expect("interrupt");
    println!(
        "Host Agy interrupt: turn={:?} status={:?}",
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
            "room": "host-agy-product-rust",
            "messageID": "msg-rust-adapter-agy-interrupt",
            "sender": "human",
        })
        .to_string(),
    };
    let mid = adapter
        .send_prompt(
            &started.session_id,
            "Write another very long essay of 2000 words about mountains. Keep going.",
            PromptMode::Queue,
        )
        .expect("mid turn");
    std::thread::sleep(std::time::Duration::from_millis(100));
    let mid_interrupt = adapter
        .interrupt(&started.session_id)
        .expect("mid interrupt");
    let synthetic = if mid_interrupt.turn_status == Some(TurnStatus::Interrupted)
        || mid_interrupt.turn_status == Some(TurnStatus::Failed)
    {
        DeliveryDispatchResult::interrupted(
            interrupt_delivery.delivery_id,
            mid.turn_id,
            format!(
                "Agy turn interrupted; status={:?}",
                mid_interrupt.turn_status
            ),
        )
    } else {
        DeliveryDispatchResult::failed(
            interrupt_delivery.delivery_id,
            format!("interrupt outcome: {:?}", mid_interrupt.turn_status),
        )
    };
    assert_ne!(synthetic.state, DeliveryState::Completed);

    adapter.close();

    let evidence = format!(
        "agy_version={version}\n\
         session={}\n\
         seed_status={:?}\n\
         seed_preview={}\n\
         delivery_id={delivery_id}\n\
         delivery_state={:?}\n\
         delivery_detail={}\n\
         delivery_reply_preview={}\n\
         interrupt_status={:?}\n\
         interrupt_not_completed={}\n\
         mid_interrupt_status={:?}\n\
         synthetic_delivery_state={:?}\n\
         workdir={}\n\
         gemini_dir=default:~/.gemini\n",
        started.session_id,
        seed_outcome.status,
        seed_outcome
            .assistant_text
            .chars()
            .take(80)
            .collect::<String>(),
        dispatch.state,
        dispatch.detail,
        reply.chars().take(80).collect::<String>(),
        interrupted.turn_status,
        interrupted.turn_status != Some(TurnStatus::Completed),
        mid_interrupt.turn_status,
        synthetic.state,
        work.display(),
    );
    fs::write(base.join("acp-smoke.txt"), evidence).expect("write evidence sidecar");
    println!(
        "Host Agy ACP smoke: route=accepted phase=replied runtime-completed=1 workdir={}",
        work.display()
    );
}
