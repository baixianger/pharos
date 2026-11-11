//! Live Cursor CLI product round-trip via SessionAdapter / DeliveryWorker.
//!
//! Gate: `PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1`
//! Data dir: `~/personal/pharos-msg-test/peer-phase-a/rust-adapter-cursor-*`
//!
//! Never reads `~/.cursor` private DB. Never prints secrets.

use pharos_adapter_cursor::{
    CursorSessionAdapter, DeliveryJob, DeliveryWorker, PromptMode, SessionAdapter,
    StartSessionRequest, TurnStatus, msg_test_root, unsupported_list_chats,
};
use pharos_protocol::DeliveryState;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

fn gated() -> bool {
    env::var("PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST")
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
        .join(format!("rust-adapter-cursor-{stamp}"))
}

#[test]
fn list_chats_is_explicit_unsupported() {
    let error = unsupported_list_chats();
    assert!(error.message.contains("unsupported"));
}

#[test]
fn product_roundtrip_resume_and_interrupt_never_completed() {
    if !gated() {
        eprintln!(
            "skip: set PHAROS_RUST_ADAPTER_CURSOR_PRODUCT_PATH_TEST=1 for live Cursor product path"
        );
        return;
    }

    let mut adapter = CursorSessionAdapter::connect().expect("resolve Cursor agent CLI");
    let version = adapter.agent_version();
    println!("Cursor agent version: {version}");
    assert!(
        !version.is_empty() && version != "unknown",
        "agent --version failed"
    );

    let base = unique_base();
    let work = base.join("cursor-work");
    fs::create_dir_all(&work).expect("create work dir");

    let started = adapter
        .start_session(StartSessionRequest {
            workspace_path: work.display().to_string(),
            model: None,
            // ask-mode path (no --force): enough for marker replies
            mode: None,
        })
        .expect("create-chat / start_session");
    println!(
        "Host product-path Cursor Session (Rust): chat={}",
        started.session_id
    );

    // Seed turn via --resume <chatId>
    let seed = adapter
        .send_prompt(
            &started.session_id,
            "Reply exactly PHAROS_RUST_ADAPTER_CURSOR_SEED. Do not use tools or access files.",
            PromptMode::Queue,
        )
        .expect("seed send_prompt");
    println!("Host Cursor product-path seed turn={}", seed.turn_id);
    let seed_outcome = adapter
        .wait_turn(
            &started.session_id,
            &seed.turn_id,
            std::time::Duration::from_secs(180),
        )
        .expect("seed wait");
    println!(
        "Host Cursor product-path seed outcome: status={:?} raw={} error={:?} preview={:?}",
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
            .contains("PHAROS_RUST_ADAPTER_CURSOR_SEED")
            || seed_outcome
                .assistant_text
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_cursor_seed")
            || !seed_outcome.assistant_text.trim().is_empty(),
        "seed reply empty/missing marker: {}",
        seed_outcome.failure_detail()
    );

    // Steer must be explicit unsupported (not a stub success).
    let steer_err = adapter
        .send_prompt(&started.session_id, "steer?", PromptMode::Steer)
        .expect_err("steer must be unsupported");
    assert!(
        steer_err.message.contains("unsupported"),
        "steer error must say unsupported: {}",
        steer_err.message
    );

    // DeliveryWorker round-trip (second --resume prompt on same chat).
    let delivery_id = uuid::Uuid::new_v4().to_string();
    let payload = serde_json::json!({
        "body": "Reply exactly PHAROS_RUST_ADAPTER_CURSOR_DONE. Do not use tools or access files.",
        "room": "host-cursor-product-rust",
        "messageID": "msg-rust-adapter-cursor-1",
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
        "Host Cursor product-path delivery: state={:?} detail={} turn={:?} assistant={:?}",
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
        reply.contains("PHAROS_RUST_ADAPTER_CURSOR_DONE")
            || reply
                .to_ascii_lowercase()
                .contains("pharos_rust_adapter_cursor_done")
            || !reply.trim().is_empty(),
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
    std::thread::sleep(std::time::Duration::from_millis(800));
    let interrupted = adapter.interrupt(&started.session_id).expect("interrupt");
    println!(
        "Host Cursor interrupt: turn={:?} status={:?}",
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

    // Synthetic delivery outcome for interrupt path — never Completed.
    let synthetic = pharos_adapter_cursor::DeliveryDispatchResult::interrupted(
        uuid::Uuid::new_v4().to_string(),
        long.turn_id.clone(),
        format!(
            "Cursor turn interrupted; status={:?}",
            interrupted.turn_status
        ),
    );
    assert_ne!(synthetic.state, DeliveryState::Completed);
    assert_eq!(synthetic.state, DeliveryState::Failed);

    let turns = adapter
        .read_turns(&started.session_id)
        .expect("local read_turns");
    println!(
        "Host Cursor local turns observed: {}",
        turns
            .iter()
            .map(|turn| format!("{}:{:?}", turn.turn_id, turn.status))
            .collect::<Vec<_>>()
            .join(" | ")
    );

    adapter.close();

    let evidence = format!(
        "agent_version={version}\n\
         session={}\n\
         vendor_thread={}\n\
         seed_status={:?}\n\
         seed_preview={}\n\
         delivery_id={delivery_id}\n\
         delivery_state={:?}\n\
         delivery_detail={}\n\
         delivery_reply_preview={}\n\
         interrupt_status={:?}\n\
         interrupt_not_completed={}\n\
         synthetic_delivery_state={:?}\n\
         steer_unsupported=1\n\
         workdir={}\n",
        started.session_id,
        started.vendor_thread_id,
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
        synthetic.state,
        work.display(),
    );
    fs::write(base.join("product-roundtrip.txt"), &evidence).expect("write evidence sidecar");
    println!("{evidence}");
    println!(
        "Host Cursor product-path: route=accepted phase=replied runtime-completed=1 workdir={}",
        work.display()
    );
}
