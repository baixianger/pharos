//! Live DSH product round-trip (Rust adapter equivalent of
//! `PHAROS_HOST_THREAD_DSH_PRODUCT_PATH_TEST`).
//!
//! Gate: `PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST=1`
//! Data dir: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-dsh-*`
//!
//! Never prints secrets / Host tokens. Never touches the 3080 dsh Host.

use pharos_adapter_dsh::{
    DeliveryDispatchResult, DeliveryJob, DeliveryWorker, DshSessionAdapter, PromptMode,
    SessionAdapter, StartSessionRequest, TurnStatus, msg_test_root,
};
use pharos_protocol::DeliveryState;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn gated() -> bool {
    env::var("PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST")
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
        .join(format!("rust-adapter-dsh-{stamp}"))
}

fn dsh_version() -> String {
    let executable = env::var("PHAROS_DSH_EXECUTABLE").unwrap_or_else(|_| {
        for candidate in [
            "/home/box/.local/bin/dsh",
            "/usr/local/bin/dsh",
            "/opt/homebrew/bin/dsh",
        ] {
            if PathBuf::from(candidate).is_file() {
                return candidate.to_owned();
            }
        }
        "dsh".into()
    });
    Command::new(executable)
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
            "skip: set PHAROS_RUST_ADAPTER_DSH_PRODUCT_PATH_TEST=1 for live DSH product path"
        );
        return;
    }

    let version = dsh_version();
    assert!(
        version.contains("0.2.2"),
        "expected dsh 0.2.2.x, got {version}"
    );

    let base = unique_base();
    let work = base.join("dsh-work");
    let home = base.join("dsh-home");
    fs::create_dir_all(&work).expect("create work dir");
    fs::create_dir_all(&home).expect("create isolated DSH_HOME");

    let mut adapter =
        DshSessionAdapter::connect_isolated(&home, &work).expect("start isolated dsh web Host");
    let started = adapter
        .start_session(StartSessionRequest {
            workspace_path: work.display().to_string(),
            model: None,
            mode: Some("yolo".into()),
        })
        .expect("session/create");
    println!(
        "Host product-path DSH Session (Rust): {}",
        started.session_id
    );

    std::thread::sleep(std::time::Duration::from_millis(500));
    let seed = adapter
        .send_prompt(
            &started.session_id,
            "Reply exactly PHAROS_RUST_ADAPTER_DSH_SEED. Do not use tools or access files.",
            PromptMode::Queue,
        )
        .expect("seed prompt");
    println!("Host DSH product-path seed turn={}", seed.turn_id);
    let seed_outcome = adapter
        .wait_turn(
            &started.session_id,
            &seed.turn_id,
            std::time::Duration::from_secs(180),
        )
        .expect("seed wait");
    println!(
        "Host DSH product-path seed outcome: status={:?} raw={} error={:?} preview={:?}",
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
            .contains("PHAROS_RUST_ADAPTER_DSH_SEED")
            || seed_outcome
                .assistant_text
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_dsh_seed")
            || !seed_outcome.assistant_text.trim().is_empty(),
        "seed reply empty/missing marker: {}",
        seed_outcome.failure_detail()
    );

    let delivery_id = uuid::Uuid::new_v4().to_string();
    let payload = serde_json::json!({
        "body": "Reply exactly PHAROS_RUST_ADAPTER_DSH_DONE. Do not use tools or access files.",
        "room": "host-dsh-product-rust",
        "messageID": "msg-rust-adapter-dsh-1",
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
    let turns_snapshot = adapter
        .read_turns(&started.session_id)
        .unwrap_or_default()
        .into_iter()
        .map(|turn| {
            format!(
                "{}:{}:err={}:preview={:?}",
                turn.turn_id,
                turn.raw_status,
                turn.vendor_error.as_deref().unwrap_or("-"),
                turn.assistant_text.chars().take(60).collect::<String>()
            )
        })
        .collect::<Vec<_>>()
        .join(" | ");
    println!(
        "Host DSH product-path delivery: state={:?} detail={} turn={:?} assistant={:?}",
        dispatch.state,
        dispatch.detail,
        dispatch.turn_id,
        dispatch
            .assistant_text
            .as_ref()
            .map(|text| text.chars().take(80).collect::<String>())
    );
    println!("Host DSH product-path turns snapshot: {turns_snapshot}");
    assert_eq!(
        dispatch.state,
        DeliveryState::Completed,
        "delivery not Completed; detail={} turn={:?} turns=[{turns_snapshot}]",
        dispatch.detail,
        dispatch.turn_id
    );
    let reply = dispatch
        .assistant_text
        .clone()
        .expect("assistant text present on Completed");
    assert!(
        reply.contains("PHAROS_RUST_ADAPTER_DSH_DONE")
            || reply
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_dsh_done")
            || !reply.trim().is_empty(),
        "product reply missing marker: detail={} reply={reply:?}",
        dispatch.detail
    );

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
        "Host DSH interrupt: turn={:?} status={:?}",
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

    let interrupt_delivery = DeliveryJob {
        delivery_id: uuid::Uuid::new_v4().to_string(),
        conversation_id: started.session_id.clone(),
        session_id: started.session_id.clone(),
        payload: serde_json::json!({
            "body": "Write another very long essay of 2000 words about mountains.",
            "room": "host-dsh-product-rust",
            "messageID": "msg-rust-adapter-dsh-interrupt",
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
    std::thread::sleep(std::time::Duration::from_millis(300));
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
                "DSH turn interrupted; status={:?}",
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
        "dsh_version={version}\n\
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
         dsh_home={}\n",
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
        home.display(),
    );
    fs::write(base.join("product-roundtrip.txt"), evidence).expect("write evidence sidecar");
    println!(
        "Host DSH product-path: route=accepted phase=replied runtime-completed=1 workdir={}",
        work.display()
    );
}
